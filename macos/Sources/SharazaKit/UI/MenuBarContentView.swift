import AppKit
import ServiceManagement
import SwiftUI

public struct MenuBarContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var recorder = ScreenRecorderService.shared
    @State private var launchAtStartup = LoginItemService.isEnabled

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Button("Capture Region (⌃⇧4)") {
            Task { await appState.triggerCapture(.Region) }
        }
        Button("Capture Active Window (⌃⇧2)") {
            Task { await appState.triggerCapture(.ActiveWindow) }
        }
        Menu("Capture Window") {
            Button("Pick Window Interactively…") {
                Task { await appState.triggerCapture(.Window) }
            }
            Divider()
            ForEach(WindowInspector.listApplicationWindows().prefix(12)) { win in
                let label = win.title.isEmpty ? win.ownerName : "\(win.ownerName) — \(win.title)"
                Button(label) {
                    Task { await appState.captureSpecificWindow(win) }
                }
            }
        }
        Menu("Capture Monitor") {
            Button("All Monitors (Fullscreen) (⌃⇧3)") {
                Task { await appState.triggerCapture(.Fullscreen) }
            }
            Button("Active Monitor (Under Cursor)") {
                Task { await appState.triggerCapture(.ActiveMonitor) }
            }
            Divider()
            ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { idx, screen in
                Button("Display \(idx + 1): \(screen.localizedName) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))") {
                    Task { await appState.captureSpecificMonitor(index: idx) }
                }
            }
        }
        Button("Capture Last Region") {
            Task { await appState.triggerCapture(.LastRegion) }
        }
        Button("Scrolling Capture") {
            Task { await appState.triggerCapture(.ScrollingCapture) }
        }

        Divider()

        if recorder.isRecording {
            Button(recorder.isPaused ? "Resume Recording" : "Pause Recording") {
                recorder.togglePause()
            }
            Button("Stop Recording (\(recorder.elapsedSeconds)s)") {
                Task { await recorder.stopRecording() }
            }
            Button("Abort Recording") {
                Task { await recorder.abortRecording() }
            }
        } else {
            Button("Record Screen (MP4) (⌃⇧5)") {
                Task { await appState.triggerCapture(.ScreenRecordingMp4) }
            }
            Button("Record Screen (GIF)") {
                Task { await appState.triggerCapture(.ScreenRecordingGif) }
            }
        }

        Divider()

        Menu("Tools") {
            Button("OCR Screen Region (⌃⇧O)") {
                Task { await appState.captureRegionForOCR() }
            }
            Button("Scan QR Code From Screen") {
                Task { await appState.captureRegionForQRScan() }
            }
            Button("Screen Color Picker (⌃⇧C)") {
                Task { await appState.runScreenColorPicker() }
            }
            Button("Screen Ruler") {
                OverlayToolsController.shared.showScreenRuler()
            }
            Button("Image Editor…") {
                appState.openImageEditorFromFile()
            }
        }

        Menu("After-Capture Tasks") {
            Toggle(
                "Annotate in Image Editor",
                isOn: Binding(
                    get: { appState.config.default_settings.hasAfterCapture(.annotateImage) },
                    set: {
                        appState.config.default_settings.setAfterCapture(.annotateImage, enabled: $0)
                        appState.persistConfig()
                    }
                )
            )
            Toggle(
                "Beautify Image",
                isOn: Binding(
                    get: { appState.config.default_settings.hasAfterCapture(.beautifyImage) },
                    set: {
                        appState.config.default_settings.setAfterCapture(.beautifyImage, enabled: $0)
                        appState.persistConfig()
                    }
                )
            )
            Toggle(
                "Copy Image to Clipboard",
                isOn: Binding(
                    get: { appState.config.default_settings.hasAfterCapture(.copyImageToClipboard) },
                    set: {
                        appState.config.default_settings.setAfterCapture(.copyImageToClipboard, enabled: $0)
                        appState.persistConfig()
                    }
                )
            )
            Toggle(
                "Save Image to File",
                isOn: Binding(
                    get: { appState.config.default_settings.hasAfterCapture(.saveImageToFile) },
                    set: {
                        appState.config.default_settings.setAfterCapture(.saveImageToFile, enabled: $0)
                        appState.persistConfig()
                    }
                )
            )
            Toggle(
                "Upload Image to Host",
                isOn: Binding(
                    get: { appState.config.default_settings.hasAfterCapture(.uploadImageToHost) },
                    set: {
                        appState.config.default_settings.setAfterCapture(.uploadImageToHost, enabled: $0)
                        appState.persistConfig()
                    }
                )
            )
        }

        if !appState.historyItems.isEmpty {
            Menu("Recent History") {
                ForEach(appState.historyItems.prefix(6)) { item in
                    Button(item.file_name.isEmpty ? item.primaryURL : item.file_name) {
                        if !item.primaryURL.isEmpty {
                            ClipboardService.copyText(item.primaryURL)
                        } else if !item.file_path.isEmpty {
                            ClipboardService.revealInFinder(item.file_path)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Upload From Clipboard") {
            Task { await appState.uploadFromClipboard() }
        }
        Button("Upload File…") {
            Task { await appState.uploadFileDialog() }
        }

        Divider()

        Button("Open Sharaza Workspace") {
            WorkspaceWindow.show(appState: appState)
        }

        Toggle("Launch at startup", isOn: Binding(
            get: { launchAtStartup },
            set: { updateLaunchAtStartup($0) }
        ))
        .onAppear { launchAtStartup = LoginItemService.isEnabled }

        Button("Quit Sharaza") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func updateLaunchAtStartup(_ enabled: Bool) {
        do {
            try LoginItemService.setEnabled(enabled)
            launchAtStartup = LoginItemService.isEnabled
        } catch {
            launchAtStartup = LoginItemService.isEnabled
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at startup"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

@MainActor
private enum WorkspaceWindow {
    private static var window: NSWindow?

    static func show(appState: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(
            rootView: MainWorkspaceView(appState: appState)
                .frame(minWidth: 960, minHeight: 640)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "Sharaza"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 1120, height: 740))
        window.minSize = NSSize(width: 960, height: 640)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

private enum LoginItemService {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            true
        default:
            false
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status == .notRegistered || service.status == .notFound {
                try service.register()
            }
        } else if service.status != .notRegistered {
            try service.unregister()
        }
    }
}
