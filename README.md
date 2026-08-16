# AOOSTAR WTR MAX Dashboard

A restrained, distance-readable front-panel dashboard for `asterctl` 0.2.0.
It uses the supported AOOSTAR-X panel format, so it stays independent of the
`aoostar-rs` source tree.

## Included pages

`monitor.json` rotates through four 960 × 376 panels (`setup.switchTime`
controls dwell time; `mianban` lists the rotation order — normally
`[1, 2, 3]`, becoming `[1, 4, 2, 4, 3, 4]` while the alert-interrupt
supervisor has an active condition, see below):

**System Overview** — CPU load and temperature, memory percent and used /
total, pool use, network receive / transmit rate, IP address and date/time.
Rendered from `sensors/dashboard.txt` by `scripts/generate-sensors.sh`.

**Container Overview** — Running / Healthy / Issues / Updates-available
counts, plus one status line: a truncated list of the affected container
names (issues take priority over updates when both are present), or
"✓ Everything Healthy" when there's nothing to report. Deliberately not a
per-container list — the container count only grows over time, and the page
is sized for a summary, not a scrolling table. Rendered from
`sensors/containers.txt` by `scripts/generate-container-sensors.sh`, which
runs on the same 1-second loop as `generate-sensors.sh` (no registry calls,
just `docker ps`/`docker inspect` — though at this cadence, on a stack with
many containers, that's a `docker inspect` per running/exited container
every second; see "Sensor data lives on tmpfs, not disk" below for the
tradeoff).

Update detection needs a value to compare against, which isn't cheap to get
that often: `scripts/check-container-updates.sh` compares each running
container's locally-pulled image digest against its registry's current
digest for the same tag (generic OCI Distribution auth flow — works against
Docker Hub, GHCR, quay.io, lscr.io, and most self-hosted registries without
per-registry special-casing) and writes the result to `sensors/.updates-cache`.
It runs once a day via `aoostar-container-updates.timer`, not the fast loop,
to stay well clear of registry rate limits (Docker Hub's anonymous pull limit
in particular). Requires `jq`; installs via `apt-get install -y jq` if
missing (it silently skips and logs a note if `jq` or `docker` isn't found,
rather than failing the whole run).

**Storage Overview** (reworked 2026-08-15 into a two-row-per-pool layout —
see "Page 3: one row per pool" below) — a TANK row and an NVME row, each
showing that pool's capacity/read/write, plus a two-line disk grid (tank's
5 disks, then nvme-pool's 4) with per-disk temperature and health. Rendered
from `sensors/storage.txt` by `scripts/generate-storage-sensors.sh`, plus
`pool_usage`/`pool_detail` reused directly from `sensors/dashboard.txt` for
the TANK row's capacity (asterctl merges every `*.txt` under
`--sensor-path` into one key/value map, so any panel can reference any
key from any file).

**Alert-interrupt supervisor** — a normally-absent panel that interleaves
into the rotation only while at least one monitored condition is active
(pool faulted/degraded, a disk health error, CPU/GPU/disk/NVMe over-temp,
container issues, or the boot drive nearly full), most severe first,
capped at 6 lines. See `scripts/check-alert-supervisor.sh`'s own header
comment for the full design/debounce/mianban-swap mechanism.

The visual labels, dividers, and accent bars are supplied as editable SVG
sources where they still exist (`img/system-overview.svg`,
`img/container-overview.svg`, `img/storage-overview.svg` — the latter now
stale relative to the 2026-08-15 row rework, see the PNG-generation note
below) and matching ready-to-use PNGs. The text values are rendered live by
`asterctl` from files in `sensors/`.

## Install on TrueNAS

Copy this directory to a persistent location, for example
`/mnt/nvme-pool/apps/projects/software/aoostar-dashboard`. The included PNG is ready to deploy. If
you edit the SVG, regenerate the PNG at its native 960 × 376 dimensions.

Configure the values at the top of `scripts/generate-sensors.sh`, make it
executable, and test it:

```sh
chmod +x scripts/generate-sensors.sh
scripts/generate-sensors.sh
cat sensors/dashboard.txt
```

Copy the known-working font from the existing AOOSTAR config before launching
the panel (the configured font name is `HarmonyOS_Sans_SC_Bold`):

```sh
mkdir -p fonts
cp /tmp/cfg/fonts/HarmonyOS_Sans_SC_Bold.ttf fonts/
```

Run the panel with the same persistent dashboard directory for both the config
and image lookup:

```sh
asterctl \
  --device /dev/serial/by-id/usb-Synwit_USB_Virtual_COM-if00 \
  --config /mnt/nvme-pool/apps/projects/software/aoostar-dashboard/monitor.json \
  --config-dir /mnt/nvme-pool/apps/projects/software/aoostar-dashboard \
  --sensor-path /mnt/nvme-pool/apps/projects/software/aoostar-dashboard/sensors/dashboard.txt
```

`--device` pins asterctl to the WTR MAX's onboard LCD by its stable `/dev/serial/by-id/`
symlink rather than a raw `/dev/ttyACMn` path (device numbering isn't exclusive to this
device and shifts depending on what else is plugged in). See the "USB-serial device
scoping" section below for why this matters.

Schedule the sensor script every second (cron, a small service, or a
TrueNAS post-init task) — `asterctl` can refresh the current page every
second, which is also the practical ceiling for this loop (see "Sensor data
lives on tmpfs, not disk" below for why 1s and not faster). The generator
simply replaces the sensor file atomically.

## Persistence across reboot

The dashboard runs as systemd units instead of a hand-rolled `nohup`
background script:

- `aoostar-asterctl.service` — the LCD renderer, `Restart=always`.
- `aoostar-sensors.service` — the 1-second sensor loop (all four generator
  scripts: `generate-sensors.sh`, `generate-container-sensors.sh`,
  `generate-storage-sensors.sh`, `check-alert-supervisor.sh`),
  `Restart=always`.
- `aoostar-container-updates.timer` / `.service` — the daily registry-digest
  update check, `OnCalendar=daily` with `Persistent=true` (catches up after
  a reboot/downtime instead of silently missing a day).

**Important:** on this box, launching `asterctl` via `nohup ... &` from an
interactive shell is unreliable — it intermittently (and eventually
consistently) fails to exec with a `Function not implemented` error once the
process is detached from the login session, almost certainly a systemd
session/cgroup scoping quirk. `systemd-run` / real unit files (which run
under `system.slice`, not tied to any login session) do not have this
problem and are proven working. Don't reintroduce a `nohup`-based launcher
here.

Install and start all units:

```sh
chmod +x scripts/install-systemd-units.sh
sudo scripts/install-systemd-units.sh
```

This copies the unit files into `/etc/systemd/system/`, then runs
`systemctl daemon-reload` and `systemctl enable --now` on the two services
and the update-check timer. It's
idempotent — safe to rerun any time (e.g. after editing a unit file).

Check status and logs:

```sh
systemctl status aoostar-asterctl aoostar-sensors aoostar-container-updates.timer
sudo journalctl -u aoostar-asterctl -f
tail -f logs/container-updates.log
```

Run the update check on demand instead of waiting for the timer (useful
while testing):

```sh
sudo systemctl start aoostar-container-updates.service
```

Stop or restart while iterating on a new page:

```sh
sudo systemctl stop aoostar-asterctl aoostar-sensors
sudo systemctl restart aoostar-asterctl aoostar-sensors
```

To make this survive a reboot on TrueNAS SCALE, add the installer as a Post
Init script (this also makes it self-healing if `/etc/systemd/system` gets
reset by a TrueNAS SCALE version upgrade, since it reinstalls the units
fresh every boot):

**System Settings → Advanced → Init/Shutdown Scripts → Add**

- Description: `aoostar-dashboard`
- Type: `Script`
- Script: `/mnt/nvme-pool/apps/projects/software/aoostar-dashboard/scripts/install-systemd-units.sh`
- When: `Post Init`
- Enabled: checked

Post Init runs after the pool is imported and the network is up, which is
required since the units depend on the dashboard's dataset being mounted and
(for later pages) Docker being available.

### Sensor data lives on tmpfs, not disk

`sensors/*.txt` and the `.cpu-state`/`.network-state`/`.disk-io-state`/
`.arc-state`/`.alert-state`/`.container-poll-state` files it depends on are fully
ephemeral — regenerated from scratch every loop iteration, never meant to survive a
reboot. Writing that to the real ZFS-backed dataset was ~17k/day of unnecessary disk
writes (at the original 5s cadence) for data nobody needs persisted (identified
2026-08-14 while investigating `tank`'s write load as part of the NVMe-pool
migration — see `nvme-tmpfs-migration.md`).

**Exception: `.updates-cache` does NOT live on tmpfs**, unlike everything else here.
It's written once a day and needs to survive until the next day's run — found
silently vanishing from `/run` well within 24h (no reboot involved, most likely
systemd's own periodic `/run` cleanup, which the ~1s-rewritten files above never sit
still long enough to be swept by). Stays on persistent disk unconditionally, on both
the write side (`check-container-updates.sh`) and read side
(`generate-container-sensors.sh`) so they can't drift onto different paths — see
`nvme-tmpfs-migration.md` for the incident.

**Loop interval is now 1s, not 5s** (same day, once the writes moved to
tmpfs made the interval itself cheap to shorten — `asterctl` can't usefully
refresh faster than once a second anyway, so 1s is the practical ceiling,
not an arbitrary pick). The loop body lives in `scripts/sensor-loop.sh`, not
inline in the unit file — it times its own work each cycle and only sleeps
the remainder, targeting a real ~1s period regardless of how long the four
generator scripts take. (An earlier version used a plain `sleep 1` *after*
the scripts, which gives a real period of `1s + script runtime` — measured
at ~1.35-1.4s on-device, a real ~35-40% miss at this timescale, though
negligible at the old 5s cadence.) Two things the faster interval itself
changed to stay correct/sane, not just "worked anyway":
- `check-alert-supervisor.sh`'s `ALERT_DEBOUNCE_CYCLES` (default) went
  `2 → 10`, to hold the same ~10s real debounce *time* — it was expressed in
  cycles, not seconds, so leaving it at 2 would have cut debouncing to ~2s
  and made alerts flappier.
- `cpu_percent`/`arc_hit_pct`'s underlying tick-count ratios are
  interval-agnostic, and `network_rx/tx`/disk read/write rates already
  measure real elapsed time via `date +%s` rather than assuming a fixed
  interval — so nothing was actually *wrong* running them every 1s. But a
  literal 1s sampling window makes those windowed metrics read
  0/near-zero far more often during light activity than a 5s window did —
  purely a readability problem, not a correctness one. Fixed the same day
  (not just accepted): see `RATE_WINDOW_SEC` below.

**`RATE_WINDOW_SEC` (default 5) decouples the display refresh rate from
the averaging window** for `network_rx/tx`, disk `read_speed`/`write_speed`,
and `arc_hit_pct`. Each one's state file baseline only advances once
`RATE_WINDOW_SEC` real seconds have actually elapsed, not every 1s loop
tick — so the number shown is a rolling average even though the sensor file
itself is rewritten every second. Default is 5, not an arbitrarily larger
number: this project already spent multiple rounds tuning these specific
metrics' on-device smoothness back when the loop itself ran every 5s, so 5s
reproduces that already-validated behavior rather than guessing at a new
one now that window and refresh rate are decoupled. (Whole-second
`date +%s` resolution means this shouldn't be pushed much below ~2-3s
without switching to sub-second timestamps.)

**`CONTAINER_POLL_INTERVAL_SEC` (default 15) throttles `generate-container-sensors.sh`
independently of the loop.** Its real cost is one `docker inspect` per
running/exited container every invocation (dockerd/CPU load, not disk I/O —
the tmpfs change above didn't touch it), and container counts don't need
re-checking every second. The script now checks a timestamp file and exits
immediately, leaving `containers.txt` at its last real values, unless this
many seconds have passed since the last actual Docker scan. Default is 15,
not 60: dockerd load drops off fast with interval (this stack's 46+
containers work out to ~14 `docker inspect` calls/sec sustained at the
original 5s cadence, ~4.7/s at 15s, ~1.2/s at 60s — most of the win is
already had by 15s), while alert latency (below) scales linearly with this
value the whole way, so a bigger number keeps buying less and less load
reduction for a real, ongoing cost in responsiveness. **Side effect**:
`check-alert-supervisor.sh` reads that same file for container-issue
alerting, so a crashed/unhealthy container can take up to
`CONTAINER_POLL_INTERVAL_SEC` to appear as a candidate alert condition —
at the default 15s, combined with the ~10s debounce, that's close to this
project's original ~15s pre-2026-08-14 detection latency, not a regression
(pool/temp/disk alerts are unaffected — those come from scripts that still
run every 1s). Lower it if that latency ever matters more than the dockerd
load saved by throttling.

`aoostar-sensors.service` and `aoostar-asterctl.service` redirect this to
`/run/aoostar-dashboard` (tmpfs): `RuntimeDirectory=aoostar-dashboard` in each
creates the directory before `ExecStart` runs, and
`Environment=SENSOR_DIR=/run/aoostar-dashboard` (or, for `asterctl`, its
`--sensor-path` flag) tells them to use it instead of `$DASHBOARD_DIR/sensors`.
Every generator script's `OUT_DIR` still defaults to `$DASHBOARD_DIR/sensors` when
`SENSOR_DIR` isn't set, so manual/local runs (the "test it" section above) are
unaffected. **`aoostar-container-updates.service` does NOT use `RuntimeDirectory`/
`SENSOR_DIR`** — `check-container-updates.sh` hardcodes `.updates-cache` to
persistent disk (see the exception above), so it needs neither.

Practical effect of the reboot losing this data: sensor readings show a
single "0%/idle"-looking cycle on first read after any restart (same as
today, already-tested cold-start behavior) — cosmetic, self-healing within
seconds. `.updates-cache` is unaffected by reboot entirely — it's on
persistent disk, not tmpfs.

### USB-serial device scoping

`asterctl` defaults to opening *any* serial device that matches its `--usb`
VID:PID filter (`416:90A1` — AOOSTAR's LCD, by default), but if that specific
device isn't found it's been observed opportunistically claiming other
`/dev/ttyACM*`/`/dev/ttyUSB*` devices instead — which is a problem on a box
where other USB-serial gear (e.g. an ESP32 dev board for an unrelated
project) may be plugged in at the same time. Confirmed 2026-08-06: it grabbed
an ESP32-S3's USB-JTAG/serial interface and blocked flashing it.

`aoostar-asterctl.service`'s `ExecStart` now passes `--device
/dev/serial/by-id/usb-Synwit_USB_Virtual_COM-if00` explicitly (`--device`
takes priority over `--usb`) — this is the WTR MAX's onboard LCD controller
(Synwit, VID:PID `0416:90a1`), pinned by its persistent `/dev/serial/by-id/`
symlink rather than a raw `ttyACMn` path, so it can't drift onto whatever
port a different device happens to enumerate at. If the LCD's USB descriptor
ever changes (e.g. after a hardware revision), re-check the symlink name with
`ls -la /dev/serial/by-id/` and update the unit file accordingly. See
`history-2026-07.md`'s "`asterctl` USB-device + rotation-crash-loop bugs" section
for background.

## Data inputs

`generate-sensors.sh` reads everything directly from the OS rather than a
vendor sensor file — the AOOSTAR-X `aster-sysinfo` file it originally read
from (`/root/aoostar/sensors/sysinfo.txt`) turned out to be a one-time
snapshot written at initial device setup, never live, so relying on it was
a dead end:
- **CPU usage** — delta of `/proc/stat`'s aggregate `cpu` line between
  consecutive runs of this script (state in `sensors/.cpu-state`).
- **CPU temperature** — the `k10temp` hwmon driver's `Tctl` sensor (this
  box is an AMD Ryzen APU), found by hwmon *name* rather than a hardcoded
  `hwmonN` path since that index isn't stable across reboots.
- **Memory** — `/proc/meminfo`'s `MemTotal`/`MemAvailable`.
- **Pool usage** — `zfs list -Hp -o used,avail` on `POOL_NAME` (live, exact
  bytes); `POOL_USED`/`POOL_TOTAL` env vars can still override it for
  testing without real ZFS state.
- **GPU usage/temperature** (added 2026-07-31) — `gpu_busy_percent` under
  the `amdgpu` PCI device's sysfs dir (found via the `amdgpu` hwmon entry's
  `device` symlink, not a hardcoded path) and that same hwmon's
  `temp1_input`.
- **Network** — rate is sampled from the selected interface's
  `/sys/class/net/*/statistics` counters between runs, same delta pattern
  as CPU usage.

`memory_detail`/`pool_detail` are pre-formatted as `"used/total UNIT"`
(e.g. `"24.9/31.3 GB"`) rather than asterctl's own digit handling — needed
to fit Page 1's 4-column layout (see below).

`generate-container-sensors.sh` reads only from `docker ps`/`docker inspect`
(local, no network) plus the cache file written by
`check-container-updates.sh`.

`generate-storage-sensors.sh` (Page 3) reads:
- **TANK row** — capacity reuses `pool_usage`/`pool_detail` from
  `dashboard.txt` (not recomputed here). Read/write is delta of
  `/proc/diskstats` sectors read/written (sector = fixed 512 bytes) summed
  across tank's member disks, same pattern as CPU/network. Member disks
  found dynamically (any block device with a `drivetemp` hwmon sensor
  attached), not hardcoded.
- **NVME row** (reworked 2026-08-15 — this used to be a single "NVME"
  column showing `boot-pool` capacity only; `NVME_POOL_NAME` now defaults
  to the real `nvme-pool`, a 4-drive raidz1) — capacity via `zfs list -Hp
  -o used,avail`, same reasoning as tank's. Read/write via the same
  diskstats-delta pattern, own state file. Member disks are NOT found via
  hwmon (can't distinguish nvme-pool's 4 drives from boot-pool's own NVMe
  drive that way — both are hwmon name `nvme`) — instead parsed from
  `zpool status -L nvme-pool`'s config table, stripping the trailing
  partition suffix (`nvme1n1p1` → `nvme1n1`).
- **Per-disk temperature/health** — tank's grid (5 slots) unchanged,
  `drivetemp` hwmon. nvme-pool's grid (4 slots, `NVMe1`..`NVMe4` display
  names) uses `nvme` hwmon, restricted to the pool's actual 4 members (see
  above) — **not** all 5 nvme hwmon devices on the box, 1 of which is
  boot-pool's own drive. Own over-temp threshold `NVME_TEMP_HIGH_F`
  (default 160°F) — NVMe idles noticeably hotter than spinning disks (two
  of this box's nvme-pool drives read ~125-127°F at idle), so reusing
  `DISK_TEMP_HIGH_F` (130°F) would false-alarm almost immediately.
- **Pool health** — `zpool status -L`'s `state:` block for both pools;
  overall severity is the worse of tank's state, a scrub finding real
  errors, or nvme-pool's state — drives the shared footer status dot/text
  on all pages. SCRUB/ARC-hit%/fragmentation had a dedicated column at one
  point during the 2026-08-15/16 redesign, then were eliminated entirely
  (not valuable enough to justify the space) — see
  `storage-page-redesign-2026-08.md`. The underlying scrub-error severity
  still feeds the footer/alert supervisor regardless, no visible tile needed
  for that.
- **Boot drive fill %** (`bootpool_percent`, added 2026-08-15) — alert-only,
  no visible tile on any page (see "Page 3: one row per pool" below for
  why). Read by `check-alert-supervisor.sh`, not rendered by any panel.

## Page 3: one row per pool

Reworked 2026-08-15 once nvme-pool (a real 4-drive raidz1, not just the
boot/OS drive) needed capacity+read+write of its own — the old 4-column
layout (NVME/SCRUB/READ/WRITE, all single stats) had no room for a second
pool's full stat set. Now each pool gets its own row (TANK, NVME) with
CAPACITY/READ/WRITE columns, and the disk grid below gained a second line
for nvme-pool's 4 drives under tank's existing 5.

Boot-pool (the single-drive OS pool, previously shown as Page 3's "NVME"
column) moved to an alert-only fill-% check instead of a permanent tile —
it's small and essentially static, so a dedicated always-visible slot
would compete for space with metrics that actually change every second,
for a fact worth checking maybe once a year. `check-alert-supervisor.sh`'s
`BOOTPOOL_FULL_PCT` (default 85%) surfaces it same as any other alert
condition once it's actually worth looking at.

Went through 9 rounds of on-device iteration before landing (2026-08-15/16) —
final coordinates in `render-storage-bg.py`/`monitor.json` were verified against
`asterctl`'s actual text-placement formula via `tools/pixel-probe/`, not just
eyeballed in a sandbox preview. Full history and the technical finding behind that
tool in `storage-page-redesign-2026-08.md`.

## Next pages

Pages 1–3 plus the alert-interrupt supervisor (interleaved panel 4) are all live.
See `MASTER_PLAN.md`'s "Further Reference" section for the full change history
across every page.

Note: `img/system-overview.png` and `img/storage-overview.png` are
generated with `scripts/render-system-bg.py`/`render-storage-bg.py` (plain
PIL), not `rsvg-convert` — no working SVG rasterizer has been available in
any sandbox session on this project so far. If one ever is, prefer
regenerating from the SVG source the normal way; keep the two in sync by
hand until then.
