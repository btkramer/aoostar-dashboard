#!/usr/bin/env python3
"""Renders a monitor.json panel + a sensor value file to a PNG, approximating
how asterctl draws it live on the LCD. This is a layout preview, not a
verified-pixel-identical screenshot.

CONFIRMED WRONG for vertical (y) placement (2026-08-15): this script draws
text at `y - fontSize`, treating sensor.y as a rough baseline. Real
asterctl does not do this -- see tools/pixel-probe/README.md for the
actual formula (found by reading asterctl's own source), which places ink
noticeably lower than this script assumes. A layout that looks
clean here can still overlap on the real device (this happened, on the
Storage panel's stat rows -- see MASTER_PLAN.md's 2026-08-15 3rd-pass
entry). Use tools/pixel-probe for any spacing decision that actually
matters; treat this script's output as rough visual composition only
(are things roughly where I meant them, not do they clear each other).

Usage: render-preview.py <panel-index-0-based> <sensor-file> <output-png> [label=value ...]
Trailing label=value args override/add values not present in the sensor file
(handy for mocking states -- e.g. an "issues present" example -- without
needing real device data).
"""
import json
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

DASHBOARD_DIR = Path(__file__).resolve().parent.parent
FONT_DIR = DASHBOARD_DIR / "fonts"
FONT_FILES = {"HarmonyOS_Sans_SC_Bold": FONT_DIR / "HarmonyOS_Sans_SC_Bold.ttf"}


def load_sensor_values(path):
    values = {}
    if path and Path(path).exists():
        for line in Path(path).read_text().splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                values[k.strip()] = v.strip()
    return values


def format_value(field, raw):
    unit = field.get("unit", "")
    digits = field.get("decimalDigits", -1)
    if digits is not None and digits >= 0:
        try:
            raw = f"{float(raw):.{digits}f}"
        except ValueError:
            pass
    return f"{raw}{unit}"


def main():
    panel_index = int(sys.argv[1])
    sensor_file = sys.argv[2]
    out_path = sys.argv[3]
    overrides = dict(a.split("=", 1) for a in sys.argv[4:])

    monitor = json.loads((DASHBOARD_DIR / "monitor.json").read_text())
    panel = monitor["diy"][panel_index]

    img = Image.open(DASHBOARD_DIR / panel["img"]).convert("RGB")
    draw = ImageDraw.Draw(img)
    values = load_sensor_values(sensor_file)
    values.update(overrides)

    for field in panel["sensor"]:
        label = field["label"]
        if label not in values:
            continue
        text = format_value(field, values[label])
        font_path = FONT_FILES.get(field["fontFamily"])
        font = ImageFont.truetype(str(font_path), field["fontSize"]) if font_path else ImageFont.load_default()
        color = field["fontColor"]
        x, y = field["x"], field["y"]
        align = field.get("textAlign", "left")
        bbox = draw.textbbox((0, 0), text, font=font)
        w = bbox[2] - bbox[0]
        if align == "right":
            x -= w
        elif align == "center":
            x -= w / 2
        # asterctl's y is a baseline-ish anchor for these fonts in practice;
        # nudge up by the font's ascent so this matches on-device framing.
        draw.text((x, y - field["fontSize"]), text, font=font, fill=color)

    img.save(out_path)
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
