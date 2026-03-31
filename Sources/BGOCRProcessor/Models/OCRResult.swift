public struct OCRResult: Sendable {
    public let text: String
    public let boundingBoxes: [BoundingBox]

    public init(text: String, boundingBoxes: [BoundingBox]) {
        self.text = text
        self.boundingBoxes = boundingBoxes
    }
}
