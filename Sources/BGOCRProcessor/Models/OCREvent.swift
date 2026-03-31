import Foundation

public struct OCREvent: Sendable {
    public let id: String
    public let imagePath: String
    public let batchID: String
    public let index: Int
    public let totalCount: Int
    public let result: Result<OCRResult, OCRError>
    public let timestamp: Date

    public init(
        id: String,
        imagePath: String,
        batchID: String,
        index: Int,
        totalCount: Int,
        result: Result<OCRResult, OCRError>,
        timestamp: Date
    ) {
        self.id = id
        self.imagePath = imagePath
        self.batchID = batchID
        self.index = index
        self.totalCount = totalCount
        self.result = result
        self.timestamp = timestamp
    }
}
