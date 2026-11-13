use crate::error::{CoreError, CoreResult};
use crate::models::{ImageEffectsConfig, ImageFormat};
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat as ImgFmt, Rgba, RgbaImage};
use std::io::Cursor;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScrollingStitchStatus {
    Successful,
    PartiallySuccessful,
    NoNewContent,
    Failed,
}

#[derive(Debug)]
pub struct ScrollingStitchState {
    pub accumulated: Option<RgbaImage>,
    pub best_match_count: usize,
    pub best_match_index: usize,
    pub best_ignore_bottom_offset: usize,
    pub auto_ignore_bottom_edge: bool,
    pub status: ScrollingStitchStatus,
}

impl Default for ScrollingStitchState {
    fn default() -> Self {
        Self {
            accumulated: None,
            best_match_count: 0,
            best_match_index: 0,
            best_ignore_bottom_offset: 0,
            auto_ignore_bottom_edge: true,
            status: ScrollingStitchStatus::Failed,
        }
    }
}

impl ScrollingStitchState {
    pub fn new(auto_ignore_bottom_edge: bool) -> Self {
        Self {
            auto_ignore_bottom_edge,
            ..Default::default()
        }
    }

    /// Reconstructs `ShareX.ScreenCaptureLib.ScrollingCaptureManager.CombineImages`
    /// (`ScrollingCaptureManager.cs` lines 258-391) in memory-safe Rust.
    pub fn push_frame(&mut self, current: &RgbaImage) -> ScrollingStitchStatus {
        let Some(ref result) = self.accumulated else {
            self.accumulated = Some(current.clone());
            self.status = ScrollingStitchStatus::Successful;
            return self.status;
        };

        if result.as_raw() == current.as_raw() {
            return ScrollingStitchStatus::NoNewContent;
        }

        let w = current.width() as usize;
        let h_cur = current.height() as usize;
        let h_res = result.height() as usize;

        if w != result.width() as usize || h_cur > h_res || w < 8 || h_cur < 8 {
            self.status = ScrollingStitchStatus::Failed;
            return self.status;
        }

        let match_limit = (h_cur / 2).max(1);
        let ignore_side = (w / 20).max(50.min(w / 4)).min(w / 3);
        let compare_width_px = w.saturating_sub(ignore_side * 2);
        if compare_width_px == 0 {
            self.status = ScrollingStitchStatus::Failed;
            return self.status;
        }

        let stride = w * 4;
        let side_byte_offset = ignore_side * 4;
        let compare_byte_len = compare_width_px * 4;

        let res_raw = result.as_raw();
        let cur_raw = current.as_raw();

        let row_eq = |res_y: usize, cur_y: usize| -> bool {
            let r_start = res_y * stride + side_byte_offset;
            let c_start = cur_y * stride + side_byte_offset;
            res_raw[r_start..r_start + compare_byte_len]
                == cur_raw[c_start..c_start + compare_byte_len]
        };

        let ignore_bottom_max = h_cur / 3;
        let mut ignore_bottom = (h_cur / 10).max(50.min(h_cur / 5));

        if self.auto_ignore_bottom_edge {
            for i in 0..=ignore_bottom_max {
                if !row_eq(h_res - 1 - i, h_cur - 1 - i) {
                    ignore_bottom += i;
                    break;
                }
            }
            ignore_bottom = ignore_bottom.max(self.best_ignore_bottom_offset);
        }
        ignore_bottom = ignore_bottom.min(ignore_bottom_max);

        if h_res <= ignore_bottom {
            self.status = ScrollingStitchStatus::Failed;
            return self.status;
        }
        let rect_bottom = h_res - ignore_bottom - 1;

        let mut match_count = 0usize;
        let mut match_index = 0usize;

        let mut current_image_y = h_cur as isize - 1;
        while current_image_y >= 0 && match_count < match_limit {
            let cur_y_usize = current_image_y as usize;
            let mut cur_match = 0usize;
            let max_y = cur_y_usize.min(rect_bottom);

            for y in 0..=max_y {
                if cur_match >= match_limit {
                    break;
                }
                if row_eq(rect_bottom - y, cur_y_usize - y) {
                    cur_match += 1;
                } else {
                    break;
                }
            }

            if cur_match > match_count {
                match_count = cur_match;
                match_index = cur_y_usize;
            }
            current_image_y -= 1;
        }

        let mut best_guess = false;
        if match_count == 0 && self.best_match_count > 0 {
            match_count = self.best_match_count;
            match_index = self.best_match_index;
            ignore_bottom = self.best_ignore_bottom_offset;
            best_guess = true;
        }

        if match_count > 0 && match_index + 1 < h_cur {
            let match_height = h_cur - match_index - 1;
            if match_count > self.best_match_count {
                self.best_match_count = match_count;
                self.best_match_index = match_index;
                self.best_ignore_bottom_offset = ignore_bottom;
            }

            let kept_res_height = h_res - ignore_bottom;
            let new_height = kept_res_height + match_height;
            let mut combined = vec![0u8; new_height * stride];
            combined[..kept_res_height * stride]
                .copy_from_slice(&res_raw[..kept_res_height * stride]);
            let cur_src_start = (match_index + 1) * stride;
            let cur_src_end = cur_src_start + match_height * stride;
            combined[kept_res_height * stride..]
                .copy_from_slice(&cur_raw[cur_src_start..cur_src_end]);

            if let Some(img) = RgbaImage::from_raw(w as u32, new_height as u32, combined) {
                self.accumulated = Some(img);
                if best_guess {
                    self.status = ScrollingStitchStatus::PartiallySuccessful;
                } else if self.status != ScrollingStitchStatus::PartiallySuccessful {
                    self.status = ScrollingStitchStatus::Successful;
                }
                return self.status;
            }
        }

        self.status = ScrollingStitchStatus::Failed;
        self.status
    }
}

pub fn stitch_scrolling_frames(
    frames: &[RgbaImage],
    auto_ignore_bottom_edge: bool,
) -> CoreResult<(RgbaImage, ScrollingStitchStatus)> {
    if frames.is_empty() {
        return Err(CoreError::InvalidConfig(
            "At least one frame is required for scrolling capture".to_string(),
        ));
    }
    let mut stitcher = ScrollingStitchState::new(auto_ignore_bottom_edge);
    for frame in frames {
        stitcher.push_frame(frame);
    }
    let status = stitcher.status;
    let out = stitcher
        .accumulated
        .ok_or_else(|| CoreError::InvalidConfig("Stitching produced no output".to_string()))?;
    Ok((out, status))
}

/// Applies ShareX Image Beautifier (`AfterCaptureTasks.BeautifyImage`):
/// rounded corners on screenshot, soft drop shadow, and diagonal gradient padded canvas.
pub fn beautify_image(src: &RgbaImage, cfg: &ImageEffectsConfig) -> RgbaImage {
    let pad = cfg.beautify_padding;
    if pad == 0 {
        return round_corners(src, cfg.beautify_corner_radius);
    }

    let rounded = round_corners(src, cfg.beautify_corner_radius);
    let out_w = src.width() + pad * 2;
    let out_h = src.height() + pad * 2;
    let mut canvas = RgbaImage::new(out_w, out_h);

    let c0 = cfg.beautify_bg_start_rgba;
    let c1 = cfg.beautify_bg_end_rgba;
    let denom = (out_w + out_h).max(1) as f32;

    for y in 0..out_h {
        for x in 0..out_w {
            let t = ((x + y) as f32 / denom).clamp(0.0, 1.0);
            let r = lerp_u8(c0[0], c1[0], t);
            let g = lerp_u8(c0[1], c1[1], t);
            let b = lerp_u8(c0[2], c1[2], t);
            let a = lerp_u8(c0[3], c1[3], t);
            canvas.put_pixel(x, y, Rgba([r, g, b, a]));
        }
    }

    // Soft drop shadow around rounded rect
    if cfg.beautify_shadow_radius > 0 && cfg.beautify_shadow_opacity > 0.0 {
        let sr = cfg.beautify_shadow_radius as i32;
        let shadow_offset_y = (sr / 3).max(2);
        let left = pad as i32;
        let top = pad as i32 + shadow_offset_y;
        let right = (pad + src.width()) as i32;
        let bottom = (pad + src.height()) as i32 + shadow_offset_y;
        let corner_r = cfg.beautify_corner_radius as f32;

        let y_min = (top - sr).max(0) as u32;
        let y_max = (bottom + sr).min(out_h as i32) as u32;
        let x_min = (left - sr).max(0) as u32;
        let x_max = (right + sr).min(out_w as i32) as u32;

        for y in y_min..y_max {
            for x in x_min..x_max {
                let dist = signed_distance_rounded_rect(
                    x as f32,
                    y as f32,
                    left as f32,
                    top as f32,
                    (right - left) as f32,
                    (bottom - top) as f32,
                    corner_r,
                );
                if dist < sr as f32 {
                    let norm = (dist.max(0.0) / sr as f32).clamp(0.0, 1.0);
                    let falloff = (1.0 - norm).powi(2);
                    let alpha = (cfg.beautify_shadow_opacity * falloff * 255.0) as u8;
                    if alpha > 0 {
                        let dst = *canvas.get_pixel(x, y);
                        canvas.put_pixel(x, y, blend_over(dst, Rgba([0, 0, 0, alpha])));
                    }
                }
            }
        }
    }

    // Composite rounded foreground onto padded gradient canvas
    for y in 0..rounded.height() {
        for x in 0..rounded.width() {
            let fg = *rounded.get_pixel(x, y);
            if fg[3] > 0 {
                let dst = *canvas.get_pixel(x + pad, y + pad);
                canvas.put_pixel(x + pad, y + pad, blend_over(dst, fg));
            }
        }
    }

    canvas
}

pub fn round_corners(src: &RgbaImage, radius: u32) -> RgbaImage {
    if radius == 0 {
        return src.clone();
    }
    let mut out = src.clone();
    let w = out.width() as f32;
    let h = out.height() as f32;
    let r = (radius as f32).min(w / 2.0).min(h / 2.0);

    for y in 0..out.height() {
        for x in 0..out.width() {
            let sd = signed_distance_rounded_rect(x as f32 + 0.5, y as f32 + 0.5, 0.0, 0.0, w, h, r);
            if sd > 0.5 {
                let mut px = *out.get_pixel(x, y);
                px[3] = 0;
                out.put_pixel(x, y, px);
            } else if sd > -0.5 {
                let cov = (0.5 - sd).clamp(0.0, 1.0);
                let mut px = *out.get_pixel(x, y);
                px[3] = (px[3] as f32 * cov) as u8;
                out.put_pixel(x, y, px);
            }
        }
    }
    out
}

pub fn apply_image_effects(src: &RgbaImage, cfg: &ImageEffectsConfig) -> RgbaImage {
    let mut img = src.clone();

    if cfg.resize_scale_percent > 0 && cfg.resize_scale_percent != 100 {
        let nw = ((img.width() as u64 * cfg.resize_scale_percent as u64) / 100).max(1) as u32;
        let nh = ((img.height() as u64 * cfg.resize_scale_percent as u64) / 100).max(1) as u32;
        img = image::imageops::resize(&img, nw, nh, FilterType::Lanczos3);
    }

    if cfg.border_size > 0 {
        let b = cfg.border_size;
        let color = Rgba(cfg.border_rgba);
        if cfg.border_inside {
            for y in 0..img.height() {
                for x in 0..img.width() {
                    if x < b || y < b || x >= img.width().saturating_sub(b) || y >= img.height().saturating_sub(b) {
                        let dst = *img.get_pixel(x, y);
                        img.put_pixel(x, y, blend_over(dst, color));
                    }
                }
            }
        } else {
            let mut framed = RgbaImage::from_pixel(img.width() + b * 2, img.height() + b * 2, color);
            image::imageops::overlay(&mut framed, &img, b as i64, b as i64);
            img = framed;
        }
    }

    img
}

pub fn pixelate_region(img: &mut RgbaImage, rx: u32, ry: u32, rw: u32, rh: u32, block_size: u32) {
    let block = block_size.max(2);
    let x_end = (rx + rw).min(img.width());
    let y_end = (ry + rh).min(img.height());
    let mut by = ry;
    while by < y_end {
        let bh = block.min(y_end - by);
        let mut bx = rx;
        while bx < x_end {
            let bw = block.min(x_end - bx);
            let mut r_sum = 0u64;
            let mut g_sum = 0u64;
            let mut b_sum = 0u64;
            let mut a_sum = 0u64;
            let count = (bw * bh).max(1) as u64;
            for y in by..by + bh {
                for x in bx..bx + bw {
                    let p = img.get_pixel(x, y);
                    r_sum += p[0] as u64;
                    g_sum += p[1] as u64;
                    b_sum += p[2] as u64;
                    a_sum += p[3] as u64;
                }
            }
            let avg = Rgba([
                (r_sum / count) as u8,
                (g_sum / count) as u8,
                (b_sum / count) as u8,
                (a_sum / count) as u8,
            ]);
            for y in by..by + bh {
                for x in bx..bx + bw {
                    img.put_pixel(x, y, avg);
                }
            }
            bx += block;
        }
        by += block;
    }
}

pub fn blur_region(img: &mut RgbaImage, rx: u32, ry: u32, rw: u32, rh: u32, sigma: f32) {
    let x0 = rx.min(img.width());
    let y0 = ry.min(img.height());
    let w = rw.min(img.width().saturating_sub(x0));
    let h = rh.min(img.height().saturating_sub(y0));
    if w == 0 || h == 0 {
        return;
    }
    let sub = image::imageops::crop_imm(img, x0, y0, w, h).to_image();
    let blurred = image::imageops::blur(&sub, sigma.max(1.0));
    image::imageops::replace(img, &blurred, x0 as i64, y0 as i64);
}

pub fn create_thumbnail(src: &RgbaImage, target_w: u32, target_h: u32) -> RgbaImage {
    if target_w == 0 && target_h == 0 {
        return src.clone();
    }
    let (nw, nh) = if target_h == 0 {
        let ratio = target_w as f32 / src.width().max(1) as f32;
        (target_w, ((src.height() as f32 * ratio).round() as u32).max(1))
    } else if target_w == 0 {
        let ratio = target_h as f32 / src.height().max(1) as f32;
        (((src.width() as f32 * ratio).round() as u32).max(1), target_h)
    } else {
        (target_w, target_h)
    };
    image::imageops::resize(src, nw, nh, FilterType::Lanczos3)
}

pub fn encode_rgba_image(
    src: &RgbaImage,
    format: ImageFormat,
    jpeg_quality: u8,
) -> CoreResult<Vec<u8>> {
    let mut buf = Vec::new();
    match format {
        ImageFormat::PNG => {
            DynamicImage::ImageRgba8(src.clone())
                .write_to(&mut Cursor::new(&mut buf), ImgFmt::Png)?;
        }
        ImageFormat::JPEG => {
            let rgb = DynamicImage::ImageRgba8(src.clone()).to_rgb8();
            let mut enc = JpegEncoder::new_with_quality(&mut buf, jpeg_quality.clamp(1, 100));
            enc.encode_image(&rgb)?;
        }
        ImageFormat::WEBP => {
            DynamicImage::ImageRgba8(src.clone())
                .write_to(&mut Cursor::new(&mut buf), ImgFmt::WebP)?;
        }
        ImageFormat::GIF => {
            DynamicImage::ImageRgba8(src.clone())
                .write_to(&mut Cursor::new(&mut buf), ImgFmt::Gif)?;
        }
        ImageFormat::BMP => {
            DynamicImage::ImageRgba8(src.clone())
                .write_to(&mut Cursor::new(&mut buf), ImgFmt::Bmp)?;
        }
    }
    Ok(buf)
}

pub fn decode_rgba_image(bytes: &[u8]) -> CoreResult<RgbaImage> {
    let img = image::load_from_memory(bytes)?;
    Ok(img.to_rgba8())
}

fn lerp_u8(a: u8, b: u8, t: f32) -> u8 {
    (a as f32 + (b as f32 - a as f32) * t).round().clamp(0.0, 255.0) as u8
}

fn blend_over(dst: Rgba<u8>, src: Rgba<u8>) -> Rgba<u8> {
    let sa = src[3] as f32 / 255.0;
    let da = dst[3] as f32 / 255.0;
    let out_a = sa + da * (1.0 - sa);
    if out_a <= 0.0001 {
        return Rgba([0, 0, 0, 0]);
    }
    let r = (src[0] as f32 * sa + dst[0] as f32 * da * (1.0 - sa)) / out_a;
    let g = (src[1] as f32 * sa + dst[1] as f32 * da * (1.0 - sa)) / out_a;
    let b = (src[2] as f32 * sa + dst[2] as f32 * da * (1.0 - sa)) / out_a;
    Rgba([
        r.round().clamp(0.0, 255.0) as u8,
        g.round().clamp(0.0, 255.0) as u8,
        b.round().clamp(0.0, 255.0) as u8,
        (out_a * 255.0).round().clamp(0.0, 255.0) as u8,
    ])
}

fn signed_distance_rounded_rect(
    px: f32,
    py: f32,
    rx: f32,
    ry: f32,
    rw: f32,
    rh: f32,
    radius: f32,
) -> f32 {
    let cx = rx + rw * 0.5;
    let cy = ry + rh * 0.5;
    let hx = rw * 0.5 - radius;
    let hy = rh * 0.5 - radius;
    let dx = (px - cx).abs() - hx;
    let dy = (py - cy).abs() - hy;
    let out_dist = (dx.max(0.0).powi(2) + dy.max(0.0).powi(2)).sqrt();
    let in_dist = dx.max(dy).min(0.0);
    out_dist + in_dist - radius
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stitches_scrolling_frames_accurately() {
        // Construct a synthetic 300x600 tall document and take 3 overlapping 300x260 viewport frames
        let full_w = 300u32;
        let full_h = 600u32;
        let mut doc = RgbaImage::new(full_w, full_h);
        for y in 0..full_h {
            for x in 0..full_w {
                let r = ((y * 7 + x) % 251) as u8;
                let g = ((y * 13 + x * 3) % 241) as u8;
                let b = ((y * 29) % 239) as u8;
                doc.put_pixel(x, y, Rgba([r, g, b, 255]));
            }
        }

        let vp_h = 260u32;
        let f1 = image::imageops::crop_imm(&doc, 0, 0, full_w, vp_h).to_image();
        let f2 = image::imageops::crop_imm(&doc, 0, 150, full_w, vp_h).to_image();
        let f3 = image::imageops::crop_imm(&doc, 0, 340, full_w, vp_h).to_image();

        let (stitched, status) = stitch_scrolling_frames(&[f1, f2, f3], false).unwrap();
        assert_eq!(status, ScrollingStitchStatus::Successful);
        assert_eq!(stitched.width(), full_w);
        assert_eq!(stitched.height(), full_h);
        assert_eq!(stitched.get_pixel(150, 0), doc.get_pixel(150, 0));
        assert_eq!(stitched.get_pixel(150, 300), doc.get_pixel(150, 300));
        assert_eq!(stitched.get_pixel(150, 599), doc.get_pixel(150, 599));
    }

    #[test]
    fn beautifier_adds_padding_and_preserves_opaque_center() {
        let src = RgbaImage::from_pixel(120, 80, Rgba([240, 245, 250, 255]));
        let cfg = ImageEffectsConfig::default();
        let out = beautify_image(&src, &cfg);
        assert_eq!(out.width(), 120 + cfg.beautify_padding * 2);
        assert_eq!(out.height(), 80 + cfg.beautify_padding * 2);
        let center = out.get_pixel(out.width() / 2, out.height() / 2);
        assert_eq!(*center, Rgba([240, 245, 250, 255]));
    }
}
