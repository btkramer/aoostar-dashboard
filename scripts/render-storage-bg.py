#!/usr/bin/env python3
"""Generates img/storage-overview.png directly with PIL, since no SVG
rasterizer (rsvg-convert, working cairosvg) has been available in any
sandbox session working on this project so far. If rsvg-convert ever
becomes available, prefer the README-documented workflow instead:
`rsvg-convert -w 960 -h 376 img/storage-overview.svg -o img/storage-overview.png`
-- this script exists only because that path hasn't worked. Keep this
script's hardcoded values in sync with img/storage-overview.svg by hand if
the SVG source is ever edited; this does not read the SVG at all.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

DASHBOARD_DIR = Path(__file__).resolve().parent.parent
W, H = 960, 376
BG = (11, 16, 32)          # #0b1020
ACCENT = (56, 189, 248)    # #38bdf8
WHITE = (248, 250, 252)    # #f8fafc
KICKER = (148, 163, 184)   # #94a3b8 (bumped from #64748b 2026-07-29, brighter per user request)
PAGE_LABEL = (203, 213, 225) # #cbd5e1, brighter than KICKER (page title, top right)
LABEL = (148, 163, 184)    # #94a3b8
DIVIDER = (58, 74, 104)    # #3a4a68

FONT_DIR = "/usr/share/fonts/truetype/dejavu"
bold = lambda sz: ImageFont.truetype(f"{FONT_DIR}/DejaVuSans-Bold.ttf", sz)
reg = lambda sz: ImageFont.truetype(f"{FONT_DIR}/DejaVuSans.ttf", sz)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)


def draw_spaced(xy, text, font, fill, spacing=0, anchor_end=False, anchor_middle=False):
    """Draws text char-by-char with extra letter-spacing, matching SVG's
    letter-spacing behavior (added after every glyph including the last,
    which is what right-aligned/text-anchor=end measurements use). xy's y
    is the true typographic BASELINE (matching SVG <text> semantics),
    converted to PIL's top-left convention via the font's real ascent --
    not a fontSize approximation (that convention is specific to
    render-preview.py's approximation of asterctl's own dynamic-text
    rendering, a different renderer with different metrics -- do not reuse
    it for static backgrounds meant to match true SVG semantics)."""
    x, y_baseline = xy
    ascent, _ = font.getmetrics()
    y = y_baseline - ascent
    widths = [font.getlength(c) for c in text]
    total = sum(widths) + spacing * len(text)
    if anchor_end:
        x -= total
    elif anchor_middle:
        x -= total / 2
    cx = x
    for c, w in zip(text, widths):
        d.text((cx, y), c, font=font, fill=fill)
        cx += w + spacing


# Header
d.rounded_rectangle((24, 18, 24 + 7, 18 + 35), radius=2, fill=ACCENT)
draw_spaced((42, 53), "TrueNAS", bold(43), WHITE, spacing=1)
draw_spaced((910, 40), "STORAGE OVERVIEW", reg(30), PAGE_LABEL, spacing=2, anchor_end=True)
d.line((24, 72, 936, 72), fill=DIVIDER, width=2)

# Rows reworked 2026-08-15 into one row per pool (TANK, NVME) instead of 4
# single-stat columns -- nvme-pool is now a real 4-drive raidz1, not just
# the boot/OS drive, so it needs its own capacity+read+write.
#
# Went through several more rounds the same day (see MASTER_PLAN.md for
# the full history of each -- what was tried, what on-device feedback said
# was wrong, and why). Two lasting technical findings from that process,
# both still true and worth knowing before touching this file again:
#
# 1. asterctl (the real device renderer, NOT this script) positions
#    dynamic text using a y-formula this project had never verified:
#      y_draw = sensor.y + height/2 - text_size.1 * 1.3333 / 2
#    (crates/asterctl/src/render.rs, render_text -- height is a per-field
#    JSON property this project has never set, always 0). This is NOT a
#    baseline convention -- ink extends notably further BELOW sensor.y
#    than above it, in a way that depends on fontSize/text and isn't
#    obvious by eye. A layout that looks clean in a naive preview can
#    still overlap for real.
# 2. Don't guess -- verify. tools/pixel-probe/ links the actual
#    ab_glyph/imageproc crates asterctl is built from and runs the real
#    formula against the real font/fontSize/text, giving an exact pixel
#    range. Every Y coordinate below was chosen and checked that way, not
#    eyeballed or approximated.
#
# 5th pass: SCRUB column eliminated outright ("not sure the current scrub
# column is very valuable at this point"). Its width was meant to go to
# the row-label/detail block on the far left -- misread as "move the
# percentage under the row name too", which is the EXACT mistake already
# corrected once before (3rd pass) and called out again just as directly
# on-device: percent belongs in its own column, only the smaller
# used/total DETAIL text belongs under TANK/NVME. Not making that mistake
# a third time -- see MASTER_PLAN.md's 6th-pass entry.
#
# 6th pass: reverted to CAPACITY as its own column with a header (same
# shape as the 4th pass, before the 5th pass's detour), with SCRUB's freed
# width going to bigger fonts throughout: row label 26->34,
# detail-under-the-name 22->28, CAPACITY% 44->48, READ/WRITE 40->44.
#
# 7th pass: column headers bigger again (18->22), row labels bigger again
# (34->38), detail-under-the-name bigger again (28->32) -- and the disk
# grid's own two sub-rows given real breathing room (their baseline-to-
# baseline gap grew 26->30, worth ~10px of real ink-to-ink clearance now
# vs ~6-7px before -- "cramped drive temps" on-device feedback).
# CAPACITY's column also shifted right (300->320) because the bigger
# detail text (32pt is noticeably wider than 28pt) left only ~1.5px of
# real clearance to it at the old x.
#
# 8th pass: repositioned vertically, not resized -- on-device feedback
# described each row's true visual unit as the band BETWEEN its divider
# lines (e.g. NVME's row = the space from TANK's divider down to NVME's
# own divider), and asked for two things centered within that band rather
# than stacked top-down from the header: the row-label+detail pair (as a
# tight pair, ~5px real gap between them) and the CAPACITY/READ/WRITE line
# (independently centered on its own, off to the right -- they don't
# share x, so both center in the same band without colliding).
#
# 9th pass: row label pulled down closer to the (unmoved) detail line
# below it -- ~5px gap tightened to ~3px, a further step in the same
# direction as the 8th pass, not a new one. Column headers grew 22->30
# (explicitly asked to match "STORAGE OVERVIEW"'s own size, the
# page-title text drawn separately near the top of this file) and moved
# down a little (90->97) to keep clear of the bigger row labels now
# sitting closer beneath them.
#
# 10th pass (2026-08-16): TANK/NVME rows shrunk to free up room for the
# disk-temp grid below ("tighten up the row height... space [the temp
# rows] out better, maybe even make them bigger" -- on-device feedback).
# Every junction in the 9th-pass layout was already at its real-ink
# minimum clearance (2-9px, verified via tools/pixel-probe at the time),
# so there was no slack left to reclaim -- shrinking the band required
# shrinking fonts too, not just gaps: row label 38->32, capacity-detail
# 32->26, CAPACITY% 48->40, READ/WRITE 44->36 (monitor.json fields, not
# drawn here). Band height (divider to divider) 92->72. Freed ~45px,
# handed to the disk grid below: its own fonts grew 24/20/18->28/24/20
# and its two sub-rows' baseline gap grew 30->53. Every new coordinate
# (this file's static labels/bars/dividers AND monitor.json's dynamic
# fields) re-verified with tools/pixel-probe against real worst-case
# text -- see its README before changing any of this again.
#
# 11th pass (2026-08-17): column headers moved down (97->108) and shrunk
# (30->26). The 9th-pass comment above believed 97 was already pinned
# against the TANK/NVME row label's clearance -- re-checked this pass and
# that was never a real constraint (the row label sits at x=40, headers at
# x=320/560/810, horizontally disjoint, can't visually collide regardless
# of y). The real constraint is the header's own column vs the CAPACITY%/
# READ/WRITE values below it in that SAME x -- ~13px real clearance to
# those at the new position, still comfortable.
row_label_font = bold(32)
col_header_font = bold(26)
COL_X = {"CAPACITY": 320, "READ": 560, "WRITE": 810}
BAR_HALF_WIDTH = 70
HEADER_Y = 108

for text, x in COL_X.items():
    draw_spaced((x, HEADER_Y), text, col_header_font, LABEL, spacing=1.5, anchor_middle=True)

for row_label, label_y, bar_y, divider_y in (
    ("TANK", 124, 163, 169),
    ("NVME", 196, 235, 241),
):
    draw_spaced((40, label_y), row_label, row_label_font, WHITE, spacing=1)
    for x in COL_X.values():
        d.rounded_rectangle((x - BAR_HALF_WIDTH, bar_y, x + BAR_HALF_WIDTH, bar_y + 3), radius=1, fill=ACCENT)
    d.line((24, divider_y, 936, divider_y), fill=DIVIDER, width=2)

# Disk grid (two sub-rows: tank's 5 disks, then nvme-pool's 4) -- each
# disk is a single dynamic line (name, temp, small color dot for health --
# "sda 108°F ●" / "NVMe1 127°F ●"), so there's no static header left to
# draw here. Collapsed from 2 lines/disk (name+temp, then a health TEXT
# line below) down to 1 line/disk later the same day (2026-08-15) -- the
# health line's baseline sat closer to the temp line above it than either
# font's own ascent+descent, so on-device it visibly overlapped, and the
# tank sub-row's health line + the nvme sub-row's name/temp line right
# below it had the same problem. See generate-storage-sensors.sh /
# monitor.json disk1..disk5_*, nvme_disk1..nvme_disk4_* (dot_ok/dot_bad
# fields, not health_ok/health_bad -- those are still written to
# storage.txt for check-alert-supervisor.sh's alert-line text, just no
# longer drawn on this page).
#
# 11th pass (2026-08-17): a thin vertical tick before each disk ("break
# them up visually" -- 5-6 adjacent name/temp/dot groups otherwise read as
# one dense run of text). Purely decorative/static, so drawn here rather
# than as a monitor.json field -- these x's are the disk*_name /
# nvme_disk*_name x's from monitor.json minus a small gap, and must be
# kept in sync by hand if those ever move.
TICK_HALF_HEIGHT = 16
for row_y, disk_name_xs in (
    (271, [82, 249, 416, 583, 750]),   # tank: disk1..5_name
    (316, [48, 269, 490, 711]),        # nvme: nvme_disk1..4_name
):
    for name_x in disk_name_xs:
        tick_x = name_x - 14
        d.line((tick_x, row_y - TICK_HALF_HEIGHT, tick_x, row_y + TICK_HALF_HEIGHT), fill=DIVIDER, width=2)

# Footer: entirely live monitor.json sensor fields -- status dot+text
# (left), date_time (center), ip_address (right). Nothing left to draw
# here. See generate-storage-sensors.sh.

out = DASHBOARD_DIR / "img" / "storage-overview.png"
img.save(out)
print(f"saved {out}")
