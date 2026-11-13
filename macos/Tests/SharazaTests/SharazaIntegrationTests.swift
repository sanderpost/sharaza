import AppKit
import CoreGraphics
import ImageIO
@testable import SharazaKit
import XCTest

final class SharazaIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var core: RustCoreClient!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sharaza_swift_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        core = try RustCoreClient(dataDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        core = nil
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testConfigNamingPatternAndWorkflowPersistence() throws {
        var cfg = try core.loadConfig()
        XCTAssertTrue(cfg.hotkeys_enabled)
        XCTAssertFalse(cfg.hotkeys.isEmpty)

        let preview = try core.previewPattern(
            "%pn_%y-%mo-%d_%widthx%height_%i{4}",
            windowTitle: "Editor",
            processName: "Xcode",
            width: 3024,
            height: 1964
        )
        XCTAssertTrue(preview.hasPrefix("Xcode_"))
        XCTAssertTrue(preview.contains("_3024x1964_0042"), "Unexpected preview: \(preview)")

        cfg.default_settings.image_format = .WEBP
        try core.saveConfig(cfg)
        let reloaded = try core.loadConfig()
        XCTAssertEqual(reloaded.default_settings.image_format, .WEBP)

        let preset = WorkflowPreset(
            id: "preset-1",
            name: "Annotated WebP",
            settings: reloaded.default_settings
        )
        try core.saveWorkflow(preset)
        let presets = try core.listWorkflows()
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(presets[0].name, "Annotated WebP")
    }

    func testImageWorkflowBeautifierAndSQLiteHistoryRoundTrip() async throws {
        let baseCG = makeSolidCGImage(width: 200, height: 120, r: 40, g: 120, b: 220)
        let png = try XCTUnwrap(baseCG.pngData())

        var settings = try core.loadConfig().default_settings
        let capturesDir = tempDir.appendingPathComponent("Captures", isDirectory: true)
        settings.screenshots_folder = capturesDir.path
        settings.sub_folder_pattern = ""
        settings.name_pattern = "slice_%i{3}"
        settings.after_capture_tasks = AfterCaptureFlags([
            .beautifyImage,
            .copyImageToClipboard,
            .saveImageToFile,
            .saveThumbnailToFile,
        ]).rawValue

        let report = try await core.executeImageWorkflow(
            pngData: png,
            metadata: CaptureMetadata(window_title: "Cursor Window", process_name: "Cursor", width: 200, height: 120),
            settings: settings,
            credentials: ResolvedCredentials()
        )

        XCTAssertTrue(report.copy_image_to_clipboard)
        let savedPath = try XCTUnwrap(report.saved_file_path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedPath))
        let thumbPath = try XCTUnwrap(report.saved_thumbnail_path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbPath))

        let history = try await core.queryHistory(HistoryFilter(search_query: "Cursor"))
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].tags["ProcessName"], "Cursor")

        // Verify ShareX JSON History import compatibility
        let sharexJSON = """
        [{"FileName":"legacy.png","FilePath":"/tmp/legacy.png","DateTime":"2026-11-01T10:00:00Z","Type":"Image","Host":"Imgur","URL":"https://i.imgur.com/legacy.png"}]
        """
        let importedCount = try await core.importShareXHistory(jsonText: sharexJSON)
        XCTAssertEqual(importedCount, 1)

        let stats = try await core.historyStats()
        XCTAssertEqual(stats.total_count, 2)
        XCTAssertEqual(stats.uploaded_count, 1)
    }

    func testQRCodeGenerationAndAppleVisionBarcodeDecodingRoundTrip() throws {
        let expectedPayload = "https://github.com/ShareX/ShareX"
        let qrPNG = try RustCoreClient.generateQRCodePNG(text: expectedPayload, moduleSize: 10)
        let nsImg = try XCTUnwrap(NSImage(data: qrPNG))
        let cgImg = try XCTUnwrap(nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil))

        let decoded = try VisionService.decodeQRAndBarcodes(in: cgImg)
        XCTAssertEqual(decoded, [expectedPayload])
    }

    func testAnnotationRendererAndAppleVisionOCRRoundTrip() throws {
        let base = makeSolidCGImage(width: 640, height: 260, r: 248, g: 250, b: 252)

        let items: [AnnotationItem] = [
            AnnotationItem(
                tool: .text,
                startPoint: CGPoint(x: 40, y: 40),
                endPoint: CGPoint(x: 40, y: 40),
                color: .black,
                text: "SHARAZA MACOS PARITY",
                fontSize: 34
            ),
            AnnotationItem(
                tool: .arrow,
                startPoint: CGPoint(x: 60, y: 180),
                endPoint: CGPoint(x: 260, y: 140),
                color: .red,
                strokeWidth: 5
            ),
            AnnotationItem(
                tool: .stepNumber,
                startPoint: CGPoint(x: 340, y: 170),
                endPoint: CGPoint(x: 340, y: 170),
                color: .blue,
                fontSize: 24,
                stepValue: 1
            ),
            AnnotationItem(
                tool: .blur,
                startPoint: CGPoint(x: 430, y: 140),
                endPoint: CGPoint(x: 580, y: 220),
                effectIntensity: 12
            ),
            AnnotationItem(
                tool: .speechBalloon,
                startPoint: CGPoint(x: 380, y: 24),
                endPoint: CGPoint(x: 610, y: 110),
                color: .orange,
                text: "CALLOUT",
                fontSize: 20
            ),
            AnnotationItem(
                tool: .smartEraser,
                startPoint: CGPoint(x: 10, y: 220),
                endPoint: CGPoint(x: 80, y: 250)
            ),
            AnnotationItem(
                tool: .magnify,
                startPoint: CGPoint(x: 120, y: 140),
                endPoint: CGPoint(x: 200, y: 220),
                color: .green
            ),
        ]

        let rendered = AnnotationRenderer.render(baseImage: base, annotations: items)
        XCTAssertEqual(rendered.width, 640)
        XCTAssertEqual(rendered.height, 260)

        let ocr = try VisionService.recognizeText(in: rendered)
        XCTAssertTrue(
            ocr.fullText.uppercased().contains("SHARAZA"),
            "Expected Vision OCR to read rendered annotation text, got: '\(ocr.fullText)'"
        )

        // Verify crop tool trims dimensions accurately
        let cropItem = AnnotationItem(
            tool: .crop,
            startPoint: CGPoint(x: 20, y: 20),
            endPoint: CGPoint(x: 320, y: 140)
        )
        let cropped = AnnotationRenderer.render(baseImage: rendered, annotations: [cropItem])
        XCTAssertEqual(cropped.width, 300)
        XCTAssertEqual(cropped.height, 120)
    }

    func testAnimatedGifEncodingAndRecordingFinalization() async throws {
        let f1 = makeSolidCGImage(width: 160, height: 100, r: 220, g: 40, b: 40)
        let f2 = makeSolidCGImage(width: 160, height: 100, r: 40, g: 200, b: 80)
        let f3 = makeSolidCGImage(width: 160, height: 100, r: 40, g: 90, b: 230)

        let gifURL = tempDir.appendingPathComponent("demo_anim.gif")
        try GifEncoder.encodeGIF(frames: [f1, f2, f3], fps: 15, to: gifURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gifURL.path))

        let imgSrc = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(imgSrc), 3)

        let settings = try core.loadConfig().default_settings
        let rep = try await core.finalizeRecordingWorkflow(
            filePath: gifURL.path,
            isGif: true,
            settings: settings,
            credentials: ResolvedCredentials()
        )
        XCTAssertEqual(rep.file_name, "demo_anim.gif")
        XCTAssertNotNil(rep.history_item)
    }

    func testScrollingStitcherHashesColorAndCustomUploaderFFI() throws {
        // 1.Hashes & Color
        let hashes = try core.computeTextHashes(text: "ShareX")
        XCTAssertEqual(hashes.crc32, "3b4f8d0a")
        XCTAssertEqual(hashes.sha256, "7947880f6d8b6dec76c60782c85e6dedcae2b94ce5e8c6c6914dff2ffdb9e007")

        let color = try core.convertColor(r: 255, g: 87, b: 51)
        XCTAssertEqual(color.hex_upper, "#FF5733")

        // 2. Ruler geometry
        let m = RulerMeasurement.compute(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: 40), scale: 2.0)
        XCTAssertEqual(m.widthPx, 60.0)
        XCTAssertEqual(m.heightPx, 80.0)
        XCTAssertEqual(m.diagonalPx, 100.0)

        // 3. Custom uploader (.sxcu) persistence
        let sxcu = """
        {
          "Version": "22.4.0",
          "Name": "CustomSxcuTest",
          "DestinationType": "ImageUploader",
          "RequestMethod": "POST",
          "RequestURL": "https://example.org/upload",
          "Body": "MultipartFormData",
          "FileFormName": "file",
          "URL": "$json:url$"
        }
        """
        let saved = try core.saveCustomUploader(sxcuJSON: sxcu)
        XCTAssertEqual(saved.Name, "CustomSxcuTest")
        let all = try core.listCustomUploaders()
        XCTAssertEqual(all.count, 1)

        // 4. Scrolling Capture PNG Stitcher across C ABI
        let fullDoc = makePatternedCGImage(width: 240, height: 420)
        let vp1 = try XCTUnwrap(fullDoc.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 240))?.pngData())
        let vp2 = try XCTUnwrap(fullDoc.cropping(to: CGRect(x: 0, y: 180, width: 240, height: 240))?.pngData())
        let stitchedPNG = try RustCoreClient.stitchScrollingPNGFrames([vp1, vp2], autoIgnoreBottom: false)
        let stitchedNS = try XCTUnwrap(NSImage(data: stitchedPNG))
        let stitchedCG = try XCTUnwrap(stitchedNS.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(stitchedCG.width, 240)
        XCTAssertEqual(stitchedCG.height, 420)
    }

    private func makePatternedCGImage(width: Int, height: Int) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                pixels[idx] = UInt8((y * 11 + x * 3) % 251)
                pixels[idx + 1] = UInt8((y * 17 + x * 5) % 241)
                pixels[idx + 2] = UInt8((y * 23) % 239)
                pixels[idx + 3] = 255
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func makeSolidCGImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(
            CGColor(
                srgbRed: CGFloat(r) / 255.0,
                green: CGFloat(g) / 255.0,
                blue: CGFloat(b) / 255.0,
                alpha: 1.0
            )
        )
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
