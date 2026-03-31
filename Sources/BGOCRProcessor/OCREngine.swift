import CoreGraphics
import Vision
import os

public protocol OCREngineProtocol: Sendable {
    func recognize(image: CGImage) async throws -> OCRResult
}

public struct OCREngine: OCREngineProtocol, Sendable {

    private static let logger = Logger(subsystem: "com.bgocrprocessor", category: "OCREngine")

    public init() {}

    public func recognize(image: CGImage) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: OCRError.ocrFailed(error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(text: "", boundingBoxes: []))
                    return
                }

                var boundingBoxes: [BoundingBox] = []
                var textLines: [String] = []

                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }

                    let visionRect = observation.boundingBox
                    let normalizedRect = CGRect(
                        x: visionRect.minX,
                        y: 1 - visionRect.maxY,
                        width: visionRect.width,
                        height: visionRect.height
                    )

                    let box = BoundingBox(
                        text: topCandidate.string,
                        normalizedRect: normalizedRect,
                        confidence: topCandidate.confidence
                    )
                    boundingBoxes.append(box)
                    textLines.append(topCandidate.string)
                }

                let fullText = textLines.joined(separator: "\n")
                continuation.resume(returning: OCRResult(text: fullText, boundingBoxes: boundingBoxes))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let supportedRevisions = VNRecognizeTextRequest.supportedRevisions
            if let maxRevision = supportedRevisions.max() {
                request.revision = maxRevision
            }

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.ocrFailed(error.localizedDescription))
            }
        }
    }
}
