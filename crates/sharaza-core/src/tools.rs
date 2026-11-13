use crate::error::{CoreError, CoreResult};
use crate::image_ops::encode_rgba_image;
use crate::models::ImageFormat;
use image::{Rgba, RgbaImage};
use md5::Md5;
use qrcode::QrCode;
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use sha2::{Digest, Sha256, Sha384, Sha512};
use std::fs::File;
use std::io::Read;
use std::path::Path;

/// Matches `ShareX.HelpersLib.HashType` (`Enums.cs` lines 77-92).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileHashes {
    pub crc32: String,
    pub md5: String,
    pub sha1: String,
    pub sha256: String,
    pub sha384: String,
    pub sha512: String,
}

pub fn compute_hashes_bytes(bytes: &[u8]) -> FileHashes {
    let crc = crc32fast::hash(bytes);
    let md5 = hex::encode(Md5::digest(bytes));
    let sha1 = hex::encode(Sha1::digest(bytes));
    let sha256 = hex::encode(Sha256::digest(bytes));
    let sha384 = hex::encode(Sha384::digest(bytes));
    let sha512 = hex::encode(Sha512::digest(bytes));

    FileHashes {
        crc32: format!("{crc:08x}"),
        md5,
        sha1,
        sha256,
        sha384,
        sha512,
    }
}

pub fn compute_hashes_file<P: AsRef<Path>>(path: P) -> CoreResult<FileHashes> {
    let mut file = File::open(path)?;
    let mut crc_hasher = crc32fast::Hasher::new();
    let mut md5_hasher = Md5::new();
    let mut sha1_hasher = Sha1::new();
    let mut sha256_hasher = Sha256::new();
    let mut sha384_hasher = Sha384::new();
    let mut sha512_hasher = Sha512::new();

    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        let chunk = &buf[..n];
        crc_hasher.update(chunk);
        md5_hasher.update(chunk);
        sha1_hasher.update(chunk);
        sha256_hasher.update(chunk);
        sha384_hasher.update(chunk);
        sha512_hasher.update(chunk);
    }

    Ok(FileHashes {
        crc32: format!("{:08x}", crc_hasher.finalize()),
        md5: hex::encode(md5_hasher.finalize()),
        sha1: hex::encode(sha1_hasher.finalize()),
        sha256: hex::encode(sha256_hasher.finalize()),
        sha384: hex::encode(sha384_hasher.finalize()),
        sha512: hex::encode(sha512_hasher.finalize()),
    })
}

/// Generates a crisp QR code PNG image for any text or URL (`ShareX` QRCode tool).
pub fn generate_qr_png(text: &str, module_px: u32) -> CoreResult<Vec<u8>> {
    if text.is_empty() {
        return Err(CoreError::InvalidConfig(
            "QR code content cannot be empty".to_string(),
        ));
    }
    let code = QrCode::new(text.as_bytes())
        .map_err(|e| CoreError::InvalidConfig(format!("QR encode error: {e}")))?;
    let scale = module_px.clamp(2, 32);
    let quiet = 4u32;
    let modules = code.width() as u32;
    let total = (modules + quiet * 2) * scale;
    let mut img = RgbaImage::from_pixel(total, total, Rgba([255, 255, 255, 255]));

    for my in 0..modules {
        for mx in 0..modules {
            if code[(mx as usize, my as usize)] == qrcode::Color::Dark {
                let px0 = (mx + quiet) * scale;
                let py0 = (my + quiet) * scale;
                for dy in 0..scale {
                    for dx in 0..scale {
                        img.put_pixel(px0 + dx, py0 + dy, Rgba([0, 0, 0, 255]));
                    }
                }
            }
        }
    }

    encode_rgba_image(&img, ImageFormat::PNG, 100)
}

/// Matches `ShareX.HelpersLib.ColorType` representations (`RGBA`, `HSB`, `HSL`, `CMYK`, `Hex`, `Decimal`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ColorFormats {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
    pub hex: String,
    pub hex_upper: String,
    pub argb_hex: String,
    pub rgb_css: String,
    pub rgba_css: String,
    pub decimal: u32,
    pub hsb: [f32; 3],
    pub hsl: [f32; 3],
    pub cmyk: [f32; 4],
}

impl ColorFormats {
    pub fn from_rgba(r: u8, g: u8, b: u8, a: u8) -> Self {
        let rf = r as f32 / 255.0;
        let gf = g as f32 / 255.0;
        let bf = b as f32 / 255.0;

        let max = rf.max(gf).max(bf);
        let min = rf.min(gf).min(bf);
        let delta = max - min;

        let hue = if delta <= f32::EPSILON {
            0.0
        } else if (max - rf).abs() <= f32::EPSILON {
            60.0 * (((gf - bf) / delta).rem_euclid(6.0))
        } else if (max - gf).abs() <= f32::EPSILON {
            60.0 * (((bf - rf) / delta) + 2.0)
        } else {
            60.0 * (((rf - gf) / delta) + 4.0)
        };

        let sat_hsb = if max <= f32::EPSILON { 0.0 } else { delta / max };
        let val_hsb = max;

        let light = (max + min) * 0.5;
        let sat_hsl = if delta <= f32::EPSILON {
            0.0
        } else {
            delta / (1.0 - (2.0 * light - 1.0).abs())
        };

        let k = 1.0 - max;
        let (c, m, y) = if (1.0 - k) <= f32::EPSILON {
            (0.0, 0.0, 0.0)
        } else {
            (
                (1.0 - rf - k) / (1.0 - k),
                (1.0 - gf - k) / (1.0 - k),
                (1.0 - bf - k) / (1.0 - k),
            )
        };

        let decimal = ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);
        Self {
            r,
            g,
            b,
            a,
            hex: format!("#{r:02x}{g:02x}{b:02x}"),
            hex_upper: format!("#{r:02X}{g:02X}{b:02X}"),
            argb_hex: format!("#{a:02X}{r:02X}{g:02X}{b:02X}"),
            rgb_css: format!("rgb({r}, {g}, {b})"),
            rgba_css: format!("rgba({r}, {g}, {b}, {:.2})", a as f32 / 255.0),
            decimal,
            hsb: [
                (hue * 10.0).round() / 10.0,
                (sat_hsb * 1000.0).round() / 10.0,
                (val_hsb * 1000.0).round() / 10.0,
            ],
            hsl: [
                (hue * 10.0).round() / 10.0,
                (sat_hsl * 1000.0).round() / 10.0,
                (light * 1000.0).round() / 10.0,
            ],
            cmyk: [
                (c * 1000.0).round() / 10.0,
                (m * 1000.0).round() / 10.0,
                (y * 1000.0).round() / 10.0,
                (k * 1000.0).round() / 10.0,
            ],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn computes_all_six_sharex_hashes() {
        let h = compute_hashes_bytes(b"ShareX");
        assert_eq!(h.crc32, "3b4f8d0a");
        assert_eq!(h.md5, "e0ace74469217da1f250003857c8bad8");
        assert_eq!(h.sha1, "4f5d90f368de0be11792481eab511b7505574e61");
        assert_eq!(
            h.sha256,
            "7947880f6d8b6dec76c60782c85e6dedcae2b94ce5e8c6c6914dff2ffdb9e007"
        );
        assert_eq!(
            h.sha384,
            "8bb9d7eb2ae4521df36d89d61a8aaafd5c71f3aa796e4dc178b1368b193fda6c78d4eab42f14e9bc4495d26c1606d4c9"
        );
        assert_eq!(
            h.sha512,
            "8cb1e3e8cc4d09dc0c973693902d36f708b4e1b2b526ba917856d1c446739376beee9502aa5eb035bb7697190c3b04104f296e060e51ec6ef04dd25b345c3051"
        );
    }

    #[test]
    fn generates_valid_qr_png() {
        let png = generate_qr_png("https://github.com/ShareX/ShareX", 6).unwrap();
        assert!(png.starts_with(&[137, 80, 78, 71]));
        let decoded = crate::image_ops::decode_rgba_image(&png).unwrap();
        assert!(decoded.width() > 100);
    }

    #[test]
    fn converts_color_spaces_accurately() {
        let cf = ColorFormats::from_rgba(255, 87, 51, 255);
        assert_eq!(cf.hex_upper, "#FF5733");
        assert_eq!(cf.decimal, 0xFF5733);
        assert_eq!(cf.rgb_css, "rgb(255, 87, 51)");
    }
}
