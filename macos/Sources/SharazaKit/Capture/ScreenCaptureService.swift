import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CapturedFrame: Sendable {
    public let cgImage: CGImage
    public let pngData: Data
    public let metadata: CaptureMetadata
    public let quartzRect: CGRect
}

public enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplayFound
    case noWindowFound
    case captureFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required. Enable Sharaza in System Settings > Privacy & Security > Screen Recording."
        case .noDisplayFound:
            return "No active display available for capture."
        case .noWindowFound:
            return "No capturable application window found."
        case .captureFailed(let reason):
            return "Screen capture failed: \(reason)"
        case .cancelled:
            return "Capture cancelled."
        }
    }
}

/// Native `ScreenCaptureKit` capture engine supporting Fullscreen, Multi-Monitor, Active Monitor,
/// Window, Region, and Delayed screenshots at native Retina resolution.
public final class ScreenCaptureService: Sendable {
    public static let shared = ScreenCaptureService()
    private init() {}

    @MainActor
    private func preflightAndDelay(delayMs: UInt64) async throws {
        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            throw CaptureError.permissionDenied
        }
        if delayMs > 0 {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
    }

    public func captureMonitor(index: Int, settings: TaskSettings) async throws -> CapturedFrame {
        try await preflightAndDelay(delayMs: settings.screenshot_delay_ms)
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard shareable.displays.indices.contains(index) else {
            throw CaptureError.noDisplayFound
        }
        return try await captureSCDisplay(shareable.displays[index], shareable: shareable, settings: settings)
    }

    public func captureActiveMonitor(settings: TaskSettings) async throws -> CapturedFrame {
        try await preflightAndDelay(delayMs: settings.screenshot_delay_ms)

        let mouseQuartz = await MainActor.run {
            ScreenCoordinates.appKitPointToQuartz(NSEvent.mouseLocation)
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first(where: { $0.frame.contains(mouseQuartz) }) ?? shareable.displays.first else {
            throw CaptureError.noDisplayFound
        }
        return try await captureSCDisplay(display, shareable: shareable, settings: settings)
    }

    public func captureFullscreenAllMonitors(settings: TaskSettings) async throws -> CapturedFrame {
        try await preflightAndDelay(delayMs: settings.screenshot_delay_ms)

        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !shareable.displays.isEmpty else {
            throw CaptureError.noDisplayFound
        }
        if shareable.displays.count == 1 {
            return try await captureSCDisplay(shareable.displays[0], shareable: shareable, settings: settings)
        }

        // Multi-monitor composite across all connected displays
        var unionRect = CGRect.null
        for d in shareable.displays {
            unionRect = unionRect.union(d.frame)
        }
        let maxScale: CGFloat = await MainActor.run {
            NSScreen.screens.map(\.backingScaleFactor).max() ?? 2.0
        }
        let outW = max(1, Int((unionRect.width * maxScale).rounded()))
        let outH = max(1, Int((unionRect.height * maxScale).rounded()))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: outW,
                  height: outH,
                  bitsPerComponent: 8,
                  bytesPerRow: outW * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CaptureError.captureFailed("Unable to allocate multi-monitor graphics context")
        }

        for display in shareable.displays {
            let single = try await captureSCDisplay(display, shareable: shareable, settings: settings)
            let relX = (display.frame.minX - unionRect.minX) * maxScale
            // CGContext has bottom-left origin; flip Quartz Y into CGContext Y
            let relY = (unionRect.maxY - display.frame.maxY) * maxScale
            let drawRect = CGRect(
                x: relX,
                y: relY,
                width: display.frame.width * maxScale,
                height: display.frame.height * maxScale
            )
            ctx.draw(single.cgImage, in: drawRect)
        }

        guard let combined = ctx.makeImage(), let png = combined.pngData() else {
            throw CaptureError.captureFailed("Failed to encode composite screenshot")
        }

        return CapturedFrame(
            cgImage: combined,
            pngData: png,
            metadata: CaptureMetadata(width: UInt32(combined.width), height: UInt32(combined.height)),
            quartzRect: unionRect
        )
    }

    public func captureActiveWindow(settings: TaskSettings) async throws -> CapturedFrame {
        try await preflightAndDelay(delayMs: settings.screenshot_delay_ms)
        guard let target = WindowInspector.frontmostForeignWindow() else {
            throw CaptureError.noWindowFound
        }
        return try await captureWindow(windowID: target.windowID, fallbackInfo: target, settings: settings)
    }

    public func captureWindow(
        windowID: CGWindowID,
        fallbackInfo: DesktopWindowInfo? = nil,
        settings: TaskSettings
    ) async throws -> CapturedFrame {
        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            throw CaptureError.permissionDenied
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let scWindow = shareable.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.noWindowFound
        }

        let scale: CGFloat = await MainActor.run {
            let appKitRect = ScreenCoordinates.quartzToAppKit(scWindow.frame)
            return NSScreen.screens.first(where: { $0.frame.intersects(appKitRect) })?.backingScaleFactor ?? 2.0
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let pixelW = max(1, Int((scWindow.frame.width * scale).rounded()))
        let pixelH = max(1, Int((scWindow.frame.height * scale).rounded()))
        config.width = pixelW
        config.height = pixelH
        config.showsCursor = settings.capture_cursor
        config.ignoreShadowsSingleWindow = !settings.capture_shadow
        config.shouldBeOpaque = !settings.capture_transparent

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = image.pngData() else {
            throw CaptureError.captureFailed("PNG encoding failed")
        }

        let ownerName = scWindow.owningApplication?.applicationName ?? fallbackInfo?.ownerName
        let winTitle = scWindow.title ?? fallbackInfo?.title

        return CapturedFrame(
            cgImage: image,
            pngData: png,
            metadata: CaptureMetadata(
                window_title: winTitle,
                process_name: ownerName,
                width: UInt32(image.width),
                height: UInt32(image.height)
            ),
            quartzRect: scWindow.frame
        )
    }

    public func captureQuartzRegion(
        _ quartzRect: CGRect,
        metadata: CaptureMetadata? = nil,
        settings: TaskSettings,
        excludeOwnApp: Bool = true
    ) async throws -> CapturedFrame {
        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            throw CaptureError.permissionDenied
        }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)
        guard let display = shareable.displays.first(where: { $0.frame.contains(center) })
            ?? shareable.displays.first(where: { $0.frame.intersects(quartzRect) })
            ?? shareable.displays.first else {
            throw CaptureError.noDisplayFound
        }

        let clipped = quartzRect.intersection(display.frame)
        guard !clipped.isNull && clipped.width >= 2 && clipped.height >= 2 else {
            throw CaptureError.captureFailed("Selected region is outside display bounds")
        }

        let scale: CGFloat = await MainActor.run {
            let appKitDisplay = ScreenCoordinates.quartzToAppKit(display.frame)
            return NSScreen.screens.first(where: { $0.frame.intersects(appKitDisplay) })?.backingScaleFactor ?? 2.0
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = excludeOwnApp
            ? shareable.applications.filter { $0.processID == ownPID }
            : []
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let localRect = CGRect(
            x: clipped.minX - display.frame.minX,
            y: clipped.minY - display.frame.minY,
            width: clipped.width,
            height: clipped.height
        )

        let config = SCStreamConfiguration()
        config.sourceRect = localRect
        config.width = max(1, Int((localRect.width * scale).rounded()))
        config.height = max(1, Int((localRect.height * scale).rounded()))
        config.showsCursor = settings.capture_cursor

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = image.pngData() else {
            throw CaptureError.captureFailed("PNG encoding failed")
        }

        return CapturedFrame(
            cgImage: image,
            pngData: png,
            metadata: CaptureMetadata(
                window_title: metadata?.window_title,
                process_name: metadata?.process_name,
                width: UInt32(image.width),
                height: UInt32(image.height)
            ),
            quartzRect: clipped
        )
    }

    private func captureSCDisplay(
        _ display: SCDisplay,
        shareable: SCShareableContent,
        settings: TaskSettings
    ) async throws -> CapturedFrame {
        let scale: CGFloat = await MainActor.run {
            let appKitDisplay = ScreenCoordinates.quartzToAppKit(display.frame)
            return NSScreen.screens.first(where: { $0.frame.intersects(appKitDisplay) })?.backingScaleFactor ?? 2.0
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excludedApps = shareable.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = max(1, Int((display.frame.width * scale).rounded()))
        config.height = max(1, Int((display.frame.height * scale).rounded()))
        config.showsCursor = settings.capture_cursor

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let png = image.pngData() else {
            throw CaptureError.captureFailed("PNG encoding failed")
        }

        return CapturedFrame(
            cgImage: image,
            pngData: png,
            metadata: CaptureMetadata(width: UInt32(image.width), height: UInt32(image.height)),
            quartzRect: display.frame
        )
    }
}
