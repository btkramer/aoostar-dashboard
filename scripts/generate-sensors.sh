#!/usr/bin/env bash
# Writes aliases that asterctl 0.2.0 can consume directly. No --sensor-mapping required.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
OUT_FILE="$OUT_DIR/dashboard.txt"
NET_IFACE="${NET_IFACE:-enp101s0}"
POOL_NAME="${POOL_NAME:-tank}"
STATE_FILE="$OUT_DIR/.network-state"
# High-temp red thresholds (added 2026-07-31, same "all temps everywhere"
# request that added disk temp color-coding on Page 3 -- see
# generate-storage-sensors.sh's DISK_TEMP_HIGH_F for that one). Silicon
# runs far hotter than spinning disks before it's actually a concern, so
# these defaults are much higher than the disk grid's 130°F -- 185°F
# (~85°C) is comfortably below this chip's typical throttle point
# (Ryzen APUs are usually ~95°C/203°F for Tctl) while still well above
# normal idle/light-load readings (98°F CPU / 108°F GPU observed on this
# box), i.e. a "running hot" flag, not a "about to throttle" one. Not
# confirmed against this specific chip's datasheet -- tune via the env
# vars if these don't fit. Unlike the disk grid, there's no "hottest of
# the group" concept for a single CPU/single GPU reading, so these are
# just two-tier (normal/over), not three-tier (normal/hot/over).
CPU_TEMP_HIGH_F="${CPU_TEMP_HIGH_F:-185}"
GPU_TEMP_HIGH_F="${GPU_TEMP_HIGH_F:-185}"

mkdir -p "$OUT_DIR"
# Binary (1024-based) math -- matches what `zfs list`/`df`/the TrueNAS UI
# actually compute -- but labeled "TB"/"GB"/"KB" without the "i", matching how
# those same tools display it and how most people read storage sizes.
# KB is the smallest unit shown (i starts at 2, with an unconditional first
# /1024) -- raw bytes ("512 B") aren't useful at this dashboard's scale and
# read as noise next to the KB/MB/GB/TB values everywhere else.
human_bytes() { awk -v b="${1:-0}" -v p="${2:-2}" 'BEGIN { split("B KB MB GB TB",u," "); i=2; b/=1024; while (b>=1024 && i<5) {b/=1024;i++} printf "%.*f %s",p,b,u[i] }'; }

# CPU usage: read directly from /proc/stat rather than the vendor's
# sysinfo.txt -- that file turned out to be a one-time snapshot from initial
# setup (Modify == Birth == 2026-05-30), never live, not a bug that needed
# restarting anything. Percentage is a delta between this invocation and the
# last one (persisted in CPU_STATE_FILE), averaged over the ~5s loop
# interval -- same pattern already used below for network rx/tx, smoother
# than sampling twice within one invocation since it doesn't need an
# artificial sleep.
CPU_STATE_FILE="$OUT_DIR/.cpu-state"
read -r c_user c_nice c_system c_idle c_iowait c_irq c_softirq c_steal _ < <(awk '/^cpu /{ $1=""; print }' /proc/stat)
c_idle_all=$((c_idle + c_iowait))
c_total=$((c_user + c_nice + c_system + c_idle + c_iowait + c_irq + c_softirq + c_steal))
cpu_percent=0
if [ -r "$CPU_STATE_FILE" ]; then
  read -r p_total p_idle < "$CPU_STATE_FILE" || true
  p_total=${p_total:-$c_total}; p_idle=${p_idle:-$c_idle_all}
  d_total=$((c_total - p_total)); d_idle=$((c_idle_all - p_idle))
  if [ "$d_total" -gt 0 ]; then
    cpu_percent=$(awk -v dt="$d_total" -v di="$d_idle" 'BEGIN { printf "%.0f", 100*(dt-di)/dt }')
  fi
fi
printf '%s %s\n' "$c_total" "$c_idle_all" > "$CPU_STATE_FILE"
# CPU temperature: read the k10temp driver's Tctl sensor directly (this
# box is an AMD Ryzen APU -- confirmed via `sensors`/hwmon name matching
# 2026-07-28). Found by hwmon *name*, not a hardcoded hwmonN index -- that
# index isn't stable across reboots since it depends on module load order.
cpu_temp_c=0
for hw in /sys/class/hwmon/*; do
  if [ -r "$hw/name" ] && [ "$(cat "$hw/name")" = "k10temp" ] && [ -r "$hw/temp1_input" ]; then
    cpu_temp_c=$(awk -v m="$(cat "$hw/temp1_input")" 'BEGIN { printf "%.1f", m/1000 }')
    break
  fi
done
cpu_temp=$(awk -v c="$cpu_temp_c" 'BEGIN { printf "%.1f", c * 9 / 5 + 32 }')
# GPU usage + temperature: this box's AMD Ryzen APU exposes iGPU load via
# the amdgpu kernel driver's gpu_busy_percent sysfs file (a sibling of the
# PCI device dir, not under hwmon -- hwmon only carries the temp/power
# sensors), found by walking hwmon for the "amdgpu" name and using its
# device symlink to locate the PCI device dir, same "find by name, don't
# hardcode a path" rule as k10temp/drivetemp elsewhere in this script.
gpu_percent=0
gpu_temp_c=0
for hw in /sys/class/hwmon/*; do
  if [ -r "$hw/name" ] && [ "$(cat "$hw/name")" = "amdgpu" ]; then
    dev_dir=$(readlink -f "$hw/device")
    [ -r "$dev_dir/gpu_busy_percent" ] && gpu_percent=$(cat "$dev_dir/gpu_busy_percent")
    [ -r "$hw/temp1_input" ] && gpu_temp_c=$(awk -v m="$(cat "$hw/temp1_input")" 'BEGIN { printf "%.1f", m/1000 }')
    break
  fi
done
gpu_temp=$(awk -v c="$gpu_temp_c" 'BEGIN { printf "%.1f", c * 9 / 5 + 32 }')
# Memory: read directly from /proc/meminfo. MemAvailable (not MemFree)
# accounts for reclaimable cache/buffers -- it's the figure `free -h`/htop
# use for "actually free for new allocations", matching what people expect
# a memory-used percentage to mean.
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_used_kb=$((mem_total_kb - mem_avail_kb))
mem_percent=$(awk -v u="$mem_used_kb" -v t="$mem_total_kb" 'BEGIN { if(t>0) printf "%.0f",100*u/t; else print 0 }')
# Tightened format (2026-07-31, Page 1 4-column redesign to fit a new GPU
# column): "24.9/31.3 GB" instead of the old "24.89 GB / 31.32 GB" -- the
# old string (258px at fontSize 27) doesn't fit the new 228px column pitch
# (65/293/521/749, matching Page 2's spacing), the new one (168px) does.
# Unit dropped from the first (used) number since it's implied by the
# second -- only the total's human_bytes call keeps its unit suffix.
mem_used_fmt="$(human_bytes $((mem_used_kb * 1024)) 1)"
mem_total_fmt="$(human_bytes $((mem_total_kb * 1024)) 1)"
mem_detail="${mem_used_fmt% *}/${mem_total_fmt}"

# Real usable-capacity pool usage from the root dataset (used/avail, exact
# bytes via -p). Deliberately `zfs list`, not `zpool list` -- zpool's
# alloc/size are raw vdev capacity and include parity/redundancy overhead,
# which reads much higher than the actual usable space TrueNAS's own UI shows.
# POOL_USED / POOL_TOTAL can still be overridden via environment for testing.
if [ -z "${POOL_USED:-}" ] || [ -z "${POOL_TOTAL:-}" ]; then
  if command -v zfs >/dev/null 2>&1; then
    read -r zfs_used zfs_avail < <(zfs list -Hp -o used,avail "$POOL_NAME" 2>/dev/null) || true
  fi
  POOL_USED="${POOL_USED:-${zfs_used:-0}}"
  POOL_TOTAL="${POOL_TOTAL:-$(( ${zfs_used:-0} + ${zfs_avail:-0} ))}"
fi
pool_percent=$(awk -v u="$POOL_USED" -v t="$POOL_TOTAL" 'BEGIN { if(t>0) printf "%.0f",100*u/t; else print 0 }')
# Tightened format -- same reasoning as mem_detail above.
pool_used_fmt="$(human_bytes "$POOL_USED" 1)"
pool_total_fmt="$(human_bytes "$POOL_TOTAL" 1)"
pool_detail="${pool_used_fmt% *}/${pool_total_fmt}"

rx_file="/sys/class/net/$NET_IFACE/statistics/rx_bytes"; tx_file="/sys/class/net/$NET_IFACE/statistics/tx_bytes"
rx_now=0; tx_now=0; [ -r "$rx_file" ] && rx_now=$(<"$rx_file"); [ -r "$tx_file" ] && tx_now=$(<"$tx_file")
now=$(date +%s); rx_rate=0; tx_rate=0
if [ -r "$STATE_FILE" ]; then
  read -r old_time old_rx old_tx < "$STATE_FILE" || true
  elapsed=$((now - old_time)); [ "$elapsed" -lt 1 ] && elapsed=1
  rx_rate=$(( (rx_now - old_rx) / elapsed )); tx_rate=$(( (tx_now - old_tx) / elapsed ))
fi
printf '%s %s %s\n' "$now" "$rx_now" "$tx_now" > "$STATE_FILE"
ip_address=$(ip -4 -o addr show dev "$NET_IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1); ip_address=${ip_address:-Offline}

# Uptime: straight from /proc/uptime (first field, seconds since boot) --
# no dependency on `uptime`/`uptimed`'s locale-varying output format.
# Compact "Nd Nh" style matching this dashboard's terse convention
# elsewhere; drops to "Nh Nm" under a day, "Nm" under an hour.
uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
uptime_display=$(awk -v s="$uptime_seconds" 'BEGIN {
  d = int(s/86400); h = int((s%86400)/3600); m = int((s%3600)/60)
  if (d > 0) printf "%dd %dh", d, h
  else if (h > 0) printf "%dh %dm", h, m
  else printf "%dm", m
}')

# Active connections (broadened 2026-07-31 -- was SMB/NFS-only, then
# widened to all inbound connections same day, then refined again same day
# after real `ss -tnp state established` output from the box showed the
# first widening drastically overcounted). Read straight from
# /proc/net/tcp{,6} -- no dependency on ss/netstat, which aren't
# guaranteed present. Counts ESTABLISHED (state 01) sockets whose LOCAL
# port matches a real LISTEN (state 0A) port on this box, which separates
# inbound (someone connecting to a service we offer) from outbound (a
# container reaching out to the internet -- random high local port, not a
# listening one, excluded automatically).
#
# That alone still overcounted heavily on the real box: `docker-proxy`
# (Docker's userspace port-forwarder) shows up as established connections
# FROM other containers' bridge IPs (172.16-31.x.x, Docker's default IPAM
# range) TO this box's published ports -- e.g. redis on :6380 was hit by
# a dozen+ such connections from a single other container, none of them a
# real client. Same issue for services proxying to each other via this
# box's own LAN IP instead of localhost (seen live: nginx -> Jellyfin as
# `192.168.1.5:8096 <- 192.168.1.5:50530`, not caught by a 127.0.0.1-only
# loopback check since it's not loopback, it's the box's real IP talking
# to itself). Fixed by excluding both: any remote address in
# 172.16.0.0/12 (Docker's private range -- real LAN clients are on the
# home network's own subnet, e.g. 192.168.x.x, never overlaps), and any
# remote address equal to this box's own IP ($ip_address, computed above).
# True 127.0.0.1 loopback is also still excluded. hex2dec/is_internal are
# plain string-index hex parsing, not strtonum() (this box's awk isn't
# gawk, strtonum isn't portable here).
# KNOWN LIMITATION: this only catches the two noise patterns actually
# observed on the box (Docker bridge-range peers, self-via-LAN-IP) -- a
# container reaching this box's published port from some OTHER private
# range, or IPv6 loopback/self traffic, wouldn't be caught. Good enough
# for "how many real clients, approximately," not a guaranteed-exact count.
tcp_files=(/proc/net/tcp)
[ -r /proc/net/tcp6 ] && tcp_files+=(/proc/net/tcp6)
active_connections=$(awk -v own_ip="$ip_address" '
  function hex2dec(h,    i, v, c) {
    v = 0
    for (i = 1; i <= length(h); i++) {
      c = substr(h, i, 1)
      v = v * 16 + index("0123456789ABCDEF", c) - 1
    }
    return v
  }
  function is_internal(raddr,    b1, b2, b3, b4, dotted) {
    b1 = hex2dec(substr(raddr,7,2)); b2 = hex2dec(substr(raddr,5,2))
    if (b1 == 127) return 1
    if (b1 == 172 && b2 >= 16 && b2 <= 31) return 1
    b3 = hex2dec(substr(raddr,3,2)); b4 = hex2dec(substr(raddr,1,2))
    dotted = b1"."b2"."b3"."b4
    if (dotted == own_ip) return 1
    return 0
  }
  FNR>1 {
    split($2,loc,":"); lport=loc[2]
    split($3,rem,":"); raddr=rem[1]
    st=$4
    if (st=="0A") { listen[lport]=1 }
    else if (st=="01") { n++; el[n]=lport; er[n]=raddr }
  }
  END {
    for (i=1;i<=n;i++) {
      if ((el[i] in listen) && !is_internal(er[i])) c++
    }
    print c+0
  }
' "${tcp_files[@]}" 2>/dev/null)
active_connections=${active_connections:-0}

# Percent/temperature fields are formatted fully here (zero-padded to a
# minimum of 2 integer digits, growing naturally past that -- e.g. "04%",
# "81%", "100%") with the unit baked directly into the string, rather than
# relying on asterctl's own integerDigits handling. Confirmed from
# asterctl's actual source (crates/asterctl/src/format_value.rs) that it
# only supports two modes: always-pad-to-exactly-N-digits (saturating to
# repeated 9s if the real value is wider -- the original "stuck at 99" bug)
# or natural-width-no-padding at all -- neither gives "minimum 2, grow
# past that" on its own. But any value that fails to parse as a plain
# number is passed through completely unprocessed (this is already how
# e.g. memory_detail below displays as free-form text) -- so pre-formatting
# the full string here, with the unit's non-numeric character guaranteeing
# the parse fails, gets exactly the intended padding. matched by unit: ""
# on these fields in monitor.json. NOTE for future consumers of this file
# (e.g. the planned alert supervisor): these three fields are no longer
# bare numbers -- strip the trailing %/°F before doing numeric comparisons.
pct() { awk -v v="$1" 'BEGIN { printf "%02.0f%%", v }'; }

# CPU/GPU temp red-threshold color-toggle (added 2026-07-31, same trick as
# the disk grid's three-tier version, but two-tier here since a single
# CPU/GPU reading has no "hottest of the group" to highlight -- just
# normal vs over threshold).
cpu_temp_str=$(awk -v v="$cpu_temp" 'BEGIN { printf "%02.0f°F", v }')
cpu_temp_rounded=$(awk -v v="$cpu_temp" 'BEGIN { printf "%.0f", v }')
cpu_temperature_normal=""; cpu_temperature_over=""
if [ "$cpu_temp_rounded" -gt "$CPU_TEMP_HIGH_F" ]; then cpu_temperature_over="$cpu_temp_str"; else cpu_temperature_normal="$cpu_temp_str"; fi
gpu_temp_str=$(awk -v v="$gpu_temp" 'BEGIN { printf "%02.0f°F", v }')
gpu_temp_rounded=$(awk -v v="$gpu_temp" 'BEGIN { printf "%.0f", v }')
gpu_temperature_normal=""; gpu_temperature_over=""
if [ "$gpu_temp_rounded" -gt "$GPU_TEMP_HIGH_F" ]; then gpu_temperature_over="$gpu_temp_str"; else gpu_temperature_normal="$gpu_temp_str"; fi

tmp=$(mktemp "$OUT_DIR/.dashboard.XXXXXX")
cat > "$tmp" <<EOF
cpu_percent: $(pct "$cpu_percent")
cpu_temperature_normal: $cpu_temperature_normal
cpu_temperature_over: $cpu_temperature_over
memory_usage: $(pct "$mem_percent")
memory_detail: $mem_detail
pool_usage: $(pct "$pool_percent")
pool_detail: $pool_detail
gpu_percent: $(pct "$gpu_percent")
gpu_temperature_normal: $gpu_temperature_normal
gpu_temperature_over: $gpu_temperature_over
network_rx: $(human_bytes "$rx_rate" 0)/s
network_tx: $(human_bytes "$tx_rate" 0)/s
ip_address: $ip_address
date_time: $(date '+%b %d  %I:%M %p')
uptime_display: $uptime_display
active_connections: $active_connections
EOF
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
