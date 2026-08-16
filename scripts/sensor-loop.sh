#!/usr/bin/env bash
# aoostar-sensors.service's loop body, extracted out of ExecStart= (added
# 2026-08-14) for two reasons:
# 1. A plain `sleep 1` after the four generator scripts gives a real period
#    of ~1s + however long they took to run (~0.35-0.4s combined under live
#    load), not 1s -- fine at the old 5s cadence (~5.1-5.3s, negligible
#    overshoot) but a real ~35-40% miss at 1s, confirmed on-device via
#    dashboard.txt's mtime advancing every ~1.35-1.4s instead of ~1s. This
#    script times its own work each cycle and only sleeps the remainder, so
#    the period self-corrects to LOOP_TARGET_SEC regardless of how long the
#    scripts take (doesn't accumulate drift across cycles -- each iteration
#    recomputes from its own actual elapsed time, not a running total).
# 2. The timing math needs `date +%s.%N`, and systemd's ExecStart= treats a
#    bare `%` as the start of its own specifier syntax -- doing this inline
#    in the unit file would need `%%`-escaping throughout, which is fragile
#    and hard to read. Keeping it in a real script avoids that entirely.
#
# Deliberately no `set -e`: if one generator script has a transient failure
# (non-zero exit), the loop should keep going, same tolerance the old
# inline `while true; do ...; done` unit-file loop already had (it never
# had `-e` either).
set -uo pipefail

DASHBOARD_DIR="${DASHBOARD_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
LOOP_TARGET_SEC="${LOOP_TARGET_SEC:-1}"

while true; do
  t0=$(date +%s.%N)
  "$DASHBOARD_DIR/scripts/generate-sensors.sh"
  "$DASHBOARD_DIR/scripts/generate-container-sensors.sh"
  "$DASHBOARD_DIR/scripts/generate-storage-sensors.sh"
  "$DASHBOARD_DIR/scripts/check-alert-supervisor.sh"
  t1=$(date +%s.%N)
  # Floor of 0.1s so a cycle that ever runs long (e.g. a slow zpool call)
  # can't turn this into a busy-loop with no sleep at all.
  sleep_for=$(awk -v a="$t0" -v b="$t1" -v target="$LOOP_TARGET_SEC" \
    'BEGIN { d = b - a; if (d < 0) d = 0; s = target - d; if (s < 0.1) s = 0.1; printf "%.3f", s }')
  sleep "$sleep_for"
done
