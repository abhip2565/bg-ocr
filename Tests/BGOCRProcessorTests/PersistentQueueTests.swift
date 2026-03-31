import XCTest
@testable import BGOCRProcessor

final class PersistentQueueTests: XCTestCase {

    private var queue: PersistentQueue!
    private var dbPath: String!

    override func setUp() async throws {
        let tempDir = NSTemporaryDirectory()
        dbPath = (tempDir as NSString).appendingPathComponent("test_\(UUID().uuidString).sqlite3")
        queue = try PersistentQueue(databasePath: dbPath)
    }

    override func tearDown() async throws {
        queue = nil
        if let dbPath = dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
            try? FileManager.default.removeItem(atPath: dbPath + "-wal")
            try? FileManager.default.removeItem(atPath: dbPath + "-shm")
        }
    }

    func testEnqueueItemsAppearAsPending() async throws {
        let count = try await queue.enqueue(["/img/a.jpg", "/img/b.jpg"], batchID: "batch1")
        XCTAssertEqual(count, 2)

        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 2)
    }

    func testDequeueRespectsLimitAndFIFO() async throws {
        _ = try await queue.enqueue(["/img/1.jpg", "/img/2.jpg", "/img/3.jpg"], batchID: "batch1")

        let items = try await queue.dequeue(limit: 2)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].imagePath, "/img/1.jpg")
        XCTAssertEqual(items[1].imagePath, "/img/2.jpg")

        let remaining = try await queue.pendingCount()
        XCTAssertEqual(remaining, 1)
    }

    func testDuplicateEnqueueInsertsOnlyOnce() async throws {
        let first = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        XCTAssertEqual(first, 1)

        let second = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        XCTAssertEqual(second, 0)

        let total = try await queue.pendingCount()
        XCTAssertEqual(total, 1)
    }

    func testSamePathDifferentBatchInsertsBoth() async throws {
        let first = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let second = try await queue.enqueue(["/img/a.jpg"], batchID: "batch2")
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1)
    }

    func testResetStaleProcessingMovesPendingAndIncrementsAttempt() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        XCTAssertEqual(items.count, 1)

        let resetCount = try await queue.resetStaleProcessing()
        XCTAssertEqual(resetCount, 1)

        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 1)

        let item = try await queue.itemByID(items[0].id)
        XCTAssertEqual(item?.attemptCount, 1)
        XCTAssertEqual(item?.status, .pending)
    }

    func testResetStaleProcessingMarksPermanentlyFailedAfterThreeAttempts() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")

        for _ in 0..<3 {
            let items = try await queue.dequeue(limit: 1)
            if items.isEmpty { break }
            _ = try await queue.resetStaleProcessing()
        }

        let items = try await queue.dequeue(limit: 1)
        XCTAssertTrue(items.isEmpty)

        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }

    func testMarkCompletedUpdatesStatusAndResultJSON() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        let id = items[0].id

        try await queue.markCompleted(id, resultJSON: "{\"text\":\"hello\"}")

        let item = try await queue.itemByID(id)
        XCTAssertEqual(item?.status, .completed)
        XCTAssertEqual(item?.resultJSON, "{\"text\":\"hello\"}")
    }

    func testMarkJSProcessedSetsFlagAndPurgeAfter() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        let id = items[0].id
        try await queue.markCompleted(id, resultJSON: "{}")

        try await queue.markJSProcessed([id])

        let item = try await queue.itemByID(id)
        XCTAssertEqual(item?.jsProcessed, true)
        XCTAssertNotNil(item?.purgeAfter)
    }

    func testAutoPurgeDeletesExpiredRows() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        let id = items[0].id
        try await queue.markCompleted(id, resultJSON: "{}")
        try await queue.markJSProcessed([id])

        let purgedBefore = try await queue.autoPurge()
        XCTAssertEqual(purgedBefore, 0)
    }

    func testAutoPurgeDoesNotDeleteUnprocessedByJS() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        let id = items[0].id
        try await queue.markCompleted(id, resultJSON: "{}")

        let purged = try await queue.autoPurge()
        XCTAssertEqual(purged, 0)

        let unprocessed = try await queue.unprocessedByJS()
        XCTAssertEqual(unprocessed.count, 1)
    }

    func testTotalCountsForBatch() async throws {
        _ = try await queue.enqueue(["/img/a.jpg", "/img/b.jpg", "/img/c.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        try await queue.markCompleted(items[0].id, resultJSON: "{}")

        let (completed, total) = try await queue.totalCounts(batchID: "batch1")
        XCTAssertEqual(total, 3)
        XCTAssertEqual(completed, 1)
    }

    func testUnprocessedByJSReturnsCompletedItems() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        try await queue.markCompleted(items[0].id, resultJSON: "{\"text\":\"result\"}")

        let unprocessed = try await queue.unprocessedByJS()
        XCTAssertEqual(unprocessed.count, 1)
        XCTAssertEqual(unprocessed[0].resultJSON, "{\"text\":\"result\"}")
    }

    func testMarkFailedUpdatesStatusAndError() async throws {
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        let id = items[0].id

        try await queue.markFailed(id, error: "OCR failed", attemptCount: 1)

        let item = try await queue.itemByID(id)
        XCTAssertEqual(item?.status, .failed)
        XCTAssertEqual(item?.errorMessage, "OCR failed")
        XCTAssertEqual(item?.attemptCount, 1)
    }

    func testDatabaseFileCreatedWithWAL() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
        let walPath = dbPath + "-wal"
        XCTAssertTrue(FileManager.default.fileExists(atPath: walPath))
    }

    func testDeleteAllClearsQueue() async throws {
        _ = try await queue.enqueue(["/img/a.jpg", "/img/b.jpg"], batchID: "batch1")
        try await queue.deleteAll()

        let pending = try await queue.pendingCount()
        XCTAssertEqual(pending, 0)
    }
}
