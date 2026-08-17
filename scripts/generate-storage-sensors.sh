#!/usr/bin/env bash
# Page 3 (Storage) data. Reworked 2026-08-15 into a two-row-per-pool layout
# (TANK row, NVME row -- see monitor.json/render-storage-bg.py) now that
# nvme-pool is a real 4-drive raidz1, not just the boot/OS drive. Pool
# *capacity* for tank is NOT recomputed here -- the page reuses
# pool_usage/pool_detail from generate-sensors.sh's dashboard.txt directly
# (asterctl merges every *.txt under --sensor-path into one key/value map).
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
# SENSOR_DIR overrides where sensor/state files are written -- see the note
# in generate-sensors.sh.
OUT_DIR="${SENSOR_DIR:-$DASHBOARD_DIR/sensors}"
OUT_FILE="$OUT_DIR/storage.txt"
STATE_FILE="$OUT_DIR/.disk-io-state"
NVME_STATE_FILE="$OUT_DIR/.nvme-disk-io-state"
POOL_NAME="${POOL_NAME:-tank}"
# NVME_POOL_NAME used to mean "boot-pool" (Page 3's old col-1, capacity
# only). Repointed 2026-08-15 at the REAL nvme-pool (4-drive raidz1) now
# that it gets its own full row -- boot-pool moved to an alert-only fill%
# check instead (see BOOT_POOL_NAME below and check-alert-supervisor.sh),
# since it's a small, rarely-changing system drive that isn't worth a
# permanently-visible tile competing with metrics that move every second.
NVME_POOL_NAME="${NVME_POOL_NAME:-nvme-pool}"
BOOT_POOL_NAME="${BOOT_POOL_NAME:-boot-pool}"
# Rate/ratio calcs (disk I/O below) average over this many real seconds,
# not the loop's own 1s interval -- see generate-sensors.sh's matching
# network-rate comment for why.
RATE_WINDOW_SEC="${RATE_WINDOW_SEC:-5}"

mkdir -p "$OUT_DIR"
# KB is the smallest unit shown -- same reasoning as generate-sensors.sh's
# copy of this function.
human_bytes() { awk -v b="${1:-0}" -v p="${2:-2}" 'BEGIN { split("B KB MB GB TB",u," "); i=2; b/=1024; while (b>=1024 && i<5) {b/=1024;i++} printf "%.*f %s",p,b,u[i] }'; }
# For a used/total PAIR: human_bytes() picks each number's own best-fit
# unit independently, so "used/total" text built by stripping used_fmt's
# unit and keeping total_fmt's silently mislabels used whenever they land
# in different magnitude buckets (found live 2026-08-16: nvme-pool at
# 158G/1.84T rendered as "158.1/1.3 TB" -- 158.1 is actually GB). This
# scales BOTH numbers by total's unit instead, so they're always
# expressed in the same one.
human_bytes_pair() {
  awk -v used="${1:-0}" -v total="${2:-0}" -v p="${3:-1}" 'BEGIN {
    split("B KB MB GB TB", u, " "); i = 2; total /= 1024
    while (total >= 1024 && i < 5) { total /= 1024; i++ }
    divisor = 1024 ^ (i - 1)
    printf "%.*f/%.*f %s", p, used / divisor, p, total, u[i]
  }'
}

# ---- NVME (nvme-pool) capacity -- same used/avail-not-alloc/size
# reasoning as tank's pool_usage/pool_detail in generate-sensors.sh.
if [ -z "${NVME_USED:-}" ] || [ -z "${NVME_TOTAL:-}" ]; then
  if command -v zfs >/dev/null 2>&1; then
    read -r nvme_zfs_used nvme_zfs_avail < <(zfs list -Hp -o used,avail "$NVME_POOL_NAME" 2>/dev/null) || true
  fi
  NVME_USED="${NVME_USED:-${nvme_zfs_used:-0}}"
  NVME_TOTAL="${NVME_TOTAL:-$(( ${nvme_zfs_used:-0} + ${nvme_zfs_avail:-0} ))}"
fi
nvme_percent=$(awk -v u="$NVME_USED" -v t="$NVME_TOTAL" 'BEGIN { if(t>0) printf "%.0f",100*u/t; else print 0 }')
nvme_detail="$(human_bytes_pair "$NVME_USED" "$NVME_TOTAL" 1)"

# ---- boot-pool fill % -- alert-only (2026-08-15), no visible tile on any
# page. Small, rarely-changing OS/system drive -- not worth a permanent
# slot next to metrics that change every second, but a full boot-pool is a
# real problem, so check-alert-supervisor.sh thresholds this itself
# (BOOTPOOL_FULL_PCT) rather than this script doing its own color-toggle
# formatting (that trick exists for VISIBLE fields; this one is invisible
# until it crosses the line).
if command -v zfs >/dev/null 2>&1; then
  read -r bp_used bp_avail < <(zfs list -Hp -o used,avail "$BOOT_POOL_NAME" 2>/dev/null) || true
fi
bp_used=${bp_used:-0}; bp_avail=${bp_avail:-0}
bootpool_percent=$(awk -v u="$bp_used" -v a="$bp_avail" 'BEGIN { t=u+a; if(t>0) printf "%.0f",100*u/t; else print 0 }')

# ---- Pool member disks (tank): derived from which block devices have a
# `drivetemp` hwmon sensor attached (same technique cpu_temperature uses
# for k10temp -- find by hwmon *name*, not a hardcoded path, since indices
# shift across reboots). On this box that resolves to the 5 SATA disks
# forming "tank" -- NVMe drives don't have a drivetemp sensor so they're
# naturally excluded. Sorted (not hwmon glob order, which isn't stable) so
# each disk lands in the same grid column every cycle.
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
MAX_DISKS=5  # matches this box's real tank disk count; grid columns fixed in monitor.json

# ---- Pool health text (shared helper, used for both tank and nvme-pool
# below) -- `-L` ("real paths") confirmed necessary on this box: without
# it, the config table's NAME column shows the persistent GUID/partuuid
# TrueNAS SCALE actually uses (e.g. a UUID string), not a device name.
zpool_status_L() { command -v zpool >/dev/null 2>&1 && zpool status -L "$1" 2>/dev/null || true; }

zstatus="$(zpool_status_L "$POOL_NAME")"
nvme_zstatus="$(zpool_status_L "$NVME_POOL_NAME")"

# ---- nvme-pool member disks -- discovered from `zpool status -L
# nvme-pool`'s config table rather than blind hwmon iteration, because
# hwmon can't distinguish nvme-pool's 4 drives from boot-pool's own NVMe
# drive (both just show up as hwmon name=="nvme" -- confirmed on this box,
# 5 total nvme hwmon devices exist, only 4 belong to nvme-pool). Config
# table lines look like "nvme1n1p1  ONLINE ..."; strip the trailing
# partition suffix to get the whole-disk name diskstats/hwmon use.
nvme_disk_config="$(printf '%s\n' "$nvme_zstatus" | awk '/^[[:space:]]*config:/{f=1;next} /^[[:space:]]*errors:/{f=0} f')"
nvme_pool_disks=()
while read -r dname; do
  [ -n "$dname" ] && nvme_pool_disks+=("$dname")
done < <(printf '%s\n' "$nvme_disk_config" | awk '{print $1}' | grep -oE '^nvme[0-9]+n[0-9]+' | sort -u)
MAX_NVME_DISKS=4  # matches nvme-pool's real drive count; grid columns fixed in monitor.json

# ---- Read/write throughput (tank): sum sectors read/written (always 512
# bytes/sector -- a fixed kernel accounting unit) across the pool's member
# disks between consecutive invocations. Same delta-over-interval pattern
# as cpu_percent/network_rx, same periodic-baseline-reset windowing as
# generate-sensors.sh's network rate.
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
  if [ "$elapsed" -ge "$RATE_WINDOW_SEC" ]; then
    printf '%s %s %s\n' "$now" "$sectors_read" "$sectors_written" > "$STATE_FILE"
  fi
else
  printf '%s %s %s\n' "$now" "$sectors_read" "$sectors_written" > "$STATE_FILE"
fi

# ---- Read/write throughput (nvme-pool): identical pattern, own state
# file, own member-disk list.
nvme_sectors_read=0; nvme_sectors_written=0
for dev in "${nvme_pool_disks[@]}"; do
  read -r sr sw < <(awk -v d="$dev" '$3==d {print $6, $10}' /proc/diskstats)
  nvme_sectors_read=$((nvme_sectors_read + ${sr:-0}))
  nvme_sectors_written=$((nvme_sectors_written + ${sw:-0}))
done
nvme_read_rate=0; nvme_write_rate=0
if [ -r "$NVME_STATE_FILE" ]; then
  read -r nvme_old_time nvme_old_sr nvme_old_sw < "$NVME_STATE_FILE" || true
  nvme_elapsed=$((now - nvme_old_time)); [ "$nvme_elapsed" -lt 1 ] && nvme_elapsed=1
  nvme_read_rate=$(( (nvme_sectors_read - nvme_old_sr) * 512 / nvme_elapsed ))
  nvme_write_rate=$(( (nvme_sectors_written - nvme_old_sw) * 512 / nvme_elapsed ))
  if [ "$nvme_elapsed" -ge "$RATE_WINDOW_SEC" ]; then
    printf '%s %s %s\n' "$now" "$nvme_sectors_read" "$nvme_sectors_written" > "$NVME_STATE_FILE"
  fi
else
  printf '%s %s %s\n' "$now" "$nvme_sectors_read" "$nvme_sectors_written" > "$NVME_STATE_FILE"
fi

# ---- Per-disk temperature (tank, drivetemp hwmon) -- unchanged technique.
DISK_TEMP_HIGH_F="${DISK_TEMP_HIGH_F:-130}"
declare -A disk_temp_f_by_dev=()
for hw in /sys/class/hwmon/*; do
  if [ -r "$hw/name" ] && [ "$(cat "$hw/name")" = "drivetemp" ] && [ -r "$hw/temp1_input" ]; then
    dev=$(ls "$hw/device/block/" 2>/dev/null | head -n1)
    [ -z "$dev" ] && continue
    c=$(cat "$hw/temp1_input")
    disk_temp_f_by_dev["$dev"]=$(awk -v m="$c" 'BEGIN { printf "%.0f", (m/1000)*9/5+32 }')
  fi
done
disk_max_temp_f=""
for dev in "${!disk_temp_f_by_dev[@]}"; do
  t="${disk_temp_f_by_dev[$dev]}"
  if [ -z "$disk_max_temp_f" ] || [ "$t" -gt "$disk_max_temp_f" ]; then
    disk_max_temp_f="$t"
  fi
done

# ---- Per-disk temperature (nvme-pool, `nvme` hwmon) -- separate
# threshold from spinning disks: NVMe drives idle noticeably hotter (two
# of this box's four nvme-pool members read ~125-127°F at idle, confirmed
# live 2026-08-15), so reusing DISK_TEMP_HIGH_F's 130°F would false-alarm
# almost immediately. 160°F gives real headroom above observed idle temps
# while still catching genuine trouble -- not vendor-datasheet-confirmed
# for these specific drives, tune via env var if it doesn't hold up.
NVME_TEMP_HIGH_F="${NVME_TEMP_HIGH_F:-160}"
declare -A nvme_temp_f_by_dev=()
for hw in /sys/class/hwmon/*; do
  if [ -r "$hw/name" ] && [ "$(cat "$hw/name")" = "nvme" ] && [ -r "$hw/temp1_input" ]; then
    dev=$(ls "$hw"/device/nvme*/ 2>/dev/null | grep -oE 'nvme[0-9]+n[0-9]+' | head -n1)
    [ -z "$dev" ] && continue
    c=$(cat "$hw/temp1_input")
    nvme_temp_f_by_dev["$dev"]=$(awk -v m="$c" 'BEGIN { printf "%.0f", (m/1000)*9/5+32 }')
  fi
done
nvme_max_temp_f=""
for dev in "${nvme_pool_disks[@]}"; do
  t="${nvme_temp_f_by_dev[$dev]:-}"
  [ -z "$t" ] && continue
  if [ -z "$nvme_max_temp_f" ] || [ "$t" -gt "$nvme_max_temp_f" ]; then
    nvme_max_temp_f="$t"
  fi
done

# ---- Pool state (both pools).
pool_state="UNKNOWN"
[ -n "$zstatus" ] && pool_state="$(printf '%s\n' "$zstatus" | awk -F': ' '/^[[:space:]]*state:/ {print $2; exit}')"
nvme_pool_state="UNKNOWN"
[ -n "$nvme_zstatus" ] && nvme_pool_state="$(printf '%s\n' "$nvme_zstatus" | awk -F': ' '/^[[:space:]]*state:/ {print $2; exit}')"

# ---- Scrub status text + fragmentation % (restored 2026-08-15, 3rd pass
# -- dropped in the first Page-3 rework that same day for lack of room,
# then explicitly asked back once the row layout had space for a 4th
# column). Shared helper since the scan-block parsing is identical for
# tank and nvme-pool -- only the pool name and its zpool status text
# differ. ARC hit % (the third field the old single-row design packed
# into this same column) is NOT restored: it's a system-wide ZFS stat
# (/proc/spl/kstat/zfs/arcstats has no per-pool breakdown), so showing it
# under both TANK and NVME would just repeat the same number twice --
# confirmed with Brian, dropped by choice, not an oversight.
#
# The SCRUB column itself was later dropped entirely too (2026-08-15, 5th
# pass -- "not sure the current scrub column is very valuable at this
# point", freed its width for a bigger CAPACITY/READ/WRITE), so
# scrub_ok_text/frag (this function's 1st/3rd return values) are no
# longer written to storage.txt at all -- nothing displays them. Still
# computed, because scrub_bad_text (2nd value) still needs to feed the
# footer/alert severity tier below exactly as before -- a scrub finding
# real errors is still worth surfacing even with no dedicated visible
# tile, same reasoning as pool_frag/bootpool_percent already established
# on this page.
# Prints "scrub_ok_text<TAB>scrub_bad_text<TAB>frag" on stdout.
compute_scrub_frag() {
  local zs="$1" pn="$2" ok="" bad="" frag="?" frag_raw scan_block
  if command -v zpool >/dev/null 2>&1; then
    # Own `zpool list` call since `zpool status` doesn't carry this field.
    # `-Hp` for a plain machine-readable percentage (0-100); reads "-" on
    # pools where the fragmentation feature isn't active.
    frag_raw="$(zpool list -Hp -o frag "$pn" 2>/dev/null || true)"
    [ -n "$frag_raw" ] && [ "$frag_raw" != "-" ] && frag="${frag_raw}%"
  fi
  if [ -n "$zs" ]; then
    # The scan block can span multiple lines -- an active scrub's %/ETA is
    # on the line(s) after "scan:", not on it. Capture from "scan:" up to
    # (not including) "config:" -- tolerate leading whitespace before
    # "config:" (this box's real `zpool status` needs it -- a column-0
    # assumption was wrong and let the capture run into the per-device
    # config table, picking up an unrelated second "on <date>" from there).
    scan_block="$(printf '%s\n' "$zs" | awk '/^[[:space:]]*scan:/{f=1} /^[[:space:]]*config:/{f=0} f')"
    # head -n1 on every extraction below is deliberate defense-in-depth for
    # the same reason -- don't rely solely on scan_block's boundary being
    # exactly right for every zpool status variant.
    if printf '%s' "$scan_block" | grep -q "none requested"; then
      ok="Scrub: never run"
    elif printf '%s' "$scan_block" | grep -qi "resilver.*in progress"; then
      local pct
      pct="$(printf '%s' "$scan_block" | grep -oE '[0-9]+(\.[0-9]+)?% done' | head -n1 | grep -oE '^[0-9]+')"
      ok="Resilver: ${pct:-0}%"
    elif printf '%s' "$scan_block" | grep -qi "scrub in progress"; then
      local pct
      pct="$(printf '%s' "$scan_block" | grep -oE '[0-9]+(\.[0-9]+)?% done' | head -n1 | grep -oE '^[0-9]+')"
      ok="Scrub: ${pct:-0}% done"
    elif printf '%s' "$scan_block" | grep -q "scrub repaired\|scrub canceled"; then
      local errs raw_date fmt_date plural
      errs="$(printf '%s' "$scan_block" | grep -oE 'with [0-9]+ errors' | head -n1 | grep -oE '[0-9]+')"
      errs="${errs:-0}"
      raw_date="$(printf '%s' "$scan_block" | grep -oE 'on .*$' | head -n1 | sed 's/^on //')"
      fmt_date="$(date -d "$raw_date" '+%b %d' 2>/dev/null || true)"
      [ -z "$fmt_date" ] && fmt_date="$raw_date"
      if [ "$errs" -eq 0 ] 2>/dev/null; then
        # "Last:" not "Scrub:" -- redundant under the SCRUB column header.
        # The other branches above (never run / in-progress / resilver)
        # keep their own verb since they're not just a bare date.
        ok="Last: $fmt_date"
      else
        plural=""; [ "$errs" != "1" ] && plural="s"
        bad="${errs} error${plural} found!"
      fi
    fi
  fi
  [ -z "$ok" ] && [ -z "$bad" ] && ok="Scrub: unknown"
  # Field separator is \x1f (ASCII unit separator), not a tab -- bash's
  # `read` treats tab as IFS *whitespace* even when it's the only
  # character in IFS, which collapses consecutive delimiters and silently
  # shifts every field after an empty one (confirmed live: with $bad empty,
  # `read -r a b c` on "$ok\t\t$frag" put $frag into $b, leaving $c empty).
  # \x1f isn't whitespace, so empty fields are preserved correctly.
  printf '%s\x1f%s\x1f%s\n' "$ok" "$bad" "$frag"
}
IFS=$'\x1f' read -r scrub_ok_text scrub_bad_text pool_frag < <(compute_scrub_frag "$zstatus" "$POOL_NAME")
IFS=$'\x1f' read -r nvme_scrub_ok_text nvme_scrub_bad_text nvme_pool_frag < <(compute_scrub_frag "$nvme_zstatus" "$NVME_POOL_NAME")

pool_tier() {
  case "$1" in
    ONLINE) echo 0 ;;
    DEGRADED) echo 1 ;;
    *) echo 2 ;;  # FAULTED, OFFLINE, UNAVAIL, REMOVED, UNKNOWN
  esac
}
state_tier=$(pool_tier "$pool_state")
nvme_state_tier=$(pool_tier "$nvme_pool_state")
scrub_tier=0
[ -n "$scrub_bad_text" ] && scrub_tier=1
nvme_scrub_tier=0
[ -n "$nvme_scrub_bad_text" ] && nvme_scrub_tier=1

# Overall tier is the worst of: tank state, tank scrub errors, nvme-pool
# state, nvme-pool scrub errors. footer_word is just the bare state/signal
# word (ONLINE/DEGRADED/FAULTED/.../ERRORS), no pool-name prefix
# (2026-08-17: dropped "NVME " -- on-device it collided with the footer's
# date/time text at DEGRADED length, and which pool is responsible is
# already unambiguous from the alert-interrupt page this same tier change
# triggers, plus which row's bar is red on this page). Ties (e.g. both
# pools have scrub errors) favor whichever was checked first below --
# tank.
tier=$state_tier
footer_word="$pool_state"
[ "$scrub_tier" -gt "$tier" ] && { tier=$scrub_tier; footer_word="ERRORS"; }
if [ "$nvme_state_tier" -gt "$tier" ]; then
  tier=$nvme_state_tier
  footer_word="$nvme_pool_state"
fi
if [ "$nvme_scrub_tier" -gt "$tier" ]; then
  tier=$nvme_scrub_tier
  footer_word="ERRORS"
fi

dot='●'
footer_dot_ok=""; footer_dot_warn=""; footer_dot_bad=""
footer_text_ok=""; footer_text_warn=""; footer_text_bad=""
case "$tier" in
  0) footer_dot_ok="$dot"; footer_text_ok="ONLINE" ;;
  1) footer_dot_warn="$dot"; footer_text_warn="${footer_word:-UNKNOWN}" ;;
  2) footer_dot_bad="$dot"; footer_text_bad="${footer_word:-UNKNOWN}" ;;
esac

# ---- Per-disk grid (tank, 5 slots). Reworked 2026-08-15 (2nd pass, same
# day) from 2 lines/disk (name+temp, then a health TEXT line below it) down
# to 1 line/disk -- on-device the health line's baseline sat only ~22px
# below the temp line, closer than either font's own ascent+descent, so it
# visibly overlapped; and the tank sub-row's health line + the nvme
# sub-row's name/temp line right below it had the same problem between
# them. Health is now a small colored DOT next to temp on the same
# baseline (grid_dot_ok/grid_dot_bad) instead of its own text line/row --
# same ok/bad toggle-field convention the footer already uses. The actual
# state WORD (grid_health_ok/grid_health_bad) is still computed and written
# below for check-alert-supervisor.sh, which needs the real text (e.g.
# "FAULTED") for its alert-line detail -- only the on-grid glyph changed,
# not what's tracked.
disk_config="$(printf '%s\n' "$zstatus" | awk '/^[[:space:]]*config:/{f=1;next} /^[[:space:]]*errors:/{f=0} f')"
declare -A grid_name=() grid_temp_normal=() grid_temp_hot=() grid_temp_over=() grid_health_ok=() grid_health_bad=() grid_dot_ok=() grid_dot_bad=()
for i in $(seq 1 "$MAX_DISKS"); do
  idx=$((i - 1))
  dev="${pool_disks[$idx]:-}"
  [ -z "$dev" ] && continue
  f="${disk_temp_f_by_dev[$dev]:-}"
  grid_name[$i]="$dev"
  if [ -n "$f" ] && [ "$f" -gt "$DISK_TEMP_HIGH_F" ]; then
    grid_temp_over[$i]="${f}°F"
  elif [ -n "$f" ] && [ -n "$disk_max_temp_f" ] && [ "$f" -eq "$disk_max_temp_f" ]; then
    grid_temp_hot[$i]="${f}°F"
  else
    grid_temp_normal[$i]="${f:-?}°F"
  fi
  dstate="$(printf '%s\n' "$disk_config" | awk -v d="$dev" 'index($1,d)==1 {print $2; exit}')"
  if [ "$dstate" = "ONLINE" ]; then
    grid_health_ok[$i]="OK"
    grid_dot_ok[$i]="●"
  else
    grid_health_bad[$i]="${dstate:-?}"
    grid_dot_bad[$i]="●"
  fi
done

# ---- Per-disk grid (nvme-pool, 4 slots) -- same pattern/rework as tank
# above. Device names ("nvme1n1"..) are longer than tank's ("sda"..) and
# the grid column is sized for the short form, so display as "NVMe1"..
# "NVMe4" instead of the raw kernel name -- also reads more clearly than a
# raw device node on a small panel.
declare -A nvme_grid_name=() nvme_grid_temp_normal=() nvme_grid_temp_hot=() nvme_grid_temp_over=() nvme_grid_health_ok=() nvme_grid_health_bad=() nvme_grid_dot_ok=() nvme_grid_dot_bad=()
for i in $(seq 1 "$MAX_NVME_DISKS"); do
  idx=$((i - 1))
  dev="${nvme_pool_disks[$idx]:-}"
  [ -z "$dev" ] && continue
  f="${nvme_temp_f_by_dev[$dev]:-}"
  ctrl="$(printf '%s' "$dev" | grep -oE '^nvme[0-9]+')"
  nvme_grid_name[$i]="NVMe${ctrl#nvme}"
  if [ -n "$f" ] && [ "$f" -gt "$NVME_TEMP_HIGH_F" ]; then
    nvme_grid_temp_over[$i]="${f}°F"
  elif [ -n "$f" ] && [ -n "$nvme_max_temp_f" ] && [ "$f" -eq "$nvme_max_temp_f" ]; then
    nvme_grid_temp_hot[$i]="${f}°F"
  else
    nvme_grid_temp_normal[$i]="${f:-?}°F"
  fi
  ndstate="$(printf '%s\n' "$nvme_disk_config" | awk -v d="$dev" 'index($1,d)==1 {print $2; exit}')"
  if [ "$ndstate" = "ONLINE" ]; then
    nvme_grid_health_ok[$i]="OK"
    nvme_grid_dot_ok[$i]="●"
  else
    nvme_grid_health_bad[$i]="${ndstate:-?}"
    nvme_grid_dot_bad[$i]="●"
  fi
done

tmp=$(mktemp "$OUT_DIR/.storage.XXXXXX")
cat > "$tmp" <<EOF
nvme_usage: $(awk -v v="$nvme_percent" 'BEGIN { printf "%02.0f%%", v }')
nvme_detail: $nvme_detail
bootpool_percent: $bootpool_percent
read_speed: $(human_bytes "$read_rate" 0)/s
write_speed: $(human_bytes "$write_rate" 0)/s
nvme_read_speed: $(human_bytes "$nvme_read_rate" 0)/s
nvme_write_speed: $(human_bytes "$nvme_write_rate" 0)/s
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
disk1_dot_ok: ${grid_dot_ok[1]:-}
disk1_dot_bad: ${grid_dot_bad[1]:-}
disk2_name: ${grid_name[2]:-}
disk2_temp_normal: ${grid_temp_normal[2]:-}
disk2_temp_hot: ${grid_temp_hot[2]:-}
disk2_temp_over: ${grid_temp_over[2]:-}
disk2_health_ok: ${grid_health_ok[2]:-}
disk2_health_bad: ${grid_health_bad[2]:-}
disk2_dot_ok: ${grid_dot_ok[2]:-}
disk2_dot_bad: ${grid_dot_bad[2]:-}
disk3_name: ${grid_name[3]:-}
disk3_temp_normal: ${grid_temp_normal[3]:-}
disk3_temp_hot: ${grid_temp_hot[3]:-}
disk3_temp_over: ${grid_temp_over[3]:-}
disk3_health_ok: ${grid_health_ok[3]:-}
disk3_health_bad: ${grid_health_bad[3]:-}
disk3_dot_ok: ${grid_dot_ok[3]:-}
disk3_dot_bad: ${grid_dot_bad[3]:-}
disk4_name: ${grid_name[4]:-}
disk4_temp_normal: ${grid_temp_normal[4]:-}
disk4_temp_hot: ${grid_temp_hot[4]:-}
disk4_temp_over: ${grid_temp_over[4]:-}
disk4_health_ok: ${grid_health_ok[4]:-}
disk4_health_bad: ${grid_health_bad[4]:-}
disk4_dot_ok: ${grid_dot_ok[4]:-}
disk4_dot_bad: ${grid_dot_bad[4]:-}
disk5_name: ${grid_name[5]:-}
disk5_temp_normal: ${grid_temp_normal[5]:-}
disk5_temp_hot: ${grid_temp_hot[5]:-}
disk5_temp_over: ${grid_temp_over[5]:-}
disk5_health_ok: ${grid_health_ok[5]:-}
disk5_health_bad: ${grid_health_bad[5]:-}
disk5_dot_ok: ${grid_dot_ok[5]:-}
disk5_dot_bad: ${grid_dot_bad[5]:-}
nvme_disk1_name: ${nvme_grid_name[1]:-}
nvme_disk1_temp_normal: ${nvme_grid_temp_normal[1]:-}
nvme_disk1_temp_hot: ${nvme_grid_temp_hot[1]:-}
nvme_disk1_temp_over: ${nvme_grid_temp_over[1]:-}
nvme_disk1_health_ok: ${nvme_grid_health_ok[1]:-}
nvme_disk1_health_bad: ${nvme_grid_health_bad[1]:-}
nvme_disk1_dot_ok: ${nvme_grid_dot_ok[1]:-}
nvme_disk1_dot_bad: ${nvme_grid_dot_bad[1]:-}
nvme_disk2_name: ${nvme_grid_name[2]:-}
nvme_disk2_temp_normal: ${nvme_grid_temp_normal[2]:-}
nvme_disk2_temp_hot: ${nvme_grid_temp_hot[2]:-}
nvme_disk2_temp_over: ${nvme_grid_temp_over[2]:-}
nvme_disk2_health_ok: ${nvme_grid_health_ok[2]:-}
nvme_disk2_health_bad: ${nvme_grid_health_bad[2]:-}
nvme_disk2_dot_ok: ${nvme_grid_dot_ok[2]:-}
nvme_disk2_dot_bad: ${nvme_grid_dot_bad[2]:-}
nvme_disk3_name: ${nvme_grid_name[3]:-}
nvme_disk3_temp_normal: ${nvme_grid_temp_normal[3]:-}
nvme_disk3_temp_hot: ${nvme_grid_temp_hot[3]:-}
nvme_disk3_temp_over: ${nvme_grid_temp_over[3]:-}
nvme_disk3_health_ok: ${nvme_grid_health_ok[3]:-}
nvme_disk3_health_bad: ${nvme_grid_health_bad[3]:-}
nvme_disk3_dot_ok: ${nvme_grid_dot_ok[3]:-}
nvme_disk3_dot_bad: ${nvme_grid_dot_bad[3]:-}
nvme_disk4_name: ${nvme_grid_name[4]:-}
nvme_disk4_temp_normal: ${nvme_grid_temp_normal[4]:-}
nvme_disk4_temp_hot: ${nvme_grid_temp_hot[4]:-}
nvme_disk4_temp_over: ${nvme_grid_temp_over[4]:-}
nvme_disk4_health_ok: ${nvme_grid_health_ok[4]:-}
nvme_disk4_health_bad: ${nvme_grid_health_bad[4]:-}
nvme_disk4_dot_ok: ${nvme_grid_dot_ok[4]:-}
nvme_disk4_dot_bad: ${nvme_grid_dot_bad[4]:-}
EOF
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
