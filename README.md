# Sharaza — Native ShareX for macOS

**Sharaza** is an evidence-driven, native macOS reconstruction of [ShareX](https://github.com/ShareX/ShareX) built with **Rust + Tokio + SQLite** for the platform-independent core and **SwiftUI + AppKit** for the native macOS desktop experience — with zero Electron, Tauri, or web UI wrappers.

Reverse-engineered and verified against ShareX `v22.4.0` (`81507974a3a14cbcd4b7135654599d28f423189e`) using **[REA — Reverse Engineer Anything](https://github.com/morluto/rea)** (`rea-agents` v6.9.0).

---

## Highlights

- **Screen & Window Capture (`ScreenCaptureKit` + `CGWindowList`):** Full-screen (multi-monitor union), active monitor, specific display, active window, interactive window picker, delayed capture, last-region repeat, and precision multi-monitor region overlay with crosshair, dimensions HUD, and `15×15` pixel-grid magnifier loupe.
- **Scrolling Capture:** Vertical scanline overlap stitcher (`ScrollingCaptureManager.CombineImages` parity) in Rust paired with `ScreenCaptureKit` frame sampling and optional synthetic scroll injection.
- **Screen Recording & Animated GIFs (`SCStream` + `AVAssetWriter` + `ImageIO`):** Hardware-accelerated H.264/AAC `.mp4` (with system audio & macOS 15+ microphone support) and looping `.gif` recording with a floating Pause / Resume / Stop / Abort HUD bar.
- **Native Image Editor (`CoreGraphics` + `CoreImage` + SwiftUI):** Arrow, Rectangle, Ellipse, Line, Freehand Pen, Highlight, Text, Callout Speech Balloon, Auto-Increment Step Numbers (`1, 2, 3…`), Gaussian Blur, Pixelate, Spotlight, Smart Eraser, 2× Magnify Loupe, Crop, Undo/Redo, and ShareX Image Beautifier (gradient canvas, rounded corners, soft drop shadow).
- **ShareX Workflow Engine (`SharazaEngine` in Rust):** Configurable `AfterCaptureTasks` & `AfterUploadTasks` pipelines, external CLI `%input`/`%output` actions, full 28-token ShareX `NameParser` (`%y`, `%mo`, `%pn`, `%t`, `%i{4}`, `%ra{6}`, `%guid`, etc.), and `UploadInfoParser` link formatters.
- **Uploaders, `.sxcu` Custom Uploaders & macOS Keychain:** Imgur, vgy.me, catbox.moe, 0x0.st, temp.sh, Pastebin, GitHub Gist, Dropbox, Nextcloud/ownCloud WebDAV, Amazon S3 PUT, URL shorteners (`is.gd`, `v.gd`, `tinyurl.com`, `bit.ly`), and full `.sxcu` Custom Uploader import/export/execution (`$json:...$`, `$xml:...$`, `$regex:...$`, `$header:...$`, `$response$`), backed by `Security.framework` macOS Keychain (`app.sharaza.credentials`).
- **Productivity Utilities (`Vision` + AppKit + Rust):** Accurate offline OCR (`VNRecognizeTextRequest`), QR code generator & screen/file scanner (`VNDetectBarcodesRequest`), Screen Color Picker (`HEX`, `RGB`, `HSB`, `HSL`, `CMYK`, `Decimal`), Screen Ruler, Always-on-Top Pin to Screen, and 6-algorithm Hash Check (`CRC-32`, `MD5`, `SHA-1`, `SHA-256`, `SHA-384`, `SHA-512`).
- **Menu Bar & Global Shortcuts:** Resident SwiftUI `MenuBarExtra`, Carbon `RegisterEventHotKey` global shortcuts with interactive shortcut recording (no Accessibility prompt required), and 100% ShareX-compatible SQLite `History` database (`~/Library/Application Support/Sharaza/History.sqlite`).

---

## Documentation

- [`docs/KNOWLEDGE_BASE.md`](docs/KNOWLEDGE_BASE.md) — Pinned upstream revisions, REA Evidence ledger (`ev_...`), CIL/native-boundary findings, extracted functional specifications, and documented macOS platform constraints.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Rust/SwiftUI/AppKit module topology, C ABI (`sharaza_ffi.h`) memory contract, Keychain security model, and TCC permission design.
- [`docs/FEATURE_PARITY_MATRIX.md`](docs/FEATURE_PARITY_MATRIX.md) — Requirement-by-requirement traceability matrix mapping ShareX subsystems to Sharaza Rust/Swift modules and verification evidence.

---

## Building, Testing & Packaging

### Prerequisites
- macOS 14.0+ (Apple Silicon or Intel) with Xcode / Swift 6 toolchain
- Rust (`rustc` & `cargo`)

### Build Installable `Sharaza.app` Bundle
```bash
./scripts/build-app.sh
open dist/Sharaza.app
```
To install system-wide, drag `dist/Sharaza.app` to `/Applications`.

### Publish a release

Push a `v*` tag to build that commit on GitHub and attach `Sharaza.app` to a release. The tag is the version (`v0.2.0` stamps the app as `0.2.0`). Nothing is versioned automatically.

```bash
git tag v0.2.0
git push origin v0.2.0
```

The release asset is an Apple Silicon zip. It is ad-hoc signed until a Developer ID certificate is available, so first launch still needs `xattr -dr com.apple.quarantine Sharaza.app`.

### Run Automated Verification Suites
```bash
# 1. Rust Core + C ABI FFI + Upstream .sxcu Corpus Tests
cargo test --workspace

# 2. Native macOS Swift + C ABI + Vision OCR/QR + GIF + SQLite Integration Tests
swift test --package-path macos
```

---

## License

Licensed under the **GNU General Public License v3.0** (`GPL-3.0-or-later`), matching upstream ShareX. See [`LICENSE`](LICENSE) for full terms.
