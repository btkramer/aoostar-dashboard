use ab_glyph::{Font, FontRef, PxScale, ScaleFont};
use imageproc::drawing::text_size;
use std::env;
use std::fs;

fn main() {
    let args: Vec<String> = env::args().collect();
    let font_path = &args[1];
    let font_size: f32 = args[2].parse().unwrap();
    let text = &args[3];
    let sensor_y: f32 = args[4].parse().unwrap();
    let sensor_height: f32 = args.get(5).map(|s| s.parse().unwrap()).unwrap_or(0.0);

    let bytes = fs::read(font_path).unwrap();
    let font = FontRef::try_from_slice(&bytes).unwrap();

    let adjustment_hack = 0.75;
    let px_per_em = (font_size * adjustment_hack) * (96.0 / 72.0);
    let units_per_em = font.units_per_em().unwrap();
    let height_unscaled = font.height_unscaled();
    let scale_val = px_per_em * height_unscaled / units_per_em;
    let scale = PxScale::from(scale_val);

    let size = text_size(scale, &font, text);
    let y = sensor_y + sensor_height / 2.0 - (size.1 as f32 * 1.3333 / 2.0);

    // Now compute actual ink bounds like draw_text_mut does, to find real top/bottom pixel rows
    let scaled_font = font.as_scaled(scale);
    let mut w = 0.0f32;
    let mut min_y = f32::INFINITY;
    let mut max_y = f32::NEG_INFINITY;
    let mut prev: Option<ab_glyph::GlyphId> = None;
    for c in text.chars() {
        let glyph_id = scaled_font.glyph_id(c);
        let glyph = glyph_id.with_scale_and_position(scale, ab_glyph::point(w, scaled_font.ascent()));
        w += scaled_font.h_advance(glyph_id);
        if let Some(g) = scaled_font.outline_glyph(glyph) {
            if let Some(p) = prev { w += scaled_font.kern(glyph_id, p); }
            prev = Some(glyph_id);
            let bb = g.px_bounds();
            if bb.min.y < min_y { min_y = bb.min.y; }
            if bb.max.y > max_y { max_y = bb.max.y; }
        }
    }
    let ink_top_local = min_y;
    let ink_bottom_local = max_y;
    let draw_y_top = y + ink_top_local;
    let draw_y_bottom = y + ink_bottom_local;

    println!("fontSize={} text={:?}", font_size, text);
    println!("  scale_px={:.2} size=({},{})", scale_val, size.0, size.1);
    println!("  sensor.y={} -> layout_y={:.2}", sensor_y, y);
    println!("  ACTUAL drawn ink top={:.2} bottom={:.2} (relative to sensor.y: top={:.2} bottom={:.2})",
        draw_y_top, draw_y_bottom, draw_y_top - sensor_y, draw_y_bottom - sensor_y);
}
