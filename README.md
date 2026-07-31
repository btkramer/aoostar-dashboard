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
  --config /mnt/tank/apps/aoostar-dashboard/monitor.json \
  --config-dir /mnt/tank/apps/aoostar-dashboard \
  --sensor-path /mnt/tank/apps/aoostar-dashboard/sensors/dashboard.txt
```

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
- **Network** — rate is sampled from the selected interface's
  `/sys/class/net/*/statistics` counters between runs, same delta pattern
  as CPU usage.

`generate-container-sensors.sh` reads only from `docker ps`/`docker inspect`
(local, no network) plus the cache file written by
`check-container-updates.sh`.

`generate-storage-sensors.sh` (Page 3) reads:
- **Read/write throughput** — delta of `/proc/diskstats` sectors
  read/written (sector = fixed 512 bytes) summed across the pool's member
  disks, same pattern as CPU/network. Pool member disks are found
  dynamically (any block device with a `drivetemp` hwmon sensor attached),
  not hardcoded.
- **Disk temperature avg/hottest** — same `drivetemp` hwmon devices, read
  directly (same technique as `cpu_temperature`'s `k10temp` lookup).
- **Pool capacity** — not recomputed; this panel reuses the
  `pool_usage`/`pool_detail` keys already written by `generate-sensors.sh`
  (asterctl merges every `*.txt` file under `--sensor-path` into one
  key/value map, so any panel can reference any key from any file).

## Next pages

Page 3 (Storage) is live. Add Page 4 (Temperature: CPU/GPU/NVMe/hottest
HDD) next, followed by an alert-interrupt supervisor (asterctl has no
hot-reload or live override, so an alert has to swap in a single-panel
config and restart the process, then revert once clear).

Note: `img/storage-overview.png` was generated with
`scripts/render-storage-bg.py` (plain PIL), not `rsvg-convert` — no
working SVG rasterizer has been available in any sandbox session on this
project so far. If one ever is, prefer regenerating from the SVG source
the normal way; keep the two in sync by hand until then.
