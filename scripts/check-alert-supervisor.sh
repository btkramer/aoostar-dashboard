#!/usr/bin/env bash
# Alert-interrupt supervisor (added 2026-07-31). Runs at the end of every
# ~5s cycle of aoostar-sensors.service, after generate-sensors.sh,
# generate-container-sensors.sh, and generate-storage-sensors.sh have all
# written fresh data this same cycle -- deliberately reads THEIR already-
# computed, already-formatted output (footer_text_bad/warn, diskN_health_bad,
# *_temp_over, containers_status_bad/containers_detail) rather than
# re-deriving any of it, so this stays in sync with those scripts' logic
# for free instead of duplicating it.
#
# Design (per multiple rounds of discussion, not guessed):
# - Triggers: pool faulted/unavailable, a specific disk health error, pool
#   degraded, CPU/GPU over temp, a disk over temp, container issues.
# - Content: a LIST of every currently active condition (not just the
#   worst), most severe first, capped at 6 lines with "+N more" beyond
#   that -- same truncation convention containers_detail already uses.
# - Debounce: a condition set must be non-empty (or empty) for 2
#   consecutive cycles (~10s) before the alert page is added to/removed
#   from rotation -- avoids flapping the display on a single noisy read.
# - Mechanism: asterctl has no hot-reload and no query API for "what page
#   is showing right now" (confirmed from its source, same finding
#   documented elsewhere in this project), so entering/exiting alert mode
#   means editing monitor.json's top-level "mianban" array and restarting
#   asterctl -- normal rotation [1,2,3] becomes [1,4,2,4,3,4] (alert panel
#   interleaved after every normal page), and back. That restart is ONLY
#   needed for the two transitions (entering/leaving alert mode) -- while
#   already active, the list content updates live every cycle like any
#   other sensor field, no restart needed, since only the page STRUCTURE
#   (which panels exist in the rotation) requires one, not their text
#   content.
#
# - **IMPORTANT -- these mianban values only work correctly on the CUSTOM-
#   PATCHED /root/aoostar/asterctl binary, not the stock vendor release.**
#   Found 2026-08-06: upstream asterctl 0.2.0 has a bug in
#   crates/asterctl/src/cfg.rs, get_next_active_panel() -- its rotation
#   wraparound check compares against the TOTAL number of defined panels
#   (diy.len(), i.e. panels.len()) instead of the actual length of
#   `mianban`. A mianban shorter than diy.len() crashes ("Error: No active
#   panel", systemd Restart=always crash loop every ~30s -- this was live
#   for about a week, since the alert panel was added on 2026-07-31, before
#   being noticed); a mianban longer than diy.len() silently truncates,
#   making entries past position diy.len() permanently unreachable (the
#   original "1 4 2 4 3 4" only ever showed its first 4 slots, so
#   storage-overview and the second alert slot never displayed, the whole
#   time this feature existed). Patched by changing the wraparound
#   comparison to use the count of `mianban`'s own non-zero entries
#   instead. Built from the exact v0.2.0 tag (matching what was already
#   deployed, so no other behavior drift) with this one function changed;
#   verified against the real LCD hardware before deploying -- both
#   `[1,2,3]` (clean repeating rotation, no crash across multiple laps) and
#   `[1,4,2,4,3,4]` (correct every-other alert interleaving, all 3 real
#   pages actually appear) confirmed working live. Binary + patch source
#   kept in this repo's `bin/` directory.
#   **If asterctl is ever reinstalled/upgraded from upstream, this bug
#   returns and mianban needs to go back to the length-matching workaround
#   values documented in this file's git history (2026-08-06 commits) --
#   or the patch needs reapplying to whatever new version is installed.**
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
OUT_FILE="$OUT_DIR/alert.txt"
STATE_FILE="$OUT_DIR/.alert-state"
MONITOR_JSON="$DASHBOARD_DIR/monitor.json"
DEBOUNCE_CYCLES="${ALERT_DEBOUNCE_CYCLES:-2}"
MAX_LINES=6

mkdir -p "$OUT_DIR"

sensor_val() {
  # $1=file $2=key -- first "key: value" match, everything after the
  # first ": " (values can themselves contain colons, e.g. "Last: Jul 19").
  awk -v k="$2" -F': ' 'index($0,k": ")==1 { sub(/^[^:]*: /,""); print; exit }' "$1" 2>/dev/null
}

dashboard_txt="$OUT_DIR/dashboard.txt"
storage_txt="$OUT_DIR/storage.txt"
containers_txt="$OUT_DIR/containers.txt"

lines=()

# 1. Pool faulted/unavailable (worst) -- footer_text_bad is already the
# top tier of generate-storage-sensors.sh's 3-way pool/scrub severity
# calculation (state_tier/scrub_tier -> tier 2). Mutually exclusive with
# footer_text_warn (only one of asterctl's toggle-fields is ever
# non-empty), so no risk of double-counting the same underlying signal.
pool_bad="$(sensor_val "$storage_txt" footer_text_bad)"
[ -n "$pool_bad" ] && lines+=("Pool: $pool_bad")

# 2. Per-disk health errors (specific, actionable -- which physical disk).
for i in 1 2 3 4 5; do
  hbad="$(sensor_val "$storage_txt" "disk${i}_health_bad")"
  if [ -n "$hbad" ]; then
    dname="$(sensor_val "$storage_txt" "disk${i}_name")"
    lines+=("${dname:-disk$i}: $hbad")
  fi
done

# 3. Pool degraded (tier 1 -- redundancy lost but still serving, or a
# scrub found errors on an otherwise-online pool).
pool_warn="$(sensor_val "$storage_txt" footer_text_warn)"
[ -n "$pool_warn" ] && lines+=("Pool: $pool_warn")

# 4/5. CPU/GPU over temp threshold (generate-sensors.sh's own
# CPU_TEMP_HIGH_F/GPU_TEMP_HIGH_F-driven fields).
cpu_over="$(sensor_val "$dashboard_txt" cpu_temperature_over)"
[ -n "$cpu_over" ] && lines+=("CPU: $cpu_over")
gpu_over="$(sensor_val "$dashboard_txt" gpu_temperature_over)"
[ -n "$gpu_over" ] && lines+=("GPU: $gpu_over")

# 6. Per-disk over-temp (uncapped -- every disk past the line, not just
# the hottest one; DISK_TEMP_HIGH_F-driven fields from
# generate-storage-sensors.sh).
for i in 1 2 3 4 5; do
  tover="$(sensor_val "$storage_txt" "disk${i}_temp_over")"
  if [ -n "$tover" ]; then
    dname="$(sensor_val "$storage_txt" "disk${i}_name")"
    lines+=("${dname:-disk$i}: $tover")
  fi
done

# 7. Container issues -- containers_status_bad is already the clean
# ok/bad toggle field (not the raw count, which can carry a zero-width-
# space padding trick -- see generate-container-sensors.sh); reuse
# containers_detail as-is, it's already formatted ("Issues: sonarr, +1 more").
c_bad="$(sensor_val "$containers_txt" containers_status_bad)"
if [ -n "$c_bad" ]; then
  c_detail="$(sensor_val "$containers_txt" containers_detail)"
  lines+=("${c_detail:-Container issues}")
fi

total="${#lines[@]}"
display_lines=()
if [ "$total" -le "$MAX_LINES" ]; then
  display_lines=("${lines[@]}")
else
  for i in 0 1 2 3 4; do display_lines+=("${lines[$i]}"); done
  display_lines+=("+$((total - 5)) more")
fi

# Debounce state: active(0/1) pending_enter pending_clear, space-separated.
active=0; pending_enter=0; pending_clear=0
if [ -r "$STATE_FILE" ]; then
  read -r active pending_enter pending_clear < "$STATE_FILE" || true
  active=${active:-0}; pending_enter=${pending_enter:-0}; pending_clear=${pending_clear:-0}
fi

set_mianban() {
  # $1 = space-separated panel indices, e.g. "1 2 3" or "1 4 2 4 3 4".
  # Plain awk, no jq/python -- this script must run on the box where
  # neither is confirmed present. Relies on monitor.json's mianban block
  # having the exact fixed formatting this project has always written it
  # in ("mianban": [ / one bare number per line / ] on its own line) --
  # verify by hand if that block is ever reformatted differently.
  local indices="$1" tmp
  tmp=$(mktemp "$DASHBOARD_DIR/.monitor.json.XXXXXX")
  awk -v idx="$indices" '
    BEGIN { n = split(idx, arr, " ") }
    /"mianban": \[/ {
      print "    \"mianban\": ["
      for (i = 1; i <= n; i++) printf "        %s%s\n", arr[i], (i < n ? "," : "")
      print "    ]"
      skip = 1
      next
    }
    skip && /^[ \t]*\]/ { skip = 0; next }
    skip { next }
    { print }
  ' "$MONITOR_JSON" > "$tmp"
  mv "$tmp" "$MONITOR_JSON"
  chmod 777 "$MONITOR_JSON" 2>/dev/null || true
}

if [ "$total" -gt 0 ]; then
  pending_clear=0
  if [ "$active" -eq 0 ]; then
    pending_enter=$((pending_enter + 1))
    if [ "$pending_enter" -ge "$DEBOUNCE_CYCLES" ]; then
      set_mianban "1 4 2 4 3 4"
      systemctl restart aoostar-asterctl 2>/dev/null || true
      active=1
      pending_enter=0
    fi
  fi
else
  pending_enter=0
  if [ "$active" -eq 1 ]; then
    pending_clear=$((pending_clear + 1))
    if [ "$pending_clear" -ge "$DEBOUNCE_CYCLES" ]; then
      set_mianban "1 2 3"
      systemctl restart aoostar-asterctl 2>/dev/null || true
      active=0
      pending_clear=0
    fi
  fi
fi

printf '%s %s %s\n' "$active" "$pending_enter" "$pending_clear" > "$STATE_FILE"

tmp=$(mktemp "$OUT_DIR/.alert.XXXXXX")
{
  for i in 1 2 3 4 5 6; do
    idx=$((i - 1))
    echo "alert_line${i}: ${display_lines[$idx]:-}"
  done
} > "$tmp"
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
