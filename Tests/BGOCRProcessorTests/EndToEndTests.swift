import XCTest
import CoreGraphics
import CoreText
import ImageIO
@testable import BGOCRProcessor

final class EndToEndTests: XCTestCase {

    private var tempDir: String!
    private var dbPath: String!

    override func setUp() {
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("E2E_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        dbPath = (tempDir as NSString).appendingPathComponent("e2e.sqlite3")
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    // MARK: - Full Pipeline: Real Image → ImagePipeline → Real OCREngine → DB → Event

    func testFullPipelineWithRealVisionOCR() async throws {
        let imagePath = try createImageWithText("Hello World", name: "hello.png")

        let queue = try PersistentQueue(databasePath: dbPath)
        let engine = OCREngine()
        let processor = OCRProcessor(
            queue: queue,
            engine: engine,
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )

        let eventsStream = await processor.events
        let batchID = try await processor.enqueue([imagePath])

        var receivedEvent: OCREvent?
        let expectation = XCTestExpectation(description: "Receive OCR event")

        let collectTask = Task {
            for await event in eventsStream {
                receivedEvent = event
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 30)
        collectTask.cancel()

        guard let event = receivedEvent else {
            XCTFail("No event received")
            return
        }

        XCTAssertEqual(event.batchID, batchID)
        XCTAssertEqual(event.imagePath, imagePath)

        if case .success(let result) = event.result {
            XCTAssertFalse(result.text.isEmpty, "OCR should extract text from the image")
            XCTAssertTrue(result.text.lowercased().contains("hello"), "Expected 'hello' in OCR result, got: \(result.text)")
        } else {
            XCTFail("Expected success, got failure: \(event.result)")
        }

        let (completed, total) = try await processor.progress(for: batchID)
        XCTAssertEqual(total, 1)
        XCTAssertEqual(completed, 1)

        let unprocessed = try await processor.unprocessedResults()
        XCTAssertEqual(unprocessed.count, 1)
        XCTAssertNotNil(unprocessed.first?.resultJSON)

        try await processor.markJSProcessed([event.id])
        let afterMark = try await processor.unprocessedResults()
        XCTAssertEqual(afterMark.count, 0)
    }

    // MARK: - Multi-Image Batch: Verifies parallel processing and per-image events

    func testMultiImageBatchProcessing() async throws {
        let paths = try (1...5).map { i in
            try createImageWithText("Image \(i)", name: "img\(i).png")
        }

        let queue = try PersistentQueue(databasePath: dbPath)
        let processor = OCRProcessor(
            queue: queue,
            engine: OCREngine(),
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )

        let eventsStream = await processor.events
        let batchID = try await processor.enqueue(paths)

        var receivedEvents: [OCREvent] = []
        let expectation = XCTestExpectation(description: "Receive all events")
        expectation.expectedFulfillmentCount = 5

        let collectTask = Task {
            for await event in eventsStream {
                receivedEvents.append(event)
                expectation.fulfill()
                if receivedEvents.count >= 5 { break }
            }
        }

        await fulfillment(of: [expectation], timeout: 60)
        collectTask.cancel()

        XCTAssertEqual(receivedEvents.count, 5)

        let successCount = receivedEvents.filter {
            if case .success = $0.result { return true }
            return false
        }.count
        XCTAssertEqual(successCount, 5)

        let (completed, total) = try await processor.progress(for: batchID)
        XCTAssertEqual(total, 5)
        XCTAssertEqual(completed, 5)
    }

    // MARK: - Mixed Batch: Good images + corrupt + missing file

    func testMixedBatchWithCorruptAndMissingFiles() async throws {
        let goodPath = try createImageWithText("Valid", name: "good.png")
        let corruptPath = (tempDir as NSString).appendingPathComponent("corrupt.png")
        try Data([0xFF, 0xD8, 0x00, 0x00]).write(to: URL(fileURLWithPath: corruptPath))
        let missingPath = "/nonexistent/missing.png"

        let queue = try PersistentQueue(databasePath: dbPath)
        let processor = OCRProcessor(
            queue: queue,
            engine: OCREngine(),
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )

        let eventsStream = await processor.events
        _ = try await processor.enqueue([goodPath, corruptPath, missingPath])

        var events: [OCREvent] = []
        let expectation = XCTestExpectation(description: "Receive all events")
        expectation.expectedFulfillmentCount = 3

        let collectTask = Task {
            for await event in eventsStream {
                events.append(event)
                expectation.fulfill()
                if events.count >= 3 { break }
            }
        }

        await fulfillment(of: [expectation], timeout: 30)
        collectTask.cancel()

        XCTAssertEqual(events.count, 3)

        let successEvents = events.filter {
            if case .success = $0.result { return true }
            return false
        }
        let failureEvents = events.filter {
            if case .failure = $0.result { return true }
            return false
        }

        XCTAssertEqual(successEvents.count, 1, "One good image should succeed")
        XCTAssertEqual(failureEvents.count, 2, "Corrupt + missing should fail")

        let fileNotFoundEvent = failureEvents.first { event in
            if case .failure(.fileNotFound) = event.result { return true }
            return false
        }
        XCTAssertNotNil(fileNotFoundEvent, "Should have a fileNotFound error")
    }

    // MARK: - Duplicate Enqueue: Same paths in same batch are ignored

    func testDuplicateEnqueueSilentlyIgnored() async throws {
        let path = try createImageWithText("Dup", name: "dup.png")

        let queue = try PersistentQueue(databasePath: dbPath)
        let batchID = UUID().uuidString

        let count1 = try await queue.enqueue([path], batchID: batchID)
        XCTAssertEqual(count1, 1)

        let count2 = try await queue.enqueue([path], batchID: batchID)
        XCTAssertEqual(count2, 0)

        let (_, total) = try await queue.totalCounts(batchID: batchID)
        XCTAssertEqual(total, 1)
    }

    // MARK: - App Kill Recovery: Stale processing items reset correctly

    func testAppKillRecoveryResetsStaleItems() async throws {
        let queue = try PersistentQueue(databasePath: dbPath)
        let batchID = UUID().uuidString
        _ = try await queue.enqueue(["/img/a.jpg", "/img/b.jpg", "/img/c.jpg"], batchID: batchID)

        let items = try await queue.dequeue(limit: 3)
        XCTAssertEqual(items.count, 3)

        let pendingBefore = try await queue.pendingCount()
        XCTAssertEqual(pendingBefore, 0)

        let resetCount = try await queue.resetStaleProcessing()
        XCTAssertEqual(resetCount, 3)

        let pendingAfter = try await queue.pendingCount()
        XCTAssertEqual(pendingAfter, 3)

        for item in items {
            let updated = try await queue.itemByID(item.id)
            XCTAssertEqual(updated?.status, .pending)
            XCTAssertEqual(updated?.attemptCount, 1)
        }
    }

    // MARK: - Max Retries Exceeded: Items become permanentlyFailed after 3 attempts

    func testMaxRetriesMarksAsPermanentlyFailed() async throws {
        let queue = try PersistentQueue(databasePath: dbPath)
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")

        for attempt in 1...3 {
            let items = try await queue.dequeue(limit: 1)
            if items.isEmpty {
                let failedItem = try await queue.itemByID((try await queue.unprocessedByJS()).first?.id ?? "")
                XCTAssertNil(failedItem, "Item should be permanently failed, not in unprocessed")
                break
            }
            _ = try await queue.resetStaleProcessing()

            if attempt < 3 {
                let item = try await queue.itemByID(items[0].id)
                XCTAssertEqual(item?.status, .pending, "Attempt \(attempt): should reset to pending")
                XCTAssertEqual(item?.attemptCount, attempt)
            } else {
                let item = try await queue.itemByID(items[0].id)
                XCTAssertEqual(item?.status, .permanentlyFailed, "After 3 attempts should be permanently failed")
            }
        }
    }

    // MARK: - Disk Space Check: Processor emits diskSpaceLow when threshold not met

    func testDiskSpaceLowStopsProcessing() async throws {
        let path = try createImageWithText("Test", name: "disk.png")

        let queue = try PersistentQueue(databasePath: dbPath)
        let processor = OCRProcessor(
            queue: queue,
            engine: OCREngine(),
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: UInt64.max
        )

        let eventsStream = await processor.events
        _ = try await processor.enqueue([path])

        var receivedEvent: OCREvent?
        let expectation = XCTestExpectation(description: "Receive disk space event")

        let collectTask = Task {
            for await event in eventsStream {
                receivedEvent = event
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 10)
        collectTask.cancel()

        guard let event = receivedEvent else {
            XCTFail("No event received")
            return
        }

        if case .failure(.diskSpaceLow) = event.result {
        } else {
            XCTFail("Expected diskSpaceLow error, got: \(event.result)")
        }
    }

    // MARK: - JS Processed + Auto Purge Lifecycle

    func testJSProcessedPurgeLifecycle() async throws {
        let queue = try PersistentQueue(databasePath: dbPath)
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")
        let items = try await queue.dequeue(limit: 1)
        let id = items[0].id

        try await queue.markCompleted(id, resultJSON: "{\"text\":\"result\"}")

        let unprocessed1 = try await queue.unprocessedByJS()
        XCTAssertEqual(unprocessed1.count, 1)

        try await queue.markJSProcessed([id])

        let unprocessed2 = try await queue.unprocessedByJS()
        XCTAssertEqual(unprocessed2.count, 0)

        let item = try await queue.itemByID(id)
        XCTAssertEqual(item?.jsProcessed, true)
        XCTAssertNotNil(item?.purgeAfter)

        let purgedNow = try await queue.autoPurge()
        XCTAssertEqual(purgedNow, 0, "Should NOT purge yet — 72h window")
    }

    // MARK: - Concurrency Policy Values

    func testConcurrencyPolicyValues() {
        let fgLimit = ConcurrencyPolicy.limit(for: .foreground)
        XCTAssertGreaterThanOrEqual(fgLimit, 1)
        XCTAssertLessThanOrEqual(fgLimit, 4)

        let bgLimit = ConcurrencyPolicy.limit(for: .background)
        XCTAssertEqual(bgLimit, 1)

        let bgtLimit = ConcurrencyPolicy.limit(for: .backgroundTask)
        XCTAssertEqual(bgtLimit, 1)

        XCTAssertEqual(ConcurrencyPolicy.maxImageDimension(for: .foreground), 4096)
        XCTAssertEqual(ConcurrencyPolicy.maxImageDimension(for: .background), 2048)
        XCTAssertEqual(ConcurrencyPolicy.maxImageDimension(for: .backgroundTask), 2048)
    }

    // MARK: - ImagePipeline: Oversized image is downscaled in background mode

    func testBackgroundModeDownscalesImages() throws {
        let path = try createImageWithText("Big", name: "big.png", width: 5000, height: 3000)
        let pipeline = ImagePipeline()

        let bgMaxDim = ConcurrencyPolicy.maxImageDimension(for: .background)
        let result = try pipeline.prepare(at: path, maxDimension: bgMaxDim)

        XCTAssertLessThanOrEqual(max(result.width, result.height), bgMaxDim)
    }

    // MARK: - BGTask Kill Recovery

    func testBGTaskKillRecoveryReprocessesStaleAndPendingItems() async throws {
        let path1 = try createImageWithText("One", name: "one.png")
        let path2 = try createImageWithText("Two", name: "two.png")
        let path3 = try createImageWithText("Three", name: "three.png")

        let queue = try PersistentQueue(databasePath: dbPath)
        let batchID = UUID().uuidString
        _ = try await queue.enqueue([path1, path2, path3], batchID: batchID)

        // Simulate: BGTask dequeued 2, then app was killed. 2 stuck in processing, 1 pending.
        let dequeued = try await queue.dequeue(limit: 2)
        XCTAssertEqual(dequeued.count, 2)
        let pendingBeforeReset = try await queue.pendingCount()
        XCTAssertEqual(pendingBeforeReset, 1)

        // Simulate next BGTask launch via handleBackgroundLaunch.
        // It calls resetStaleProcessing, then processes everything.
        let processor = OCRProcessor(
            queue: queue,
            engine: OCREngine(),
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )

        let eventsStream = await processor.events
        var events: [OCREvent] = []
        let expectation = XCTestExpectation(description: "All 3 items processed")
        expectation.expectedFulfillmentCount = 3

        let collectTask = Task {
            for await event in eventsStream {
                events.append(event)
                expectation.fulfill()
                if events.count >= 3 { break }
            }
        }

        let shouldReschedule = await BGTaskCoordinator.handleBackgroundLaunch(
            processor: processor,
            queue: queue
        )

        await fulfillment(of: [expectation], timeout: 30)
        collectTask.cancel()

        XCTAssertFalse(shouldReschedule, "Queue should be empty after processing")
        XCTAssertEqual(events.count, 3)

        let successCount = events.filter {
            if case .success = $0.result { return true }
            return false
        }.count
        XCTAssertEqual(successCount, 3)

        let (completed, total) = try await processor.progress(for: batchID)
        XCTAssertEqual(completed, 3)
        XCTAssertEqual(total, 3)
    }

    func testBGTaskKillRepeatedlyBumpsAttemptUntilPermanentFailure() async throws {
        let queue = try PersistentQueue(databasePath: dbPath)
        _ = try await queue.enqueue(["/img/a.jpg"], batchID: "batch1")

        // Simulate 3 successive BGTask kills while processing the same item.
        for expectedAttempt in 1...3 {
            let items = try await queue.dequeue(limit: 1)
            XCTAssertEqual(items.count, 1, "Attempt \(expectedAttempt): item should be dequeueable")
            _ = try await queue.resetStaleProcessing()

            let item = try await queue.itemByID(items[0].id)
            if expectedAttempt < 3 {
                XCTAssertEqual(item?.status, .pending)
                XCTAssertEqual(item?.attemptCount, expectedAttempt)
            } else {
                XCTAssertEqual(item?.status, .permanentlyFailed)
                XCTAssertEqual(item?.attemptCount, 3)
            }
        }

        let finalPending = try await queue.pendingCount()
        XCTAssertEqual(finalPending, 0)
    }

    func testHandleBackgroundLaunchReturnsTrueWhenItemsRemain() async throws {
        let queue = try PersistentQueue(databasePath: dbPath)
        let mockEngine = MockOCREngine()

        // Enqueue 1 real image + 1 path that will stay pending because we pause.
        let path = try createImageWithText("BG", name: "bg.png")
        _ = try await queue.enqueue([path], batchID: "b1")

        let processor = OCRProcessor(
            queue: queue,
            engine: mockEngine,
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )

        let eventsStream = await processor.events
        let expectation = XCTestExpectation(description: "First item processed")
        let collectTask = Task {
            for await _ in eventsStream {
                expectation.fulfill()
                break
            }
        }

        let shouldReschedule = await BGTaskCoordinator.handleBackgroundLaunch(
            processor: processor,
            queue: queue
        )

        await fulfillment(of: [expectation], timeout: 10)
        collectTask.cancel()

        // Queue is empty after processing 1 item.
        XCTAssertFalse(shouldReschedule)

        // Now enqueue more after processing finished and test with a fresh processor.
        _ = try await queue.enqueue(["/img/future.jpg"], batchID: "b2")
        // Dequeue it so it's stuck in processing (simulating kill).
        _ = try await queue.dequeue(limit: 1)

        let processor2 = OCRProcessor(
            queue: queue,
            engine: mockEngine,
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )

        // handleBackgroundLaunch resets stale + tries to process.
        // /img/future.jpg doesn't exist → fails → but still counts as processed.
        let eventsStream2 = await processor2.events
        let expectation2 = XCTestExpectation(description: "Second item processed")
        let collectTask2 = Task {
            for await _ in eventsStream2 {
                expectation2.fulfill()
                break
            }
        }

        let shouldReschedule2 = await BGTaskCoordinator.handleBackgroundLaunch(
            processor: processor2,
            queue: queue
        )

        await fulfillment(of: [expectation2], timeout: 10)
        collectTask2.cancel()

        XCTAssertFalse(shouldReschedule2)
    }

    // MARK: - Helpers

    private func createImageWithText(_ text: String, name: String, width: Int = 400, height: Int = 200) throws -> String {
        let path = (tempDir as NSString).appendingPathComponent(name)
        let url = URL(fileURLWithPath: path)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Test", code: 1)
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 48, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)

        context.textPosition = CGPoint(x: 20, y: CGFloat(height) / 2 - 20)
        CTLineDraw(line, context)

        guard let image = context.makeImage() else {
            throw NSError(domain: "Test", code: 2)
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "Test", code: 3)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "Test", code: 4)
        }

        return path
    }
}
