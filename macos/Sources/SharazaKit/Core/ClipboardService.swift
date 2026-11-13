import AppKit
import Foundation
@preconcurrency import UserNotifications

/// Native macOS clipboard, Finder, sound, and notification integration matching `ShareX.HelpersLib.ClipboardHelpers` & `FileHelpers`.
@MainActor
public enum ClipboardService {
    public static func copyPNGData(_ pngData: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(pngData, forType: .png)
        if let image = NSImage(data: pngData), let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    public static func copyImage(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    public static func copyFileURL(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    public static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public static func readImagePNGData() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) {
            return png
        }
        if let image = NSImage(pasteboard: pb) {
            return image.pngData()
        }
        return nil
    }

    public static func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    public static func playCaptureSound() {
        NSSound(named: NSSound.Name("Tink"))?.play()
    }

    public static func sendUserNotification(title: String, body: String) {
        // UNUserNotificationCenter requires a bundled .app with bundleIdentifier; guard safely when running under swift test
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(req)
        }
    }
}

extension NSImage {
    public func pngData() -> Data? {
        guard let tiff = self.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    public static func fromCGImage(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension CGImage {
    public func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }
}
