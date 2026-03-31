import CoreGraphics

public struct BoundingBox: Sendable {
    public let text: String
    public let normalizedRect: CGRect
    public let confidence: Float

    public init(text: String, normalizedRect: CGRect, confidence: Float) {
        self.text = text
        self.normalizedRect = normalizedRect
        self.confidence = confidence
    }
}
