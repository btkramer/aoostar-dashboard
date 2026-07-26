#!/usr/bin/env bash
# Daily-cadence container image update check via registry digest comparison.
# Deliberately NOT run on the fast 5s loop -- each container costs one or two
# HTTPS calls to its registry, which would risk rate limits (notably Docker
# Hub's anonymous pull limit) if run that often. Run via systemd timer.
#
# Generic OCI Distribution auth flow (works against Docker Hub, GHCR, quay.io,
# lscr.io, and most self-hosted registries) rather than per-registry logic:
# GET the manifest, and if challenged with a 401 + WWW-Authenticate header,
# fetch a bearer token from the realm it names and retry.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
CACHE_FILE="$OUT_DIR/.updates-cache"
LOG_FILE="$DASHBOARD_DIR/logs/container-updates.log"
ACCEPT='Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'

mkdir -p "$OUT_DIR" "$(dirname "$LOG_FILE")"
log() { printf '%s %s\n' "$(date '+%F %T')" "$1" >> "$LOG_FILE"; }

if ! command -v docker >/dev/null 2>&1; then
  log "docker not found, skipping"; exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq not found, skipping (apt-get install -y jq)"; exit 0
fi

# Splits an image ref into registry host / repo path / tag. Fails (intending
# "skip") if the container was run pinned to a digest, since there's no tag
# to compare against.
parse_image_ref() {
  local ref="$1"
  case "$ref" in
    *@sha256:*) return 1 ;;
  esac
  local tag="latest" path="$ref"
  local last_slash_part="${ref##*/}"
  if [[ "$last_slash_part" == *:* ]]; then
    tag="${last_slash_part##*:}"
    path="${ref%:*}"
  fi
  local first_seg="${path%%/*}" host repo
  if [[ "$first_seg" == *.* || "$first_seg" == *:* || "$first_seg" == "localhost" ]]; then
    host="$first_seg"
    repo="${path#*/}"
  else
    host="registry-1.docker.io"
    repo="$path"
    [[ "$repo" != */* ]] && repo="library/$repo"
  fi
  [[ "$host" == "docker.io" || "$host" == "index.docker.io" ]] && host="registry-1.docker.io"
  printf '%s\t%s\t%s' "$host" "$repo" "$tag"
}

remote_digest() {
  local host="$1" repo="$2" tag="$3"
  local url="https://$host/v2/$repo/manifests/$tag"
  local headers status
  headers=$(curl -sS --max-time 10 -D - -o /dev/null -H "$ACCEPT" "$url" 2>/dev/null) || return 1
  status=$(printf '%s' "$headers" | head -1 | grep -o '[0-9]\{3\}')
  if [ "$status" = "401" ]; then
    local auth realm service scope token
    auth=$(printf '%s' "$headers" | grep -i '^www-authenticate:' | tr -d '\r')
    realm=$(printf '%s' "$auth" | sed -n 's/.*[Rr]ealm="\([^"]*\)".*/\1/p')
    service=$(printf '%s' "$auth" | sed -n 's/.*[Ss]ervice="\([^"]*\)".*/\1/p')
    scope=$(printf '%s' "$auth" | sed -n 's/.*[Ss]cope="\([^"]*\)".*/\1/p')
    [ -z "$scope" ] && scope="repository:$repo:pull"
    [ -z "$realm" ] && return 1
    token=$(curl -fsS --max-time 10 "$realm?service=$service&scope=$scope" 2>/dev/null | jq -r '.token // .access_token // empty') || true
    [ -z "$token" ] && return 1
    headers=$(curl -sS --max-time 10 -D - -o /dev/null -H "$ACCEPT" -H "Authorization: Bearer $token" "$url" 2>/dev/null) || return 1
  fi
  local digest
  digest=$(printf '%s' "$headers" | grep -i '^docker-content-digest:' | awk '{print $2}' | tr -d '\r')
  [ -z "$digest" ] && return 1
  printf '%s' "$digest"
}

tmp=$(mktemp "$OUT_DIR/.updates-cache.XXXXXX")
checked=0
available=0

while IFS= read -r cid; do
  [ -z "$cid" ] && continue
  read -r name image_ref image_id <<<"$(docker inspect -f '{{.Name}} {{.Config.Image}} {{.Image}}' "$cid" 2>/dev/null)" || true
  name="${name#/}"
  [ -z "$name" ] && continue

  parsed=$(parse_image_ref "$image_ref") || { log "$name: pinned by digest or unparseable ref ($image_ref), skipping"; continue; }
  IFS=$'\t' read -r host repo tag <<<"$parsed"

  local_digest=$(docker image inspect -f '{{range .RepoDigests}}{{.}} {{end}}' "$image_id" 2>/dev/null | awk '{print $1}' | sed 's/.*@//') || true
  if [ -z "$local_digest" ]; then
    log "$name: no local RepoDigest (locally built/tagged image), skipping"; continue
  fi

  remote="$(remote_digest "$host" "$repo" "$tag")" || { log "$name: registry check failed for $host/$repo:$tag"; continue; }
  checked=$((checked + 1))

  if [ "$remote" != "$local_digest" ]; then
    printf '%s\t1\n' "$name" >> "$tmp"
    available=$((available + 1))
    log "$name: update available ($host/$repo:$tag)"
  else
    printf '%s\t0\n' "$name" >> "$tmp"
  fi
  sleep 0.3
done < <(docker ps -q)

cat "$tmp" > "$CACHE_FILE"
rm -f "$tmp"
chmod 644 "$CACHE_FILE"
log "checked=$checked available=$available"
