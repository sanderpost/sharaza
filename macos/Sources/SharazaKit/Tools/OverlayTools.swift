import AppKit
import CoreGraphics
import SwiftUI

public struct RulerMeasurement: Sendable, Equatable {
    public let startPoint: CGPoint
    public let endPoint: CGPoint
    public let widthPx: Double
    public let heightPx: Double
    public let diagonalPx: Double
    public let angleDegrees: Double

    public static func compute(from start: CGPoint, to end: CGPoint, scale: Double = 1.0) -> RulerMeasurement {
        let dx = (end.x - start.x) * scale
        let dy = (end.y - start.y) * scale
        let w = abs(dx)
        let h = abs(dy)
        let diag = hypot(dx, dy)
        let deg = atan2(-dy, dx) * 180.0 / .pi
        return RulerMeasurement(
            startPoint: start,
            endPoint: end,
            widthPx: (w * 10).rounded() / 10,
            heightPx: (h * 10).rounded() / 10,
            diagonalPx: (diag * 10).rounded() / 10,
            angleDegrees: (deg * 10).rounded() / 10
        )
    }
}

/// Native macOS implementations of ShareX's desktop productivity overlays (`ShareX.Tools`):
/// 1. **Screen Color Picker** (`NSColorSampler` + `RustCoreClient.convertColor`)
/// 2. **Screen Ruler** (interactive pixel/angle measurement overlay)
/// 3. **Pin to Screen** (borderless always-on-top draggable/resizable floating image `NSPanel`)
@MainActor
public final class OverlayToolsController {
    public static let shared = OverlayToolsController()
    private var pinnedPanels: [UUID: NSPanel] = [:]
    private var rulerPanel: NSPanel?

    private init() {}

    // MARK: - Screen Color Picker

    public func pickScreenColor(core: RustCoreClient) async -> ColorFormats? {
        let formats: ColorFormats? = await withCheckedContinuation { cont in
            let sampler = NSColorSampler()
            sampler.show { selectedColor in
                guard let srgb = selectedColor?.usingColorSpace(.sRGB) else {
                    cont.resume(returning: nil)
                    return
                }
                let r = UInt8((srgb.redComponent * 255.0).rounded().clamped(to: 0...255))
                let g = UInt8((srgb.greenComponent * 255.0).rounded().clamped(to: 0...255))
                let b = UInt8((srgb.blueComponent * 255.0).rounded().clamped(to: 0...255))
                let a = UInt8((srgb.alphaComponent * 255.0).rounded().clamped(to: 0...255))
                cont.resume(returning: try? core.convertColor(r: r, g: g, b: b, a: a))
            }
        }
        if let hex = formats?.hex_upper {
            ClipboardService.copyText(hex)
        }
        return formats
    }

    // MARK: - Pin to Screen

    public func pinImageToScreen(_ nsImage: NSImage) {
        let id = UUID()
        let maxInitial: CGFloat = 520
        let rawSize = nsImage.size
        let ratio = min(1.0, maxInitial / max(1, max(rawSize.width, rawSize.height)))
        let winSize = NSSize(width: max(120, rawSize.width * ratio), height: max(80, rawSize.height * ratio))
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1280, height: 800)
        let origin = NSPoint(
            x: screenFrame.midX - winSize.width * 0.5,
            y: screenFrame.midY - winSize.height * 0.5
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: winSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = PinnedImagePanelView(
            image: nsImage,
            onCopy: { ClipboardService.copyImage(nsImage) },
            onClose: { [weak self] in
                if let p = self?.pinnedPanels.removeValue(forKey: id) {
                    p.orderOut(nil)
                    p.close()
                }
            }
        )
        panel.contentView = NSHostingView(rootView: rootView)
        pinnedPanels[id] = panel
        panel.orderFrontRegardless()
    }

    public func closeAllPinnedPanels() {
        for (_, panel) in pinnedPanels {
            panel.orderOut(nil)
            panel.close()
        }
        pinnedPanels.removeAll()
    }

    // MARK: - Interactive Screen Ruler

    public func showScreenRuler() {
        rulerPanel?.close()
        let mousePt = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mousePt, $0.frame, false) }) ?? NSScreen.main else { return }

        NSApp.activate(ignoringOtherApps: true)

        let panel = OverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true

        let view = ScreenRulerOverlayView(
            scale: screen.backingScaleFactor,
            onClose: { [weak self] in
                self?.rulerPanel?.orderOut(nil)
                self?.rulerPanel?.close()
                self?.rulerPanel = nil
            }
        )
        let hosting = FirstMouseHostingView(rootView: view)
        panel.contentView = hosting
        self.rulerPanel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
    }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PinnedImagePanelView: View {
    let image: NSImage
    let onCopy: () -> Void
    let onClose: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                )

            if hovered {
                HStack(spacing: 6) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(8)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy Image", action: onCopy)
            Divider()
            Button("Close Pin", role: .destructive, action: onClose)
        }
    }
}

private struct ScreenRulerOverlayView: View {
    let scale: Double
    let onClose: () -> Void

    @State private var startPt: CGPoint?
    @State private var currentPt: CGPoint?

    var measurement: RulerMeasurement? {
        guard let s = startPt, let c = currentPt else { return nil }
        return RulerMeasurement.compute(from: s, to: c, scale: scale)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            startPt = val.startLocation
                            currentPt = val.location
                        }
                )

            if let s = startPt, let c = currentPt, let m = measurement {
                Path { path in
                    path.move(to: s)
                    path.addLine(to: c)
                    path.addRect(
                        CGRect(
                            x: min(s.x, c.x),
                            y: min(s.y, c.y),
                            width: abs(c.x - s.x),
                            height: abs(c.y - s.y)
                        )
                    )
                }
                .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Ruler")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                    Text(String(format: "W: %.0f px   H: %.0f px", m.widthPx, m.heightPx))
                    Text(String(format: "Diagonal: %.1f px   Angle: %.1f°", m.diagonalPx, m.angleDegrees))
                    HStack {
                        Button("Copy Measurement") {
                            ClipboardService.copyText(
                                String(format: "%.0fx%.0f px (diag %.1f px, %.1f°)", m.widthPx, m.heightPx, m.diagonalPx, m.angleDegrees)
                            )
                        }
                        .controlSize(.small)
                        Button("Close (Esc)", action: onClose)
                            .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
                .position(x: (s.x + c.x) * 0.5, y: max(60, min(s.y, c.y) - 52))
            } else {
                VStack(spacing: 8) {
                    Text("Drag anywhere to measure pixels, diagonal distance & angle")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Button("Close Ruler", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.82)))
            }
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
