#!/usr/bin/env bash
# Daily-cadence container image update check via registry digest comparison.
# Deliberately NOT run on the fast 1s loop -- each container costs one or two
# HTTPS calls to its registry, which would risk rate limits (notably Docker
# Hub's anonymous pull limit) if run that often. Run via systemd timer.
#
# Generic OCI Distribution auth flow (works against Docker Hub, GHCR, quay.io,
# lscr.io, and most self-hosted registries) rather than per-registry logic:
# GET the manifest, and if challenged with a 401 + WWW-Authenticate header,
# fetch a bearer token from the realm it names and retry.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
# CACHE_FILE deliberately does NOT follow SENSOR_DIR onto tmpfs (2026-08-15
# regression fix, caught live on the box -- dashboard showing "Updates:
# None" despite that same day's run having found 8). Unlike every other
# sensor file (rewritten every ~1s, so tmpfs durability never matters),
# this one is written once a day and needs to survive until the next
# day's run. Confirmed on the real host: the file was written successfully
# (this script's own log proved it) but vanished from /run/aoostar-dashboard
# well within 24h with no reboot in between -- most likely systemd's own
# periodic /run cleanup, which the OTHER files there never sit still long
# enough to be swept by (~1s rewrite cadence) but this one does. The
# original tmpfs migration only accounted for reboot as a loss scenario for
# this specific file ("a brief 'no updates known' window") -- that
# assumption didn't hold. Stays on the persistent dataset, same as
# LOG_FILE below, unconditionally (not SENSOR_DIR-overridable, and no
# longer using OUT_DIR/SENSOR_DIR at all -- nothing else in this script
# needs them) so generate-container-sensors.sh's read side can't drift
# from this write side onto two different directories.
CACHE_DIR="$DASHBOARD_DIR/sensors"
CACHE_FILE="$CACHE_DIR/.updates-cache"
LOG_FILE="$DASHBOARD_DIR/logs/container-updates.log"
ACCEPT='Accept: application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json'

mkdir -p "$CACHE_DIR" "$(dirname "$LOG_FILE")"
# Truncated at the start of each run, not appended -- this only runs once a
# day, so there's no need to accumulate history; last run's log is enough.
: > "$LOG_FILE"
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

# This host's real platform (confirmed via `uname -m`: x86_64 ->
# linux/amd64) -- used below to pick the one manifest that's actually
# relevant, out of a multi-arch image's several. Hardcoded, not detected at
# runtime: this project has never run on anything but this one box.
LOCAL_PLATFORM_OS="linux"
LOCAL_PLATFORM_ARCH="amd64"

# Bearer tokens, cached per "host repo" so a multi-arch image's two manifest
# fetches (list, then the resolved platform manifest) -- and repeat hits on
# the same repo across different containers sharing a base image, e.g.
# postgres:16-alpine used by 3 containers here -- share one token instead
# of each independently redoing the anonymous-probe -> 401 -> token-fetch
# dance. Added 2026-09-24: back-to-back token requests for the same repo
# were observed failing (empty token) when each fetch_manifest call
# authenticated for itself -- looks like Docker Hub's auth endpoint doesn't
# like rapid repeat requests for the same scope. Fetching once and reusing
# fixed it outright and halves registry calls as a side effect.
declare -A TOKEN_CACHE=()

# GETs a manifest (tag or digest reference) and returns its raw JSON body.
# Handles the 401 + WWW-Authenticate -> bearer-token retry itself, using
# (and populating) TOKEN_CACHE above.
fetch_manifest() {
  local host="$1" repo="$2" ref="$3"
  local url="https://$host/v2/$repo/manifests/$ref"
  local cache_key="$host $repo"
  local hdr_file out status

  if [ -n "${TOKEN_CACHE[$cache_key]:-}" ]; then
    out=$(curl -sS --max-time 10 -H "$ACCEPT" -H "Authorization: Bearer ${TOKEN_CACHE[$cache_key]}" "$url" 2>/dev/null) || return 1
    printf '%s' "$out"
    return 0
  fi

  hdr_file=$(mktemp /tmp/.manifest-headers.XXXXXX)
  out=$(curl -sS --max-time 10 -D "$hdr_file" -H "$ACCEPT" "$url" 2>/dev/null) || { rm -f "$hdr_file"; return 1; }
  status=$(head -1 "$hdr_file" | grep -o '[0-9]\{3\}')
  if [ "$status" = "401" ]; then
    local auth realm service scope token
    auth=$(grep -i '^www-authenticate:' "$hdr_file" | tr -d '\r')
    realm=$(printf '%s' "$auth" | sed -n 's/.*[Rr]ealm="\([^"]*\)".*/\1/p')
    service=$(printf '%s' "$auth" | sed -n 's/.*[Ss]ervice="\([^"]*\)".*/\1/p')
    scope=$(printf '%s' "$auth" | sed -n 's/.*[Ss]cope="\([^"]*\)".*/\1/p')
    [ -z "$scope" ] && scope="repository:$repo:pull"
    rm -f "$hdr_file"
    [ -z "$realm" ] && return 1
    token=$(curl -fsS --max-time 10 "$realm?service=$service&scope=$scope" 2>/dev/null | jq -r '.token // .access_token // empty') || true
    [ -z "$token" ] && return 1
    TOKEN_CACHE[$cache_key]="$token"
    out=$(curl -sS --max-time 10 -H "$ACCEPT" -H "Authorization: Bearer $token" "$url" 2>/dev/null) || return 1
  else
    rm -f "$hdr_file"
  fi
  printf '%s' "$out"
}

# Returns the registry's current CONFIG digest for this image ref's actual
# platform -- the same value `docker inspect -f '{{.Image}}'` reports for a
# locally running container, i.e. the thing that actually changes when
# `docker compose pull && up -d` would replace the container. Deliberately
# NOT the tag's raw manifest digest: for a multi-arch tag that resolves to
# a manifest LIST/index, the list's own digest bumps whenever ANY of its
# ~9 platform builds gets rebuilt (arm/s390x/riscv64/etc., completely
# unrelated to what's actually running here) even when the amd64 build --
# the only one this host ever uses -- hasn't changed at all. Comparing that
# list digest against the locally-recorded one is what caused two real
# false positives (postgres:16-alpine, redis:7-alpine both flagged
# indefinitely) -- root-caused 2026-09-24 with a peer session's help
# (cross-checked via a platform-pinned `docker pull --platform linux/amd64`
# + `docker inspect .Id`, matched exactly to the two-hop resolution below).
remote_config_digest() {
  local host="$1" repo="$2" tag="$3"
  local body media_type
  body=$(fetch_manifest "$host" "$repo" "$tag") || return 1
  media_type=$(printf '%s' "$body" | jq -r '.mediaType // empty' 2>/dev/null)
  case "$media_type" in
  *manifest.list*|*image.index*)
    local platform_digest
    platform_digest=$(printf '%s' "$body" | jq -r --arg os "$LOCAL_PLATFORM_OS" --arg arch "$LOCAL_PLATFORM_ARCH" \
      '.manifests[]? | select(.platform.os == $os and .platform.architecture == $arch) | .digest' \
      2>/dev/null | head -1)
    [ -z "$platform_digest" ] && return 1
    body=$(fetch_manifest "$host" "$repo" "$platform_digest") || return 1
    ;;
  esac
  local config_digest
  config_digest=$(printf '%s' "$body" | jq -r '.config.digest // empty' 2>/dev/null)
  [ -z "$config_digest" ] && return 1
  printf '%s' "$config_digest"
}

tmp=$(mktemp "$CACHE_DIR/.updates-cache.XXXXXX")
checked=0
available=0

# Caches remote_config_digest's result per "host repo tag" -- several
# containers here share the exact same image (postgres:16-alpine alone
# backs 3), and each now costs 2 registry GETs (list + resolved platform
# manifest) instead of the original design's 1 HEAD-only probe. Real cost
# of getting this check actually correct (2026-09-24) -- deduping repeat
# hits on the same tag keeps the daily total from creeping toward Docker
# Hub's 100/hr anonymous rate limit (confirmed hit while testing this fix,
# recovers within its own 1hr window, unrelated to normal daily operation
# but real all the same).
declare -A DIGEST_RESULT_CACHE=()

while IFS= read -r cid; do
  [ -z "$cid" ] && continue
  read -r name image_ref image_id <<<"$(docker inspect -f '{{.Name}} {{.Config.Image}} {{.Image}}' "$cid" 2>/dev/null)" || true
  name="${name#/}"
  [ -z "$name" ] && continue

  parsed=$(parse_image_ref "$image_ref") || { log "$name: pinned by digest or unparseable ref ($image_ref), skipping"; continue; }
  IFS=$'\t' read -r host repo tag <<<"$parsed"

  # $image_id (docker inspect's .Image, "sha256:...") IS the image's config
  # digest by the OCI/Docker image spec -- compared directly against the
  # registry's config digest below, no RepoDigests lookup needed.
  digest_key="$host $repo $tag"
  if [ -n "${DIGEST_RESULT_CACHE[$digest_key]:-}" ]; then
    remote="${DIGEST_RESULT_CACHE[$digest_key]}"
  else
    remote="$(remote_config_digest "$host" "$repo" "$tag")" || { log "$name: registry check failed for $host/$repo:$tag"; continue; }
    DIGEST_RESULT_CACHE[$digest_key]="$remote"
  fi
  checked=$((checked + 1))

  if [ "$remote" != "$image_id" ]; then
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
