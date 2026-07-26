#!/usr/bin/env bash
# Fast container status pass (no network calls): running/healthy/issues counts.
# "Updates available" is computed separately and slowly by
# check-container-updates.sh; this script only reads its cache file.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
OUT_FILE="$OUT_DIR/containers.txt"
UPDATES_CACHE="$OUT_DIR/.updates-cache"
MAX_NAMES=3
MAX_CHARS=60

mkdir -p "$OUT_DIR"

running=0
healthy=0
issues=()
updates=()

if command -v docker >/dev/null 2>&1; then
  # "running" here includes containers mid-crash-loop (status=restarting) so
  # they show up as issues instead of silently vanishing from the count.
  while IFS=$'\t' read -r name status health; do
    [ -z "$name" ] && continue
    running=$((running + 1))
    name="${name#/}"
    if [ "$status" = "restarting" ] || [ "$health" = "unhealthy" ]; then
      issues+=("$name")
    else
      healthy=$((healthy + 1))
    fi
  done < <(docker ps -a --filter status=running --filter status=restarting --format '{{.ID}}' | while read -r cid; do
    docker inspect -f $'{{.Name}}\t{{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null
  done)

  # Exited containers with a non-zero exit code are flagged; a clean exit(0)
  # is treated as an intentional one-shot/init container, not an issue.
  while IFS=$'\t' read -r name code; do
    [ -z "$name" ] && continue
    [ "$code" = "0" ] && continue
    issues+=("${name#/}")
  done < <(docker ps -a --filter status=exited --format '{{.Names}}' | while read -r n; do
    printf '%s\t%s\n' "$n" "$(docker inspect -f '{{.State.ExitCode}}' "$n" 2>/dev/null || echo 0)"
  done)
fi

if [ -r "$UPDATES_CACHE" ]; then
  while IFS=$'\t' read -r name avail; do
    [ "$avail" = "1" ] && updates+=("$name")
  done < "$UPDATES_CACHE"
fi

issues_count=${#issues[@]}
updates_count=${#updates[@]}

# Renders up to MAX_NAMES comma-joined names plus a "+N more" tail, then hard
# -truncates to MAX_CHARS so unusually long container names can't overflow
# the panel regardless of how many names were joined.
join_list() {
  local arr=("$@")
  local n=${#arr[@]}
  local shown=("${arr[@]:0:$MAX_NAMES}")
  local out=""
  local name
  for name in "${shown[@]}"; do
    if [ -z "$out" ]; then out="$name"; else out="$out, $name"; fi
  done
  if [ "$n" -gt "$MAX_NAMES" ]; then
    out="$out +$((n - MAX_NAMES)) more"
  fi
  if [ "${#out}" -gt "$MAX_CHARS" ]; then
    out="${out:0:$((MAX_CHARS - 1))}…"
  fi
  printf '%s' "$out"
}

if [ "$issues_count" -eq 0 ] && [ "$updates_count" -eq 0 ]; then
  # HarmonyOS_Sans_SC_Bold.ttf has no glyph for a real checkmark (U+2713/U+2714)
  # -- it renders blank on the LCD. sqrt sign is the closest glyph the font
  # actually has.
  detail="√ Everything Healthy"
elif [ "$issues_count" -gt 0 ]; then
  detail="$(join_list "${issues[@]}")"
else
  detail="$(join_list "${updates[@]}")"
fi

tmp=$(mktemp "$OUT_DIR/.containers.XXXXXX")
cat > "$tmp" <<EOF
containers_running: $running
containers_healthy: $healthy
containers_issues: $issues_count
containers_updates: $updates_count
containers_detail: $detail
EOF
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
