#!/usr/bin/env python3
"""Generates img/container-overview.png directly with PIL, since no SVG
rasterizer (rsvg-convert, working cairosvg) has been available in any
sandbox session working on this project so far. If rsvg-convert ever
becomes available, prefer the README-documented workflow instead:
`rsvg-convert -w 960 -h 376 img/container-overview.svg -o img/container-overview.png`
-- this script exists only because that path hasn't worked. Keep this
script's hardcoded values in sync with img/container-overview.svg by hand
if the SVG source is ever edited; this does not read the SVG at all.
Written 2026-07-31 (no PIL generator previously existed for this page --
container-overview.png had been hand-edited in place via crop-translate/
pixel-recolor techniques up to this point) so the row-1 header labels could
be centered the same way system/storage-overview's generators do.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

DASHBOARD_DIR = Path(__file__).resolve().parent.parent
W, H = 960, 376
BG = (11, 16, 32)          # #0b1020
ACCENT = (56, 189, 248)    # #38bdf8
WHITE = (248, 250, 252)    # #f8fafc
KICKER = (148, 163, 184)   # #94a3b8
PAGE_LABEL = (203, 213, 225) # #cbd5e1, brighter than KICKER (page title, top right)
LABEL = (148, 163, 184)    # #94a3b8
DIVIDER = (84, 104, 142)   # #546c8e, brightened from #3a4a68 (2026-08-17)

FONT_DIR = "/usr/share/fonts/truetype/dejavu"
bold = lambda sz: ImageFont.truetype(f"{FONT_DIR}/DejaVuSans-Bold.ttf", sz)
reg = lambda sz: ImageFont.truetype(f"{FONT_DIR}/DejaVuSans.ttf", sz)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)


def draw_spaced(xy, text, font, fill, spacing=0, anchor_end=False, anchor_middle=False):
    """Draws text char-by-char with extra letter-spacing, matching SVG's
    letter-spacing behavior. xy's y is the true typographic BASELINE
    (matching SVG <text> semantics), converted to PIL's top-left convention
    via the font's real ascent."""
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


# Header. TrueNAS label 43->48pt, page-title 30->34, header divider
# DIVIDER(gray)->ACCENT(blue) (2026-08-17, matching render-storage-bg.py's
# same-day treatment so all three main pages match -- NOT
# render-alert-bg.py, which deliberately keeps its own inverted red/amber
# hazard scheme). Accent bar's y-span recomputed from the real ink bbox
# at the new TrueNAS size (17-54, was 18-53) so it still exactly brackets
# the text.
d.rounded_rectangle((24, 14, 24 + 7, 14 + 40), radius=2, fill=ACCENT)
draw_spaced((42, 53), "TrueNAS", bold(52), WHITE, spacing=1)
draw_spaced((910, 50), "CONTAINER OVERVIEW", reg(34), PAGE_LABEL, spacing=2, anchor_end=True)
d.line((24, 72, 936, 72), fill=ACCENT, width=2)

# Row 1 labels + blue bars -- centered 2026-07-31 at each column's center
# x=155/383/611/839 (bar_x+90), was left-aligned at the bar starts.
label_font = bold(24)
for x, text in [(155, "RUNNING"), (383, "HEALTHY"), (611, "ISSUES"), (839, "UPDATES")]:
    draw_spaced((x, 100), text, label_font, LABEL, spacing=1.5, anchor_middle=True)
for x in (65, 293, 521, 749):
    d.rounded_rectangle((x, 165, x + 180, 165 + 4), radius=2, fill=ACCENT)

d.line((24, 183, 936, 183), fill=DIVIDER, width=2)

# STATUS section label -- left-aligned, not part of the column grid.
draw_spaced((45, 211), "STATUS", label_font, LABEL, spacing=1.5)

# Divider above the footer row (2026-08-17), ACCENT (blue) -- same
# treatment across all 4 pages (alert uses its own DARK_TEXT instead),
# see render-storage-bg.py's same-day comment for the y=339 derivation
# (clears the lowest content on any page, ~9-10px clearance each side).
d.line((24, 328, 936, 328), fill=ACCENT, width=2)

# Footer: entirely live monitor.json sensor fields, nothing to draw here.

out = DASHBOARD_DIR / "img" / "container-overview.png"
img.save(out)
print(f"saved {out}")
