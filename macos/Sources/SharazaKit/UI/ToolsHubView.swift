import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ToolsHubView: View {
    @ObservedObject var appState: AppState

    @State private var qrInputText: String = "https://github.com/ShareX/ShareX"
    @State private var hashInputText: String = ""
    @State private var computedHashes: FileHashes?
    @State private var expectedHash: String = ""
    @State private var shortenInputURL: String = ""
    @State private var shortenedOutputURL: String = ""

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. Vision OCR
                GroupBox("OCR — Apple Vision Text Recognition") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button("Select Screen Region for OCR") {
                                Task { await appState.captureRegionForOCR() }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("OCR From Image File…") {
                                runOCRFromFile()
                            }

                            Button("OCR From Clipboard Image") {
                                if let png = ClipboardService.readImagePNGData(),
                                   let ns = NSImage(data: png),
                                   let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                   let res = try? VisionService.recognizeText(in: cg) {
                                    appState.latestOCRText = res.fullText
                                    ClipboardService.copyText(res.fullText)
                                    appState.statusBanner = "Clipboard OCR copied (\(res.lineCount) lines)"
                                }
                            }

                            if let txt = appState.latestOCRText, !txt.isEmpty {
                                Button("Copy Recognized Text") {
                                    ClipboardService.copyText(txt)
                                }
                            }
                        }

                        TextEditor(
                            text: Binding(
                                get: { appState.latestOCRText ?? "" },
                                set: { appState.latestOCRText = $0 }
                            )
                        )
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 110)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 2. QR Code Encode & Decode
                GroupBox("QR Code Generator & Screen Scanner") {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Text or URL to encode as QR…", text: $qrInputText)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 8) {
                                Button("Generate QR Code") {
                                    if let png = try? RustCoreClient.generateQRCodePNG(text: qrInputText, moduleSize: 8),
                                       let img = NSImage(data: png) {
                                        appState.latestQRImage = img
                                    }
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Scan QR From Screen") {
                                    Task { await appState.captureRegionForQRScan() }
                                }

                                Button("Decode QR From File…") {
                                    decodeQRFromFile()
                                }
                            }

                            if !appState.latestDecodedBarcodes.isEmpty {
                                Text("Decoded: \(appState.latestDecodedBarcodes.joined(separator: ", "))")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }

                        if let qrImg = appState.latestQRImage {
                            VStack(spacing: 6) {
                                Image(nsImage: qrImg)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 120, height: 120)
                                Button("Copy QR") {
                                    ClipboardService.copyImage(qrImg)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 3. Color Picker, Ruler & Pin to Screen
                GroupBox("Desktop Overlay Utilities (Color Picker, Ruler, Pin to Screen)") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Button("Pick Screen Color") {
                                Task { await appState.runScreenColorPicker() }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Launch Screen Ruler") {
                                OverlayToolsController.shared.showScreenRuler()
                            }

                            Button("Pin Clipboard Image to Screen") {
                                if let png = ClipboardService.readImagePNGData(),
                                   let img = NSImage(data: png) {
                                    OverlayToolsController.shared.pinImageToScreen(img)
                                }
                            }

                            Button("Close All Pins") {
                                OverlayToolsController.shared.closeAllPinnedPanels()
                            }
                        }

                        if let c = appState.latestColorPick {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(.sRGB, red: Double(c.r) / 255.0, green: Double(c.g) / 255.0, blue: Double(c.b) / 255.0, opacity: 1.0))
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("HEX: \(c.hex_upper)   •   \(c.rgb_css)   •   Decimal: \(c.decimal)")
                                    Text(String(format: "HSB: (%.1f°, %.1f%%, %.1f%%)   •   HSL: (%.1f°, %.1f%%, %.1f%%)   •   CMYK: (%.1f, %.1f, %.1f, %.1f)",
                                                c.hsb[0], c.hsb[1], c.hsb[2], c.hsl[0], c.hsl[1], c.hsl[2],
                                                c.cmyk[0], c.cmyk[1], c.cmyk[2], c.cmyk[3]))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 4. Hash Check (CRC32, MD5, SHA1, SHA256, SHA384, SHA512)
                GroupBox("Hash Check (CRC-32, MD5, SHA-1, SHA-256, SHA-384, SHA-512)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Select File to Hash…") {
                                let p = NSOpenPanel()
                                if p.runModal() == .OK, let u = p.url {
                                    Task {
                                        computedHashes = try? await appState.core.computeFileHashes(path: u.path)
                                    }
                                }
                            }
                            TextField("Or enter text to hash…", text: $hashInputText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    computedHashes = try? appState.core.computeTextHashes(text: hashInputText)
                                }
                            Button("Hash Text") {
                                computedHashes = try? appState.core.computeTextHashes(text: hashInputText)
                            }
                        }

                        TextField("Optional expected hash to compare…", text: $expectedHash)
                            .textFieldStyle(.roundedBorder)

                        if let h = computedHashes {
                            VStack(alignment: .leading, spacing: 4) {
                                HashLine(label: "CRC-32", digest: h.crc32, target: expectedHash)
                                HashLine(label: "MD5", digest: h.md5, target: expectedHash)
                                HashLine(label: "SHA-1", digest: h.sha1, target: expectedHash)
                                HashLine(label: "SHA-256", digest: h.sha256, target: expectedHash)
                                HashLine(label: "SHA-384", digest: h.sha384, target: expectedHash)
                                HashLine(label: "SHA-512", digest: h.sha512, target: expectedHash)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 5. URL Shortener Tool
                GroupBox("URL Shortener") {
                    HStack {
                        TextField("https://example.com/very/long/link", text: $shortenInputURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Shorten") {
                            Task {
                                do {
                                    let creds = KeychainManager.shared.resolveCredentials()
                                    let res = try await appState.core.shortenURL(
                                        shortener: appState.config.default_settings.url_shortener,
                                        url: shortenInputURL,
                                        credentials: creds,
                                        customUploaderName: appState.config.default_settings.custom_uploader_name
                                    )
                                    shortenedOutputURL = res
                                    ClipboardService.copyText(res)
                                } catch {
                                    appState.lastError = error.localizedDescription
                                }
                            }
                        }
                        if !shortenedOutputURL.isEmpty {
                            Text(shortenedOutputURL)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Productivity Tools")
    }

    private func runOCRFromFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url,
              let ns = NSImage(contentsOf: u),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let res = try? VisionService.recognizeText(in: cg) else { return }
        appState.latestOCRText = res.fullText
        ClipboardService.copyText(res.fullText)
    }

    private func decodeQRFromFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        guard p.runModal() == .OK, let u = p.url,
              let ns = NSImage(contentsOf: u),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let codes = try? VisionService.decodeQRAndBarcodes(in: cg) else { return }
        appState.latestDecodedBarcodes = codes
        if let first = codes.first {
            ClipboardService.copyText(first)
        }
    }
}

private struct HashLine: View {
    let label: String
    let digest: String
    let target: String

    private var matches: Bool {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t.caseInsensitiveCompare(digest) == .orderedSame
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .frame(width: 64, alignment: .leading)
            Text(digest)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            if matches {
                Label("Match", systemImage: "checkmark.seal.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
            }
            Button("Copy") {
                ClipboardService.copyText(digest)
            }
            .controlSize(.mini)
        }
    }
}
