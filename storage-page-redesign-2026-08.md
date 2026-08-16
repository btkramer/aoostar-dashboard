# History: Storage page (Page 3) redesign, nvme-pool joins tank (2026-08-15/16)

*Frozen archive — closed, don't append to it; log new work in `MASTER_PLAN.md`
instead.* Nine rounds of on-device iteration once `nvme-pool` needed to appear
alongside `tank` on the Storage page. Current layout lives in `monitor.json` and
`scripts/render-storage-bg.py` — this file is the reasoning and lessons, not a
coordinate reference (every exact pixel value here was superseded within the same
stretch, several more than once).

## What changed, end to end

Original Page 3 was a single row (tank only): NVME(boot-pool capacity)/SCRUB/READ/
WRITE. Final design: one row per pool (TANK, NVME), each with its row name + capacity
% (own column, with a header) + capacity detail (small used/total text, under the row
name) + READ + WRITE, plus a disk-temp grid below (tank's 5 disks, then nvme-pool's
4, one line each: name + temp + a color-toggle health dot). SCRUB and fragmentation %
were tried, then dropped — not valuable enough to justify the space at sizes that
also had to fit READ/WRITE and the row name legibly.

**Terminology, gotten wrong twice, now settled**: "capacity numbers" means the small
used/total detail text (e.g. "4.2/10.0 TB") — it goes under the row name. The
percentage always lives in its own column with a header, same as READ/WRITE. Getting
this backwards (moving the percentage under the row name) was corrected on-device
twice before it stuck.

## The real finding: `asterctl`'s actual text-placement formula

Two rounds shipped layouts that looked clean in `render-preview.py` but had text
visibly overlapping accent bars on the real device. Root cause: this project had
never actually verified how `asterctl` positions text — `render-preview.py`'s
`y - fontSize` nudge, and this project's own earlier hand-derived DejaVu
ascent/descent math, were both just approximations that happened to look right in
their own preview.

Read `asterctl`'s actual source (`crates/asterctl/src/render.rs`, `render_text`,
from the same `zehnm/aoostar-rs` v0.2.0 tag this box's patched binary is built from)
and found the real formula:
```
scale = font.pt_to_px_scale(fontSize * 0.75)
size  = text_size(scale, font, text)      // size.1 = font.height() at that scale
y     = sensor.y + height/2 - size.1 * 1.3333 / 2   // height (JSON field) is always 0 here
```
This is not a baseline convention — ink extends noticeably further below `sensor.y`
than above it, in a way that depends on font/size/text. `asterctl`'s own source
calls this "still a mystery" in its own FIXME comments; never fully resolved even by
that project's author.

Rather than guess a third time, built `tools/pixel-probe/` — a small Rust harness
linking the *actual* `ab_glyph`/`imageproc` crates `asterctl` is built from, running
the real formula against the real font. Gives an exact pixel range for any
(fontSize, text, sensor.y). **Every coordinate in the current layout was placed and
verified this way, not eyeballed.** Use it for any future spacing decision on this
page — see its own `README.md`.

## Other real bugs found along the way (not layout)

- **Bash `read` + tab-delimited fields with an empty middle field silently shift.**
  `IFS=$'\t' read -r a b c` on `"X\t\tY"` (empty middle field) puts `Y` into `b`,
  leaving `c` empty — tab counts as IFS *whitespace* even when it's the only
  character assigned to `IFS`, so consecutive delimiters collapse instead of marking
  an empty field. Fixed by using `\x1f` (ASCII unit separator) instead of tab
  wherever a script splits multiple return values this way
  (`generate-storage-sensors.sh`'s `compute_scrub_frag()`).
- **Sandbox testing `check-alert-supervisor.sh` mutates the real `monitor.json`.**
  Its `MONITOR_JSON` path is hardcoded off `DASHBOARD_DIR`, not covered by the
  `SENSOR_DIR` override used to sandbox everything else — repeated test cycles can
  legitimately trip its debounce and flip the real `mianban`. Silently un-pinned a
  manually-pinned page mid-session once. If this script needs testing again, isolate
  a full repo copy first, or expect it to touch the live file.
- **`.updates-cache` tmpfs regression** — found and fixed the same week; full writeup
  in `nvme-tmpfs-migration.md`, not repeated here (different topic, coincided in
  time).

## Verified-safe font sizes / spacing (current, for reference)

Row label 38pt, capacity detail 32pt (real ~3px gap between them, intentionally
tight), CAPACITY/READ/WRITE 48pt/44pt/44pt, column headers 30pt (matched to the
page-title "STORAGE OVERVIEW" size), disk-grid name/temp/dot 24pt/20pt/18pt. Every
adjacent pair checked with `tools/pixel-probe` has positive real clearance, including
worst-case text (4-digit throughput, "100%", a long scrub-style error string was
considered before that column was dropped).
