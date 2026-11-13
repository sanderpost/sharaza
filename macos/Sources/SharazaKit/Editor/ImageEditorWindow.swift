import AppKit
import SwiftUI

@MainActor
public final class ImageEditorViewModel: ObservableObject {
    @Published public var baseCGImage: CGImage
    @Published public var annotations: [AnnotationItem] = []
    @Published public var undoStack: [[AnnotationItem]] = []
    @Published public var redoStack: [[AnnotationItem]] = []
    @Published public var selectedTool: EditorTool = .arrow
    @Published public var activeColor: RGBAColor = .red
    @Published public var strokeWidth: CGFloat = 4.0
    @Published public var filledShapes: Bool = false
    @Published public var fontSize: CGFloat = 24.0
    @Published public var textInput: String = "Note"
    @Published public var effectIntensity: CGFloat = 14.0
    @Published public var nextStepNumber: Int = 1
    @Published public var selectedAnnotationID: UUID?
    @Published public var activeDraft: AnnotationItem?

    public let onCommit: (Data) -> Void
    public let onCancel: () -> Void

    public init(
        cgImage: CGImage,
        onCommit: @escaping (Data) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.baseCGImage = cgImage
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    public var renderedPreview: NSImage {
        var all = annotations
        if let draft = activeDraft {
            all.append(draft)
        }
        let cg = AnnotationRenderer.render(baseImage: baseCGImage, annotations: all)
        return NSImage.fromCGImage(cg)
    }

    public func pushUndoSnapshot() {
        undoStack.append(annotations)
        redoStack.removeAll()
    }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = prev
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
    }

    public func clearAll() {
        guard !annotations.isEmpty else { return }
        pushUndoSnapshot()
        annotations.removeAll()
        nextStepNumber = 1
    }

    public func applyBeautifier() {
        let flattened = AnnotationRenderer.render(baseImage: baseCGImage, annotations: annotations)
        guard let png = flattened.pngData(),
              let beautifiedPNG = try? RustCoreClient.beautifyPNG(png),
              let nsImg = NSImage(data: beautifiedPNG),
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        pushUndoSnapshot()
        annotations.removeAll()
        baseCGImage = cg
    }

    public func flattenPNGData() -> Data? {
        let cg = AnnotationRenderer.render(baseImage: baseCGImage, annotations: annotations)
        return cg.pngData()
    }

    public func copyFlattenedToClipboard() {
        if let data = flattenPNGData() {
            ClipboardService.copyPNGData(data)
        }
    }

    public func saveAsDialog() {
        guard let data = flattenPNGData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "annotated.png"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }
}

/// Native SwiftUI + AppKit Image Editor window (`ShareX.ImageEditor` macOS reconstruction).
@MainActor
public final class ImageEditorWindowController {
    public static let shared = ImageEditorWindowController()
    private var openWindows: [UUID: NSWindow] = [:]

    private init() {}

    /// Opens the interactive Image Editor as an async workflow step (`AfterCaptureTasks.AnnotateImage`),
    /// returning edited PNG bytes when user clicks "Done", or `nil` if cancelled.
    public func editImageModalWorkflow(cgImage: CGImage) async -> Data? {
        await withCheckedContinuation { cont in
            let winID = UUID()
            var resumed = false

            let finish: (Data?) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                if let win = self?.openWindows.removeValue(forKey: winID) {
                    win.close()
                }
                cont.resume(returning: result)
            }

            let vm = ImageEditorViewModel(
                cgImage: cgImage,
                onCommit: { png in finish(png) },
                onCancel: { finish(nil) }
            )

            let view = ImageEditorRootView(vm: vm)
            let hosting = NSHostingController(rootView: view)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Sharaza Image Editor"
            win.contentViewController = hosting
            win.center()
            win.isReleasedWhenClosed = false
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: win,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    finish(nil)
                }
            }
            openWindows[winID] = win
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func openStandaloneEditor(cgImage: CGImage, onSaved: @escaping (Data) -> Void) {
        Task { @MainActor in
            if let edited = await editImageModalWorkflow(cgImage: cgImage) {
                onSaved(edited)
            }
        }
    }
}

public struct ImageEditorRootView: View {
    @ObservedObject var vm: ImageEditorViewModel

    private let palette: [RGBAColor] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black,
    ]

    public init(vm: ImageEditorViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Tool Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(EditorTool.allCases) { tool in
                        Button {
                            vm.selectedTool = tool
                        } label: {
                            Label(tool.rawValue, systemImage: tool.systemSymbol)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(vm.selectedTool == tool ? Color.accentColor.opacity(0.22) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().frame(height: 22)

                    Button { vm.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(vm.undoStack.isEmpty)
                        .help("Undo (⌘Z)")
                    Button { vm.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(vm.redoStack.isEmpty)
                        .help("Redo (⇧⌘Z)")
                    Button { vm.clearAll() } label: { Image(systemName: "trash") }
                        .disabled(vm.annotations.isEmpty)
                        .help("Clear annotations")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)

            Divider()

            // Secondary Style Options Bar
            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    ForEach(Array(palette.enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(Color(nsColor: color.nsColor))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(vm.activeColor == color ? Color.primary : Color.secondary.opacity(0.4), lineWidth: vm.activeColor == color ? 2.5 : 1)
                            )
                            .onTapGesture { vm.activeColor = color }
                    }
                }

                Divider().frame(height: 18)

                HStack(spacing: 6) {
                    Text("Stroke")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $vm.strokeWidth, in: 1...16)
                        .frame(width: 90)
                    Text("\(Int(vm.strokeWidth))px")
                        .font(.caption.monospacedDigit())
                }

                if vm.selectedTool == .rectangle || vm.selectedTool == .ellipse {
                    Toggle("Fill", isOn: $vm.filledShapes)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                if vm.selectedTool == .text || vm.selectedTool == .speechBalloon {
                    TextField("Annotation text…", text: $vm.textInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }

                if vm.selectedTool == .blur || vm.selectedTool == .pixelate {
                    HStack(spacing: 6) {
                        Text("Strength")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $vm.effectIntensity, in: 4...40)
                            .frame(width: 90)
                    }
                }

                Spacer()

                Button {
                    vm.applyBeautifier()
                } label: {
                    Label("Beautify", systemImage: "wand.and.stars")
                }

                Button {
                    vm.copyFlattenedToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    vm.saveAsDialog()
                } label: {
                    Label("Save As…", systemImage: "square.and.arrow.down")
                }

                Button("Cancel") {
                    vm.onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Done") {
                    if let png = vm.flattenPNGData() {
                        vm.onCommit(png)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            // Interactive Canvas
            GeometryReader { geo in
                let imgW = CGFloat(vm.baseCGImage.width)
                let imgH = CGFloat(vm.baseCGImage.height)
                let scale = min(
                    max(0.05, (geo.size.width - 32) / max(1, imgW)),
                    max(0.05, (geo.size.height - 32) / max(1, imgH)),
                    1.0
                )
                let dispW = imgW * scale
                let dispH = imgH * scale

                ZStack {
                    Color(nsColor: .underPageBackgroundColor)

                    Image(nsImage: vm.renderedPreview)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: dispW, height: dispH)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let px = CGPoint(
                                        x: (value.location.x / scale).clamped(to: 0...imgW),
                                        y: (value.location.y / scale).clamped(to: 0...imgH)
                                    )
                                    let startPx = CGPoint(
                                        x: (value.startLocation.x / scale).clamped(to: 0...imgW),
                                        y: (value.startLocation.y / scale).clamped(to: 0...imgH)
                                    )
                                    handleCanvasDrag(start: startPx, current: px)
                                }
                                .onEnded { value in
                                    let px = CGPoint(
                                        x: (value.location.x / scale).clamped(to: 0...imgW),
                                        y: (value.location.y / scale).clamped(to: 0...imgH)
                                    )
                                    let startPx = CGPoint(
                                        x: (value.startLocation.x / scale).clamped(to: 0...imgW),
                                        y: (value.startLocation.y / scale).clamped(to: 0...imgH)
                                    )
                                    handleCanvasEnd(start: startPx, end: px)
                                }
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handleCanvasDrag(start: CGPoint, current: CGPoint) {
        switch vm.selectedTool {
        case .select:
            if vm.selectedAnnotationID == nil {
                vm.selectedAnnotationID = vm.annotations.last(where: {
                    $0.boundingRect.insetBy(dx: -14, dy: -14).contains(start)
                })?.id
                if vm.selectedAnnotationID != nil {
                    vm.pushUndoSnapshot()
                }
            }
            if let id = vm.selectedAnnotationID,
               let idx = vm.annotations.firstIndex(where: { $0.id == id }) {
                let prev = vm.activeDraft?.endPoint ?? start
                vm.annotations[idx].translate(dx: current.x - prev.x, dy: current.y - prev.y)
                vm.activeDraft = AnnotationItem(tool: .select, startPoint: start, endPoint: current)
            }

        case .freehand:
            if var draft = vm.activeDraft {
                draft.freehandPoints.append(current)
                draft.endPoint = current
                vm.activeDraft = draft
            } else {
                vm.activeDraft = AnnotationItem(
                    tool: .freehand,
                    startPoint: start,
                    endPoint: current,
                    freehandPoints: [start, current],
                    color: vm.activeColor,
                    strokeWidth: vm.strokeWidth
                )
            }

        case .stepNumber, .text:
            vm.activeDraft = AnnotationItem(
                tool: vm.selectedTool,
                startPoint: current,
                endPoint: current,
                color: vm.activeColor,
                strokeWidth: vm.strokeWidth,
                text: vm.textInput,
                fontSize: vm.fontSize,
                stepValue: vm.nextStepNumber
            )

        default:
            vm.activeDraft = AnnotationItem(
                tool: vm.selectedTool,
                startPoint: start,
                endPoint: current,
                color: vm.activeColor,
                strokeWidth: vm.strokeWidth,
                filled: vm.filledShapes,
                text: vm.textInput,
                fontSize: vm.fontSize,
                stepValue: vm.nextStepNumber,
                effectIntensity: vm.effectIntensity
            )
        }
    }

    private func handleCanvasEnd(start: CGPoint, end: CGPoint) {
        defer {
            vm.activeDraft = nil
            vm.selectedAnnotationID = nil
        }

        if vm.selectedTool == .select {
            return
        }

        if vm.selectedTool == .stepNumber {
            vm.pushUndoSnapshot()
            let item = AnnotationItem(
                tool: .stepNumber,
                startPoint: end,
                endPoint: end,
                color: vm.activeColor,
                fontSize: vm.fontSize,
                stepValue: vm.nextStepNumber
            )
            vm.annotations.append(item)
            vm.nextStepNumber += 1
            return
        }

        if vm.selectedTool == .text {
            vm.pushUndoSnapshot()
            let item = AnnotationItem(
                tool: .text,
                startPoint: end,
                endPoint: end,
                color: vm.activeColor,
                text: vm.textInput,
                fontSize: vm.fontSize
            )
            vm.annotations.append(item)
            return
        }

        guard let draft = vm.activeDraft else { return }

        if vm.selectedTool == .crop {
            let cropped = AnnotationRenderer.render(baseImage: vm.baseCGImage, annotations: vm.annotations + [draft])
            vm.pushUndoSnapshot()
            vm.annotations.removeAll()
            vm.baseCGImage = cropped
            return
        }

        if draft.tool == .freehand || hypot(end.x - start.x, end.y - start.y) >= 3 {
            vm.pushUndoSnapshot()
            vm.annotations.append(draft)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
