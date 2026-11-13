import AppKit
import SwiftUI

public struct MenuBarContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var recorder = ScreenRecorderService.shared
    @Environment(\.openWindow) private var openWindow

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
            openWindow(id: "main-workspace")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button("Quit Sharaza") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
