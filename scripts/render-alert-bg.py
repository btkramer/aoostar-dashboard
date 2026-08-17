#!/usr/bin/env python3
"""Generates img/alert-overview.png directly with PIL, since no SVG
rasterizer (rsvg-convert, working cairosvg) has been available in any
sandbox session working on this project so far. If rsvg-convert ever
becomes available, prefer the README-documented workflow instead:
`rsvg-convert -w 960 -h 376 img/alert-overview.svg -o img/alert-overview.png`
-- this script exists only because that path hasn't worked. Keep this
script's hardcoded values in sync with img/alert-overview.svg by hand if
the SVG source is ever edited; this does not read the SVG at all.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

DASHBOARD_DIR = Path(__file__).resolve().parent.parent
W, H = 960, 376
# Solid amber fill (not the usual dark #0b1020) -- user wanted this page
# to grab attention like a hazard sign. Body text reuses the normal
# pages' dark background color AS this page's text color (deliberate
# inversion). Accent bar/kicker stay red for a hazard-sign red-on-yellow
# highlight.
BG = (245, 158, 11)        # #f59e0b, amber fill
DARK_TEXT = (11, 16, 32)   # #0b1020, body text (was this page's own bg on the other 3 pages)
ALERT_ACCENT = (239, 68, 68)  # #ef4444, red accent bar/kicker

FONT_DIR = "/usr/share/fonts/truetype/dejavu"
bold = lambda sz: ImageFont.truetype(f"{FONT_DIR}/DejaVuSans-Bold.ttf", sz)
reg = lambda sz: ImageFont.truetype(f"{FONT_DIR}/DejaVuSans.ttf", sz)

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)


def draw_spaced(xy, text, font, fill, spacing=0, anchor_end=False):
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
    cx = x
    for c, w in zip(text, widths):
        d.text((cx, y), c, font=font, fill=fill)
        cx += w + spacing


# Header -- red accent bar + kicker, dark body text, everything below the
# divider is blank: alert_line1..6 (monitor.json) are all dynamic,
# populated by scripts/check-alert-supervisor.sh, no static columns/bars
# needed for a page that's just a list.
d.rounded_rectangle((24, 18, 24 + 7, 18 + 35), radius=2, fill=ALERT_ACCENT)
draw_spaced((42, 53), "TrueNAS", bold(43), DARK_TEXT, spacing=1)
draw_spaced((910, 40), "⚠ ACTIVE ALERTS", reg(30), ALERT_ACCENT, spacing=2, anchor_end=True)
d.line((24, 72, 936, 72), fill=DARK_TEXT, width=2)

# Divider above the footer row (2026-08-17) -- same treatment added to
# the other 3 pages' generators the same day, but this page keeps
# DARK_TEXT instead of ACCENT-blue (deliberately never uses that color,
# see the hazard-scheme note at the top of this file). y=339 matches the
# other pages' derivation; alert_line6 (this page's lowest content,
# y=310) clears it with real room to spare.
d.line((24, 339, 936, 339), fill=DARK_TEXT, width=2)

out = DASHBOARD_DIR / "img" / "alert-overview.png"
img.save(out)
print(f"saved {out}")
