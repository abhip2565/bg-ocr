import CoreGraphics
@testable import BGOCRProcessor

public actor MockOCREngine: OCREngineProtocol {
    public var defaultResult: Result<OCRResult, OCRError> = .success(OCRResult(text: "mock text", boundingBoxes: []))
    public var recognizeDelay: UInt64 = 0
    public var callCount = 0

    public init() {}

    public func setDefaultResult(_ result: Result<OCRResult, OCRError>) {
        self.defaultResult = result
    }

    public func setRecognizeDelay(_ nanoseconds: UInt64) {
        self.recognizeDelay = nanoseconds
    }

    public func getCallCount() -> Int {
        return callCount
    }

    public func recognize(image: CGImage) async throws -> OCRResult {
        callCount += 1

        if recognizeDelay > 0 {
            try await Task.sleep(nanoseconds: recognizeDelay)
        }

        switch defaultResult {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}
