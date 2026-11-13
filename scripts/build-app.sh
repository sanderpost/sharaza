#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
VERSION="${SHARAZA_VERSION:-0.1.0}"
BUILD_NUMBER="${SHARAZA_BUILD:-1}"

echo "==> [1/4] Building Rust Core & C ABI Static Library (release)..."
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" --release -p sharaza-ffi

echo "==> [2/4] Building Native SwiftUI/AppKit Executable (release)..."
swift build --package-path "$ROOT_DIR/macos" -c release

APP_DIR="$ROOT_DIR/dist/Sharaza.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/macos/.build/release/Sharaza" "$MACOS_DIR/Sharaza"
chmod +x "$MACOS_DIR/Sharaza"
cp "$ROOT_DIR/LICENSE" "$RESOURCES_DIR/LICENSE"

echo "==> [3/4] Generating Retina AppIcon.icns..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" << 'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let iconsetPath = CommandLine.arguments[1]
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let s = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        CGColor(srgbRed: 0.14, green: 0.36, blue: 0.96, alpha: 1.0),
        CGColor(srgbRed: 0.06, green: 0.72, blue: 0.85, alpha: 1.0),
    ] as CFArray
    let grad = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // Viewfinder brackets + aperture ring
    ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.95))
    ctx.setLineWidth(max(1.5, s * 0.055))
    ctx.setLineCap(.round)
    let b = s * 0.26
    let len = s * 0.13

    // Corners
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: b, y: b + len), CGPoint(x: b, y: b), CGPoint(x: b + len, y: b)),
        (CGPoint(x: s - b - len, y: b), CGPoint(x: s - b, y: b), CGPoint(x: s - b, y: b + len)),
        (CGPoint(x: b, y: s - b - len), CGPoint(x: b, y: s - b), CGPoint(x: b + len, y: s - b)),
        (CGPoint(x: s - b - len, y: s - b), CGPoint(x: s - b, y: s - b), CGPoint(x: s - b, y: s - b - len)),
    ]
    for (p0, p1, p2) in corners {
        ctx.move(to: p0); ctx.addLine(to: p1); ctx.addLine(to: p2)
    }
    ctx.strokePath()

    let ring = CGRect(x: s * 0.38, y: s * 0.38, width: s * 0.24, height: s * 0.24)
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.92))
    ctx.fillEllipse(in: ring)

    let cgImg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cgImg)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(name))
}
SWIFT

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

cat > "$CONTENTS_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Sharaza</string>
    <key>CFBundleExecutable</key>
    <string>Sharaza</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>app.sharaza.macos</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Sharaza</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 Sharaza Contributors. Licensed under GNU GPL v3.0.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Sharaza needs Screen Recording permission to capture screenshots, windows, scrolling pages, and screen recordings.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sharaza needs Microphone permission when microphone audio capture is enabled during screen recording.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>sxcu</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>ShareX Custom Uploader</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "==> [4/4] Signing & verifying Sharaza.app..."
SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "    Using certificate identity: $SIGN_IDENTITY"
    codesign --force --deep --identifier "app.sharaza.macos" --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "    No Apple Developer certificate found; using ad-hoc signature (identifier: app.sharaza.macos)"
    codesign --force --deep --identifier "app.sharaza.macos" --sign - "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "==> Built successfully: $APP_DIR"
