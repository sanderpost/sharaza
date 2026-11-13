import CoreGraphics
import Foundation
import Vision

public struct OCRResultPayload: Sendable, Equatable {
    public let fullText: String
    public let lineCount: Int
    public let averageConfidence: Float
}

/// Native Apple `Vision` framework OCR (`VNRecognizeTextRequest`) and QR/Barcode decoder (`VNDetectBarcodesRequest`).
public enum VisionService {
    public static func recognizeText(in cgImage: CGImage, languages: [String] = ["en-US"]) throws -> OCRResultPayload {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        var lines: [String] = []
        var confidenceSum: Float = 0

        // Sort top-to-bottom (Vision normalized origin is bottom-left, so higher minY is higher on page)
        let sorted = observations.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        for obs in sorted {
            if let top = obs.topCandidates(1).first {
                lines.append(top.string)
                confidenceSum += top.confidence
            }
        }

        let avg = sorted.isEmpty ? 0 : (confidenceSum / Float(sorted.count))
        return OCRResultPayload(
            fullText: lines.joined(separator: "\n"),
            lineCount: lines.count,
            averageConfidence: avg
        )
    }

    public static func decodeQRAndBarcodes(in cgImage: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let results = request.results ?? []
        return results.compactMap(\.payloadStringValue).filter { !$0.isEmpty }
    }
}
