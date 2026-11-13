import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// First-class macOS TCC privacy permissions manager:
/// - Uses live `SCShareableContent` (`ScreenCaptureKit`) probes alongside `CGPreflightScreenCaptureAccess()`
///   because `CGPreflightScreenCaptureAccess()` caches `false` for the lifetime of a running process even after
///   the user enables Screen Recording in System Settings.
/// - Automatically re-checks on `NSApplication.didBecomeActiveNotification` and via a lightweight background poll
///   while denied so the UI updates immediately when toggled in System Settings.
/// - Provides one-click `resyncTCCScreenRecording()` (`tccutil reset ScreenCapture app.sharaza.macos`) to resolve
///   stale ad-hoc `CDHash` mismatches after local rebuilds (where System Settings shows ON for a previous binary).
@MainActor
public final class PermissionsManager: ObservableObject {
    public static let shared = PermissionsManager()

    @Published public private(set) var hasScreenRecording: Bool = false
    @Published public private(set) var hasAccessibility: Bool = false
    @Published public private(set) var hasMicrophone: Bool = false
    @Published public private(set) var isCheckingScreenRecording: Bool = false

    private var activationObserver: NSObjectProtocol?
    private var pollTimer: Timer?

    private var isBundledApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private init() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        guard isBundledApp else { return }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAsync()
            }
        }

        // Initial live ScreenCaptureKit check + lightweight poll while ungranted so background window updates live
        Task { [weak self] in
            await self?.refreshAsync()
        }
        startPollingIfNeeded()
    }

    public func refresh() {
        if CGPreflightScreenCaptureAccess() {
            hasScreenRecording = true
        }
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if isBundledApp {
            Task { await refreshAsync() }
        }
    }

    public func refreshAsync() async {
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if CGPreflightScreenCaptureAccess() {
            markScreenRecordingGranted()
            return
        }

        guard !isCheckingScreenRecording else { return }
        isCheckingScreenRecording = true
        defer { isCheckingScreenRecording = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                markScreenRecordingGranted()
                return
            }
        } catch {
            hasScreenRecording = false
            startPollingIfNeeded()
        }
    }

    public func markScreenRecordingGranted() {
        if !hasScreenRecording {
            hasScreenRecording = true
        }
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Authoritatively verifies ScreenCaptureKit access (`SCShareableContent`), bypassing stale `CGPreflightScreenCaptureAccess()` process caches.
    @discardableResult
    public func ensureScreenRecordingAccess(openSettingsOnDeny: Bool = true) async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            markScreenRecordingGranted()
            return true
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                markScreenRecordingGranted()
                return true
            }
        } catch {
            // Trigger legacy registration if needed so Sharaza appears in System Settings list
            _ = CGRequestScreenCaptureAccess()
        }

        hasScreenRecording = false
        startPollingIfNeeded()
        if openSettingsOnDeny {
            openScreenRecordingSettings()
        }
        return false
    }

    /// Clears a stale ad-hoc `CDHash` TCC entry (which leaves the System Settings switch visually ON for an older build
    /// while `tccd` rejects the rebuilt binary) and immediately triggers a fresh macOS permission prompt.
    public func resyncTCCScreenRecording() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "app.sharaza.macos"
        await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", "ScreenCapture", bundleID]
            try? proc.run()
            proc.waitUntilExit()
        }.value

        hasScreenRecording = false
        _ = await ensureScreenRecordingAccess(openSettingsOnDeny: true)
    }

    private func startPollingIfNeeded() {
        guard isBundledApp, !hasScreenRecording, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.hasScreenRecording {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                    return
                }
                await self.refreshAsync()
            }
        }
    }

    @discardableResult
    public func requestAccessibilityAccess() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibility = trusted
        return trusted
    }

    public func requestMicrophoneAccess() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        hasMicrophone = granted
        return granted
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
