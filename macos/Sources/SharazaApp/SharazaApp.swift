import AppKit
import SharazaKit
import SwiftUI

@MainActor
final class SharazaAppDelegate: NSObject, NSApplicationDelegate {
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
            return try AppState()
        } catch {
            fatalError("Failed to initialize Sharaza Core: \(error.localizedDescription)")
        }
    }()

    var body: some Scene {
        WindowGroup("Sharaza", id: "main-workspace") {
            MainWorkspaceView(appState: appState)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    appState.handleCLIArguments(CommandLine.arguments)
                }
                .onOpenURL { url in
                    appState.handleOpenedFileURL(url)
                }
        }
        .defaultSize(width: 1120, height: 740)

        MenuBarExtra("Sharaza", systemImage: "camera.aperture") {
            MenuBarContentView(appState: appState)
        }
    }
}
