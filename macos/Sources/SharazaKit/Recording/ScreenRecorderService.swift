import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public enum GifEncoder {
    /// Encodes a sequence of `CGImage` frames into a looping animated `.gif` with ShareX-compliant >=10ms frame delay.
    public static func encodeGIF(frames: [CGImage], fps: Int, to outputURL: URL) throws {
        guard !frames.isEmpty else {
            throw CaptureError.captureFailed("No frames captured for GIF")
        }
        let clampedFPS = max(1, min(100, fps))
        let delaySeconds = max(0.01, 1.0 / Double(clampedFPS))

        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw CaptureError.captureFailed("Could not create GIF destination at \(outputURL.path)")
        }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0
            ]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delaySeconds,
                kCGImagePropertyGIFUnclampedDelayTime: delaySeconds,
            ]
        ]

        for frame in frames {
            CGImageDestinationAddImage(dest, frame, frameProps as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else {
            throw CaptureError.captureFailed("Failed to finalize animated GIF")
        }
    }
}

public enum RecordingTarget {
    case fullscreen
    case window(DesktopWindowInfo)
    case region(CGRect)
}

/// Native `ScreenCaptureKit` (`SCStream`) + `AVAssetWriter` (H.264/AAC MP4) & `ImageIO` (Animated GIF)
/// screen recorder reconstructing `ShareX.ScreenRecordingLib.ScreenRecorder`.
@MainActor
public final class ScreenRecorderService: NSObject, ObservableObject {
    public static let shared = ScreenRecorderService()

    @Published public private(set) var isRecording: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public private(set) var isGifMode: Bool = false
    @Published public private(set) var elapsedSeconds: Int = 0

    private var stream: SCStream?
    private var outputDelegate: StreamSampleCollector?
    private var outputURL: URL?
    private var timer: Timer?
    private var activeSettings: TaskSettings?
    public var onRecordingFinalized: ((URL, Bool, TaskSettings) -> Void)?

    private override init() {
        super.init()
    }

    public func startRecording(
        target: RecordingTarget,
        isGif: Bool,
        outputDirectory: URL,
        fileNameStem: String,
        settings: TaskSettings
    ) async throws {
        guard !isRecording else { return }
        guard await PermissionsManager.shared.ensureScreenRecordingAccess() else {
            throw CaptureError.permissionDenied
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let ext = isGif ? "gif" : "mp4"
        let destURL = outputDirectory.appendingPathComponent("\(fileNameStem).\(ext)")
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int
        var sourceRect: CGRect? = nil

        switch target {
        case .window(let winInfo):
            guard let scWin = shareable.windows.first(where: { $0.windowID == winInfo.windowID }) else {
                throw CaptureError.noWindowFound
            }
            filter = SCContentFilter(desktopIndependentWindow: scWin)
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            pixelWidth = max(2, Int((scWin.frame.width * scale).rounded()) & ~1)
            pixelHeight = max(2, Int((scWin.frame.height * scale).rounded()) & ~1)

        case .region(let quartzRect):
            let center = CGPoint(x: quartzRect.midX, y: quartzRect.midY)
            guard let display = shareable.displays.first(where: { $0.frame.contains(center) }) ?? shareable.displays.first else {
                throw CaptureError.noDisplayFound
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let excluded = shareable.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let clipped = quartzRect.intersection(display.frame)
            let local = CGRect(
                x: clipped.minX - display.frame.minX,
                y: clipped.minY - display.frame.minY,
                width: clipped.width,
                height: clipped.height
            )
            sourceRect = local
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            pixelWidth = max(2, Int((local.width * scale).rounded()) & ~1)
            pixelHeight = max(2, Int((local.height * scale).rounded()) & ~1)

        case .fullscreen:
            guard let display = shareable.displays.first else {
                throw CaptureError.noDisplayFound
            }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let excluded = shareable.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            pixelWidth = max(2, Int((display.frame.width * scale).rounded()) & ~1)
            pixelHeight = max(2, Int((display.frame.height * scale).rounded()) & ~1)
        }

        let fps = isGif
            ? Int(max(1, min(30, settings.recording_gif_fps)))
            : Int(max(1, min(120, settings.recording_fps)))

        let config = SCStreamConfiguration()
        config.width = isGif ? min(pixelWidth, 1280) & ~1 : pixelWidth
        config.height = isGif
            ? max(2, Int(Double(pixelHeight) * (Double(min(pixelWidth, 1280)) / Double(max(1, pixelWidth)))) & ~1)
            : pixelHeight
        if let sr = sourceRect {
            config.sourceRect = sr
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = settings.capture_cursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let wantAudio = !isGif && (settings.recording_system_audio || settings.recording_microphone)
        config.capturesAudio = !isGif && settings.recording_system_audio
        if #available(macOS 15.0, *), !isGif && settings.recording_microphone {
            config.captureMicrophone = true
        }

        let collector = try StreamSampleCollector(
            outputURL: destURL,
            isGif: isGif,
            width: config.width,
            height: config.height,
            fps: fps,
            bitrate: Int(settings.recording_bitrate),
            recordAudio: wantAudio
        )

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        let sampleQueue = DispatchQueue(label: "app.sharaza.recorder.samples", qos: .userInitiated)
        try scStream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: sampleQueue)
        if !isGif && settings.recording_system_audio {
            try? scStream.addStreamOutput(collector, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if #available(macOS 15.0, *), !isGif && settings.recording_microphone && !settings.recording_system_audio {
            try? scStream.addStreamOutput(collector, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        try await scStream.startCapture()

        self.stream = scStream
        self.outputDelegate = collector
        self.outputURL = destURL
        self.activeSettings = settings
        self.isGifMode = isGif
        self.isRecording = true
        self.isPaused = false
        self.elapsedSeconds = 0

        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPaused else { return }
                self.elapsedSeconds += 1
            }
        }

        RecordingControlBarController.shared.show(
            isGif: isGif,
            onTogglePause: { [weak self] in
                self?.togglePause()
            },
            onStop: { [weak self] in
                Task { @MainActor in await self?.stopRecording() }
            },
            onAbort: { [weak self] in
                Task { @MainActor in await self?.abortRecording() }
            }
        )
    }

    public func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        outputDelegate?.setPaused(isPaused)
    }

    public func stopRecording() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        RecordingControlBarController.shared.hide()

        let currentStream = stream
        let collector = outputDelegate
        let url = outputURL
        let gif = isGifMode
        let settings = activeSettings

        stream = nil
        outputDelegate = nil
        outputURL = nil
        activeSettings = nil
        isRecording = false

        if let currentStream {
            try? await currentStream.stopCapture()
        }
        if let collector {
            await collector.finishWriting()
        }
        if let url, let settings, FileManager.default.fileExists(atPath: url.path) {
            onRecordingFinalized?(url, gif, settings)
        }
    }

    public func abortRecording() async {
        guard isRecording else { return }
        timer?.invalidate()
        timer = nil
        RecordingControlBarController.shared.hide()

        let currentStream = stream
        let collector = outputDelegate
        let url = outputURL

        stream = nil
        outputDelegate = nil
        outputURL = nil
        activeSettings = nil
        isRecording = false

        if let currentStream {
            try? await currentStream.stopCapture()
        }
        collector?.cancelWriting()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

private final class StreamSampleCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let outputURL: URL
    private let isGif: Bool
    private let fps: Int
    private let ciContext = CIContext()

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var paused = false
    private var gifFrames: [CGImage] = []
    private let maxGifFrames = 600
    private let lock = NSLock()

    func setPaused(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        paused = value
    }

    init(
        outputURL: URL,
        isGif: Bool,
        width: Int,
        height: Int,
        fps: Int,
        bitrate: Int,
        recordAudio: Bool
    ) throws {
        self.outputURL = outputURL
        self.isGif = isGif
        self.fps = fps
        super.init()

        if !isGif {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            if writer.canAdd(vInput) {
                writer.add(vInput)
            }
            self.videoInput = vInput

            if recordAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ]
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = true
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    self.audioInput = aInput
                }
            }
            self.assetWriter = writer
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        lock.lock()
        defer { lock.unlock() }
        if paused { return }

        if isGif {
            guard outputType == .screen,
                  gifFrames.count < maxGifFrames,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            let ciImg = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImg = ciContext.createCGImage(ciImg, from: ciImg.extent) {
                gifFrames.append(cgImg)
            }
            return
        }

        guard let writer = assetWriter else { return }

        switch outputType {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw),
                  status == .complete else {
                return
            }
            if !sessionStarted {
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            if writer.status == .writing, let vInput = videoInput, vInput.isReadyForMoreMediaData {
                vInput.append(sampleBuffer)
            }

        case .audio:
            if sessionStarted, writer.status == .writing, let aInput = audioInput, aInput.isReadyForMoreMediaData {
                aInput.append(sampleBuffer)
            }

        default:
            if #available(macOS 15.0, *), outputType == .microphone {
                if sessionStarted, writer.status == .writing, let aInput = audioInput, aInput.isReadyForMoreMediaData {
                    aInput.append(sampleBuffer)
                }
            }
        }
    }

    private func markInputsFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let started = sessionStarted
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        return started
    }

    private func drainGifFrames() -> [CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return gifFrames
    }

    func finishWriting() async {
        if isGif {
            let captured = drainGifFrames()
            try? GifEncoder.encodeGIF(frames: captured, fps: fps, to: outputURL)
            return
        }

        guard let writer = assetWriter else { return }
        let started = markInputsFinished()

        if started && writer.status == .writing {
            await writer.finishWriting()
        } else {
            writer.cancelWriting()
        }
    }

    func cancelWriting() {
        lock.lock()
        defer { lock.unlock() }
        gifFrames.removeAll()
        assetWriter?.cancelWriting()
    }
}
