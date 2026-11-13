# Sharaza — Reverse-Engineering & Reconstruction Knowledge Base

This persistent knowledge base records upstream revisions, **REA (`rea-agents` v6.9.0)** static binary/CIL inspection evidence, source-code mappings, extracted functional specifications, verified vs. inferred behaviors, and macOS platform constraints.

---

## 1. Upstream Repositories & Pinned Revisions

All reverse-engineering and behavioral specifications are anchored to the following exact upstream revisions and official release binaries:

| Repository / Artifact | URL / Source | Exact Revision / Tag | Commit / Release Date | License |
| --- | --- | --- | --- | --- |
| **ShareX/ShareX** (`develop`) | <https://github.com/ShareX/ShareX> | `81507974a3a14cbcd4b7135654599d28f423189e` | 2026-11-13 14:18:11 +0300 | GPL-3.0 |
| **ShareX v22.4.0 Portable x64** | `ShareX-22.4.0-portable-x64.zip` | `v22.4.0` | 2026-11-08 04:17:24 UTC | GPL-3.0 |
| **ShareX/XerahS** (`main`) | <https://github.com/ShareX/XerahS> | `d3f0016e0979a42bb95a7247fe330500d2001c30` | 2026-11-13 18:38:58 +0800 | GPL-3.0 |
| **ShareX/ShareX.ImageEditor** | <https://github.com/ShareX/ShareX.ImageEditor> | `f34dd43bf8b54f36e6c1f08bcb9badc1b5b5ce14` | 2026-10-19 21:25:33 +0800 | GPL-3.0 |
| **ShareX/CustomUploaders** | <https://github.com/ShareX/CustomUploaders> | `efe3d263764ad4b86823f331239f3f3bdc864515` | 2022-04-20 23:06:40 +0300 | GPL-3.0 / Community |
| **morluto/rea** (`rea-agents` 6.9.0) | <https://github.com/morluto/rea> | `cdc4541ef707f256f83abe5018df01a25182cf0b` | 2026-11-13 10:11:06 -0500 | MIT |

---

## 2. REA Static .NET Assembly & Native-Boundary Ledger (ShareX v22.4.0)

Using `rea inspect-managed-artifact`, `rea inspect-managed-native-boundaries`, and `rea inspect-managed-members` (`rea-agents@6.9.0` on Node.js `v24.22.3`), we inspected all 10 shipped ShareX v22.4.0 PE/CLI assemblies without executing Windows binaries.

### 2.1 Compiled Assembly Identity & Dependency Graph

| Assembly (`v22.4.0.0`) | SHA-256 Digest | Module MVID | Runtime / Target | Artifact Evidence ID | Native-Boundary Evidence ID | P/Invoke Count |
| --- | --- | --- | --- | --- | --- | --- |
| `ShareX.dll` | `853a1d090b75336bb968977992fcc016b36187cc05741a28e812555e442fd704` | `7f794fdb-b500-4215-9138-dfdb14e20e7a` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_7dc7a72627e5ad044dae4c4854302f8e292147814914b94229958d4144e27a29` | `ev_529189e26ab0fd187ee06a69e9dfbecb7d2fd952c1f6de6fca1e2970322c560e` | **0** |
| `ShareX.HelpersLib.dll` | `1940c039483e429785d1491e0589e733535b06af4d9f9aa43891a77f585b50b6` | `ecae2ffe-1390-42a5-b183-351ec2ee606f` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_1bfa4528fbc44415ed90eda1707c7a4ffa4b16d3097ccaf1d121decc8c0fb3c7` | `ev_18205b424f610a674352c09bdf85fbb99a0b4768dbac8f1383ccda6651017e87` | **181** |
| `ShareX.HistoryLib.dll` | `ff2f2fa0c5438ed3afac5c27f61134d031a1f33e0ebc06db5d65c56729ee0b15` | `7057c6e8-0384-484e-92ec-3344154776f1` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_97c5d81e5c4850a5621e957b58c0ff639d6d4f727fc40a78efe3910559a79269` | `ev_4d8844334ec857ac1e2f669b462df1bc839263d7d62eaa82f9c3b9b57eeeec6b` | **0** |
| `ShareX.UploadersLib.dll` | `569563597250e09539d52092f75a770003d4382bb303fc7e90e9252efd16e199` | `83437452-f7a8-4217-bd84-d5374c43bf3d` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_84cce2445e6e06dd11e4510ddef20e00e5ba85e2db275212e116750af093e943` | `ev_51d1785cf0ade1612f3c41cd452b383401e982d96059a68685b58084550bb47d` | **0** |
| `ShareX.ImageEffectsLib.dll` | `d6d8ea8fcc73c6cf3aa7ccea1c5f27f943cbda2141365dc0aeb70b8ca0076011` | `5855182c-4f84-456e-954f-6512413a996e` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_9e445d9bdb8286dd477df44d8e90f7aae5564026a7c4a3539bc1afc87a4d5808` | `ev_693bb1acc1390a4e26024bd39873cc25de01f226d79e1d7e45e7f9a0771a6900` | **0** |
| `ShareX.ScreenCaptureLib.dll` | `1ddc934cd8d83d484f479f8cfc0f9913bf66048e7659880f41b80741adfb43e8` | `c1b9488b-71c1-453c-b3dc-79f104e88ada` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_94fc2220e59de14d9db289d5880133ab544e93dcfe3dafb94f866b992f7ff015` | `ev_2c341f0aee1b9f19f5aee4c60c2011be578589095957428dd66773186bb21507` | **10** |
| `ShareX.ScreenRecordingLib.dll` | `7bd64ee2806005dff6ecf5546165c3c2397d6ab132d20c2c1fa25c625122a4ab` | `7d44f67d-b708-46af-8512-13f79233aa85` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_83f57534a7b77dd0e82667502c93ff09c7ad04b1053dc7b9e0f68b6d7a77d1f9` | `ev_0382884de6a5582b4b6c6d17aff9775d68d55f6805c63b47162fec6720f29043` | **14** |
| `ShareX.ImageEditor.dll` | `f8c7c8b1a16e15e1bb15d79f3e389e79ad4724ae8f0b13c07c28c73870a0302a` | `d80d240b-7a28-4f53-a858-de2550178bdd` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_d1286b2a30cc828ea4cfd3fe4e391ec05bf427afed222b08a96f051d26662f1e` | `ev_5ad88d44037e6cec7673ca8b9e159086cb42fd248bca69ead132da1a2f1c510e` | **12** |
| `ShareX.Tools.dll` | `51b3e95b283920f7a7ae80fec6aa775edd048e1802da7f490e6afeaffde755ac` | `d08d4916-9de9-452b-8795-799563277d9c` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_92dfcb5c457459ea4d5c72a499091e6477239b6448a2b90ac66f9f846efcb55f` | `ev_6fd1524d5773014f5afcd7e4d1b43a5f4ecb932b88c69434c057bee9164d04b2` | **29** |
| `ShareX.Avalonia.dll` | `601469c867bc4fdad722bba9a0a0887278ee9d2c0d79ff98b0662379ec46aa24` | `cfa1dd98-6874-424e-8e83-6f4dd5663a8f` | `modern-dotnet` (`.NETCoreApp,v10.0`, ReadyToRun) | `ev_69f9b074fc24467bba8407d7a543389f666eddbc517ce73cdc21b5e36fdd3d16` | `ev_1cfa45dc75d7c416365e759219bc319c3d0c9df22567004568e0d4b6325bb602` | **10** |

### 2.2 Selected Member Inspection Evidence

- `ShareX.HelpersLib.NameParser` (`ev_a1ac6abc3057cf875797493fb15e0bd7499a7c5cfe96bb0ef47c68893e91ab83`, parent `ev_f21a6d58ec279d64efab379897d7ddcbcf593144717ecdb9ffe5360c84e628ca`): Static member/CIL inspection confirming token expansion order and `AllowFileRead` security flag.
- `ShareX.UploadersLib.CustomUploaderItem` (`ev_abb4e189fc6d9984d168608571d1aea575b7d2a47248330bb39b7d5b1e75bed5`, parent `ev_e18e74434d26ab1e5abd15cf4cc7fe57823be485ab4b49dc04d63208523207d7`): Static member/CIL inspection confirming `.sxcu` request/response pipeline and `AllowFileRead = false` untrusted pattern isolation.
- `ShareX.HistoryLib.HistoryManagerSQLite` (`ev_cab0b6b51342e63fe1ec5035cc71b05296cc89cbd7cfd5d5dcd034bafe74dd8d`, parent `ev_57db35c1d9d145524cf1b51685a1e7b9a744682141a3f50ec1467d0537782a00`): Static member/CIL inspection confirming SQLite `History` schema and transactional CRUD semantics.
- `ShareX.ScreenCaptureLib.ScrollingCaptureManager` (`ev_086a75950f31481a868df3548b12e5d2d02aaf40430416cd28213e77088fa33c`, parent `ev_4c80ce88b4b27846afe7ba6aaf23be618102114662b44e4fa7cd01b6c8530fca`): Static member/CIL inspection of vertical scanline overlap detection and `CombineImages`.
- `ShareX.ScreenRecordingLib.RecordingOptions` (`ev_74146b965898d99da7cee5c4da488135aa0a15832c793bf66959e84121243e68`, parent `ev_e851153ae4852306348e65181d67f3f584f76248da31cbcfa8bab82a2ae759e6`): Static member/CIL inspection of MP4/GIF FPS, bitrate, and minimum 10ms GIF frame delay validation.
- `ShareX.WorkerTask` (`ev_0e0099d381f9aaaf1a5b5b90dac51b67a5231792532177f36ac79290cd9a0292`, parent `ev_fa1e7e16d6faae3409d2e2f9f4c3df8ae9b354a85cfbb353127ea9bd320d5ca1`): Static member/CIL inspection of `DoAfterCaptureJobs`, `DoFileJobs`, `DoUploadJob`, and `DoAfterUploadJobs` orchestration.
- `ShareX.ShareXCLIManager` (`ev_58038f4e68daa98d2ab0fa98d9ea98b2b0542a55c5c01025a31411e35d0fdafe`, parent `ev_c13e09f8b3e808e0bf5c53e60f2c8e9ff241a68b105f8d9214bb8e95f41df26d`): Static member/CIL inspection of CLI task flags and `.sxcu` file import dispatch.

### 2.4 REA Verification of Built macOS Artifact (`Sharaza.app`) & Live SQLite Database

- **Mach-O Binary Hardening (`rea inspect-binary-hardening`):** `ev_fa46df2a6ac316d974d80df967dd8fc1bc6087a0637afbf071dd72bff2016f03` (`dist/Sharaza.app/Contents/MacOS/Sharaza`, `arm64` 64-bit Mach-O, SHA-256 `1fc9ac750a1fa67f36b4aba52af336c56b2b351716d3a1eccf89986639922973`, `MH_PIE` enabled, stack/heap execution disabled).
- **Release Exposure Audit (`rea audit-release-exposure`):** `ev_6b4054f0042a5519138e42480d14c09c0eb71b5bedc3a8129a276e804e68337c` (`dist/Sharaza.app`: `exposed: 0`, `no_exposure_observed_in_assessed_checks: true`).
- **Live SQLite Schema & Runtime Row Verification (`rea inspect-sqlite-database`):** `ev_e1e24058dba3ff7311a203cd7b96ef6ce9d3a91997881ee751b362a9c01d9a62` & `ev_1deed27ac974c3ab54cefe919e7adac2924fe014e7704a234ad3e4578731d325` — verified exact 11-column ShareX `History` DDL (`Id`, `FileName`, `FilePath`, `DateTime`, `Type`, `Host`, `URL`, `ThumbnailURL`, `DeletionURL`, `ShortenedURL`, `Tags`) and live capture row `Cursor_2026-11-13_17-36-51.png` (`{"ProcessName":"Cursor","WindowTitle":"Cursor Agents","Dimensions":"1295x835"}`).

### 2.3 Key Architectural Finding from REA Native-Boundary Evidence

REA's `inspect-managed-native-boundaries` proves that **four core ShareX assemblies have zero Win32 P/Invoke imports** (`ShareX.dll`, `ShareX.HistoryLib.dll`, `ShareX.UploadersLib.dll`, `ShareX.ImageEffectsLib.dll`), while all Win32 native calls (`user32.dll`, `gdi32.dll`, `dwmapi.dll`, `d3d11.dll`, `shell32.dll`, `ole32.dll`) are confined to `HelpersLib`, `ScreenCaptureLib`, `ScreenRecordingLib`, `ImageEditor`, `Tools`, and `Avalonia`.

This directly validates our clean architectural split:
- **Rust Core (`sharaza-core`)** owns the 100% platform-independent subsystems: `WorkerTask` workflow orchestration, `TaskSettings`, `NameParser`, `UploadInfoParser`, `HistoryManagerSQLite`, `CustomUploaderItem` + `.sxcu` syntax parser, HTTP/API uploaders & URL shorteners, `ImageEffects`, `ScrollingCapture` scanline stitcher, and hash/QR generation.
- **SwiftUI + AppKit (`Sharaza`)** owns every native OS boundary via first-party macOS frameworks: `ScreenCaptureKit`, `AppKit` (`NSPanel` overlays, `NSPasteboard`, `NSStatusItem`/`MenuBarExtra`, `NSWorkspace`), `Vision` (`VNRecognizeTextRequest`, `VNDetectBarcodesRequest`), `CoreGraphics`/`CoreImage`, `AVFoundation` (`AVAssetWriter`), `ImageIO` (animated GIF), `Security` (Keychain), and `Carbon` (`RegisterEventHotKey`).

---

## 3. Extracted Implementation-Independent Specifications

### 3.1 Naming Pattern Engine (`NameParser` & `CodeMenuEntryFilename`)

**Source:** `ShareX.HelpersLib/NameParser/NameParser.cs`, `CodeMenuEntryFilename.cs` (Verified via source + REA `ev_a1ac6abc...`)

1. **Modes (`NameParserType`):**
   - `Default`: Raw substitution, no newline expansion.
   - `Text`: Enables `%n` -> `\n`.
   - `FileName`: Replaces invalid filename characters (`/`, `\`, `:`, `*`, `?`, `"`, `<`, `>`, `|`, control chars) with `_`.
   - `FilePath`: Sanitizes path segments while preserving `/` path separators.
   - `URL`: Percent-encodes path/query unsafe characters while preserving valid URL structure.
2. **Exact Evaluation Order (Critical Behavioral Detail):**
   - `%t` (sanitized & truncated to `MaxTitleLength` if `> 0`; spaces replaced with `_`) and `%pn` (sanitized, spaces -> `_`).
   - `%width` and `%height` (empty string if `<= 0`).
   - Date/time tokens in local or custom timezone: `%mon2` (English full month), `%mon` (localized month), `%yy` (2-digit year), `%y` (4-digit year), `%mo` (2-digit month), `%d` (2-digit day).
   - Hour rule: If `%pm` appears **anywhere** in the pattern prior to `%h` substitution, `%h` uses 12-hour format (`12`, `01`..`11`); otherwise 24-hour zero-padded (`00`..`23`).
   - `%mi` (minute `00`..`59`), `%s` (second `00`..`59`), `%ms` (millisecond `000`..`999`), `%wy` (ISO/calendar week of year), `%w2` (English weekday), `%w` (weekday), `%pm` (`AM` or `PM`), `%unix` (UTC Unix timestamp in seconds).
   - Auto-increment family (increments `AutoIncrementNumber` **once** per `Parse` call if any increment token is present):
     - `%ib{base,pad}` (AlphanumericInverse: `0-9a-zA-Z`) & `%iB{base,pad}` (Alphanumeric: `0-9A-Za-z`)
     - `%iAa{pad}` / `%iAa` (Base 62 `0-9A-Za-z`) & `%iaA{pad}` / `%iaA` (Base 62 `0-9a-zA-Z`)
     - `%ia{pad}` / `%ia` (Base 36 lowercase `0-9a-z`) & `%iA{pad}` / `%iA` (Base 36 uppercase `0-9A-Z`)
     - `%ix{pad}` / `%ix` (Base 16 lowercase hex) & `%iX{pad}` / `%iX` (Base 16 uppercase hex)
     - `%i{pad}` / `%i` (Base 10 decimal)
   - Computer tokens: `%un` (username), `%uln` (login/domain name), `%cn` (computer hostname).
   - Random tokens (each occurrence evaluated independently so `%ra%ra%ra` produces 3 distinct random chars!):
     - `%radjective`, `%ranimal` (TitleCase word from built-in lists)
     - `%rf{filepath}` (random line from text file — **only** when `AllowFileRead == true`; stripped to `""` when `AllowFileRead == false` such as inside `.sxcu` custom uploaders)
     - `%rna{n}` / `%rna` (Base56 unambiguous `23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz`)
     - `%rn{n}` / `%rn` (`0-9`), `%ra{n}` / `%ra` (`0-9A-Za-z`), `%rx{n}` / `%rx` (`0-9a-f`), `%rX{n}` / `%rX` (`0-9A-F`), `%remoji{n}` / `%remoji`
     - `%guid` (lowercase UUID v4), `%GUID` (uppercase UUID v4).
   - Final sanitization by `NameParserType` and truncation to `MaxNameLength` (if `> 0`).

### 3.2 SQLite History Schema (`HistoryManagerSQLite`)

**Source:** `ShareX.HistoryLib/Managers/HistoryManagerSQLite.cs` (Verified via source + REA `ev_cab0b6b5...`)

Exact upstream SQLite table DDL:
```sql
CREATE TABLE IF NOT EXISTS History (
    Id INTEGER PRIMARY KEY AUTOINCREMENT,
    FileName TEXT,
    FilePath TEXT,
    DateTime TEXT,
    Type TEXT,
    Host TEXT,
    URL TEXT,
    ThumbnailURL TEXT,
    DeletionURL TEXT,
    ShortenedURL TEXT,
    Tags TEXT
);
```
- `PRAGMA busy_timeout = 5000;`
- `DateTime` stored in ISO-8601 round-trip format (`YYYY-MM-DDTHH:MM:SS.fffffffZ` / RFC3339).
- `Tags` stored as JSON object `{"WindowTitle": "...", "ProcessName": "..."}` or `NULL`.
- Sharaza preserves this exact `History` table untouched for 100% database compatibility with ShareX 22.x `History.db`, and adds separate `sharaza_kv_settings` and `sharaza_workflows` tables in `Sharaza.sqlite` (or standalone `History.db`).

### 3.3 Task & Workflow Pipeline (`TaskSettings` & `WorkerTask`)

**Source:** `ShareX/TaskSettings.cs`, `ShareX/WorkerTask.cs`, `ShareX/Enums.cs`

1. **`AfterCaptureTasks` bitflags execution order (`WorkerTask.DoAfterCaptureJobs` + `DoFileJobs`):**
   - `BeautifyImage` -> `AddImageEffects` -> `AnnotateImage` (interactive editor; canceling aborts pipeline) -> `CopyImageToClipboard` -> `PinToScreen` -> `SendImageToPrinter` -> Image Encoding (`PNG`, `JPEG`, `WEBP`, `GIF`, `BMP`) -> `SaveImageToFile` (handling `FileExistAction`: `UniqueName`, `Overwrite`, `Cancel`) -> `SaveImageToFileWithDialog` -> `SaveThumbnailImageToFile` -> `PerformActions` (external CLI programs modifying or inspecting the file) -> `CopyFileToClipboard` / `CopyFilePathToClipboard` / `CopyFolderPathToClipboard` -> `ShowInExplorer` (Finder reveal on macOS) -> `ScanQRCode` -> `DoOCR` -> `UploadImageToHost` -> `DeleteFile` (if temporary).
2. **`AfterUploadTasks` bitflags execution order (`WorkerTask.DoAfterUploadJobs`):**
   - Optional `URLRegexReplace` -> `ResultForceHTTPS` -> `UseURLShortener` (or auto-shorten over length threshold) -> `ShareURL` -> `CopyURLToClipboard` (formatted via `UploadInfoParser` if custom format configured, else `ShortenedURL ?? URL`) -> `OpenURL` -> `ShowQRCode`.

### 3.4 Custom Uploader (`.sxcu`) Specification (`CustomUploaderItem` & `ShareXCustomUploaderSyntaxParser`)

**Source:** `ShareX.UploadersLib/CustomUploader/CustomUploaderItem.cs`, `ShareXCustomUploaderSyntaxParser.cs`, `Functions/*.cs`, and 148 real `.sxcu` files in `ShareX/CustomUploaders`.

- **JSON Fields:** `Version`, `Name`, `DestinationType` (flags: `None`, `ImageUploader`, `TextUploader`, `FileUploader`, `URLShortener`, `URLSharingService` — serialized as integer OR comma-separated string in `.sxcu`!), `RequestMethod` (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`), `RequestURL`, `Parameters`, `Headers`, `Body` (`None`, `MultipartFormData`, `FormURLEncoded`, `JSON`, `XML`, `Binary`), `Arguments`, `FileFormName`, `Data`, `URL`, `ThumbnailURL`, `DeletionURL`, `ErrorMessage`.
- **Template Syntax (`$func:arg1|arg2$`):**
  - Escape character `\`, parameter delimiter `|`, syntax delimiter `$`.
  - Functions (case-insensitive names + aliases):
    - `$response$` — raw HTTP response body
    - `$responseurl$` — final HTTP response URL (after redirects)
    - `$json:path$` or `$json:input|path$` — JSONPath/dot-and-bracket path (e.g. `url`, `data.link`, `attachments[0].url`, `files[0].url`)
    - `$xml:xpath$` — XML element/attribute extraction
    - `$regex:pattern|group$` or `$regex:input|pattern|group$` — regex match group (numeric index or named group; defaults to group `1` if present else `0`)
    - `$header:name$` — HTTP response header lookup (case-insensitive)
    - `$filename$` — upload file name
    - `$input$` — text or URL input
    - `$base64:text$` — UTF-8 to Base64 encoding
    - `$select:opt1|opt2|...$` — deterministic/first-choice or interactive option
    - `$random:opt1|opt2|...$` — random selection among parameters
    - `{input}` and `{filename}` inside JSON/XML `Data` body (with JSON/XML escaping!).
  - Security invariant: `AllowFileRead = false` whenever expanding `NameParser` tokens inside `.sxcu` templates so imported `.sxcu` files can never exfiltrate local files via `%rf{...}`.

### 3.5 Scrolling Capture Stitcher (`ScrollingCaptureManager.CombineImages`)

**Source:** `ShareX.ScreenCaptureLib/ScrollingCaptureManager.cs` lines 258–391.

- Given accumulated `result` (`W × H_res`) and `currentImage` (`W × H_cur`):
  1. Ignore horizontal scrollbar/border margins: `ignoreSideOffset = clamp(max(50, W / 20), 0, W / 3)`.
  2. Ignore static bottom footer/status bar (`AutoIgnoreBottomEdge`): scan upward from bottom row up to `H_cur / 3` comparing `result` and `currentImage` rows; any identical bottom rows increase `ignoreBottomOffset` (starting from `max(50, H_cur / 10)`, clamped to `H_cur / 3`).
  3. Search from `currentImageY = H_cur - 1` downward to `0` (early-stopping once `matchCount >= H_cur / 2`) for the longest contiguous block of identical scanlines matching `result` ending at `rectBottom = result.Height - ignoreBottomOffset - 1`.
  4. If `matchCount > 0` and `matchHeight = H_cur - matchIndex - 1 > 0`, allocate `W × (H_res - ignoreBottomOffset + matchHeight)`, copy `result[0 .. H_res - ignoreBottomOffset]` and append `currentImage[matchIndex + 1 .. H_cur]`.

---

## 4. Verified vs. Inferred Behavior & Known Platform Limitations

| Area | Classification | Evidence & macOS Adaptation / Limitation |
| --- | --- | --- |
| **Runtime execution of Windows `ShareX.exe`** | *Environment Limitation* | Host is macOS 26.5.2 (`arm64`). Windows `.exe`/Win32 P/Invokes cannot execute natively on macOS without a Windows VM. Mitigated by inspecting both upstream C# source and compiled v22.4.0 assemblies via REA (`rea-agents` 6.9.0) and testing against upstream `.sxcu` fixtures and deterministic test vectors. |
| **Screen Recording TCC Consent** | *Verified Platform Requirement* | Confirmed in macOS SDK & `XerahS.Platform.MacOS/Native/ScreenRecordingPermission.cs`: without `CGPreflightScreenCaptureAccess()`, `CGWindowList` omits window titles and captures only desktop wallpaper. Sharaza preflights TCC, calls `CGRequestScreenCaptureAccess()` once when needed, and provides direct System Settings deep-linking (`x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`). |
| **Global Hotkeys & `PrintScreen` Key** | *Verified Platform Difference* | Standard Apple keyboards lack a `PrintScreen` key, and `CGEventTap` global hooks require Accessibility TCC permission. Using Carbon `RegisterEventHotKey` (verified in `CarbonHotkeys.cs`) works with **zero TCC permissions** and cleanly intercepts shortcuts (defaulting to non-conflicting ShareX-equivalent shortcuts like `⌃⇧4` Region, `⌃⇧3` Fullscreen, `⌃⇧2` Window, `⌃⇧5` Record, `⌃⇧O` OCR, all user-customizable). |
| **Scrolling Capture Synthetic Scroll** | *Verified Platform Requirement* | Posting synthetic scroll-wheel `CGEvent`s to another app's window on macOS requires **Accessibility** permission (`AXIsProcessTrusted()`). When Accessibility is not granted, Sharaza supports manual-scroll capture (capturing frames automatically as the user scrolls and stitching them with the exact ShareX scanline stitcher) AND prompts clearly if auto-scroll is requested. |
| **Window Borderless / TopMost Manipulation of Other Apps** | *macOS Sandbox / WindowServer Limitation* | ShareX's Windows tools `ActiveWindowBorderless` and `ActiveWindowTopMost` mutate foreign `HWND` style bits via `SetWindowLong`. macOS `WindowServer` forbids mutating foreign process window levels/styles. Documented explicitly in `FEATURE_PARITY_MATRIX.md`; Sharaza instead provides native **Pin to Screen** (`NSPanel` `.floating`) for always-on-top reference windows. |
| **Credential Storage** | *Security Upgrade over Upstream* | ShareX on Windows stores `UploadersConfig.json` credentials on disk (optionally DPAPI-encrypted). Sharaza stores all uploader API keys, tokens, headers, and webhook secrets in **macOS Keychain** (`Security.framework`, service `app.sharaza.credentials`) while storing only non-sensitive metadata and Keychain reference keys in SQLite/JSON. |
