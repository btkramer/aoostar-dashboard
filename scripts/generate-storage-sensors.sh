#!/usr/bin/env bash
# Page 3 (Storage) data: pool read/write throughput + disk temperature
# summary + pool health/scrub status. Pool *capacity* is NOT recomputed
# here -- Page 1's monitor.json panel still shows pool_usage/pool_detail
# from generate-sensors.sh (asterctl merges all *.txt files under
# --sensor-path into one key/value map, so any panel can reference any
# key from any file in sensors/). Page 3's row-1-col-1 used to just reuse
# that same pair (redundant with Page 1) -- replaced 2026-07-29 with real
# pool health (zpool state + last scrub) instead, computed below.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
OUT_FILE="$OUT_DIR/storage.txt"
STATE_FILE="$OUT_DIR/.disk-io-state"
POOL_NAME="${POOL_NAME:-tank}"
NVME_POOL_NAME="${NVME_POOL_NAME:-boot-pool}"

mkdir -p "$OUT_DIR"
# KB is the smallest unit shown -- same reasoning as generate-sensors.sh's
# copy of this function.
human_bytes() { awk -v b="${1:-0}" -v p="${2:-2}" 'BEGIN { split("B KB MB GB TB",u," "); i=2; b/=1024; while (b>=1024 && i<5) {b/=1024;i++} printf "%.*f %s",p,b,u[i] }'; }

# NVMe (boot/cache drive) capacity, added 2026-07-31 for Page 3's new
# 4-column layout (col 1). Reads the ZFS boot-pool -- TrueNAS SCALE's
# default name for the pool it installs itself onto -- via `zfs list`,
# same used/avail-not-zpool-alloc/size reasoning as $POOL_NAME's capacity
# in generate-sensors.sh (avoids counting parity/redundancy overhead).
# NVME_POOL_NAME/NVME_USED/NVME_TOTAL are overridable, same pattern as
# POOL_NAME/POOL_USED/POOL_TOTAL there. UNTESTED against a real boot-pool
# as of writing -- `zfs` isn't on PATH in the sandbox this was built in,
# and this box's actual boot-pool name was never independently confirmed
# (only inferred from TrueNAS SCALE's install default) -- verify on the box.
if [ -z "${NVME_USED:-}" ] || [ -z "${NVME_TOTAL:-}" ]; then
  if command -v zfs >/dev/null 2>&1; then
    read -r nvme_zfs_used nvme_zfs_avail < <(zfs list -Hp -o used,avail "$NVME_POOL_NAME" 2>/dev/null) || true
  fi
  NVME_USED="${NVME_USED:-${nvme_zfs_used:-0}}"
  NVME_TOTAL="${NVME_TOTAL:-$(( ${nvme_zfs_used:-0} + ${nvme_zfs_avail:-0} ))}"
fi
nvme_percent=$(awk -v u="$NVME_USED" -v t="$NVME_TOTAL" 'BEGIN { if(t>0) printf "%.0f",100*u/t; else print 0 }')
nvme_used_fmt="$(human_bytes "$NVME_USED" 1)"
nvme_total_fmt="$(human_bytes "$NVME_TOTAL" 1)"
nvme_detail="${nvme_used_fmt% *}/${nvme_total_fmt}"

# ARC hit ratio (added 2026-07-31) -- fills the SCRUB column's second line
# (row 1 col 2, y=172), which had been empty; every other Page 3 column
# has a two-line big-value+detail pattern, SCRUB was the only one-line
# exception. Read directly from the ZFS kernel module's kstat interface
# (/proc/spl/kstat/zfs/arcstats), not `arc_summary`/`arcstat` (not
# confirmed present, and this matches the project's established
# preference for /proc over CLI tools that might be missing).
#
# WINDOWED, not cumulative (changed same day after the first version --
# raw hits/misses are lifetime-cumulative counters since the ZFS module
# loaded, so on a box with a long uptime it reads a permanently-near-100%
# number that barely moves and doesn't reflect *current* cache pressure,
# same problem cpu_percent/network_rx solved the same way). Delta between
# consecutive ~5s loop runs, state in sensors/.arc-state, same pattern as
# those two. If nothing touched ARC in the window (delta_hits+misses==0,
# realistic during idle periods with a ~5s window), shows 0% -- that's a
# true statement ("no ARC lookups happened"), not a broken cache, same as
# network_rx showing "0 KB/s" when idle.
ARC_STATE_FILE="$OUT_DIR/.arc-state"
read -r arc_hits arc_misses < <(awk '$1=="hits"{h=$3} $1=="misses"{m=$3} END{print h+0, m+0}' /proc/spl/kstat/zfs/arcstats 2>/dev/null) || true
arc_hits=${arc_hits:-0}; arc_misses=${arc_misses:-0}
arc_hit_pct=0
if [ -r "$ARC_STATE_FILE" ]; then
  read -r arc_prev_hits arc_prev_misses < "$ARC_STATE_FILE" || true
  arc_prev_hits=${arc_prev_hits:-$arc_hits}; arc_prev_misses=${arc_prev_misses:-$arc_misses}
  arc_d_hits=$((arc_hits - arc_prev_hits)); arc_d_misses=$((arc_misses - arc_prev_misses))
  if [ "$((arc_d_hits + arc_d_misses))" -gt 0 ]; then
    arc_hit_pct=$(awk -v h="$arc_d_hits" -v m="$arc_d_misses" 'BEGIN { printf "%.1f", 100*h/(h+m) }')
  fi
fi
printf '%s %s\n' "$arc_hits" "$arc_misses" > "$ARC_STATE_FILE"

# Pool member disks: derived from which block devices have a `drivetemp`
# hwmon sensor attached (same technique cpu_temperature uses for k10temp --
# find by hwmon *name*, not a hardcoded path, since indices shift across
# reboots). On this box that resolves to the 5 SATA disks (sda/sdb/sdc/
# sdd/sdf) forming the "tank" pool -- the NVMe (boot/cache, a separate
# device, covered on Page 4 instead) and any VM zvols don't have a
# drivetemp sensor so they're naturally excluded.
# ASSUMPTION, not independently confirmed via `zpool status tank` -- the
# `zpool` binary isn't on PATH in the sandbox this was developed in, only
# `zfs`. Strong circumstantial match (exactly 5 same-size disks, matches
# the pool's known capacity), but verify on the box if this ever looks
# wrong, and don't assume it still holds if this box's storage changes.
# Sorted (not hwmon glob order, which isn't stable) so each disk lands in
# the same grid column every cycle -- the per-disk temp+health grid below
# assigns columns positionally (disk1_*..disk5_*), not by device name, so
# column stability across restarts depends on this sort.
pool_disks=()
for hw in /sys/class/hwmon/*; do
  if [ -r "$hw/name" ] && [ "$(cat "$hw/name")" = "drivetemp" ]; then
    dev=$(ls "$hw/device/block/" 2>/dev/null | head -n1)
    [ -n "$dev" ] && pool_disks+=("$dev")
  fi
done
if [ "${#pool_disks[@]}" -gt 0 ]; then
  readarray -t pool_disks < <(printf '%s\n' "${pool_disks[@]}" | sort)
fi
MAX_DISKS=5  # matches this box's real disk count; grid columns are fixed in monitor.json

# Read/write throughput: sum sectors read/written (always 512 bytes/sector
# -- a fixed kernel accounting unit, unrelated to the disk's real physical
# sector size) across the pool's member disks between consecutive loop
# invocations. Same delta-over-interval pattern as cpu_percent/network_rx.
sectors_read=0; sectors_written=0
for dev in "${pool_disks[@]}"; do
  read -r sr sw < <(awk -v d="$dev" '$3==d {print $6, $10}' /proc/diskstats)
  sectors_read=$((sectors_read + ${sr:-0}))
  sectors_written=$((sectors_written + ${sw:-0}))
done

now=$(date +%s)
read_rate=0; write_rate=0
if [ -r "$STATE_FILE" ]; then
  read -r old_time old_sr old_sw < "$STATE_FILE" || true
  elapsed=$((now - old_time)); [ "$elapsed" -lt 1 ] && elapsed=1
  read_rate=$(( (sectors_read - old_sr) * 512 / elapsed ))
  write_rate=$(( (sectors_written - old_sw) * 512 / elapsed ))
fi
printf '%s %s %s\n' "$now" "$sectors_read" "$sectors_written" > "$STATE_FILE"

# Per-disk temperature (2026-07-29, replaces the old avg/hottest summary
# with a real per-disk grid): read each drivetemp hwmon device's
# temp1_input directly (matches cpu_temperature's k10temp approach),
# keyed by device name so it can be matched back up with pool_disks'
# sorted order below. Converted to Fahrenheit, matching this system
# owner's established preference for every other temp field.
declare -A disk_temp_f_by_dev=()
for hw in /sys/class/hwmon/*; do
  if [ -r "$hw/name" ] && [ "$(cat "$hw/name")" = "drivetemp" ] && [ -r "$hw/temp1_input" ]; then
    dev=$(ls "$hw/device/block/" 2>/dev/null | head -n1)
    [ -z "$dev" ] && continue
    c=$(cat "$hw/temp1_input")
    disk_temp_f_by_dev["$dev"]=$(awk -v m="$c" 'BEGIN { printf "%.0f", (m/1000)*9/5+32 }')
  fi
done

# Temp color tiers (added 2026-07-31, user request): the hottest drive
# (whichever has the max reading this cycle, ties all included -- no
# reason to arbitrarily pick one) is highlighted amber; ANY drive over
# DISK_TEMP_HIGH_F is red, uncapped -- not just the hottest one, every
# drive past the line turns red simultaneously if that's how many there
# are. Red takes priority over "merely hottest" if a drive is both.
# DISK_TEMP_HIGH_F is overridable (same env-var-default pattern as
# POOL_NAME/NET_IFACE elsewhere in this project); 130°F (~54°C) is a
# reasonable "starting to run warm" line for spinning disks (well below
# the ~150°F/65°C range vendors typically flag as concerning), not a
# value confirmed against this specific hardware's datasheet -- tune via
# the env var if it doesn't match this box's actual disks.
DISK_TEMP_HIGH_F="${DISK_TEMP_HIGH_F:-130}"
disk_max_temp_f=""
for dev in "${!disk_temp_f_by_dev[@]}"; do
  t="${disk_temp_f_by_dev[$dev]}"
  if [ -z "$disk_max_temp_f" ] || [ "$t" -gt "$disk_max_temp_f" ]; then
    disk_max_temp_f="$t"
  fi
done

# Pool health + last scrub (2026-07-29). Two independent signals rendered
# via the same two-field color-toggle trick used elsewhere in this project
# (asterctl has zero data-driven text color, confirmed from its own source
# -- crates/asterctl/src/format_value.rs): pool_status_ok/_bad (the zpool
# `state` word, row 1 col 1 headline) and pool_scrub_ok/_bad (last scrub
# result, the sub-detail line below it). Also drives footer_dot_ok/_bad +
# footer_text_ok/_bad -- a shared "is everything with the pool actually
# fine" light in the bottom-left corner of ALL THREE pages, not just this
# one (asterctl merges every *.txt under --sensor-path into one key/value
# map, so fields written here are visible from Page 1/2's monitor.json
# panels too -- computed once, not duplicated per script).
dot='●'
pool_state="UNKNOWN"
scrub_ok_text=""
scrub_bad_text=""
zstatus=""  # stays empty if zpool is missing/fails; per-disk health below needs a defined value under set -u
pool_frag="?"
if command -v zpool >/dev/null 2>&1; then
  # -L ("real paths") confirmed necessary on this box: without it, the
  # config table's NAME column shows the persistent GUID/partuuid TrueNAS
  # SCALE actually uses to reference members (e.g.
  # "9e943524-db59-4af2-b27d-1b8f7840c207"), not the sda/sdb/etc device
  # name pool_disks holds -- caught by dumping the real output to a debug
  # file and reading it directly, not guessed. -L resolves those back to
  # real block device paths.
  zstatus="$(zpool status -L "$POOL_NAME" 2>/dev/null || true)"
  # Fragmentation (added 2026-07-31, fills the SCRUB column's 3rd/last
  # line -- user confirmed room for one more on the physical panel). Own
  # `zpool list` call since `zpool status` doesn't carry this field.
  # `-Hp` for a plain machine-readable percentage (0-100); can read "-" on
  # pools where the fragmentation feature isn't active, handled below.
  pool_frag_raw="$(zpool list -Hp -o frag "$POOL_NAME" 2>/dev/null || true)"
  [ -n "$pool_frag_raw" ] && [ "$pool_frag_raw" != "-" ] && pool_frag="${pool_frag_raw}%"
  if [ -n "$zstatus" ]; then
    pool_state="$(printf '%s\n' "$zstatus" | awk -F': ' '/^[[:space:]]*state:/ {print $2; exit}')"
    # The scan block can span multiple lines -- an active scrub's %/ETA is
    # on the line(s) after "scan:", not on it. Capture from "scan:" up to
    # (not including) "config:" -- tolerate leading whitespace before
    # "config:" (confirmed necessary: this box's real `zpool status` needed
    # it, an assumption of column-0 "config:" was wrong and let the capture
    # run on into the per-device config table, picking up a second
    # unrelated "on <date>" from there and corrupting pool_scrub_ok with
    # two concatenated dates -- caught live on the box, not in the
    # sandbox, since zpool isn't available here to test against directly).
    scan_block="$(printf '%s\n' "$zstatus" | awk '/^[[:space:]]*scan:/{f=1} /^[[:space:]]*config:/{f=0} f')"
    # head -n1 on every extraction below is deliberate defense-in-depth for
    # the same reason -- don't rely solely on scan_block's boundary being
    # exactly right for every zpool status variant.
    if printf '%s' "$scan_block" | grep -q "none requested"; then
      scrub_ok_text="Scrub: never run"
    elif printf '%s' "$scan_block" | grep -qi "resilver.*in progress"; then
      pct="$(printf '%s' "$scan_block" | grep -oE '[0-9]+(\.[0-9]+)?% done' | head -n1 | grep -oE '^[0-9]+')"
      scrub_ok_text="Resilver: ${pct:-0}%"
    elif printf '%s' "$scan_block" | grep -qi "scrub in progress"; then
      pct="$(printf '%s' "$scan_block" | grep -oE '[0-9]+(\.[0-9]+)?% done' | head -n1 | grep -oE '^[0-9]+')"
      scrub_ok_text="Scrub: ${pct:-0}% done"
    elif printf '%s' "$scan_block" | grep -q "scrub repaired\|scrub canceled"; then
      errs="$(printf '%s' "$scan_block" | grep -oE 'with [0-9]+ errors' | head -n1 | grep -oE '[0-9]+')"
      errs="${errs:-0}"
      raw_date="$(printf '%s' "$scan_block" | grep -oE 'on .*$' | head -n1 | sed 's/^on //')"
      fmt_date="$(date -d "$raw_date" '+%b %d' 2>/dev/null || true)"
      [ -z "$fmt_date" ] && fmt_date="$raw_date"
      if [ "$errs" -eq 0 ] 2>/dev/null; then
        # "Last:" not "Scrub:" -- redundant under the SCRUB column header
        # (2026-07-31, on-device feedback). The other branches above (never
        # run / in-progress / resilver) keep their "Scrub:"/"Resilver:"
        # verb since they're not just a bare date.
        scrub_ok_text="Last: $fmt_date"
      else
        plural=""; [ "$errs" != "1" ] && plural="s"
        scrub_bad_text="${errs} error${plural} found!"
      fi
    fi
  fi
fi
if [ -z "$scrub_ok_text" ] && [ -z "$scrub_bad_text" ]; then
  scrub_ok_text="Scrub: unknown"
fi

# pool_status_ok/_bad (a big "ONLINE" headline in Page 3's old col-1) was
# removed 2026-07-31 -- it's the same pool_state the footer_text_ok/_bad
# fields below already show in the bottom-left corner of all 3 pages,
# genuinely redundant on-screen. Col 1 is now nvme_usage/nvme_detail
# instead (see the NVMe block near the top of this script). pool_state
# itself is still needed below for the footer's tier logic.

# Three-tier footer (2026-07-29, user request): green/amber/red instead of
# the original green/red toggle, since ZFS pool state genuinely has a
# middle severity (DEGRADED -- redundancy lost but still serving data) that
# a binary ok/bad collapsed. Tier is the WORSE of (a) pool_state's own
# severity and (b) whether a scrub found real errors -- e.g. an ONLINE pool
# with scrub errors still shows amber "ERRORS", not green, even though
# state itself says ONLINE.
state_tier=0  # 0=ok(green) 1=warn(amber) 2=bad(red)
case "$pool_state" in
  ONLINE) state_tier=0 ;;
  DEGRADED) state_tier=1 ;;
  *) state_tier=2 ;;  # FAULTED, OFFLINE, UNAVAIL, REMOVED, UNKNOWN
esac
scrub_tier=0
[ -n "$scrub_bad_text" ] && scrub_tier=1
tier=$state_tier
[ "$scrub_tier" -gt "$tier" ] && tier=$scrub_tier

footer_dot_ok=""; footer_dot_warn=""; footer_dot_bad=""
footer_text_ok=""; footer_text_warn=""; footer_text_bad=""
footer_word="$pool_state"
[ "$state_tier" -lt "$scrub_tier" ] && footer_word="ERRORS"
case "$tier" in
  0) footer_dot_ok="$dot"; footer_text_ok="ONLINE" ;;
  1) footer_dot_warn="$dot"; footer_text_warn="${footer_word:-UNKNOWN}" ;;
  2) footer_dot_bad="$dot"; footer_text_bad="${footer_word:-UNKNOWN}" ;;
esac

# Per-disk grid (2026-07-29, replaces the old 2-column avg/hottest temp
# summary): for each of the up to MAX_DISKS disks (sorted order from
# above, so column N is always the same physical disk across cycles),
# emit a device-name field and a temp field separately (2026-07-31 --
# previously one combined "sdX 108°F" string; split so the device name can
# render in a bigger font than the temperature, which asterctl can't do
# within a single field) plus a health_ok/health_bad pair (same two-field
# color-toggle trick used throughout this project). Health
# comes from the disk's own STATE in zpool status's per-device config
# table -- NOT smartctl (not confirmed present/permitted on this box, and
# this reuses the $zstatus text already fetched above instead of a second
# external call). Leaf disk states are typically ONLINE/OFFLINE/FAULTED/
# UNAVAIL/REMOVED; anything other than ONLINE is shown in red as the
# literal state word. A disk with no line in the config table (or no
# zstatus at all) shows "?" rather than silently claiming ONLINE.
# Same column-0 gotcha already caught once for the scan/config boundary
# above -- tolerate leading whitespace before "config:"/"errors:" here too
# (confirmed necessary: this box's real config: line isn't at column 0).
disk_config="$(printf '%s\n' "$zstatus" | awk '/^[[:space:]]*config:/{f=1;next} /^[[:space:]]*errors:/{f=0} f')"
declare -A grid_name=() grid_temp_normal=() grid_temp_hot=() grid_temp_over=() grid_health_ok=() grid_health_bad=()
for i in $(seq 1 "$MAX_DISKS"); do
  idx=$((i - 1))
  dev="${pool_disks[$idx]:-}"
  [ -z "$dev" ] && continue
  f="${disk_temp_f_by_dev[$dev]:-}"
  grid_name[$i]="$dev"
  # Three-field color-toggle trick (same pattern used throughout this
  # project -- asterctl has zero data-driven text color): only one of
  # normal/hot/over is ever non-empty for a given disk. Unknown temp ("?")
  # can't be hot or over threshold, so it always renders normal-colored.
  if [ -n "$f" ] && [ "$f" -gt "$DISK_TEMP_HIGH_F" ]; then
    grid_temp_over[$i]="${f}°F"
  elif [ -n "$f" ] && [ -n "$disk_max_temp_f" ] && [ "$f" -eq "$disk_max_temp_f" ]; then
    grid_temp_hot[$i]="${f}°F"
  else
    grid_temp_normal[$i]="${f:-?}°F"
  fi
  # Prefix match, not equality: even with -L this box's NAME column shows
  # the partition ("sda1"), not the bare disk ("sda") pool_disks/hwmon use
  # -- confirmed via the debug dump above.
  dstate="$(printf '%s\n' "$disk_config" | awk -v d="$dev" 'index($1,d)==1 {print $2; exit}')"
  if [ "$dstate" = "ONLINE" ]; then
    grid_health_ok[$i]="OK"
  else
    grid_health_bad[$i]="${dstate:-?}"
  fi
done

tmp=$(mktemp "$OUT_DIR/.storage.XXXXXX")
cat > "$tmp" <<EOF
nvme_usage: $(awk -v v="$nvme_percent" 'BEGIN { printf "%02.0f%%", v }')
nvme_detail: $nvme_detail
arc_hit_pct: ARC: ${arc_hit_pct}%
pool_frag: Frag: ${pool_frag}
read_speed: $(human_bytes "$read_rate" 0)/s
write_speed: $(human_bytes "$write_rate" 0)/s
pool_scrub_ok: $scrub_ok_text
pool_scrub_bad: $scrub_bad_text
footer_dot_ok: $footer_dot_ok
footer_dot_warn: $footer_dot_warn
footer_dot_bad: $footer_dot_bad
footer_text_ok: $footer_text_ok
footer_text_warn: $footer_text_warn
footer_text_bad: $footer_text_bad
disk1_name: ${grid_name[1]:-}
disk1_temp_normal: ${grid_temp_normal[1]:-}
disk1_temp_hot: ${grid_temp_hot[1]:-}
disk1_temp_over: ${grid_temp_over[1]:-}
disk1_health_ok: ${grid_health_ok[1]:-}
disk1_health_bad: ${grid_health_bad[1]:-}
disk2_name: ${grid_name[2]:-}
disk2_temp_normal: ${grid_temp_normal[2]:-}
disk2_temp_hot: ${grid_temp_hot[2]:-}
disk2_temp_over: ${grid_temp_over[2]:-}
disk2_health_ok: ${grid_health_ok[2]:-}
disk2_health_bad: ${grid_health_bad[2]:-}
disk3_name: ${grid_name[3]:-}
disk3_temp_normal: ${grid_temp_normal[3]:-}
disk3_temp_hot: ${grid_temp_hot[3]:-}
disk3_temp_over: ${grid_temp_over[3]:-}
disk3_health_ok: ${grid_health_ok[3]:-}
disk3_health_bad: ${grid_health_bad[3]:-}
disk4_name: ${grid_name[4]:-}
disk4_temp_normal: ${grid_temp_normal[4]:-}
disk4_temp_hot: ${grid_temp_hot[4]:-}
disk4_temp_over: ${grid_temp_over[4]:-}
disk4_health_ok: ${grid_health_ok[4]:-}
disk4_health_bad: ${grid_health_bad[4]:-}
disk5_name: ${grid_name[5]:-}
disk5_temp_normal: ${grid_temp_normal[5]:-}
disk5_temp_hot: ${grid_temp_hot[5]:-}
disk5_temp_over: ${grid_temp_over[5]:-}
disk5_health_ok: ${grid_health_ok[5]:-}
disk5_health_bad: ${grid_health_bad[5]:-}
EOF
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
