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
# Budget for the name-list portion only, after its "Issues: "/"Updates: "
# prefix -- measured against the real font at the layout's fontSize (36px)
# and the text start x (81px, after the 2026-07-29 status-circle column was
# added before it) with a safety margin below the available line width,
# using the longest real container names in this stack
# (nginx-proxy-manager, audiobookshelf, paperless-broker) as the worst
# case. Recompute (scripts/render-preview.py + PIL) if fontSize, text x,
# or the panel width ever changes -- don't just carry this number forward.
# Bumped 31->34->36 (2026-07-29, user request both times: after 34 shipped,
# user reported plenty of visible room still on the real device). Budget
# MINUS the "Updates: "/"Issues: " prefix width (165px/124px at this
# fontSize) -- the prefix eats into the same line, easy to forget since
# MAX_CHARS only counts the name-list portion. 36 lands 4px past the
# panel's divider-line inset (x:24-936, the boundary every other page
# element respects) but still 20px clear of the true PNG canvas edge
# (x:960) for the worst case (longest prefix + longest real container
# names in this stack). 38 is the hard max (0px left at the canvas edge,
# no buffer) -- don't push past 36 without the user confirming on-device
# again, this is now past the design inset, not just the safety margin.
MAX_CHARS=36

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

# Two independent lines (2026-07-28 redesign) rather than one line that
# prioritized issues over updates -- both statuses are now always visible
# at once instead of updates silently disappearing whenever issues exist.
if [ "$issues_count" -eq 0 ]; then
  detail="Everything Healthy"
else
  detail="Issues: $(join_list "${issues[@]}")"
fi

if [ "$updates_count" -eq 0 ]; then
  updates_detail="Updates: None"
else
  updates_detail="Updates: $(join_list "${updates[@]}")"
fi

# Status-circle columns (2026-07-29): asterctl has no data-driven text
# color at all -- fontColor is fixed per field in monitor.json, confirmed
# from crates/asterctl/src/format_value.rs, so a single field can't turn
# red/green based on content. Workaround: two fields at the exact same
# x/y, each a fixed color, where only one ever has non-empty text at a
# time -- the "off" one renders nothing. HarmonyOS_Sans_SC_Bold has a real
# "●" glyph (confirmed non-empty via PIL getmask earlier in this project,
# same font that lacks a real checkmark glyph -- unrelated character, does
# have this one).
dot='●'
if [ "$issues_count" -eq 0 ]; then
  status_ok="$dot"; status_bad=""
else
  status_ok=""; status_bad="$dot"
fi
if [ "$updates_count" -eq 0 ]; then
  updates_ok="$dot"; updates_warn=""
else
  updates_ok=""; updates_warn="$dot"
fi

# These 4 counts have no natural unit character (unlike %/°F fields
# elsewhere), so there's nothing to embed that would force asterctl's
# numeric parser to fail and fall through to raw-text passthrough -- which
# is the only way to get "leading zero under 100, natural width past it"
# (asterctl's own integerDigits only supports always-fixed-width or
# unpadded, confirmed from crates/asterctl/src/format_value.rs). Appending
# a zero-width space (U+200B) is an attempt to get that passthrough
# invisibly: it's not in Unicode's White_Space set, so Rust's .trim() (in
# sensors.rs) won't strip it before the value reaches format_value, and it
# breaks a plain-integer parse just like a real unit character would.
# CONFIRMED working on the physical device/font as of 2026-07-28 -- renders
# invisibly, no stray box. If a future font change ever breaks this, revert
# is just dropping ${zwsp} below (asterctl's own integerDigits:2 in
# monitor.json is already the correct fallback, no JSON change needed).
zwsp=$'\u200b'
tmp=$(mktemp "$OUT_DIR/.containers.XXXXXX")
cat > "$tmp" <<EOF
containers_running: ${running}${zwsp}
containers_healthy: ${healthy}${zwsp}
containers_issues: ${issues_count}${zwsp}
containers_updates: ${updates_count}${zwsp}
containers_status_ok: $status_ok
containers_status_bad: $status_bad
containers_detail: $detail
containers_updates_ok: $updates_ok
containers_updates_warn: $updates_warn
containers_updates_detail: $updates_detail
EOF
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
