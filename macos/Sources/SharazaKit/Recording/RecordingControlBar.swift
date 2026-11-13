import AppKit
import SwiftUI

/// Floating non-activating recording HUD reconstructing `ShareX.Presentation.ScreenRecording.ScreenRecorderBarWindow`.
@MainActor
public final class RecordingControlBarController {
    public static let shared = RecordingControlBarController()
    private var panel: NSPanel?

    private init() {}

    public func show(
        isGif: Bool,
        onTogglePause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onAbort: @escaping () -> Void
    ) {
        hide()

        let contentView = RecordingBarView(
            recorder: ScreenRecorderService.shared,
            isGif: isGif,
            onTogglePause: onTogglePause,
            onStop: onStop,
            onAbort: onAbort
        )
        let hosting = NSHostingView(rootView: contentView)
        let size = NSSize(width: 360, height: 46)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(
            x: screenFrame.midX - size.width * 0.5,
            y: screenFrame.maxY - size.height - 16
        )

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = hosting
        p.orderFrontRegardless()
        self.panel = p
    }

    public func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}

private struct RecordingBarView: View {
    @ObservedObject var recorder: ScreenRecorderService
    let isGif: Bool
    let onTogglePause: () -> Void
    let onStop: () -> Void
    let onAbort: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(recorder.isPaused ? Color.yellow : Color.red)
                .frame(width: 10, height: 10)

            Text(recorder.isPaused ? "PAUSED" : (isGif ? "GIF REC" : "MP4 REC"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)

            Text(formattedDuration(recorder.elapsedSeconds))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            Button(action: onTogglePause) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(recorder.isPaused ? "Resume recording" : "Pause recording")

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button(action: onAbort) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Abort recording without saving")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.86))
                .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
        )
    }

    private func formattedDuration(_ secs: Int) -> String {
        let m = secs / 60
        let s = secs % 60
        return String(format: "%02d:%02d", m, s)
    }
}
