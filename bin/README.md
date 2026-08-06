# `asterctl-0.2.0-mianban-fix`

A patched build of the vendor `asterctl` binary (from
[zehnm/aoostar-rs](https://github.com/zehnm/aoostar-rs), tag `v0.2.0` — the
exact version already deployed on this box) that fixes a real upstream bug
in its panel-rotation logic. Full writeup in `MASTER_PLAN.md`'s 2026-08-06
entries; short version:

`crates/asterctl/src/cfg.rs`'s `get_next_active_panel()` compares the
rotation wraparound against `panels.len()` (total defined panels, i.e.
`monitor.json`'s `diy` array) instead of `mianban`'s own length. A `mianban`
shorter than `diy.len()` crashes (`Error: No active panel`, then a systemd
`Restart=always` crash loop); a `mianban` longer than `diy.len()` silently
drops entries past that position. The patch (`mianban-fix.patch`) changes
the comparison to use the count of `mianban`'s actual non-zero entries
instead — one function, ~8 lines. See the patch file for the exact diff.

**Verified against the real WTR MAX LCD hardware** before deploying (from
the `truenas-wtrmaxlcd` dashboard container, which has the same
`/dev/serial/by-id/usb-Synwit_USB_Virtual_COM-if00` device passed through):
both `mianban: [1,2,3]` (clean repeating rotation, multiple laps, no crash)
and `mianban: [1,4,2,4,3,4]` (correct every-other alert interleaving,
`storage-overview` actually appears) confirmed working live.

## Rebuilding

```sh
git clone --depth 1 --branch v0.2.0 https://github.com/zehnm/aoostar-rs.git
cd aoostar-rs
git apply /path/to/mianban-fix.patch
cargo build --release -p asterctl
# binary at target/release/asterctl
```

The patch also disables `serialport`'s default `libudev` feature in
`crates/asterctl-lcd/Cargo.toml` — not part of the actual bug fix, just
needed because the build environment used here didn't have
`libudev-dev`/`pkg-config` available. Since this project always passes
`--device <path>` explicitly (never relies on `asterctl`'s auto-detection),
disabling that feature doesn't change any behavior we use. If rebuilding
somewhere with `libudev-dev` available, that part of the patch can be
dropped.

## Deploying

```sh
sudo systemctl stop aoostar-asterctl
sudo cp /root/aoostar/asterctl /root/aoostar/asterctl.orig-0.2.0   # backup, one-time
sudo cp /mnt/tank/apps/aoostar-dashboard/bin/asterctl-0.2.0-mianban-fix /root/aoostar/asterctl
sudo chmod 755 /root/aoostar/asterctl
sudo systemctl start aoostar-asterctl
systemctl status aoostar-asterctl
sudo journalctl -u aoostar-asterctl -f   # watch a couple of panel switches to confirm
```

**If `asterctl` is ever reinstalled or upgraded from upstream, this bug
returns** — either reapply `mianban-fix.patch` to the new version, or fall
back to the padding workaround documented in `check-alert-supervisor.sh`'s
git history (2026-08-06 commits) and this file's own history before this
patched build existed.

## Verify checksum

```sh
sha256sum /root/aoostar/asterctl
```

Should match: `b11eaafd16c6ad843c6ed83f6407dbad3d3444464cf0e5a0b2f83d4de81e3c51`
