# History: path migrations + tmpfs sensor storage (2026-08-13 / 2026-08-14)

*Frozen archive — closed, don't append to it; log new work in `MASTER_PLAN.md`
instead.* Living reference for the resulting architecture is `README.md`'s
"Sensor data lives on tmpfs, not disk" section — this file is the incident/reasoning
history behind it.

## 2026-08-13: reboot regression (tank-path move)

The project's 2026-08-11 move to `apps/projects/software/` left every systemd unit
file still hardcoded to the pre-move path. This didn't break anything immediately
(already-running processes don't re-resolve `ExecStart`), so sensor data went stale
silently until a reboot forced `asterctl` to start fresh against a nonexistent config
path — LCD fell back to the factory default screen. Fixed in the repo; **lesson**:
after any path move, the TrueNAS Post Init script entry (System Settings → Advanced →
Init/Shutdown Scripts) is UI state, not a repo file, and needs a separate manual
update — it will silently reinstall stale units on the next reboot otherwise. (Then
made moot the next day anyway — see below.)

## 2026-08-14: NVMe-pool migration (tank → nvme-pool)

The whole homelab moved `tank/apps` to a new dedicated `nvme-pool` (tracked in
`truenas-docker`'s own scope, not here) — same class of path fix as 2026-08-13, one
hop further. Repo paths updated tank → nvme-pool; deployed and verified live via
read-only SSH. Post Init re-pointed at the new path and confirmed correct
(`midclt call initshutdownscript.query`) the same day — closed, not an open item.

## 2026-08-14: sensor data moved to tmpfs

A `truenas-docker` write-load audit traced ~17k/day of unnecessary real-disk writes
to this project's 1s sensor loop rewriting several small files every cycle for data
with zero persistence value. Fixed: every generator script's output directory
became `${SENSOR_DIR:-$DASHBOARD_DIR/sensors}` (default unchanged for local/dev
runs), all three systemd units gained `RuntimeDirectory=aoostar-dashboard` (creates
`/run/aoostar-dashboard`, tmpfs) and pointed `SENSOR_DIR`/`--sensor-path` there.
Full current mechanics (which files, `RATE_WINDOW_SEC`, `CONTAINER_POLL_INTERVAL_SEC`,
the loop-interval speedup 5s→1s that came the same day) are documented live in
`README.md`, not duplicated here.

**One exception found later (2026-08-15) and fixed**: `.updates-cache` was
originally moved to tmpfs along with everything else, on the assumption that only a
reboot could lose it. That assumption was wrong — it was found silently vanishing
from `/run` well within a day with no reboot involved (most likely systemd's own
periodic `/run` cleanup, which the ~1s-rewritten files never sit still long enough
to be swept by, but a once-a-day file does). Moved back to persistent disk
permanently, unconditionally on both the write side (`check-container-updates.sh`)
and read side (`generate-container-sensors.sh`) so they can't drift onto different
paths — see `README.md`'s "Sensor data lives on tmpfs, not disk" section for the
current durability rule. **This is the one file that does NOT live on tmpfs** —
don't move it back without re-solving the same durability problem.
