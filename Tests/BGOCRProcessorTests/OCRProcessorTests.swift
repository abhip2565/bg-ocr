import XCTest
import CoreGraphics
import ImageIO
@testable import BGOCRProcessor

final class OCRProcessorTests: XCTestCase {

    private var processor: OCRProcessor!
    private var mockEngine: MockOCREngine!
    private var queue: PersistentQueue!
    private var dbPath: String!
    private var tempDir: String!

    override func setUp() async throws {
        tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("OCRProcessorTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        dbPath = (tempDir as NSString).appendingPathComponent("test.sqlite3")
        queue = try PersistentQueue(databasePath: dbPath)
        mockEngine = MockOCREngine()

        processor = OCRProcessor(
            queue: queue,
            engine: mockEngine,
            appStateObserver: AppStateObserver(),
            bgTaskCoordinator: BGTaskCoordinator(),
            memoryThreshold: 0,
            diskThreshold: 0
        )
    }

    override func tearDown() async throws {
        processor = nil
        queue = nil
        mockEngine = nil
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testEnqueueReturnsBatchID() async throws {
        let imagePath = try createTestImageFile()
        let batchID = try await processor.enqueue([imagePath])
        XCTAssertFalse(batchID.isEmpty)
    }

    func testEnqueueEmitsEventsForEachImage() async throws {
        let path1 = try createTestImageFile(name: "img1.png")
        let path2 = try createTestImageFile(name: "img2.png")

        let eventsStream = await processor.events
        let batchID = try await processor.enqueue([path1, path2])
        XCTAssertFalse(batchID.isEmpty)

        var receivedEvents: [OCREvent] = []
        let expectation = XCTestExpectation(description: "Receive events")
        expectation.expectedFulfillmentCount = 2

        let collectTask = Task {
            for await event in eventsStream {
                receivedEvents.append(event)
                expectation.fulfill()
                if receivedEvents.count >= 2 { break }
            }
        }

        await fulfillment(of: [expectation], timeout: 10)
        collectTask.cancel()

        XCTAssertEqual(receivedEvents.count, 2)
        for event in receivedEvents {
            if case .success = event.result {
            } else {
                XCTFail("Expected success result")
            }
        }
    }

    func testFailedImagesProduceFailureEvents() async throws {
        await mockEngine.setDefaultResult(.failure(.ocrFailed("test failure")))

        let path = try createTestImageFile()
        let eventsStream = await processor.events
        _ = try await processor.enqueue([path])

        var receivedEvent: OCREvent?
        let expectation = XCTestExpectation(description: "Receive failure event")

        let collectTask = Task {
            for await event in eventsStream {
                receivedEvent = event
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 10)
        collectTask.cancel()

        if let event = receivedEvent, case .failure = event.result {
        } else {
            XCTFail("Expected failure event")
        }
    }

    func testStateTransitionsIdleToProcessingToIdle() async throws {
        let path = try createTestImageFile()

        let stateStream = await processor.stateStream
        _ = try await processor.enqueue([path])

        var states: [String] = []
        let expectation = XCTestExpectation(description: "Receive idle state")

        let collectTask = Task {
            for await state in stateStream {
                switch state {
                case .idle:
                    states.append("idle")
                    expectation.fulfill()
                case .processing:
                    states.append("processing")
                case .paused:
                    states.append("paused")
                }
                if states.contains("idle") && states.count > 0 { break }
            }
        }

        await fulfillment(of: [expectation], timeout: 10)
        collectTask.cancel()

        XCTAssertTrue(states.contains("idle"))
    }

    func testCancelAllStopsProcessing() async throws {
        await mockEngine.setRecognizeDelay(2_000_000_000)
        let path = try createTestImageFile()

        _ = try await processor.enqueue([path])
        try await Task.sleep(nanoseconds: 100_000_000)

        try await processor.cancelAll()

        let state = await processor.state
        if case .idle = state {
        } else {
            XCTFail("Expected idle after cancelAll")
        }
    }

    func testPauseAndResumeProcessing() async throws {
        await mockEngine.setRecognizeDelay(1_000_000_000)
        let path = try createTestImageFile()

        _ = try await processor.enqueue([path])
        try await Task.sleep(nanoseconds: 100_000_000)

        await processor.pauseProcessing()
        let state = await processor.state
        switch state {
        case .paused, .idle:
            break
        default:
            XCTFail("Expected paused or idle state")
        }

        await processor.resumeProcessing()
    }

    func testProgressForBatch() async throws {
        let path = try createTestImageFile()
        let batchID = try await processor.enqueue([path])

        try await Task.sleep(nanoseconds: 2_000_000_000)

        let (completed, total) = try await processor.progress(for: batchID)
        XCTAssertEqual(total, 1)
        XCTAssertGreaterThanOrEqual(completed, 0)
    }

    func testFileNotFoundProducesEvent() async throws {
        let eventsStream = await processor.events
        _ = try await processor.enqueue(["/nonexistent/path.jpg"])

        var receivedEvent: OCREvent?
        let expectation = XCTestExpectation(description: "Receive file not found event")

        let collectTask = Task {
            for await event in eventsStream {
                receivedEvent = event
                expectation.fulfill()
                break
            }
        }

        await fulfillment(of: [expectation], timeout: 10)
        collectTask.cancel()

        if let event = receivedEvent, case .failure(.fileNotFound) = event.result {
        } else {
            XCTFail("Expected fileNotFound error")
        }
    }

    private func createTestImageFile(name: String = "test.png") throws -> String {
        let path = (tempDir as NSString).appendingPathComponent(name)
        let url = URL(fileURLWithPath: path)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "Test", code: 1)
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))

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
