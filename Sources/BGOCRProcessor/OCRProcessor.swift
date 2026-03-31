import Foundation
import os

public actor OCRProcessor {

    private static let logger = Logger(subsystem: "com.bgocrprocessor", category: "OCRProcessor")

    public static let shared = OCRProcessor()

    private let queue: PersistentQueue
    private let engine: OCREngineProtocol
    public let appStateObserver: AppStateObserver
    private let bgTaskCoordinator: BGTaskCoordinator
    private let imagePipeline: ImagePipeline

    private var processingTask: Task<Void, Never>?
    private var isPaused = false
    private var eventContinuation: AsyncStream<OCREvent>.Continuation?
    private var stateContinuation: AsyncStream<ProcessorState>.Continuation?
    private var processedSincePurge = 0

    private let memoryThreshold: UInt64
    private let diskThreshold: UInt64

    public private(set) var state: ProcessorState = .idle

    public lazy var events: AsyncStream<OCREvent> = {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                await self?.setEventContinuation(continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.clearEventContinuation()
                }
            }
        }
    }()

    public lazy var stateStream: AsyncStream<ProcessorState> = {
        AsyncStream { [weak self] continuation in
            Task { [weak self] in
                await self?.setStateContinuation(continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.clearStateContinuation()
                }
            }
        }
    }()

    public init(
        queue: PersistentQueue? = nil,
        engine: OCREngineProtocol? = nil,
        appStateObserver: AppStateObserver? = nil,
        bgTaskCoordinator: BGTaskCoordinator? = nil,
        memoryThreshold: UInt64 = 30_000_000,
        diskThreshold: UInt64 = 50_000_000
    ) {
        if let queue = queue {
            self.queue = queue
        } else {
            let appSupport = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first
                ?? NSTemporaryDirectory()
            let dbDir = (appSupport as NSString).appendingPathComponent("BGOCRProcessor")
            let dbPath = (dbDir as NSString).appendingPathComponent("queue.sqlite3")
            self.queue = (try? PersistentQueue(databasePath: dbPath)) ?? {
                fatalError("Failed to create PersistentQueue at \(dbPath)")
            }()
        }
        self.engine = engine ?? OCREngine()
        self.appStateObserver = appStateObserver ?? AppStateObserver()
        self.bgTaskCoordinator = bgTaskCoordinator ?? BGTaskCoordinator()
        self.imagePipeline = ImagePipeline()
        self.memoryThreshold = memoryThreshold
        self.diskThreshold = diskThreshold
    }

    public static func configure() {
        Task {
            let processor = OCRProcessor.shared
            let resetCount = try? await processor.queue.resetStaleProcessing()
            if let resetCount, resetCount > 0 {
                logger.debug("Reset \(resetCount) stale items on configure")
            }
            processor.bgTaskCoordinator.register(processor: processor, queue: processor.queue)
            await processor.appStateObserver.startObserving()
            await processor.startStateObservation()

            // If there are pending items from a previous killed session,
            // schedule a BGTask so they get processed even if the user
            // backgrounds the app immediately.
            let pending = try? await processor.queue.pendingCount()
            if let pending, pending > 0 {
                try? processor.bgTaskCoordinator.scheduleIfNeeded()
                logger.debug("Scheduled BGTask for \(pending) pending items on configure")
            }
        }
    }

    public func enqueue(_ paths: [String]) async throws -> String {
        let batchID = UUID().uuidString
        let insertedCount = try await queue.enqueue(paths, batchID: batchID)
        Self.logger.debug("Enqueued \(insertedCount) items with batchID \(batchID)")

        startProcessingIfNeeded()

        let pending = try? await queue.pendingCount()
        if let pending, pending > 0 {
            try? bgTaskCoordinator.scheduleIfNeeded()
        }

        return batchID
    }

    public func cancelBatch(_ batchID: String) async throws {
        Self.logger.debug("Cancel batch not yet granular — use cancelAll for now")
    }

    public func cancelAll() async throws {
        processingTask?.cancel()
        processingTask = nil
        isPaused = false
        try await queue.deleteAll()
        updateState(.idle)
        Self.logger.debug("Cancelled all processing")
    }

    public func pauseProcessing() {
        isPaused = true
        if case .processing(let completed, let total) = state {
            updateState(.paused(completed: completed, total: total))
        }
        Self.logger.debug("Processing paused")
    }

    public func resumeProcessing() {
        isPaused = false
        startProcessingIfNeeded()
        Self.logger.debug("Processing resumed")
    }

    public func progress(for batchID: String) async throws -> (completed: Int, total: Int) {
        return try await queue.totalCounts(batchID: batchID)
    }

    public func unprocessedResults() async throws -> [QueueItem] {
        return try await queue.unprocessedByJS()
    }

    public func markJSProcessed(_ ids: [String]) async throws {
        try await queue.markJSProcessed(ids)
    }

    public func pendingItemCount() async throws -> Int {
        return try await queue.pendingCount()
    }

    public func availableDiskSpace() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        return attrs?[.systemFreeSize] as? UInt64 ?? 0
    }

    private func setEventContinuation(_ continuation: AsyncStream<OCREvent>.Continuation) {
        eventContinuation = continuation
    }

    private func clearEventContinuation() {
        eventContinuation = nil
    }

    private func setStateContinuation(_ continuation: AsyncStream<ProcessorState>.Continuation) {
        stateContinuation = continuation
    }

    private func clearStateContinuation() {
        stateContinuation = nil
    }

    private func updateState(_ newState: ProcessorState) {
        state = newState
        stateContinuation?.yield(newState)
    }

    private func emitEvent(_ event: OCREvent) {
        eventContinuation?.yield(event)
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil || processingTask?.isCancelled == true else { return }
        processingTask = Task { [weak self] in
            await self?.processingLoop()
        }
    }

    private func startStateObservation() {
        Task { [weak self] in
            guard let self else { return }
            let observer = self.appStateObserver
            for await state in await observer.stateChanges {
                if case .foreground = state {
                    await self.resumeIfPendingWork()
                }
            }
        }
    }

    private func resumeIfPendingWork() async {
        let pending = try? await queue.pendingCount()
        if pending ?? 0 > 0 {
            startProcessingIfNeeded()
        }
    }

    private func processingLoop() async {
        defer { processingTask = nil }
        while !Task.isCancelled && !isPaused {
            let currentAppState = await appStateObserver.currentState
            let concurrencyLimit = ConcurrencyPolicy.limit(for: currentAppState)
            let maxDimension = ConcurrencyPolicy.maxImageDimension(for: currentAppState)
            Self.logger.debug("Processing loop: state=\(String(describing: currentAppState)), concurrency=\(concurrencyLimit), maxDimension=\(maxDimension)")

            if availableMemory() < memoryThreshold {
                Self.logger.error("Memory below threshold, stopping processing")
                try? bgTaskCoordinator.scheduleIfNeeded()
                break
            }

            if availableDiskSpace() < diskThreshold {
                Self.logger.error("Disk space below threshold")
                emitEvent(OCREvent(
                    id: UUID().uuidString,
                    imagePath: "",
                    batchID: "",
                    index: 0,
                    totalCount: 0,
                    result: .failure(.diskSpaceLow),
                    timestamp: Date()
                ))
                break
            }

            guard let items = try? await queue.dequeue(limit: concurrencyLimit), !items.isEmpty else {
                updateState(.idle)
                break
            }

            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask { [self] in
                        await self.processItem(item, maxDimension: maxDimension)
                    }
                }
            }

            processedSincePurge += items.count
            if processedSincePurge >= 100 {
                _ = try? await queue.autoPurge()
                processedSincePurge = 0
            }

            if let batchID = items.first?.batchID {
                let (completed, total) = (try? await queue.totalCounts(batchID: batchID)) ?? (0, 0)
                updateState(.processing(completed: completed, total: total))
            }
        }

        if isPaused {
            if case .processing(let completed, let total) = state {
                updateState(.paused(completed: completed, total: total))
            }
        }
    }

    private func processItem(_ item: QueueItem, maxDimension: Int) async {
        do {
            if !FileManager.default.fileExists(atPath: item.imagePath) {
                try await queue.markPermanentlyFailed(item.id, error: "File not found: \(item.imagePath)")
                let event = await makeEvent(for: item, result: .failure(.fileNotFound(item.imagePath)))
                emitEvent(event)
                return
            }

            let cgImage = try imagePipeline.prepare(at: item.imagePath, maxDimension: maxDimension)
            let ocrResult = try await engine.recognize(image: cgImage)

            let resultJSON = encodeResultJSON(ocrResult)
            try await queue.markCompleted(item.id, resultJSON: resultJSON)
            let event = await makeEvent(for: item, result: .success(ocrResult))
            emitEvent(event)
        } catch {
            let ocrError = mapToOCRError(error)
            let newAttemptCount = item.attemptCount + 1

            if newAttemptCount >= 3 {
                try? await queue.markPermanentlyFailed(item.id, error: error.localizedDescription)
                let event = await makeEvent(for: item, result: .failure(.maxRetriesExceeded(item.imagePath)))
                emitEvent(event)
            } else {
                try? await queue.markFailed(item.id, error: error.localizedDescription, attemptCount: newAttemptCount)
                let event = await makeEvent(for: item, result: .failure(ocrError))
                emitEvent(event)
            }
        }
    }

    private func makeEvent(for item: QueueItem, result: Result<OCRResult, OCRError>) async -> OCREvent {
        let counts = (try? await queue.totalCounts(batchID: item.batchID)) ?? (completed: 0, total: 0)
        return OCREvent(
            id: item.id,
            imagePath: item.imagePath,
            batchID: item.batchID,
            index: counts.completed,
            totalCount: counts.total,
            result: result,
            timestamp: Date()
        )
    }

    private func availableMemory() -> UInt64 {
        return UInt64(os_proc_available_memory())
    }

    private func mapToOCRError(_ error: Error) -> OCRError {
        if let ocrError = error as? OCRError {
            return ocrError
        }
        return .ocrFailed(error.localizedDescription)
    }

    private func encodeResultJSON(_ result: OCRResult) -> String {
        var boxes: [[String: Any]] = []
        for box in result.boundingBoxes {
            boxes.append([
                "text": box.text,
                "x": box.normalizedRect.origin.x,
                "y": box.normalizedRect.origin.y,
                "width": box.normalizedRect.size.width,
                "height": box.normalizedRect.size.height,
                "confidence": box.confidence
            ])
        }

        let dict: [String: Any] = [
            "text": result.text,
            "boundingBoxes": boxes
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"text\":\"\(result.text)\",\"boundingBoxes\":[]}"
        }

        return json
    }
}
