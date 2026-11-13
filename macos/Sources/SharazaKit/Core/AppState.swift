import AppKit
import CoreGraphics
import Foundation
import SwiftUI

public enum WorkspaceSection: String, CaseIterable, Identifiable {
    case dashboard = "Capture & Dashboard"
    case history = "History"
    case workflows = "Workflows & Tasks"
    case uploaders = "Uploaders & .sxcu"
    case tools = "Productivity Tools"
    case settings = "Preferences & Permissions"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .dashboard: return "camera.viewfinder"
        case .history: return "clock.arrow.circlepath"
        case .workflows: return "slider.horizontal.3"
        case .uploaders: return "icloud.and.arrow.up"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
public final class AppState: ObservableObject {
    public let core: RustCoreClient
    @Published public var config: AppConfig
    @Published public var selectedSection: WorkspaceSection = .dashboard
    @Published public var historyItems: [HistoryItem] = []
    @Published public var historyStats: HistoryStats = HistoryStats(
        total_count: 0, image_count: 0, video_count: 0, text_count: 0, file_count: 0, uploaded_count: 0, by_host: [:]
    )
    @Published public var historySearch: String = ""
    @Published public var historyTypeFilter: String = "All"
    @Published public var workflows: [WorkflowPreset] = []
    @Published public var customUploaders: [CustomUploaderItem] = []

    @Published public var isBusy: Bool = false
    @Published public var statusBanner: String = "Ready"
    @Published public var lastError: String?
    @Published public var latestPreviewImage: NSImage?
    @Published public var latestOCRText: String?
    @Published public var latestColorPick: ColorFormats?
    @Published public var latestQRImage: NSImage?
    @Published public var latestDecodedBarcodes: [String] = []

    public init(dataDirectory: URL? = nil) throws {
        let client = try RustCoreClient(dataDirectory: dataDirectory)
        self.core = client
        self.config = try client.loadConfig()
        self.workflows = (try? client.listWorkflows()) ?? []
        self.customUploaders = (try? client.listCustomUploaders()) ?? []

        setupSystemBindings()
        Task { await refreshHistory() }
    }

    private func setupSystemBindings() {
        GlobalHotkeyManager.shared.onHotkeyTriggered = { [weak self] action in
            guard let self else { return }
            self.dispatchHotkeyAction(action)
        }
        GlobalHotkeyManager.shared.installAndApply(
            bindings: config.hotkeys,
            globallyEnabled: config.hotkeys_enabled
        )

        ScreenRecorderService.shared.onRecordingFinalized = { [weak self] url, isGif, settings in
            guard let self else { return }
            Task { @MainActor in
                await self.handleRecordingFinalized(url: url, isGif: isGif, settings: settings)
            }
        }
    }

    public func persistConfig() {
        do {
            try core.saveConfig(config)
            GlobalHotkeyManager.shared.installAndApply(
                bindings: config.hotkeys,
                globallyEnabled: config.hotkeys_enabled
            )
            statusBanner = "Saved settings"
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refreshHistory() async {
        do {
            let filter = HistoryFilter(
                search_query: historySearch.isEmpty ? nil : historySearch,
                item_type: historyTypeFilter == "All" ? nil : historyTypeFilter,
                limit: 250,
                offset: 0
            )
            historyItems = try await core.queryHistory(filter)
            historyStats = try await core.historyStats()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public static let availableHotkeyActions: [String] = [
        "CaptureRegion",
        "CaptureFullscreen",
        "CaptureActiveWindow",
        "ScrollingCapture",
        "ToggleScreenRecording",
        "RecordGIF",
        "OCRRegion",
        "ScreenColorPicker",
        "ScreenRuler",
        "UploadClipboard",
    ]

    public func dispatchHotkeyAction(_ action: String) {
        if action.hasPrefix("Workflow:") {
            let wfID = String(action.dropFirst("Workflow:".count))
            if let preset = workflows.first(where: { $0.id == wfID || $0.name.caseInsensitiveCompare(wfID) == .orderedSame }) {
                Task { await triggerCapture(preset.settings.capture_type, settingsOverride: preset.settings) }
            }
            return
        }

        switch action {
        case "CaptureRegion", "RectangleRegion":
            Task { await triggerCapture(.Region) }
        case "CaptureFullscreen", "PrintScreen":
            Task { await triggerCapture(.Fullscreen) }
        case "CaptureActiveWindow", "ActiveWindow":
            Task { await triggerCapture(.ActiveWindow) }
        case "ScrollingCapture":
            Task { await triggerCapture(.ScrollingCapture) }
        case "ToggleScreenRecording", "ScreenRecorder":
            Task { await toggleRecording(isGif: false) }
        case "RecordGIF", "ScreenRecorderGIF":
            Task { await toggleRecording(isGif: true) }
        case "OCRRegion", "OCR":
            Task { await captureRegionForOCR() }
        case "ScreenColorPicker", "ColorPicker":
            Task { await runScreenColorPicker() }
        case "ScreenRuler", "Ruler":
            OverlayToolsController.shared.showScreenRuler()
        case "UploadClipboard", "ClipboardUpload":
            Task { await uploadFromClipboard() }
        default:
            break
        }
    }

    /// Reconstructs `ShareX.ShareXCLIManager` (`ev_58038f4e...`) for CLI flags and file/URL associations.
    public func handleCLIArguments(_ args: [String]) {
        guard args.count > 1 else { return }
        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            let normalized = arg.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
            switch normalized {
            case "captureregion", "rectangleregion", "capture-region":
                dispatchHotkeyAction("CaptureRegion")
            case "capturefullscreen", "printscreen", "capture-fullscreen":
                dispatchHotkeyAction("CaptureFullscreen")
            case "captureactivewindow", "activewindow", "capture-window":
                dispatchHotkeyAction("CaptureActiveWindow")
            case "scrollingcapture", "scrolling-capture":
                dispatchHotkeyAction("ScrollingCapture")
            case "screenrecorder", "record-mp4":
                dispatchHotkeyAction("ToggleScreenRecording")
            case "screenrecordergif", "record-gif":
                dispatchHotkeyAction("RecordGIF")
            case "ocr":
                dispatchHotkeyAction("OCRRegion")
            case "customuploader":
                if idx + 1 < args.count {
                    idx += 1
                    handleOpenedFileURL(URL(fileURLWithPath: args[idx]))
                }
            case "workflow", "task":
                if idx + 1 < args.count {
                    idx += 1
                    dispatchHotkeyAction("Workflow:\(args[idx])")
                }
            default:
                if !arg.hasPrefix("-"), FileManager.default.fileExists(atPath: arg) {
                    handleOpenedFileURL(URL(fileURLWithPath: arg))
                }
            }
            idx += 1
        }
    }

    public func handleOpenedFileURL(_ url: URL) {
        if url.pathExtension.lowercased() == "sxcu",
           let text = try? String(contentsOf: url, encoding: .utf8),
           let saved = try? core.saveCustomUploader(sxcuJSON: text) {
            customUploaders = (try? core.listCustomUploaders()) ?? []
            config.default_settings.custom_uploader_name = saved.Name
            persistConfig()
            statusBanner = "Imported Custom Uploader: \(saved.Name)"
            selectedSection = .uploaders
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            Task {
                let creds = KeychainManager.shared.resolveCredentials()
                if let rep = try? await core.uploadFileWorkflow(
                    filePath: url.path,
                    settings: config.default_settings,
                    credentials: creds
                ) {
                    applyPostWorkflowActions(
                        report: rep,
                        cgImageForVision: nil,
                        pngData: Data(),
                        settings: config.default_settings
                    )
                    await refreshHistory()
                }
            }
        }
    }

    // MARK: - Capture & Workflow Execution

    public func triggerCapture(_ type: CaptureType, settingsOverride: TaskSettings? = nil) async {
        let settings = settingsOverride ?? config.default_settings

        if type == .ScreenRecordingMp4 {
            await toggleRecording(isGif: false, settingsOverride: settings)
            return
        }
        if type == .ScreenRecordingGif {
            await toggleRecording(isGif: true, settingsOverride: settings)
            return
        }

        isBusy = true
        lastError = nil
        statusBanner = "Starting \(type.title)…"
        defer { isBusy = false }

        do {
            let frame: CapturedFrame
            switch type {
            case .Fullscreen:
                frame = try await ScreenCaptureService.shared.captureFullscreenAllMonitors(settings: settings)
            case .ActiveMonitor, .Monitor:
                frame = try await ScreenCaptureService.shared.captureActiveMonitor(settings: settings)
            case .ActiveWindow:
                frame = try await ScreenCaptureService.shared.captureActiveWindow(settings: settings)
            case .Window:
                guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
                    throw CaptureError.permissionDenied
                }
                let sel = await RegionSelectionOverlay.shared.selectRegion(allowWindowSnap: true)
                switch sel {
                case .window(let win):
                    frame = try await ScreenCaptureService.shared.captureWindow(windowID: win.windowID, fallbackInfo: win, settings: settings)
                case .region(let r, let w):
                    frame = try await ScreenCaptureService.shared.captureQuartzRegion(
                        r,
                        metadata: CaptureMetadata(window_title: w?.title, process_name: w?.ownerName),
                        settings: settings
                    )
                case .cancelled:
                    statusBanner = "Capture cancelled"
                    return
                }
            case .Region:
                guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
                    throw CaptureError.permissionDenied
                }
                if settings.screenshot_delay_ms > 0 {
                    try await Task.sleep(nanoseconds: settings.screenshot_delay_ms * 1_000_000)
                }
                let sel = await RegionSelectionOverlay.shared.selectRegion(allowWindowSnap: true)
                switch sel {
                case .window(let win):
                    frame = try await ScreenCaptureService.shared.captureWindow(windowID: win.windowID, fallbackInfo: win, settings: settings)
                case .region(let r, let w):
                    if config.remember_last_region {
                        config.last_region = [Int32(r.origin.x), Int32(r.origin.y), Int32(r.width), Int32(r.height)]
                        try? core.saveConfig(config)
                    }
                    frame = try await ScreenCaptureService.shared.captureQuartzRegion(
                        r,
                        metadata: CaptureMetadata(window_title: w?.title, process_name: w?.ownerName),
                        settings: settings
                    )
                case .cancelled:
                    statusBanner = "Region selection cancelled"
                    return
                }
            case .LastRegion:
                if let lr = config.last_region, lr.count == 4 {
                    let rect = CGRect(x: Int(lr[0]), y: Int(lr[1]), width: Int(lr[2]), height: Int(lr[3]))
                    frame = try await ScreenCaptureService.shared.captureQuartzRegion(rect, settings: settings)
                } else {
                    await triggerCapture(.Region, settingsOverride: settings)
                    return
                }
            case .ScrollingCapture:
                guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
                    throw CaptureError.permissionDenied
                }
                frame = try await ScrollingCaptureController.shared.performScrollingCapture(settings: settings)
            case .ScreenRecordingMp4, .ScreenRecordingGif:
                return
            }

            if settings.play_sound_after_capture {
                ClipboardService.playCaptureSound()
            }

            try await runImagePipeline(frame: frame, settings: settings)
        } catch CaptureError.cancelled {
            statusBanner = "Capture cancelled"
        } catch {
            lastError = error.localizedDescription
            statusBanner = "Capture error"
        }
    }

    public func captureSpecificWindow(_ win: DesktopWindowInfo) async {
        let settings = config.default_settings
        do {
            let frame = try await ScreenCaptureService.shared.captureWindow(
                windowID: win.windowID,
                fallbackInfo: win,
                settings: settings
            )
            if settings.play_sound_after_capture {
                ClipboardService.playCaptureSound()
            }
            try await runImagePipeline(frame: frame, settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func captureSpecificMonitor(index: Int) async {
        let settings = config.default_settings
        do {
            let frame = try await ScreenCaptureService.shared.captureMonitor(index: index, settings: settings)
            if settings.play_sound_after_capture {
                ClipboardService.playCaptureSound()
            }
            try await runImagePipeline(frame: frame, settings: settings)
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func runImagePipeline(frame: CapturedFrame, settings: TaskSettings) async throws {
        var workingPNG = frame.pngData
        var workingCG = frame.cgImage

        var effectiveSettings = settings

        // Interactive editor step (`AfterCaptureTasks.AnnotateImage`)
        if effectiveSettings.hasAfterCapture(.annotateImage) {
            statusBanner = "Waiting for Image Editor…"
            guard let editedPNG = await ImageEditorWindowController.shared.editImageModalWorkflow(cgImage: workingCG) else {
                statusBanner = "Annotation cancelled"
                return
            }
            workingPNG = editedPNG
            if let ns = NSImage(data: editedPNG),
               let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                workingCG = cg
            }
        }

        // Before-upload confirmation (`AfterCaptureTasks.ShowBeforeUploadWindow`)
        if effectiveSettings.hasAfterCapture(.uploadImageToHost) && effectiveSettings.hasAfterCapture(.showBeforeUploadWindow) {
            let alert = NSAlert()
            alert.messageText = "Upload Capture?"
            alert.informativeText = "Upload this capture to \(effectiveSettings.image_uploader.displayName)?"
            alert.addButton(withTitle: "Upload")
            alert.addButton(withTitle: "Skip Upload")
            if alert.runModal() != .alertFirstButtonReturn {
                effectiveSettings.setAfterCapture(.uploadImageToHost, enabled: false)
            }
        }

        if effectiveSettings.hasAfterCapture(.sendImageToPrinter), let printImg = NSImage(data: workingPNG) {
            let iv = NSImageView(frame: NSRect(origin: .zero, size: printImg.size))
            iv.image = printImg
            NSPrintOperation(view: iv).run()
        }

        let creds = KeychainManager.shared.resolveCredentials()
        let report = try await core.executeImageWorkflow(
            pngData: workingPNG,
            metadata: frame.metadata,
            settings: effectiveSettings,
            credentials: creds
        )

        let finalPNG: Data = {
            if let b64 = report.processed_png_bytes_base64,
               let decoded = Data(base64Encoded: b64) {
                return decoded
            }
            return workingPNG
        }()

        if let preview = NSImage(data: finalPNG) {
            latestPreviewImage = preview
            if report.pin_to_screen {
                OverlayToolsController.shared.pinImageToScreen(preview)
            }
        }

        if settings.hasAfterCapture(.saveImageWithDialog) {
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = report.file_name
            if savePanel.runModal() == .OK, let url = savePanel.url {
                try? finalPNG.write(to: url)
            }
        }

        applyPostWorkflowActions(report: report, cgImageForVision: workingCG, pngData: finalPNG, settings: settings)
        await refreshHistory()
    }

    private func applyPostWorkflowActions(
        report: WorkflowExecutionReport,
        cgImageForVision: CGImage?,
        pngData: Data,
        settings: TaskSettings
    ) {
        if report.copy_image_to_clipboard {
            ClipboardService.copyPNGData(pngData)
        }
        if report.copy_file_to_clipboard, let path = report.saved_file_path {
            ClipboardService.copyFileURL(path)
        }
        if let textToCopy = report.clipboard_text_to_copy, !textToCopy.isEmpty {
            ClipboardService.copyText(textToCopy)
        }
        if let reveal = report.reveal_in_finder_path {
            ClipboardService.revealInFinder(reveal)
        }
        if let openURL = report.open_url {
            ClipboardService.openURL(openURL)
        }

        if report.run_ocr, let cg = cgImageForVision {
            if let ocr = try? VisionService.recognizeText(in: cg), !ocr.fullText.isEmpty {
                latestOCRText = ocr.fullText
                ClipboardService.copyText(ocr.fullText)
                selectedSection = .tools
            }
        }

        if report.scan_qr, let cg = cgImageForVision {
            if let codes = try? VisionService.decodeQRAndBarcodes(in: cg), !codes.isEmpty {
                latestDecodedBarcodes = codes
                ClipboardService.copyText(codes[0])
                selectedSection = .tools
            }
        }

        if let qrURL = report.show_qr_for_url,
           let qrPNG = try? RustCoreClient.generateQRCodePNG(text: qrURL),
           let nsImg = NSImage(data: qrPNG) {
            latestQRImage = nsImg
            selectedSection = .tools
        }

        if !report.warnings.isEmpty {
            lastError = report.warnings.joined(separator: "\n")
        }

        let summary: String
        if let up = report.upload_result, !up.primaryURL.isEmpty {
            summary = "Uploaded: \(up.primaryURL)"
        } else if let saved = report.saved_file_path {
            summary = "Saved: \((saved as NSString).lastPathComponent)"
        } else {
            summary = "Completed \(report.file_name)"
        }
        statusBanner = summary

        if settings.show_toast_notification {
            ClipboardService.sendUserNotification(title: "Sharaza", body: summary)
        }
    }

    // MARK: - Screen Recording

    public func toggleRecording(isGif: Bool, settingsOverride: TaskSettings? = nil) async {
        if ScreenRecorderService.shared.isRecording {
            await ScreenRecorderService.shared.stopRecording()
            return
        }

        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            statusBanner = "Screen Recording permission required"
            return
        }

        let settings = settingsOverride ?? config.default_settings
        let sel = await RegionSelectionOverlay.shared.selectRegion(allowWindowSnap: true)
        let target: RecordingTarget
        switch sel {
        case .cancelled:
            statusBanner = "Recording cancelled"
            return
        case .window(let win):
            target = .window(win)
        case .region(let r, _):
            target = .region(r)
        }

        let folderPath = (settings.screenshots_folder as NSString).expandingTildeInPath
        let outDir = URL(fileURLWithPath: folderPath, isDirectory: true)
        let stem = (try? core.previewPattern(settings.name_pattern)) ?? "recording_\(Int(Date().timeIntervalSince1970))"

        do {
            try await ScreenRecorderService.shared.startRecording(
                target: target,
                isGif: isGif,
                outputDirectory: outDir,
                fileNameStem: stem,
                settings: settings
            )
            statusBanner = isGif ? "Recording GIF…" : "Recording MP4…"
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleRecordingFinalized(url: URL, isGif: Bool, settings: TaskSettings) async {
        do {
            let creds = KeychainManager.shared.resolveCredentials()
            let report = try await core.finalizeRecordingWorkflow(
                filePath: url.path,
                isGif: isGif,
                settings: settings,
                credentials: creds
            )
            applyPostWorkflowActions(report: report, cgImageForVision: nil, pngData: Data(), settings: settings)
            await refreshHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Quick Tools

    public func captureRegionForOCR() async {
        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            statusBanner = "Screen Recording permission required"
            return
        }
        let settings = config.default_settings
        let sel = await RegionSelectionOverlay.shared.selectRegion(allowWindowSnap: true)
        guard case .region(let r, _) = sel else {
            if case .window(let w) = sel,
               let frame = try? await ScreenCaptureService.shared.captureWindow(windowID: w.windowID, fallbackInfo: w, settings: settings),
               let ocr = try? VisionService.recognizeText(in: frame.cgImage) {
                latestOCRText = ocr.fullText
                ClipboardService.copyText(ocr.fullText)
                statusBanner = "OCR copied (\(ocr.lineCount) lines)"
                selectedSection = .tools
            }
            return
        }
        do {
            let frame = try await ScreenCaptureService.shared.captureQuartzRegion(r, settings: settings)
            let ocr = try VisionService.recognizeText(in: frame.cgImage)
            latestOCRText = ocr.fullText
            if !ocr.fullText.isEmpty {
                ClipboardService.copyText(ocr.fullText)
            }
            statusBanner = "OCR copied (\(ocr.lineCount) lines)"
            selectedSection = .tools
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func captureRegionForQRScan() async {
        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            statusBanner = "Screen Recording permission required"
            return
        }
        let settings = config.default_settings
        let sel = await RegionSelectionOverlay.shared.selectRegion(allowWindowSnap: false)
        guard case .region(let r, _) = sel else { return }
        do {
            let frame = try await ScreenCaptureService.shared.captureQuartzRegion(r, settings: settings)
            let codes = try VisionService.decodeQRAndBarcodes(in: frame.cgImage)
            latestDecodedBarcodes = codes
            if let first = codes.first {
                ClipboardService.copyText(first)
                statusBanner = "Decoded QR: \(first)"
            } else {
                statusBanner = "No QR code found in selection"
            }
            selectedSection = .tools
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func runScreenColorPicker() async {
        if let picked = await OverlayToolsController.shared.pickScreenColor(core: core) {
            latestColorPick = picked
            statusBanner = "Picked \(picked.hex_upper) (copied to clipboard)"
            selectedSection = .tools
        }
    }

    public func openImageEditorFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,
           let url = panel.url,
           let nsImg = NSImage(contentsOf: url),
           let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ImageEditorWindowController.shared.openStandaloneEditor(cgImage: cg) { [weak self] editedPNG in
                guard let self else { return }
                Task { @MainActor in
                    ClipboardService.copyPNGData(editedPNG)
                    self.latestPreviewImage = NSImage(data: editedPNG)
                    self.statusBanner = "Annotated image copied to clipboard"
                }
            }
        }
    }

    public func uploadFromClipboard() async {
        let creds = KeychainManager.shared.resolveCredentials()
        let settings = config.default_settings
        isBusy = true
        defer { isBusy = false }

        do {
            if let png = ClipboardService.readImagePNGData(),
               let ns = NSImage(data: png),
               let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                var uploadSettings = settings
                uploadSettings.setAfterCapture(.uploadImageToHost, enabled: true)
                let frame = CapturedFrame(
                    cgImage: cg,
                    pngData: png,
                    metadata: CaptureMetadata(width: UInt32(cg.width), height: UInt32(cg.height)),
                    quartzRect: .zero
                )
                try await runImagePipeline(frame: frame, settings: uploadSettings)
            } else if let text = ClipboardService.readText(), !text.isEmpty {
                let rep = try await core.uploadTextWorkflow(text: text, settings: settings, credentials: creds)
                applyPostWorkflowActions(report: rep, cgImageForVision: nil, pngData: Data(), settings: settings)
                await refreshHistory()
            } else {
                statusBanner = "Clipboard has no image or text to upload"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func uploadFileDialog() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBusy = true
        defer { isBusy = false }
        do {
            let creds = KeychainManager.shared.resolveCredentials()
            let rep = try await core.uploadFileWorkflow(
                filePath: url.path,
                settings: config.default_settings,
                credentials: creds
            )
            applyPostWorkflowActions(report: rep, cgImageForVision: nil, pngData: Data(), settings: config.default_settings)
            await refreshHistory()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
