import Foundation

public enum QueueItemStatus: Int, Sendable {
    case pending = 0
    case processing = 1
    case completed = 2
    case failed = 3
    case permanentlyFailed = 4
}

public struct QueueItem: Sendable {
    public let id: String
    public let imagePath: String
    public let batchID: String
    public let status: QueueItemStatus
    public let resultJSON: String?
    public let errorMessage: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let attemptCount: Int
    public let jsProcessed: Bool
    public let purgeAfter: Date?

    public init(
        id: String,
        imagePath: String,
        batchID: String,
        status: QueueItemStatus,
        resultJSON: String?,
        errorMessage: String?,
        createdAt: Date,
        updatedAt: Date,
        attemptCount: Int,
        jsProcessed: Bool,
        purgeAfter: Date?
    ) {
        self.id = id
        self.imagePath = imagePath
        self.batchID = batchID
        self.status = status
        self.resultJSON = resultJSON
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attemptCount = attemptCount
        self.jsProcessed = jsProcessed
        self.purgeAfter = purgeAfter
    }
}
