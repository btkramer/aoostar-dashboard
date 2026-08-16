# pixel-probe

A tiny throwaway-turned-permanent Rust tool that computes EXACTLY where
asterctl will draw a given `monitor.json` text field on the real device --
not an approximation.

## Why this exists

Every monitor.json sensor field's `y` is passed through asterctl's own
render formula (`crates/asterctl/src/render.rs`, `render_text`):

```
scale = font.pt_to_px_scale(fontSize * 0.75)   // "adjustment_hack"
size  = text_size(scale, font, text)            // (w, h) -- h = font.height() at that scale, NOT ink-tight
y     = sensor.y + height/2 - size.1 * 1.3333 / 2   // height = the field's own JSON "height", always 0 in this project
```

then each glyph is drawn with its own ink bounding box relative to that
`y`. This is **not a baseline convention** -- ink typically extends
further below `sensor.y` than above it, by an amount that depends on the
specific font, fontSize, and text content. asterctl's own source code
calls this behavior "still a mystery" (see the FIXME comments in
`render_text`) -- it was never fully nailed down even by that project's
own author.

This project spent two rounds (2026-08-15) guessing at this with
DejaVu-based ascent/descent approximations and a naive `y - fontSize`
nudge (`scripts/render-preview.py`'s old behavior) -- both looked fine in
their own preview but didn't match the real device, causing on-device
text/bar overlap that wasn't visible in either preview. This tool exists
because guessing a third time wasn't worth it -- it links against the
*actual* `ab_glyph`/`imageproc` crates asterctl is built from and runs the
*actual* formula, using the real `fonts/HarmonyOS_Sans_SC_Bold.ttf` file.

## Usage

```sh
cd tools/pixel-probe
cargo build --release
./target/release/probe ../../fonts/HarmonyOS_Sans_SC_Bold.ttf 34 "42%" 162
```

Args: `<font-path> <fontSize> <text> <sensor.y> [sensor.height]`

Prints the exact pixel row range the text's ink will occupy, both absolute
and relative to `sensor.y` -- use the relative numbers to check clearance
between two fields (e.g. a value's ink bottom vs. an accent bar's y, or
two stacked fields' ink boxes) before committing coordinates to
`monitor.json`. A field with `textAlign: center` still needs its *width*
(also printed, as `size=(w,h)`) to convert `sensor.x` into a left/right
ink range -- the formula for that is in `render.rs` too (mirrors
`text_align` handling, straightforward).

Not committed as part of the normal build (nothing else in this repo
depends on Rust/Cargo) -- it's a verification aid, run it by hand when
placing new monitor.json coordinates. Requires network access the first
time to fetch the `ab_glyph`/`imageproc`/`image` crates.
