# Sharaza — System Architecture

Sharaza is a native macOS reconstruction of **ShareX** built with **Rust** for the platform-independent core and **SwiftUI + AppKit** for the native macOS user interface and system integration.

---

## 1. Module & Layer Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        macOS Application (Sharaza.app)                      │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ SwiftUI Presentation Layer                                            │  │
│  │  • MenuBarExtra (Quick Capture, Active Recording Controls, Recent)    │  │
│  │  • MainWorkspaceView (Dashboard, History Grid/Table, Workflows,       │  │
│  │    Uploaders & .sxcu Manager, Image Effects, Productivity Tools)      │  │
│  │  • PreferencesView (General, Capture, Recording, Hotkeys, Permissions)│  │
│  └───────────────────────────────┬───────────────────────────────────────┘  │
│                                  │ @MainActor / Swift Structured Concurrency│
│  ┌───────────────────────────────▼───────────────────────────────────────┐  │
│  │ AppKit & Apple Native Frameworks Layer                                │  │
│  │  • ScreenCaptureKit: Fullscreen, Monitor, Window, Region, SCStream    │  │
│  │  • AppKit Overlays: Multi-Monitor Precision Region Selector,          │  │
│  │    15×15 Pixel Magnifier Loupe, Screen Color Picker, Screen Ruler,    │  │
│  │    Pin-to-Screen Floating Panels, Recording Control Bar               │  │
│  │  • ImageEditor (AppKit/SwiftUI + CoreGraphics/CoreImage):             │  │
│  │    Arrow, Rect, Ellipse, Line, Freehand, Highlight, Text, Step #,     │  │
│  │    Gaussian Blur, Pixelate, Spotlight, Crop, Beautifier, Undo/Redo    │  │
│  │  • AVFoundation + ImageIO: H.264/HEVC MP4/MOV & Animated GIF Writer   │  │
│  │  • Vision: VNRecognizeTextRequest (OCR) & VNDetectBarcodesRequest(QR) │  │
│  │  • Carbon HIToolbox: RegisterEventHotKey Global Shortcuts             │  │
│  │  • Security.framework: macOS Keychain Credential Vault                │  │
│  │  • NSPasteboard / UserNotifications / NSWorkspace                     │  │
│  └───────────────────────────────┬───────────────────────────────────────┘  │
│                                  │ Documented C ABI (CSharazaFFI)           │
│                                  ▼                                          │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ crates/sharaza-ffi (Static Library: libsharaza_ffi.a)                 │  │
│  │  • Thread-safe SharazaCoreHandle owning multi-threaded Tokio Runtime  │  │
│  │  • JSON-enveloped command/query FFI + contiguous RGBA pixel buffer FFI│  │
│  │  • Explicit ownership & deterministic C memory release functions      │  │
│  └───────────────────────────────┬───────────────────────────────────────┘  │
│                                  ▼                                          │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ crates/sharaza-core (Pure Platform-Independent Rust Core)             │  │
│  │  • name_parser: Full ShareX % pattern & auto-increment engine         │  │
│  │  • storage: ShareX-compatible SQLite History.db + Settings & Workflows│  │
│  │  • workflow: TaskSettings, AfterCaptureTasks & AfterUploadTasks engine│  │
│  │  • uploader: CustomUploader (.sxcu) parser/executor, Imgur, Pastebin, │  │
│  │    GitHub Gist, S3/HTTP uploaders, is.gd/v.gd/TinyURL/Bitly shorteners│  │
│  │  • upload_info: UploadInfoParser ($url, $shorturl, Markdown/BBCode)   │  │
│  │  • image_ops: Scrolling capture scanline stitcher, effects, Beautifier│  │
│  │  • tools: Hash calculator (CRC32/MD5/SHA1/SHA256/SHA384/SHA512), QR   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Rust / Swift C ABI Contract (`sharaza_ffi.h`)

To guarantee zero code-generation fragility, fast incremental builds, and strict memory safety across `rustc` and `swiftc`:

1. **Lifecycle:**
   - `SharazaCoreHandle* sharaza_core_open(const char* data_dir_utf8, char** error_out)`
   - `void sharaza_core_close(SharazaCoreHandle* handle)`
2. **String & Buffer Memory Ownership:**
   - Every `char*` returned by Rust is heap-allocated via `CString::into_raw` and freed exclusively by `sharaza_string_free(char* ptr)`.
   - Every pixel/byte buffer `SharazaByteBuffer { uint8_t* ptr; size_t len; uint32_t width; uint32_t height; char* error; }` returned by Rust is freed exclusively by `sharaza_buffer_free(SharazaByteBuffer buf)`.
3. **Asynchronous Execution:**
   - `SharazaCoreHandle` owns a dedicated `tokio::runtime::Runtime`.
   - Swift invokes long-running FFI calls (`sharaza_upload_execute`, `sharaza_stitch_scrolling_frames`, `sharaza_apply_image_effects`) from off-main-thread Swift `Task.detached` executors via `RustCoreClient` (`Sendable`), keeping `@MainActor` SwiftUI views at 60/120 Hz with zero UI stalls.
4. **High-Throughput Binary Paths vs. Structured JSON Paths:**
   - Pixel operations (scrolling capture stitching, image effects, QR generation) pass raw RGBA8/PNG bytes directly across C pointers without base64 serialization overhead.
   - Configuration, workflow orchestration, `.sxcu` custom uploaders, and SQLite history queries exchange versioned `serde_json` payloads mapped to strongly typed Swift `Codable` structs.

---

## 3. Persistence & Security Architecture

1. **Application Support Directory:** `~/Library/Application Support/Sharaza/`
   - `History.sqlite`: Contains the exact upstream ShareX `History` table (`Id`, `FileName`, `FilePath`, `DateTime`, `Type`, `Host`, `URL`, `ThumbnailURL`, `DeletionURL`, `ShortenedURL`, `Tags`) plus `sharaza_settings`, `sharaza_workflows`, and `sharaza_custom_uploaders`.
   - Default captures folder: `~/Pictures/Sharaza/%y-%mo/` (configurable per workflow or globally).
2. **macOS Keychain (`Security.framework`):**
   - Service identifier: `app.sharaza.credentials`.
   - Uploader tokens (Imgur Client-ID/Bearer, GitHub Gist PAT, Pastebin dev key, Bitly token, Custom Uploader secret headers/parameters) are stored in Keychain and resolved just-in-time in memory before invoking `sharaza_upload_execute`, never persisted in plaintext SQLite or `.sxcu` exports unless explicitly requested by the user.
3. **macOS Privacy & TCC Permissions:**
   - **Screen Recording:** Preflighted via `CGPreflightScreenCaptureAccess()` before every capture/recording; guided prompt via `CGRequestScreenCaptureAccess()` and one-click link to System Settings.
   - **Microphone:** Requested via `AVCaptureDevice.requestAccess(for: .audio)` only when microphone audio is enabled in Screen Recording settings.
   - **Accessibility:** Checked via `AXIsProcessTrusted()` only when automated synthetic scroll injection is enabled in Scrolling Capture; global hotkeys use Carbon `RegisterEventHotKey` and require **no** Accessibility grant.
