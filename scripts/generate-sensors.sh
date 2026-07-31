#!/usr/bin/env bash
# Writes aliases that asterctl 0.2.0 can consume directly. No --sensor-mapping required.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
OUT_FILE="$OUT_DIR/dashboard.txt"
NET_IFACE="${NET_IFACE:-enp101s0}"
POOL_NAME="${POOL_NAME:-tank}"
STATE_FILE="$OUT_DIR/.network-state"

mkdir -p "$OUT_DIR"
# Binary (1024-based) math -- matches what `zfs list`/`df`/the TrueNAS UI
# actually compute -- but labeled "TB"/"GB"/"KB" without the "i", matching how
# those same tools display it and how most people read storage sizes.
human_bytes() { awk -v b="${1:-0}" -v p="${2:-2}" 'BEGIN { split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) {b/=1024;i++} printf "%.*f %s",p,b,u[i] }'; }

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
# Memory: read directly from /proc/meminfo. MemAvailable (not MemFree)
# accounts for reclaimable cache/buffers -- it's the figure `free -h`/htop
# use for "actually free for new allocations", matching what people expect
# a memory-used percentage to mean.
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_used_kb=$((mem_total_kb - mem_avail_kb))
mem_percent=$(awk -v u="$mem_used_kb" -v t="$mem_total_kb" 'BEGIN { if(t>0) printf "%.0f",100*u/t; else print 0 }')
mem_detail="$(human_bytes $((mem_used_kb * 1024))) / $(human_bytes $((mem_total_kb * 1024)))"

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
pool_detail="$(human_bytes "$POOL_USED") / $(human_bytes "$POOL_TOTAL")"

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

# Active connections: ESTABLISHED sockets on the SMB (445) and NFS (2049)
# ports, read straight from /proc/net/tcp{,6} -- no dependency on
# smbstatus/nfsstat/ss, which aren't guaranteed present (matches this
# project's general preference for /proc over CLI tools that might not be
# on PATH, e.g. cpu_percent/network_rx above). Port numbers are matched as
# fixed-width uppercase hex strings ("01BD"=445, "0801"=2049) rather than
# converted to decimal -- portable across awk implementations without
# strtonum() (this box's awk isn't gawk). This counts raw TCP connections,
# not distinct clients/users -- a client can hold more than one (SMB
# multichannel, repeated short-lived NFS RPCs), so treat it as "how much
# is this box being talked to" rather than a precise session count.
tcp_files=(/proc/net/tcp)
[ -r /proc/net/tcp6 ] && tcp_files+=(/proc/net/tcp6)
active_connections=$(awk '
  FNR>1 { split($2,a,":"); port=a[2]; st=$4
    if (st=="01" && (port=="01BD" || port=="0801")) c++ }
  END { print c+0 }
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
tmp=$(mktemp "$OUT_DIR/.dashboard.XXXXXX")
cat > "$tmp" <<EOF
cpu_percent: $(pct "$cpu_percent")
cpu_temperature: $(awk -v v="$cpu_temp" 'BEGIN { printf "%02.0f°F", v }')
memory_usage: $(pct "$mem_percent")
memory_detail: $mem_detail
pool_usage: $(pct "$pool_percent")
pool_detail: $pool_detail
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
