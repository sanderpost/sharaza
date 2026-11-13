import AppKit
import CoreGraphics
import Foundation

public struct DesktopWindowInfo: Identifiable, Sendable, Equatable {
    public var id: CGWindowID { windowID }
    public let windowID: CGWindowID
    public let ownerPID: pid_t
    public let ownerName: String
    public let title: String
    /// Bounds in Quartz global coordinates (origin at top-left of primary screen, Y downward).
    public let quartzBounds: CGRect
    public let layer: Int
}

public enum ScreenCoordinates {
    @MainActor
    public static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 1080
    }

    /// Converts an AppKit global rect (bottom-left origin) to Quartz global rect (top-left origin).
    @MainActor
    public static func appKitToQuartz(_ rect: CGRect) -> CGRect {
        let h = primaryScreenHeight
        return CGRect(
            x: rect.origin.x,
            y: h - (rect.origin.y + rect.size.height),
            width: rect.size.width,
            height: rect.size.height
        )
    }

    /// Converts a Quartz global rect (top-left origin) to AppKit global rect (bottom-left origin).
    @MainActor
    public static func quartzToAppKit(_ rect: CGRect) -> CGRect {
        let h = primaryScreenHeight
        return CGRect(
            x: rect.origin.x,
            y: h - (rect.origin.y + rect.size.height),
            width: rect.size.width,
            height: rect.size.height
        )
    }

    @MainActor
    public static func appKitPointToQuartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }
}

/// Fast native window enumerator via `CGWindowListCopyWindowInfo`, matching `XerahS.Platform.MacOS.Native.QuartzWindowList`.
public enum WindowInspector {
    public static func listApplicationWindows(excludingPID: pid_t? = ProcessInfo.processInfo.processIdentifier) -> [DesktopWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [DesktopWindowInfo] = []
        for entry in rawList {
            guard let winNum = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int else {
                continue
            }
            if layer != 0 { continue }
            if let excluded = excludingPID, pid == excluded { continue }

            var rect = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
               let parsed = CGRect(dictionaryRepresentation: boundsDict) {
                rect = parsed
            }
            if rect.width <= 4 || rect.height <= 4 { continue }

            let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (entry[kCGWindowName as String] as? String) ?? ""

            results.append(
                DesktopWindowInfo(
                    windowID: winNum,
                    ownerPID: pid,
                    ownerName: ownerName,
                    title: title,
                    quartzBounds: rect,
                    layer: layer
                )
            )
        }
        return results
    }

    public static func frontmostForeignWindow() -> DesktopWindowInfo? {
        listApplicationWindows(excludingPID: ProcessInfo.processInfo.processIdentifier).first
    }

    public static func windowAtQuartzPoint(_ point: CGPoint, windows: [DesktopWindowInfo]? = nil) -> DesktopWindowInfo? {
        let candidates = windows ?? listApplicationWindows(excludingPID: ProcessInfo.processInfo.processIdentifier)
        return candidates.first { $0.quartzBounds.contains(point) }
    }
}
