import AppKit
import SwiftUI

public struct MainWorkspaceView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var recorder = ScreenRecorderService.shared

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $appState.selectedSection) {
                Section("Sharaza") {
                    ForEach(WorkspaceSection.allCases) { section in
                        HStack(spacing: 10) {
                            Image(systemName: section.icon)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 20, alignment: .center)
                            Text(section.rawValue)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 3)
                        .padding(.leading, 6)
                        .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 248, max: 300)
        } detail: {
            Group {
                switch appState.selectedSection {
                case .dashboard:
                    DashboardView(appState: appState)
                case .history:
                    HistoryView(appState: appState)
                case .workflows:
                    WorkflowsView(appState: appState)
                case .uploaders:
                    UploadersView(appState: appState)
                case .tools:
                    ToolsHubView(appState: appState)
                case .settings:
                    PreferencesAndPermissionsView(appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    StatusPillView(appState: appState, recorder: recorder)

                    Button {
                        Task { await appState.triggerCapture(.Region) }
                    } label: {
                        Label("Capture Region", systemImage: "viewfinder.rectangular")
                    }
                    .help("Capture Region (⌃⇧4)")

                    Button {
                        Task { await appState.triggerCapture(.ScreenRecordingMp4) }
                    } label: {
                        Label(
                            recorder.isRecording ? "Stop Recording" : "Record",
                            systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                        )
                    }
                    .help("Toggle Screen Recording (⌃⇧5)")
                }
            }
        }
        .alert(
            "Operation Notice",
            isPresented: Binding(
                get: { appState.lastError != nil },
                set: { if !$0 { appState.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.lastError = nil }
        } message: {
            Text(appState.lastError ?? "")
        }
    }
}

private struct StatusPillView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var recorder: ScreenRecorderService

    var body: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("REC \(recorder.elapsedSeconds)s")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.red)
            } else if appState.isBusy {
                ProgressView().controlSize(.mini)
                Text(appState.statusBanner)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(appState.statusBanner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

struct DashboardView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions = PermissionsManager.shared
    @ObservedObject var recorder = ScreenRecorderService.shared

    private let actionColumns = [
        GridItem(.adaptive(minimum: 200), spacing: 12)
    ]

    private let toggleColumns = [
        GridItem(.adaptive(minimum: 190), alignment: .leading)
    ]

    private var previewImageToDisplay: NSImage? {
        if let latest = appState.latestPreviewImage {
            return latest
        }
        if let recentFile = appState.historyItems.first(where: {
            !$0.file_path.isEmpty && FileManager.default.fileExists(atPath: $0.file_path)
        })?.file_path {
            return NSImage(contentsOfFile: recentFile)
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !permissions.hasScreenRecording {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Screen Recording Permission Needed")
                                .font(.headline)
                            Text("Enable Sharaza in System Settings › Screen & System Audio Recording. If Sharaza already appears ON after a local app rebuild, toggle it off & on once or click Re-sync TCC.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button("Re-check") {
                                Task { await permissions.refreshAsync() }
                            }
                            Button("Re-sync TCC") {
                                Task { await permissions.resyncTCCScreenRecording() }
                            }
                            .help("Resets stale ad-hoc build signature in macOS TCC and requests fresh access")
                            Button("Open Settings") {
                                Task { _ = await permissions.ensureScreenRecordingAccess(openSettingsOnDeny: true) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
                }

                // Quick Capture Grid
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture & Record")
                        .font(.title3.bold())

                    LazyVGrid(columns: actionColumns, spacing: 12) {
                        QuickActionCard(title: "Capture Region", subtitle: "Crosshair + 15×15 Loupe (⌃⇧4)", icon: "viewfinder.rectangular", tint: .blue) {
                            Task { await appState.triggerCapture(.Region) }
                        }
                        QuickActionCard(title: "Capture Window", subtitle: "Snap to Application Window (⌃⇧2)", icon: "macwindow", tint: .indigo) {
                            Task { await appState.triggerCapture(.Window) }
                        }
                        QuickActionCard(title: "Capture Fullscreen", subtitle: "All Connected Displays (⌃⇧3)", icon: "rectangle.inset.filled", tint: .teal) {
                            Task { await appState.triggerCapture(.Fullscreen) }
                        }
                        QuickActionCard(title: "Scrolling Capture", subtitle: "Auto-stitch Tall Pages", icon: "arrow.up.and.down.text.horizontal", tint: .purple) {
                            Task { await appState.triggerCapture(.ScrollingCapture) }
                        }
                        QuickActionCard(
                            title: recorder.isRecording && !recorder.isGifMode ? "Stop MP4 Recording" : "Record Screen (MP4)",
                            subtitle: "H.264 + System Audio (⌃⇧5)",
                            icon: "record.circle",
                            tint: .red
                        ) {
                            Task { await appState.triggerCapture(.ScreenRecordingMp4) }
                        }
                        QuickActionCard(
                            title: recorder.isRecording && recorder.isGifMode ? "Stop GIF Recording" : "Record GIF",
                            subtitle: "Animated Looping GIF",
                            icon: "photo.stack",
                            tint: .orange
                        ) {
                            Task { await appState.triggerCapture(.ScreenRecordingGif) }
                        }
                    }
                }

                // Quick Share & Utilities Row
                VStack(alignment: .leading, spacing: 10) {
                    Text("Upload & Instant Tools")
                        .font(.title3.bold())

                    LazyVGrid(columns: actionColumns, spacing: 12) {
                        QuickActionCard(title: "OCR Screen Region", subtitle: "Apple Vision Text Recognition (⌃⇧O)", icon: "text.viewfinder", tint: .mint) {
                            Task { await appState.captureRegionForOCR() }
                        }
                        QuickActionCard(title: "Image Editor", subtitle: "Annotate, Blur, Step #, Beautify", icon: "pencil.and.outline", tint: .pink) {
                            appState.openImageEditorFromFile()
                        }
                        QuickActionCard(title: "Screen Color Picker", subtitle: "HEX / RGB / HSB / CMYK (⌃⇧C)", icon: "eyedropper.halffull", tint: .yellow) {
                            Task { await appState.runScreenColorPicker() }
                        }
                        QuickActionCard(title: "Screen Ruler", subtitle: "Measure W × H, Diagonal & Angle°", icon: "ruler", tint: .cyan) {
                            OverlayToolsController.shared.showScreenRuler()
                        }
                        QuickActionCard(title: "Upload Clipboard", subtitle: "Image or Text to Active Host", icon: "arrow.up.doc.on.clipboard", tint: .green) {
                            Task { await appState.uploadFromClipboard() }
                        }
                        QuickActionCard(title: "Upload File…", subtitle: "Upload Any Local File", icon: "icloud.and.arrow.up", tint: .blue) {
                            Task { await appState.uploadFileDialog() }
                        }
                    }
                }

                // Active After-Capture Pipeline Toggles (responsive grid)
                GroupBox("Active Workflow Pipeline") {
                    LazyVGrid(columns: toggleColumns, alignment: .leading, spacing: 10) {
                        AfterCaptureToggle(appState: appState, flag: .annotateImage, label: "Open in Image Editor")
                        AfterCaptureToggle(appState: appState, flag: .beautifyImage, label: "Beautify Image")
                        AfterCaptureToggle(appState: appState, flag: .copyImageToClipboard, label: "Copy Image to Clipboard")
                        AfterCaptureToggle(appState: appState, flag: .saveImageToFile, label: "Save Image to File")
                        AfterCaptureToggle(appState: appState, flag: .pinToScreen, label: "Pin to Screen")
                        AfterCaptureToggle(appState: appState, flag: .doOCR, label: "Run OCR")
                        AfterCaptureToggle(appState: appState, flag: .uploadImageToHost, label: "Upload to Host")
                        Toggle(
                            "Copy URL After Upload",
                            isOn: Binding(
                                get: { appState.config.default_settings.hasAfterUpload(.copyURLToClipboard) },
                                set: { val in
                                    appState.config.default_settings.setAfterUpload(.copyURLToClipboard, enabled: val)
                                    appState.persistConfig()
                                }
                            )
                        )
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Latest Capture Preview + Stats Summary
                HStack(alignment: .top, spacing: 16) {
                    GroupBox("Latest Capture") {
                        if let img = previewImageToDisplay {
                            VStack(spacing: 10) {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                HStack(spacing: 10) {
                                    Button("Copy") { ClipboardService.copyImage(img) }
                                    Button("Pin to Screen") { OverlayToolsController.shared.pinImageToScreen(img) }
                                    Button("Annotate") {
                                        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                            ImageEditorWindowController.shared.openStandaloneEditor(cgImage: cg) { edited in
                                                ClipboardService.copyPNGData(edited)
                                                appState.latestPreviewImage = NSImage(data: edited)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(8)
                        } else {
                            ContentUnavailableView("No Captures Yet", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    GroupBox("History Overview") {
                        VStack(alignment: .leading, spacing: 8) {
                            StatRow(label: "Total Items", value: "\(appState.historyStats.total_count)")
                            StatRow(label: "Images", value: "\(appState.historyStats.image_count)")
                            StatRow(label: "Videos", value: "\(appState.historyStats.video_count)")
                            StatRow(label: "Text Snippets", value: "\(appState.historyStats.text_count)")
                            StatRow(label: "Uploaded Links", value: "\(appState.historyStats.uploaded_count)")
                            Divider()
                            Button("Open Full History") {
                                appState.selectedSection = .history
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .padding(8)
                        .frame(width: 230)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Sharaza")
    }
}

private struct QuickActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.14)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AfterCaptureToggle: View {
    @ObservedObject var appState: AppState
    let flag: AfterCaptureFlags
    let label: String

    var body: some View {
        Toggle(
            label,
            isOn: Binding(
                get: { appState.config.default_settings.hasAfterCapture(flag) },
                set: { enabled in
                    appState.config.default_settings.setAfterCapture(flag, enabled: enabled)
                    appState.persistConfig()
                }
            )
        )
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
    }
}
