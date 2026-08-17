#!/usr/bin/env python3
"""Generates img/system-overview.png directly with PIL, since no SVG
rasterizer (rsvg-convert, working cairosvg) has been available in any
sandbox session working on this project so far. If rsvg-convert ever
becomes available, prefer the README-documented workflow instead:
`rsvg-convert -w 960 -h 376 img/system-overview.svg -o img/system-overview.png`
-- this script exists only because that path hasn't worked. Keep this
script's hardcoded values in sync with img/system-overview.svg by hand if
the SVG source is ever edited; this does not read the SVG at all.
Adapted from render-storage-bg.py's technique (2026-07-31, added the GPU
column to row 1).
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
DIVIDER = (58, 74, 104)    # #3a4a68

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
d.rounded_rectangle((24, 17, 24 + 7, 17 + 37), radius=2, fill=ACCENT)
draw_spaced((42, 53), "TrueNAS", bold(48), WHITE, spacing=1)
draw_spaced((910, 40), "SYSTEM OVERVIEW", reg(34), PAGE_LABEL, spacing=2, anchor_end=True)
d.line((24, 72, 936, 72), fill=ACCENT, width=2)

# Row 1: CPU/GPU/MEMORY/POOL (2026-07-31, GPU moved next to CPU). Row 2
# reflowed onto the same 4-column grid. Both rows fully centered (text-
# anchor=middle at each column's center) per a global "center everything"
# request. Column spacing rebalanced same day (round 3, on-device
# feedback): col 1 shifted left (bar x 65->40), col 4 held in place (bar x
# 749 unchanged), cols 2/3 evenly redistributed between them -- bar x =
# 40/276/513/749, centers (bar_x+90) = 130/366/603/839.
label_font = bold(24)
for x, text in [(130, "CPU"), (366, "GPU"), (603, "MEMORY"), (839, "POOL")]:
    draw_spaced((x, 100), text, label_font, LABEL, spacing=1.5, anchor_middle=True)
for x in (40, 276, 513, 749):
    d.rounded_rectangle((x, 194, x + 180, 194 + 4), radius=2, fill=ACCENT)

d.line((24, 216, 936, 216), fill=DIVIDER, width=2)

# Row 2 labels -- no blue bars (matches system-overview.svg), centered on
# the same 4 column centers as row 1.
row2_font = bold(24)
for x, text in [(130, "DOWNLOAD"), (366, "UPLOAD"), (603, "CONNECTIONS"), (839, "UPTIME")]:
    draw_spaced((x, 256), text, row2_font, LABEL, spacing=1.5, anchor_middle=True)

# Divider above the footer row (2026-08-17), ACCENT (blue) -- same
# treatment across all 4 pages (alert uses its own DARK_TEXT instead),
# see render-storage-bg.py's same-day comment for the y=339 derivation
# (clears the lowest content on any page, ~9-10px clearance each side).
d.line((24, 339, 936, 339), fill=ACCENT, width=2)

# Footer: entirely live monitor.json sensor fields, nothing to draw here.

out = DASHBOARD_DIR / "img" / "system-overview.png"
img.save(out)
print(f"saved {out}")
