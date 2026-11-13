import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Scrolling capture orchestrator reconstructing `ShareX.ScreenCaptureLib.ScrollingCaptureManager`:
/// 1. User selects a scrollable window or region via `RegionSelectionOverlay`.
/// 2. Captures consecutive frames while scrolling (automatically via `CGEvent` scroll wheel when Accessibility is granted,
///    or sampling as the user scrolls when Accessibility is not granted).
/// 3. Stitches frames vertically via `RustCoreClient.stitchScrollingPNGFrames` (exact ShareX scanline row matcher).
@MainActor
public final class ScrollingCaptureController {
    public static let shared = ScrollingCaptureController()
    private init() {}

    public func performScrollingCapture(
        settings: TaskSettings,
        maxFrames: Int = 10,
        scrollDelayMs: UInt64 = 320
    ) async throws -> CapturedFrame {
        let outcome = await RegionSelectionOverlay.shared.selectRegion(allowWindowSnap: true)
        let targetRect: CGRect
        var meta = CaptureMetadata()

        switch outcome {
        case .cancelled:
            throw CaptureError.cancelled
        case .window(let win):
            targetRect = win.quartzBounds
            meta = CaptureMetadata(window_title: win.title, process_name: win.ownerName)
        case .region(let rect, let win):
            targetRect = rect
            meta = CaptureMetadata(window_title: win?.title, process_name: win?.ownerName)
        }

        // Allow overlay to dismiss cleanly before first frame
        try await Task.sleep(nanoseconds: 180_000_000)

        let canAutoScroll = AXIsProcessTrusted()
        var capturedPNGs: [Data] = []
        var previousPNG: Data? = nil

        for step in 0..<maxFrames {
            let frame = try await ScreenCaptureService.shared.captureQuartzRegion(
                targetRect,
                metadata: meta,
                settings: settings
            )

            if let prev = previousPNG, prev == frame.pngData, step > 1 {
                // Reached bottom of scrollable area (`CompareLastTwoImages`)
                break
            }

            capturedPNGs.append(frame.pngData)
            previousPNG = frame.pngData

            if step + 1 < maxFrames {
                if canAutoScroll {
                    postScrollWheel(atQuartzCenter: CGPoint(x: targetRect.midX, y: targetRect.midY), deltaLines: -5)
                }
                try await Task.sleep(nanoseconds: scrollDelayMs * 1_000_000)
            }
        }

        let stitchedPNG = try await Task.detached(priority: .userInitiated) {
            try RustCoreClient.stitchScrollingPNGFrames(capturedPNGs, autoIgnoreBottom: true)
        }.value

        guard let nsImg = NSImage(data: stitchedPNG),
              let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CaptureError.captureFailed("Failed to decode stitched scrolling image")
        }

        return CapturedFrame(
            cgImage: cgImg,
            pngData: stitchedPNG,
            metadata: CaptureMetadata(
                window_title: meta.window_title,
                process_name: meta.process_name,
                width: UInt32(cgImg.width),
                height: UInt32(cgImg.height)
            ),
            quartzRect: targetRect
        )
    }

    private func postScrollWheel(atQuartzCenter point: CGPoint, deltaLines: Int32) {
        // Move cursor subtly or post wheel event at current focus
        _ = point
        if let wheel = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: deltaLines,
            wheel2: 0,
            wheel3: 0
        ) {
            wheel.post(tap: .cghidEventTap)
        }
    }
}
