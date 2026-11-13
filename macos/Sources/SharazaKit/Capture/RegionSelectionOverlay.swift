import AppKit
import CoreGraphics
import Foundation

public enum RegionSelectionOutcome: Sendable {
    case region(quartzRect: CGRect, hoveredWindow: DesktopWindowInfo?)
    case window(DesktopWindowInfo)
    case cancelled
}

/// AppKit multi-monitor precision region selection overlay reconstructing `ShareX.ScreenCaptureLib`:
/// - Covers every connected `NSScreen` at `.screenSaver` window level
/// - Live foreign window hover detection & click-to-snap (`DetectWindows`)
/// - Precision crosshair, dimensions HUD, and 15×15 pixel-grid magnifier loupe with live RGB & `#HEX` readout
/// - Escape / Right-click cancel
@MainActor
public final class RegionSelectionOverlay {
    public static let shared = RegionSelectionOverlay()
    private var activePanels: [OverlayPanel] = []
    private var canvasViews: [RegionSelectionCanvasView] = []
    private var continuation: CheckedContinuation<RegionSelectionOutcome, Never>?
    private var keyMonitor: Any?
    private var mouseMoveMonitor: Any?

    private init() {}

    public func selectRegion(allowWindowSnap: Bool = true) async -> RegionSelectionOutcome {
        if continuation != nil {
            cancel()
        }

        let windows = allowWindowSnap ? WindowInspector.listApplicationWindows() : []

        // Pre-capture each screen backdrop so pixels under the magnifier & frozen screen are exact
        var backdrops: [NSScreen: CGImage] = [:]
        for screen in NSScreen.screens {
            let qRect = ScreenCoordinates.appKitToQuartz(screen.frame)
            if let img = try? await captureBackdropForScreen(quartzRect: qRect, scale: screen.backingScaleFactor) {
                backdrops[screen] = img
            }
        }

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.presentPanels(windows: windows, backdrops: backdrops, allowWindowSnap: allowWindowSnap)
        }
    }

    private func captureBackdropForScreen(quartzRect: CGRect, scale: CGFloat) async throws -> CGImage? {
        // Fast single-display snapshot via ScreenCaptureKit
        let dummy = TaskSettings(
            description: "", capture_type: .Region, after_capture_tasks: 0, after_upload_tasks: 0,
            screenshot_delay_ms: 0, capture_cursor: false, capture_shadow: false, capture_transparent: false,
            screenshots_folder: "", sub_folder_pattern: "", name_pattern: "", name_pattern_window: "",
            max_name_length: 100, max_title_length: 50, image_format: .PNG, jpeg_quality: 90,
            file_exist_action: .UniqueName, thumbnail_width: 200, thumbnail_height: 0, thumbnail_name_suffix: "",
            image_effects: ImageEffectsConfig(), image_uploader: .Imgur, text_uploader: .GitHubGist,
            file_uploader: .ZeroXZero, url_shortener: .IsGd, url_sharing_service: .Reddit,
            custom_uploader_name: nil, result_force_https: false, url_regex_replace_enabled: false,
            url_regex_pattern: "", url_regex_replacement: "", auto_shorten_url_length: 0,
            clipboard_content_format: "", open_url_format: "", max_upload_retries: 0,
            recording_fps: 30, recording_gif_fps: 15, recording_bitrate: 8_000_000,
            recording_system_audio: false, recording_microphone: false,
            show_toast_notification: false, play_sound_after_capture: false, external_actions: []
        )
        return try? await ScreenCaptureService.shared.captureQuartzRegion(quartzRect, settings: dummy).cgImage
    }

    private func presentPanels(
        windows: [DesktopWindowInfo],
        backdrops: [NSScreen: CGImage],
        allowWindowSnap: Bool
    ) {
        NSCursor.crosshair.push()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.finish(with: .cancelled)
                return nil
            }
            return event
        }

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.syncCursorAcrossScreens()
            return event
        }

        // Activate app BEFORE ordering overlay panels key so MainWorkspaceView never steals key focus back
        NSApp.activate(ignoringOtherApps: true)

        let mouseGlobal = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseGlobal, $0.frame, false) }) ?? NSScreen.main

        var keyTarget: (OverlayPanel, RegionSelectionCanvasView)?

        for screen in NSScreen.screens {
            let panel = OverlayPanel(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let view = RegionSelectionCanvasView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                screen: screen,
                backdrop: backdrops[screen],
                candidateWindows: windows,
                allowWindowSnap: allowWindowSnap,
                onComplete: { [weak self] outcome in
                    self?.finish(with: outcome)
                }
            )
            panel.contentView = view
            activePanels.append(panel)
            canvasViews.append(view)

            if screen == activeScreen {
                keyTarget = (panel, view)
            } else {
                panel.orderFrontRegardless()
            }
        }

        if let (panel, view) = keyTarget ?? activePanels.first.flatMap({ p in canvasViews.first.map { (p, $0) } }) {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            DispatchQueue.main.async {
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(view)
            }
        }
    }

    private func syncCursorAcrossScreens() {
        let globalPt = NSEvent.mouseLocation
        for (idx, view) in canvasViews.enumerated() {
            let wasInside = view.cursorIsInsideScreen
            view.updateFromGlobalCursor(globalPt)
            if view.cursorIsInsideScreen && !wasInside, activePanels.indices.contains(idx) {
                activePanels[idx].makeKey()
                activePanels[idx].makeFirstResponder(view)
            }
        }
    }

    public func cancel() {
        finish(with: .cancelled)
    }

    private func finish(with outcome: RegionSelectionOutcome) {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let moveMon = mouseMoveMonitor {
            NSEvent.removeMonitor(moveMon)
            mouseMoveMonitor = nil
        }
        NSCursor.pop()
        for panel in activePanels {
            panel.orderOut(nil)
            panel.close()
        }
        activePanels.removeAll()
        canvasViews.removeAll()

        if let cont = continuation {
            continuation = nil
            cont.resume(returning: outcome)
        }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class RegionSelectionCanvasView: NSView {
    private let screen: NSScreen
    private let backdrop: CGImage?
    private let candidateWindows: [DesktopWindowInfo]
    private let allowWindowSnap: Bool
    private let onComplete: (RegionSelectionOutcome) -> Void

    private var mouseInView: CGPoint = .zero
    private(set) var cursorIsInsideScreen: Bool = false
    private var dragStartInView: CGPoint?
    private var currentDragRectInView: CGRect?
    private var hoveredWindow: DesktopWindowInfo?
    private var trackingAreaRef: NSTrackingArea?

    init(
        frame: NSRect,
        screen: NSScreen,
        backdrop: CGImage?,
        candidateWindows: [DesktopWindowInfo],
        allowWindowSnap: Bool,
        onComplete: @escaping (RegionSelectionOutcome) -> Void
    ) {
        self.screen = screen
        self.backdrop = backdrop
        self.candidateWindows = candidateWindows
        self.allowWindowSnap = allowWindowSnap
        self.onComplete = onComplete
        super.init(frame: frame)
        updateFromGlobalCursor(NSEvent.mouseLocation)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Critical AppKit override: ensures the very first click/drag immediately starts region selection
    /// rather than being swallowed by macOS purely to focus/activate the overlay panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateFromGlobalCursor(_ globalAppKitPt: CGPoint) {
        let inside = NSMouseInRect(globalAppKitPt, screen.frame, false)
        cursorIsInsideScreen = inside
        guard inside else {
            if hoveredWindow != nil && dragStartInView == nil {
                hoveredWindow = nil
                needsDisplay = true
            }
            return
        }
        mouseInView = CGPoint(
            x: globalAppKitPt.x - screen.frame.minX,
            y: globalAppKitPt.y - screen.frame.minY
        )
        if allowWindowSnap && dragStartInView == nil {
            let quartzPt = ScreenCoordinates.appKitPointToQuartz(globalAppKitPt)
            hoveredWindow = WindowInspector.windowAtQuartzPoint(quartzPt, windows: candidateWindows)
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete(.cancelled)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onComplete(.cancelled)
    }

    override func mouseMoved(with event: NSEvent) {
        cursorIsInsideScreen = true
        mouseInView = convert(event.locationInWindow, from: nil)
        if allowWindowSnap && dragStartInView == nil {
            let globalAppKit = CGPoint(
                x: screen.frame.minX + mouseInView.x,
                y: screen.frame.minY + mouseInView.y
            )
            let quartzPt = ScreenCoordinates.appKitPointToQuartz(globalAppKit)
            hoveredWindow = WindowInspector.windowAtQuartzPoint(quartzPt, windows: candidateWindows)
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        cursorIsInsideScreen = true
        window?.makeKey()
        let pt = convert(event.locationInWindow, from: nil)
        dragStartInView = pt
        mouseInView = pt
        currentDragRectInView = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursorIsInsideScreen = true
        let pt = convert(event.locationInWindow, from: nil)
        mouseInView = pt
        let start = dragStartInView ?? pt
        if dragStartInView == nil {
            dragStartInView = start
        }
        currentDragRectInView = CGRect(
            x: min(start.x, pt.x),
            y: min(start.y, pt.y),
            width: abs(pt.x - start.x),
            height: abs(pt.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        defer {
            dragStartInView = nil
            currentDragRectInView = nil
            needsDisplay = true
        }

        if let rect = currentDragRectInView, rect.width >= 5, rect.height >= 5 {
            let globalAppKit = CGRect(
                x: screen.frame.minX + rect.minX,
                y: screen.frame.minY + rect.minY,
                width: rect.width,
                height: rect.height
            )
            let quartzRect = ScreenCoordinates.appKitToQuartz(globalAppKit)
            onComplete(.region(quartzRect: quartzRect, hoveredWindow: hoveredWindow))
            return
        }

        // Single click without drag: snap to hovered window if available (`RegionCaptureOptions.QuickCapture`).
        // If no window is hovered (e.g., empty desktop or pure region mode), stay open rather than aborting;
        // Escape or Right-Click cancels explicitly.
        let globalEnd = CGPoint(x: screen.frame.minX + end.x, y: screen.frame.minY + end.y)
        let resolvedWin = hoveredWindow ?? (allowWindowSnap
            ? WindowInspector.windowAtQuartzPoint(ScreenCoordinates.appKitPointToQuartz(globalEnd), windows: candidateWindows)
            : nil)
        if allowWindowSnap, let win = resolvedWin {
            onComplete(.window(win))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let backdrop {
            ctx.draw(backdrop, in: bounds)
        }

        // Dim overlay (`BackgroundDimStrength` ~ 35%)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        // Active highlight rectangle (either dragged region or snapped window)
        let activeLocalRect: CGRect? = {
            if let drag = currentDragRectInView, drag.width >= 2, drag.height >= 2 {
                return drag
            }
            if let win = hoveredWindow {
                let globalAppKit = ScreenCoordinates.quartzToAppKit(win.quartzBounds)
                let local = CGRect(
                    x: globalAppKit.minX - screen.frame.minX,
                    y: globalAppKit.minY - screen.frame.minY,
                    width: globalAppKit.width,
                    height: globalAppKit.height
                )
                return local.intersection(bounds)
            }
            return nil
        }()

        if let sel = activeLocalRect, !sel.isNull, sel.width > 1, sel.height > 1 {
            // Reveal un-dimmed crisp region
            ctx.saveGState()
            if let backdrop {
                ctx.clip(to: sel)
                ctx.draw(backdrop, in: bounds)
            } else {
                ctx.setBlendMode(.clear)
                ctx.fill(sel)
            }
            ctx.restoreGState()

            // Selection border + dashed white inner accent
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(2.0)
            ctx.stroke(sel.insetBy(dx: -0.5, dy: -0.5))

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(sel.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()

            drawDimensionBadge(in: ctx, for: sel)
        }

        if cursorIsInsideScreen || dragStartInView != nil {
            // Fullscreen subtle crosshair lines
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: 0, y: mouseInView.y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: mouseInView.y))
            ctx.move(to: CGPoint(x: mouseInView.x, y: 0))
            ctx.addLine(to: CGPoint(x: mouseInView.x, y: bounds.height))
            ctx.strokePath()
            ctx.restoreGState()

            // 15×15 Pixel Magnifier Loupe + RGB/Hex HUD (`RegionCaptureOptions.MagnifierPixelCount = 15`)
            drawMagnifierLoupe(in: ctx, at: mouseInView)
        }
    }

    private func drawDimensionBadge(in ctx: CGContext, for sel: CGRect) {
        let scale = screen.backingScaleFactor
        let pxW = Int((sel.width * scale).rounded())
        let pxH = Int((sel.height * scale).rounded())
        var label = "\(pxW) × \(pxH) px"
        if currentDragRectInView == nil, let win = hoveredWindow, !win.ownerName.isEmpty {
            let suffix = win.title.isEmpty ? win.ownerName : "\(win.ownerName) — \(win.title)"
            label += "  •  \(suffix)"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let nsStr = NSString(string: label)
        let textSize = nsStr.size(withAttributes: attrs)
        let padX: CGFloat = 10
        let padY: CGFloat = 5
        var badgeY = sel.maxY + 8
        if badgeY + textSize.height + padY * 2 > bounds.maxY - 8 {
            badgeY = max(8, sel.minY - textSize.height - padY * 2 - 8)
        }
        let badgeRect = CGRect(
            x: max(8, min(sel.minX, bounds.maxX - textSize.width - padX * 2 - 8)),
            y: badgeY,
            width: textSize.width + padX * 2,
            height: textSize.height + padY * 2
        )

        let path = CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        nsStr.draw(at: CGPoint(x: badgeRect.minX + padX, y: badgeRect.minY + padY), withAttributes: attrs)
    }

    private func drawMagnifierLoupe(in ctx: CGContext, at cursor: CGPoint) {
        guard let backdrop else { return }
        let gridCount = 15 // Odd count matching ShareX default `MagnifierPixelCount = 15`
        let cellSize: CGFloat = 8
        let loupeSize = CGFloat(gridCount) * cellSize
        let hudHeight: CGFloat = 44

        var boxX = cursor.x + 22
        var boxY = cursor.y - loupeSize - hudHeight - 22
        if boxX + loupeSize + 12 > bounds.maxX {
            boxX = cursor.x - loupeSize - 22
        }
        if boxY < 12 {
            boxY = cursor.y + 22
        }

        let totalRect = CGRect(x: boxX, y: boxY, width: loupeSize, height: loupeSize + hudHeight)
        let loupeRect = CGRect(x: boxX, y: boxY + hudHeight, width: loupeSize, height: loupeSize)

        ctx.saveGState()
        let bgPath = CGPath(roundedRect: totalRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor(calibratedWhite: 0.1, alpha: 0.92).cgColor)
        ctx.fillPath()

        let scaleX = CGFloat(backdrop.width) / bounds.width
        let scaleY = CGFloat(backdrop.height) / bounds.height
        let imgX = Int((cursor.x * scaleX).rounded())
        // CGImage row 0 is at top; AppKit view y=0 is at bottom
        let imgY = Int(((bounds.height - cursor.y) * scaleY).rounded())
        let half = gridCount / 2

        let cropRect = CGRect(
            x: max(0, imgX - half),
            y: max(0, imgY - half),
            width: gridCount,
            height: gridCount
        )
        if let subImg = backdrop.cropping(to: cropRect) {
            ctx.saveGState()
            ctx.clip(to: loupeRect)
            ctx.interpolationQuality = .none
            ctx.draw(subImg, in: loupeRect)
            ctx.restoreGState()
        }

        // Pixel grid lines + center pixel highlight
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        for i in 0...gridCount {
            let offset = CGFloat(i) * cellSize
            ctx.move(to: CGPoint(x: loupeRect.minX + offset, y: loupeRect.minY))
            ctx.addLine(to: CGPoint(x: loupeRect.minX + offset, y: loupeRect.maxY))
            ctx.move(to: CGPoint(x: loupeRect.minX, y: loupeRect.minY + offset))
            ctx.addLine(to: CGPoint(x: loupeRect.maxX, y: loupeRect.minY + offset))
        }
        ctx.strokePath()

        let centerCell = CGRect(
            x: loupeRect.minX + CGFloat(half) * cellSize,
            y: loupeRect.minY + CGFloat(half) * cellSize,
            width: cellSize,
            height: cellSize
        )
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerCell)

        ctx.addPath(bgPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()
        ctx.restoreGState()

        // Sample exact center pixel RGB
        let (r, g, b) = samplePixelRGB(from: backdrop, x: imgX, y: imgY)
        let hex = String(format: "#%02X%02X%02X", r, g, b)
        let coordText = "X:\(imgX) Y:\(imgY)\n\(hex) (\(r),\(g),\(b))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        NSString(string: coordText).draw(
            in: CGRect(x: boxX + 6, y: boxY + 4, width: loupeSize - 12, height: hudHeight - 8),
            withAttributes: attrs
        )
    }

    private func samplePixelRGB(from image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let cx = max(0, min(image.width - 1, x))
        let cy = max(0, min(image.height - 1, y))
        guard let single = image.cropping(to: CGRect(x: cx, y: cy, width: 1, height: 1)) else {
            return (0, 0, 0)
        }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: &pixel,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 4,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return (0, 0, 0)
        }
        ctx.draw(single, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }
}
