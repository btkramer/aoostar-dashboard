# AOOSTAR WTR MAX Dashboard

A restrained, distance-readable front-panel dashboard for `asterctl` 0.2.0.
It uses the supported AOOSTAR-X panel format, so it stays independent of the
`aoostar-rs` source tree.

## Included pages

`monitor.json` rotates through two 960 × 376 panels (`setup.switchTime`
controls dwell time; `mianban` lists the rotation order):

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
runs on the same 5-second loop as `generate-sensors.sh` (no registry calls,
just `docker ps`/`docker inspect`).

Update detection needs a value to compare against, which isn't cheap to get
every 5 seconds: `scripts/check-container-updates.sh` compares each running
container's locally-pulled image digest against its registry's current
digest for the same tag (generic OCI Distribution auth flow — works against
Docker Hub, GHCR, quay.io, lscr.io, and most self-hosted registries without
per-registry special-casing) and writes the result to `sensors/.updates-cache`.
It runs once a day via `aoostar-container-updates.timer`, not the fast loop,
to stay well clear of registry rate limits (Docker Hub's anonymous pull limit
in particular). Requires `jq`; installs via `apt-get install -y jq` if
missing (it silently skips and logs a note if `jq` or `docker` isn't found,
rather than failing the whole run).

The visual labels, dividers, and accent bars for both pages are supplied as
editable SVG sources (`img/system-overview.svg`, `img/container-overview.svg`)
and matching ready-to-use PNGs. The text values are rendered live by
`asterctl` from files in `sensors/`.

## Install on TrueNAS

Copy this directory to a persistent location, for example
`/mnt/tank/apps/aoostar-dashboard`. The included PNG is ready to deploy. If
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
  --config /mnt/tank/apps/aoostar-dashboard/monitor.json \
  --config-dir /mnt/tank/apps/aoostar-dashboard \
  --sensor-path /mnt/tank/apps/aoostar-dashboard/sensors/dashboard.txt
```

`--device` pins asterctl to the WTR MAX's onboard LCD by its stable `/dev/serial/by-id/`
symlink rather than a raw `/dev/ttyACMn` path (device numbering isn't exclusive to this
device and shifts depending on what else is plugged in). See the "USB-serial device
scoping" section below for why this matters.

Schedule the sensor script every 5 seconds (cron, a small service, or a
TrueNAS post-init task). `asterctl` can refresh the current page every second;
the generator simply replaces the sensor file atomically.

## Persistence across reboot

The dashboard runs as systemd units instead of a hand-rolled `nohup`
background script:

- `aoostar-asterctl.service` — the LCD renderer, `Restart=always`.
- `aoostar-sensors.service` — the 5-second sensor loop (both
  `generate-sensors.sh` and `generate-container-sensors.sh`),
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
- Script: `/mnt/tank/apps/aoostar-dashboard/scripts/install-systemd-units.sh`
- When: `Post Init`
- Enabled: checked

Post Init runs after the pool is imported and the network is up, which is
required since the units depend on `/mnt/tank/...` being mounted and (for
later pages) Docker being available.

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
`MASTER_PLAN.md`'s 2026-08-06 entry for the full investigation.

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
- **Read/write throughput** — delta of `/proc/diskstats` sectors
  read/written (sector = fixed 512 bytes) summed across the pool's member
  disks, same pattern as CPU/network. Pool member disks are found
  dynamically (any block device with a `drivetemp` hwmon sensor attached),
  not hardcoded.
- **Per-disk temperature/health** — same `drivetemp` hwmon devices, read
  directly (same technique as `cpu_temperature`'s `k10temp` lookup), plus
  each disk's leaf state from `zpool status -L`.
- **Pool health/scrub** — `zpool status -L`'s `state:`/`scan:` blocks
  (col 2, "SCRUB"). Also drives the shared footer status dot/text on all 3
  pages (asterctl merges every `*.txt` under `--sensor-path` into one
  key/value map).
- **NVMe capacity** (added 2026-07-31, col 1, "NVME") — `zfs list -Hp -o
  used,avail` on `NVME_POOL_NAME` (default `boot-pool`, TrueNAS SCALE's
  install default), same used/avail-not-alloc/size reasoning as pool
  usage above. **Not yet verified against a real boot-pool** — `zfs` isn't
  on PATH in the sandbox this was built in, and the box's actual boot-pool
  name was only inferred, never confirmed with `zpool status`.

## Next pages

Pages 1–3 are live. A standalone Page 4 (Temperature) was considered but
dropped 2026-07-31 — its planned CPU/hottest-HDD readings were already on
Pages 1/3, so only GPU (now Page 1) and NVMe capacity (now Page 3) were
genuinely new; both got folded into the existing pages instead. See
MASTER_PLAN.md's "2026-07-31: Page 1/3 four-column rework" section for the
full change list. Next up: an alert-interrupt supervisor (asterctl has no
hot-reload or live override, so an alert has to swap in a single-panel
config and restart the process, then revert once clear).

Note: `img/system-overview.png` and `img/storage-overview.png` are
generated with `scripts/render-system-bg.py`/`render-storage-bg.py` (plain
PIL), not `rsvg-convert` — no working SVG rasterizer has been available in
any sandbox session on this project so far. If one ever is, prefer
regenerating from the SVG source the normal way; keep the two in sync by
hand until then.
