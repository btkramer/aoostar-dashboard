#!/usr/bin/env bash
# Writes aliases that asterctl 0.2.0 can consume directly. No --sensor-mapping required.
set -euo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
OUT_DIR="$DASHBOARD_DIR/sensors"
OUT_FILE="$OUT_DIR/dashboard.txt"
SYSINFO_FILE="${SYSINFO_FILE:-/root/aoostar/sensors/sysinfo.txt}"
NET_IFACE="${NET_IFACE:-enp101s0}"
POOL_NAME="${POOL_NAME:-tank}"
STATE_FILE="$OUT_DIR/.network-state"

mkdir -p "$OUT_DIR"
get_value() { awk -F': ' -v k="$1" '$1 == k { print substr($0, length(k)+3); exit }' "$SYSINFO_FILE" 2>/dev/null || true; }
num() { printf '%s' "$1" | grep -Eo '[-+]?[0-9]+([.][0-9]+)?' | head -n1 || true; }
# Binary (1024-based) math -- matches what `zfs list`/`df`/the TrueNAS UI
# actually compute -- but labeled "TB"/"GB"/"KB" without the "i", matching how
# those same tools display it and how most people read storage sizes.
human_bytes() { awk -v b="${1:-0}" -v p="${2:-2}" 'BEGIN { split("B KB MB GB TB",u," "); i=1; while (b>=1024 && i<5) {b/=1024;i++} printf "%.*f %s",p,b,u[i] }'; }

cpu_percent=$(num "$(get_value cpu_usage_percent)")
if [ -z "$cpu_percent" ]; then
  cpu_percent=$(awk -F': ' '/^cpu_cpu[0-9]+_usage:/ { sum += $2+0; n++ } END { if (n) printf "%.0f", sum/n; else print 0 }' "$SYSINFO_FILE")
fi; cpu_percent=${cpu_percent:-0}
cpu_temp_c=$(num "$(get_value temperature_cpu)"); cpu_temp_c=${cpu_temp_c:-0}
cpu_temp=$(awk -v c="$cpu_temp_c" 'BEGIN { printf "%.1f", c * 9 / 5 + 32 }')
mem_percent=$(num "$(get_value mem_usage_percent)"); mem_percent=${mem_percent:-0}
mem_used=$(get_value mem_used)
mem_total=$(get_value mem_total)
mem_detail="$mem_used / $mem_total"

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

tmp=$(mktemp "$OUT_DIR/.dashboard.XXXXXX")
cat > "$tmp" <<EOF
cpu_percent: $cpu_percent
cpu_temperature: $cpu_temp
memory_usage: $mem_percent
memory_detail: $mem_detail
pool_usage: $pool_percent
pool_detail: $pool_detail
network_rx: $(human_bytes "$rx_rate" 0)/s
network_tx: $(human_bytes "$tx_rate" 0)/s
ip_address: $ip_address
date_time: $(date '+%b %d  %I:%M %p')
EOF
cat "$tmp" > "$OUT_FILE"
rm "$tmp"
chmod 644 "$OUT_FILE"
