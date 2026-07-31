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

# Row 1 labels + blue bars -- reworked to 4 columns 2026-07-31
# (NVME/SCRUB/READ/WRITE, replacing POOL/READ/WRITE -- see storage-overview.svg
# for why), centered at each column's center x=155/383/611/839 (bar_x+90)
# per a global "center everything" request; bars stay at 65/293/521/749.
label_font = bold(24)
for x, text in [(155, "NVME"), (383, "SCRUB"), (611, "READ"), (839, "WRITE")]:
    draw_spaced((x, 100), text, label_font, LABEL, spacing=1.5, anchor_middle=True)
for x in (65, 293, 521, 749):
    d.rounded_rectangle((x, 194, x + 180, 194 + 4), radius=2, fill=ACCENT)

d.line((24, 216, 936, 216), fill=DIVIDER, width=2)

# Row 2 (2026-07-29): "DISK TEMP AVG"/"HOTTEST DISK" headers replaced by a
# live 5-column per-disk temp+health grid -- each disk's own name is baked
# into its temp line ("sda 108°F"), so there's no static header left to
# draw here. See generate-storage-sensors.sh / monitor.json
# disk1..disk5_temp/_health_ok/_health_bad.

# Footer (2026-07-29): entirely live monitor.json sensor fields now --
# status dot+text (left), date_time (center), ip_address (right, replacing
# the old static "AOOSTAR LCD" caption that used to live there). Nothing
# left to draw here. See generate-storage-sensors.sh.

out = DASHBOARD_DIR / "img" / "storage-overview.png"
img.save(out)
print(f"saved {out}")
