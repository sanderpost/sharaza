import AppKit
import SharazaKit
import SwiftUI

@MainActor
enum SharazaRuntime {
    static var appState: AppState?
}

@MainActor
final class SharazaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SharazaRuntime.appState?.handleCLIArguments(CommandLine.arguments)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            SharazaRuntime.appState?.handleOpenedFileURL(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in macOS Menu Bar when workspace window is closed, matching ShareX tray lifecycle
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregisterAll()
    }
}

@main
struct SharazaApp: App {
    @NSApplicationDelegateAdaptor(SharazaAppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState = {
        do {
            let state = try AppState()
            SharazaRuntime.appState = state
            return state
        } catch {
            fatalError("Failed to initialize Sharaza Core: \(error.localizedDescription)")
        }
    }()

    var body: some Scene {
        MenuBarExtra("Sharaza", systemImage: "camera.aperture") {
            MenuBarContentView(appState: appState)
        }
    }
}
