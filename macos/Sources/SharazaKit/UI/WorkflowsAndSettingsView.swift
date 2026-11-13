import AppKit
import SwiftUI

public struct WorkflowsView: View {
    @ObservedObject var appState: AppState
    @State private var newPresetName: String = ""
    @State private var newActionName: String = ""
    @State private var newActionPath: String = "/usr/bin/sips"
    @State private var newActionArgs: String = "-s format png %input --out %output"

    public init(appState: AppState) {
        self.appState = appState
    }

    private var patternPreview: String {
        (try? appState.core.previewPattern(appState.config.default_settings.name_pattern)) ?? ""
    }

    private var windowPatternPreview: String {
        (try? appState.core.previewPattern(
            appState.config.default_settings.name_pattern_window,
            windowTitle: "README.md — Sharaza",
            processName: "Cursor"
        )) ?? ""
    }

    public var body: some View {
        Form {
            Section("After-Capture Tasks (ShareX Pipeline Order)") {
                FlagToggle(appState: appState, flag: .beautifyImage, title: "Beautify Image (Padding + Gradient + Rounded Shadow)")
                FlagToggle(appState: appState, flag: .addImageEffects, title: "Apply Image Effects (Border / Resize)")
                FlagToggle(appState: appState, flag: .annotateImage, title: "Open in Image Editor Before Saving/Uploading")
                FlagToggle(appState: appState, flag: .copyImageToClipboard, title: "Copy Image to Clipboard")
                FlagToggle(appState: appState, flag: .pinToScreen, title: "Pin Image to Screen (Always-on-Top Panel)")
                FlagToggle(appState: appState, flag: .sendImageToPrinter, title: "Send Image to Printer…")
                FlagToggle(appState: appState, flag: .saveImageToFile, title: "Save Image to File")
                FlagToggle(appState: appState, flag: .saveImageWithDialog, title: "Save Image to File With Dialog…")
                FlagToggle(appState: appState, flag: .saveThumbnailToFile, title: "Save Thumbnail Image to File")
                FlagToggle(appState: appState, flag: .performActions, title: "Perform External CLI Actions (%input / %output)")
                FlagToggle(appState: appState, flag: .copyFileToClipboard, title: "Copy Saved File to Clipboard")
                FlagToggle(appState: appState, flag: .copyFilePathToClipboard, title: "Copy File Path to Clipboard")
                FlagToggle(appState: appState, flag: .showInFinder, title: "Reveal File in Finder")
                FlagToggle(appState: appState, flag: .scanQRCode, title: "Scan QR Code (Apple Vision)")
                FlagToggle(appState: appState, flag: .doOCR, title: "Perform OCR Text Recognition (Apple Vision)")
                FlagToggle(appState: appState, flag: .showBeforeUploadWindow, title: "Ask Confirmation Before Uploading")
                FlagToggle(appState: appState, flag: .uploadImageToHost, title: "Upload Image / File to Host")
            }

            Section("After-Upload Tasks") {
                UploadFlagToggle(appState: appState, flag: .useURLShortener, title: "Shorten URL")
                UploadFlagToggle(appState: appState, flag: .shareURL, title: "Generate URL Sharing Link")
                UploadFlagToggle(appState: appState, flag: .copyURLToClipboard, title: "Copy URL to Clipboard")
                UploadFlagToggle(appState: appState, flag: .openURL, title: "Open URL in Browser")
                UploadFlagToggle(appState: appState, flag: .showQRCode, title: "Generate QR Code for Uploaded URL")

                TextField("Custom Clipboard Format ($url, $shorturl, $filename…)", text: $appState.config.default_settings.clipboard_content_format)
                    .onSubmit { appState.persistConfig() }
                Toggle("Force HTTPS on Result URLs", isOn: $appState.config.default_settings.result_force_https)
                    .onChange(of: appState.config.default_settings.result_force_https) { _, _ in appState.persistConfig() }
            }

            Section("ShareX Naming Patterns & Destination Folder") {
                HStack {
                    TextField("Screenshots Folder", text: $appState.config.default_settings.screenshots_folder)
                        .onSubmit { appState.persistConfig() }
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true
                        p.canChooseFiles = false
                        if p.runModal() == .OK, let u = p.url {
                            appState.config.default_settings.screenshots_folder = u.path
                            appState.persistConfig()
                        }
                    }
                }
                TextField("Subfolder Pattern (e.g. %y-%mo)", text: $appState.config.default_settings.sub_folder_pattern)
                    .onSubmit { appState.persistConfig() }
                TextField("File Name Pattern", text: $appState.config.default_settings.name_pattern)
                    .onChange(of: appState.config.default_settings.name_pattern) { _, _ in appState.persistConfig() }
                LabeledContent("Live Pattern Preview") {
                    Text("\(patternPreview).\(appState.config.default_settings.image_format.rawValue.lowercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                TextField("Window Capture Name Pattern (%pn, %t)", text: $appState.config.default_settings.name_pattern_window)
                    .onChange(of: appState.config.default_settings.name_pattern_window) { _, _ in appState.persistConfig() }
                LabeledContent("Window Pattern Preview") {
                    Text("\(windowPatternPreview).\(appState.config.default_settings.image_format.rawValue.lowercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Tokens: %y %yy %mo %mon2 %d %h %mi %s %ms %pm %w2 %wy %unix %i{4} %ix %ia %iAa %ra{6} %rn{4} %rx{8} %guid %radjective %ranimal %pn %t %width %height %un %cn")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Image Format & Beautifier") {
                Picker("Image Format", selection: $appState.config.default_settings.image_format) {
                    ForEach(ImageFormat.allCases) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .onChange(of: appState.config.default_settings.image_format) { _, _ in appState.persistConfig() }

                Picker("When File Exists", selection: $appState.config.default_settings.file_exist_action) {
                    ForEach(FileExistAction.allCases) { act in
                        Text(act.rawValue).tag(act)
                    }
                }
                .onChange(of: appState.config.default_settings.file_exist_action) { _, _ in appState.persistConfig() }

                Stepper(
                    "Beautifier Padding: \(appState.config.default_settings.image_effects.beautify_padding) px",
                    value: $appState.config.default_settings.image_effects.beautify_padding,
                    in: 0...160,
                    step: 8
                )
                .onChange(of: appState.config.default_settings.image_effects.beautify_padding) { _, _ in appState.persistConfig() }

                Stepper(
                    "Corner Radius: \(appState.config.default_settings.image_effects.beautify_corner_radius) px",
                    value: $appState.config.default_settings.image_effects.beautify_corner_radius,
                    in: 0...48,
                    step: 2
                )
                .onChange(of: appState.config.default_settings.image_effects.beautify_corner_radius) { _, _ in appState.persistConfig() }
            }

            Section("External CLI Actions (ShareX PerformActions)") {
                HStack {
                    TextField("Action Name", text: $newActionName)
                    TextField("Executable Path", text: $newActionPath)
                    TextField("Args (%input, %output)", text: $newActionArgs)
                    Button("Add Action") {
                        let name = newActionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        appState.config.default_settings.external_actions.append(
                            ExternalProgramAction(
                                name: name,
                                path: newActionPath,
                                args_template: newActionArgs,
                                output_extension: nil,
                                enabled: true
                            )
                        )
                        appState.persistConfig()
                        newActionName = ""
                    }
                }
                ForEach($appState.config.default_settings.external_actions) { $act in
                    HStack {
                        Toggle(act.name, isOn: $act.enabled)
                            .onChange(of: act.enabled) { _, _ in appState.persistConfig() }
                        Text("\(act.path) \(act.args_template)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            appState.config.default_settings.external_actions.removeAll { $0.name == act.name }
                            appState.persistConfig()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }

            Section("Saved Workflow Presets") {
                HStack {
                    TextField("Preset Name (e.g. Bug Report + Upload)", text: $newPresetName)
                    Button("Save Current as Preset") {
                        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let preset = WorkflowPreset(
                            id: UUID().uuidString,
                            name: trimmed,
                            settings: appState.config.default_settings
                        )
                        try? appState.core.saveWorkflow(preset)
                        appState.workflows = (try? appState.core.listWorkflows()) ?? []
                        newPresetName = ""
                    }
                }

                ForEach(appState.workflows) { preset in
                    HStack {
                        Text(preset.name).fontWeight(.medium)
                        Spacer()
                        Button("Run Now") {
                            Task { await appState.triggerCapture(preset.settings.capture_type, settingsOverride: preset.settings) }
                        }
                        Button("Load") {
                            appState.config.default_settings = preset.settings
                            appState.persistConfig()
                        }
                        Button(role: .destructive) {
                            try? appState.core.deleteWorkflow(id: preset.id)
                            appState.workflows = (try? appState.core.listWorkflows()) ?? []
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Workflows & Task Pipeline")
    }
}

public struct PreferencesAndPermissionsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions = PermissionsManager.shared
    @State private var recordingHotkeyID: String?
    @State private var keyRecordMonitor: Any?
    @State private var newHotkeyAction: String = "ScrollingCapture"

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        Form {
            Section("macOS Privacy & TCC Permissions") {
                HStack {
                    Label(
                        permissions.hasScreenRecording ? "Screen Recording: Granted" : "Screen Recording: Not Granted / Out of Sync",
                        systemImage: permissions.hasScreenRecording ? "checkmark.shield.fill" : "xmark.shield.fill"
                    )
                    .foregroundStyle(permissions.hasScreenRecording ? .green : .orange)
                    Spacer()
                    if !permissions.hasScreenRecording {
                        Button("Re-sync TCC") {
                            Task { await permissions.resyncTCCScreenRecording() }
                        }
                    }
                    Button("Re-check") {
                        Task { await permissions.refreshAsync() }
                    }
                    Button("Open Settings") {
                        Task { _ = await permissions.ensureScreenRecordingAccess(openSettingsOnDeny: true) }
                    }
                }

                HStack {
                    Label(
                        permissions.hasAccessibility ? "Accessibility (Auto-Scroll): Granted" : "Accessibility (Optional for Auto-Scroll): Not Granted",
                        systemImage: permissions.hasAccessibility ? "checkmark.shield.fill" : "info.circle"
                    )
                    .foregroundStyle(permissions.hasAccessibility ? .green : .secondary)
                    Spacer()
                    Button("Configure Accessibility") {
                        _ = permissions.requestAccessibilityAccess()
                    }
                }

                HStack {
                    Label(
                        permissions.hasMicrophone ? "Microphone: Granted" : "Microphone (Optional for Audio Recording): Not Granted",
                        systemImage: permissions.hasMicrophone ? "mic.fill" : "mic.slash"
                    )
                    Spacer()
                    Button("Request Microphone") {
                        Task { _ = await permissions.requestMicrophoneAccess() }
                    }
                    Button("Refresh Status") {
                        permissions.refresh()
                    }
                }
            }

            Section("Capture & Screen Recording Options") {
                Stepper(
                    "Capture Delay: \(String(format: "%.1f", Double(appState.config.default_settings.screenshot_delay_ms) / 1000.0)) s",
                    value: $appState.config.default_settings.screenshot_delay_ms,
                    in: 0...15_000,
                    step: 500
                )
                .onChange(of: appState.config.default_settings.screenshot_delay_ms) { _, _ in appState.persistConfig() }

                Toggle("Include Mouse Cursor", isOn: $appState.config.default_settings.capture_cursor)
                    .onChange(of: appState.config.default_settings.capture_cursor) { _, _ in appState.persistConfig() }
                Toggle("Capture Window Shadow", isOn: $appState.config.default_settings.capture_shadow)
                    .onChange(of: appState.config.default_settings.capture_shadow) { _, _ in appState.persistConfig() }
                Toggle("Play Capture Sound", isOn: $appState.config.default_settings.play_sound_after_capture)
                    .onChange(of: appState.config.default_settings.play_sound_after_capture) { _, _ in appState.persistConfig() }
                Toggle("Show Completion Notification", isOn: $appState.config.default_settings.show_toast_notification)
                    .onChange(of: appState.config.default_settings.show_toast_notification) { _, _ in appState.persistConfig() }

                Stepper("MP4 Recording FPS: \(appState.config.default_settings.recording_fps)", value: $appState.config.default_settings.recording_fps, in: 5...60, step: 5)
                    .onChange(of: appState.config.default_settings.recording_fps) { _, _ in appState.persistConfig() }
                Stepper("GIF Recording FPS: \(appState.config.default_settings.recording_gif_fps)", value: $appState.config.default_settings.recording_gif_fps, in: 5...30, step: 5)
                    .onChange(of: appState.config.default_settings.recording_gif_fps) { _, _ in appState.persistConfig() }
                Toggle("Record System Audio in MP4", isOn: $appState.config.default_settings.recording_system_audio)
                    .onChange(of: appState.config.default_settings.recording_system_audio) { _, _ in appState.persistConfig() }
                Toggle("Record Microphone Audio in MP4 (macOS 15+)", isOn: $appState.config.default_settings.recording_microphone)
                    .onChange(of: appState.config.default_settings.recording_microphone) { _, _ in appState.persistConfig() }
            }

            Section("Global Shortcuts (Carbon RegisterEventHotKey — Zero Accessibility Prompt)") {
                Toggle("Enable Global Hotkeys", isOn: $appState.config.hotkeys_enabled)
                    .onChange(of: appState.config.hotkeys_enabled) { _, _ in appState.persistConfig() }

                ForEach($appState.config.hotkeys) { $hk in
                    HStack(spacing: 10) {
                        Toggle(hk.action, isOn: $hk.enabled)
                            .onChange(of: hk.enabled) { _, _ in appState.persistConfig() }
                        Spacer()
                        Button {
                            toggleShortcutRecording(for: hk.id)
                        } label: {
                            Text(recordingHotkeyID == hk.id ? "Press keys…" : hk.display_shortcut)
                                .font(.system(.callout, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.bordered)
                        .tint(recordingHotkeyID == hk.id ? .orange : nil)
                        .help("Click, then press a modifier + key combination to rebind")

                        Button("Run") {
                            appState.dispatchHotkeyAction(hk.action)
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    Picker("New Shortcut Action", selection: $newHotkeyAction) {
                        ForEach(AppState.availableHotkeyActions, id: \.self) { act in
                            Text(act).tag(act)
                        }
                        ForEach(appState.workflows) { preset in
                            Text("Workflow: \(preset.name)").tag("Workflow:\(preset.id)")
                        }
                    }
                    Button("Add Shortcut") {
                        let newID = "custom_\(UUID().uuidString.prefix(8))"
                        appState.config.hotkeys.append(
                            HotkeyBinding(
                                id: newID,
                                action: newHotkeyAction,
                                key_code: 0x01, // S
                                modifiers: 0x1000 | 0x0800 | 0x0200, // Ctrl+Opt+Shift
                                display_shortcut: "⌃⌥⇧S",
                                enabled: true,
                                workflow_id: nil
                            )
                        )
                        appState.persistConfig()
                    }
                }
            }

            Section("Documented macOS Platform Notes & GPL-3.0 Licensing") {
                Text("• Foreign Window Mutation (`BorderlessWindow` / `ActiveWindowTopMost`): macOS WindowServer prohibits altering window levels of other applications; use Sharaza's native Pin to Screen instead.\n• Licensed under GNU General Public License v3.0 (ShareX upstream parity).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Preferences & Permissions")
        .onDisappear {
            stopShortcutRecording()
        }
    }

    private func toggleShortcutRecording(for id: String) {
        if recordingHotkeyID == id {
            stopShortcutRecording()
            return
        }
        stopShortcutRecording()
        recordingHotkeyID = id
        GlobalHotkeyManager.shared.unregisterAll()

        keyRecordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape cancels recording
                stopShortcutRecording()
                appState.persistConfig()
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbonMods: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) { carbonMods |= 0x1000; symbols += "⌃" }
            if flags.contains(.option)  { carbonMods |= 0x0800; symbols += "⌥" }
            if flags.contains(.shift)   { carbonMods |= 0x0200; symbols += "⇧" }
            if flags.contains(.command) { carbonMods |= 0x0100; symbols += "⌘" }

            guard carbonMods != 0,
                  let idx = appState.config.hotkeys.firstIndex(where: { $0.id == id }) else {
                return nil
            }

            let keyLabel = (event.charactersIgnoringModifiers ?? "").uppercased()
            appState.config.hotkeys[idx].key_code = UInt32(event.keyCode)
            appState.config.hotkeys[idx].modifiers = carbonMods
            appState.config.hotkeys[idx].display_shortcut = symbols + (keyLabel.isEmpty ? "Key\(event.keyCode)" : keyLabel)
            stopShortcutRecording()
            appState.persistConfig()
            return nil
        }
    }

    private func stopShortcutRecording() {
        if let m = keyRecordMonitor {
            NSEvent.removeMonitor(m)
            keyRecordMonitor = nil
        }
        recordingHotkeyID = nil
    }
}

private struct FlagToggle: View {
    @ObservedObject var appState: AppState
    let flag: AfterCaptureFlags
    let title: String

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { appState.config.default_settings.hasAfterCapture(flag) },
                set: { v in
                    appState.config.default_settings.setAfterCapture(flag, enabled: v)
                    appState.persistConfig()
                }
            )
        )
    }
}

private struct UploadFlagToggle: View {
    @ObservedObject var appState: AppState
    let flag: AfterUploadFlags
    let title: String

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { appState.config.default_settings.hasAfterUpload(flag) },
                set: { v in
                    appState.config.default_settings.setAfterUpload(flag, enabled: v)
                    appState.persistConfig()
                }
            )
        )
    }
}
