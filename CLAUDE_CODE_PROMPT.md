# BGOCRProcessor — Claude Code Build Prompt

## What You Are Building

A Swift SPM library called `BGOCRProcessor` that performs background OCR on images. It takes an array of image file paths, processes them in parallel using Apple's Vision framework, and emits per-image results (extracted text + bounding boxes) as events over time. It works both when the app is in the foreground and background. It persists its queue to SQLite so processing survives app kills. It is consumable from both native iOS (via AsyncStream) and React Native (via a thin RCTEventEmitter bridge module).

This is NOT a prototype. Write production-grade, human-readable Swift. No shortcuts, no TODOs, no placeholder logic.

---

## Hard Constraints

- Swift 5.9+, iOS 15.0+ deployment target
- Full async/await — no completion handlers, no Combine, no DispatchQueue
- No third-party dependencies. Use `sqlite3` (ships with iOS), `Vision`, `UIKit` for app state notifications
- No comments in the code — the code must be self-explanatory through naming and structure
- Every public type must be `Sendable`
- The core library must have zero awareness of React Native. The RN bridge is a separate target that imports the core

---

## SPM Package Structure

```
BGOCRProcessor/
├── Package.swift
├── Sources/
│   ├── BGOCRProcessor/              ← core library target
│   │   ├── OCRProcessor.swift        ← main actor, public API
│   │   ├── PersistentQueue.swift     ← SQLite-backed queue
│   │   ├── OCREngine.swift           ← Vision framework wrapper
│   │   ├── ImagePipeline.swift       ← preprocessing (orient, resize, grayscale)
│   │   ├── BGTaskCoordinator.swift   ← BGProcessingTask lifecycle
│   │   ├── AppStateObserver.swift    ← fg/bg transitions, concurrency changes
│   │   ├── ConcurrencyPolicy.swift   ← rules for worker count
│   │   ├── DatabaseConnection.swift  ← raw sqlite3 wrapper
│   │   └── Models/
│   │       ├── OCREvent.swift
│   │       ├── OCRResult.swift
│   │       ├── BoundingBox.swift
│   │       ├── QueueItem.swift
│   │       ├── ProcessorState.swift
│   │       └── OCRError.swift
│   └── BGOCRProcessorRN/            ← React Native bridge target
│       ├── OCRBridgeModule.swift
│       └── OCRBridgeModule.m         ← ObjC macro for RCT_EXTERN_MODULE
└── Tests/
    └── BGOCRProcessorTests/
        ├── PersistentQueueTests.swift
        ├── ImagePipelineTests.swift
        ├── OCRProcessorTests.swift
        └── Mocks/
            ├── MockOCREngine.swift
            └── MockPersistentQueue.swift
```

### Package.swift

- Core target `BGOCRProcessor`: depends on nothing external. Links `sqlite3` system library.
- Bridge target `BGOCRProcessorRN`: depends on `BGOCRProcessor` and `React-Core` (via CocoaPods interop or manual framework search path — the RN project provides this).
- Test target: depends on `BGOCRProcessor` only.

---

## Component Specifications

### 1. Models (Sources/BGOCRProcessor/Models/)

All models are structs, all Sendable, all public.

```swift
public struct BoundingBox: Sendable {
    public let text: String
    public let normalizedRect: CGRect   // 0-1 coordinate space
    public let confidence: Float        // 0.0 to 1.0
}

public struct OCRResult: Sendable {
    public let text: String
    public let boundingBoxes: [BoundingBox]
}

public struct OCREvent: Sendable {
    public let id: String               // queue item UUID
    public let imagePath: String
    public let batchID: String
    public let index: Int               // position within original enqueue call
    public let totalCount: Int          // total items in this batch
    public let result: Result<OCRResult, OCRError>
    public let timestamp: Date
}

public enum ProcessorState: Sendable {
    case idle
    case processing(completed: Int, total: Int)
    case paused(completed: Int, total: Int)
}

public enum OCRError: Error, Sendable {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case corruptImage(String)
    case ocrFailed(String)
    case diskSpaceLow
    case memoryPressure
    case maxRetriesExceeded(String)
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
}

public enum QueueItemStatus: Int, Sendable {
    case pending = 0
    case processing = 1
    case completed = 2
    case failed = 3
    case permanentlyFailed = 4
}
```

### 2. DatabaseConnection (Sources/BGOCRProcessor/DatabaseConnection.swift)

A thin, synchronous wrapper around `sqlite3`. NOT an actor — it's used internally by PersistentQueue.

Responsibilities:
- Open/close SQLite database at a given path
- WAL journal mode enabled on open
- Execute statements with parameter binding
- Query rows into typed results
- Transaction support (BEGIN/COMMIT/ROLLBACK)

Design rules:
- All interactions go through `execute(_ sql: String, params: [Any?])` and `query(_ sql: String, params: [Any?]) -> [[String: Any]]`
- Handle `SQLITE_BUSY` by retrying up to 3 times with 50ms delay
- Every public method throws `DatabaseError` on failure
- The connection must be closable and reopenable (for testing)
- Thread safety: the connection itself is NOT thread-safe. The PersistentQueue actor provides serialization.

### 3. PersistentQueue (Sources/BGOCRProcessor/PersistentQueue.swift)

An `actor` that owns a `DatabaseConnection` and provides the queue abstraction.

Schema (create on first access):

```sql
CREATE TABLE IF NOT EXISTS queue_items (
    id              TEXT PRIMARY KEY,
    image_path      TEXT NOT NULL,
    batch_id        TEXT NOT NULL,
    status          INTEGER NOT NULL DEFAULT 0,
    result_json     TEXT,
    error_message   TEXT,
    created_at      REAL NOT NULL,
    updated_at      REAL NOT NULL,
    attempt_count   INTEGER NOT NULL DEFAULT 0,
    js_processed    INTEGER NOT NULL DEFAULT 0,
    purge_after     REAL,
    UNIQUE(image_path, batch_id)
);
CREATE INDEX IF NOT EXISTS idx_status ON queue_items(status);
CREATE INDEX IF NOT EXISTS idx_js_processed ON queue_items(js_processed);
```

Public API:

```swift
public actor PersistentQueue {
    init(databasePath: String) throws

    func enqueue(_ paths: [String], batchID: String) throws -> Int
    func dequeue(limit: Int) throws -> [QueueItem]
    func markProcessing(_ id: String) throws
    func markCompleted(_ id: String, resultJSON: String) throws
    func markFailed(_ id: String, error: String, attemptCount: Int) throws
    func markPermanentlyFailed(_ id: String, error: String) throws
    func markJSProcessed(_ ids: [String]) throws
    func resetStaleProcessing() throws -> Int
    func pendingCount() throws -> Int
    func totalCounts(batchID: String) throws -> (completed: Int, total: Int)
    func unprocessedByJS() throws -> [QueueItem]
    func autoPurge() throws -> Int
}
```

Behavior details:
- `enqueue` uses `INSERT OR IGNORE` to handle duplicates. Returns count of actually inserted rows.
- `dequeue` selects items with `status = pending ORDER BY created_at ASC LIMIT ?` and atomically updates their status to `processing` within a transaction.
- `resetStaleProcessing` updates all `status = processing` rows back to `pending`, increments `attempt_count`. Returns count of reset items.
- If `attempt_count >= 3` when a reset happens, mark as `permanentlyFailed` instead of `pending`.
- `markJSProcessed` sets `js_processed = 1` and `purge_after = now + 72 hours` for the given IDs.
- `autoPurge` deletes rows where `js_processed = 1 AND purge_after < now`. Returns count of deleted rows.
- DB path defaults to: `<ApplicationSupport>/BGOCRProcessor/queue.sqlite3`. Create the directory if it doesn't exist.

### 4. ImagePipeline (Sources/BGOCRProcessor/ImagePipeline.swift)

A struct (not actor, it's stateless). Performs preprocessing before OCR.

```swift
public struct ImagePipeline: Sendable {
    func prepare(at path: String, maxDimension: Int) throws -> CGImage
}
```

Steps in order:
1. Verify file exists. Throw `.fileNotFound` if not.
2. Create `CGImageSource` from the file URL. Throw `.unsupportedFormat` if nil.
3. Extract `CGImage`. Throw `.corruptImage` if nil.
4. Read EXIF orientation from image source properties. Apply orientation correction to produce an `.up` oriented image using `CGContext` drawing with the correct transform.
5. If the image's longest edge exceeds `maxDimension`, scale proportionally using `CGContext` to fit within `maxDimension x maxDimension`.
6. Return the processed `CGImage`.

Design rules:
- Use Core Graphics only. No UIImage (it's not available in all contexts and carries overhead).
- The orientation correction MUST handle all 8 EXIF orientation cases. This is critical for correct bounding box coordinates.
- Autorelease pool around the processing to control memory spikes: `try autoreleasepool { ... }`
- `maxDimension` defaults to 4096 for foreground, 2048 for background.

### 5. OCREngine (Sources/BGOCRProcessor/OCREngine.swift)

Wraps Apple's Vision framework. Must be protocol-based for testability.

```swift
public protocol OCREngineProtocol: Sendable {
    func recognize(image: CGImage) async throws -> OCRResult
}

public struct OCREngine: OCREngineProtocol, Sendable {
    public func recognize(image: CGImage) async throws -> OCRResult
}
```

Implementation:
- Create `VNRecognizeTextRequest` with `.accurate` recognition level.
- Use the highest available revision: check `VNRecognizeTextRequest.supportedRevisions` and pick `max`.
- Set `usesLanguageCorrection = true`.
- Execute via `VNImageRequestHandler(cgImage:options:).perform()`.
- This is a synchronous Vision call — wrap it in `withCheckedThrowingContinuation` to make it async (Vision's perform is sync and should run on a background thread).
- Map `VNRecognizedTextObservation` results to `[BoundingBox]`. Each observation has a `boundingBox` (normalized CGRect in Vision's coordinate system where origin is bottom-left). Convert to top-left origin: `CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)`.
- Concatenate all recognized text strings (top candidate from each observation) into the `text` field, separated by newlines.
- If the request produces zero observations, return an OCRResult with empty text and empty boundingBoxes — this is NOT an error (the image might genuinely have no text).

### 6. AppStateObserver (Sources/BGOCRProcessor/AppStateObserver.swift)

Monitors UIApplication lifecycle notifications and provides the current app state.

```swift
public enum AppState: Sendable {
    case foreground
    case background
    case backgroundTask
}

public actor AppStateObserver {
    public var currentState: AppState
    public var stateChanges: AsyncStream<AppState>

    public func startObserving()
    public func stopObserving()
    public func overrideState(_ state: AppState)  // for BGTask handler to set .backgroundTask
}
```

Listens to:
- `UIApplication.didBecomeActiveNotification` → `.foreground`
- `UIApplication.didEnterBackgroundNotification` → `.background`

Uses `NotificationCenter` async sequences internally. The `overrideState` method exists so that `BGTaskCoordinator` can force the state to `.backgroundTask` when a BGProcessingTask handler is invoked (which doesn't trigger the normal UIApplication notifications).

### 7. ConcurrencyPolicy (Sources/BGOCRProcessor/ConcurrencyPolicy.swift)

Pure function, no state.

```swift
public struct ConcurrencyPolicy: Sendable {
    public static func limit(for state: AppState) -> Int
    public static func maxImageDimension(for state: AppState) -> Int
}
```

Rules:
- `.foreground`: limit = `min(ProcessInfo.processInfo.activeProcessorCount, 4)`, maxDimension = 4096
- `.background`: limit = 1, maxDimension = 2048
- `.backgroundTask`: limit = 1, maxDimension = 2048

### 8. BGTaskCoordinator (Sources/BGOCRProcessor/BGTaskCoordinator.swift)

Manages the `BGProcessingTask` lifecycle. This is the trickiest component.

```swift
public final class BGTaskCoordinator: Sendable {
    static let taskIdentifier = "com.bgocrprocessor.processing"

    public func register(processor: OCRProcessor)
    public func scheduleIfNeeded() throws
}
```

Behavior:
- `register` calls `BGTaskScheduler.shared.register(forTaskWithIdentifier:using:)`. The handler block:
  1. Sets `AppStateObserver` to `.backgroundTask`
  2. Calls `processor.resumeProcessing()`
  3. Sets `task.expirationHandler` which calls `processor.pauseProcessing()`
  4. When processor finishes current batch or is paused, checks pending count
  5. If items remain, calls `scheduleIfNeeded()` to re-enqueue the next BGTask
  6. Calls `task.setTaskCompleted(success: true)`
- `scheduleIfNeeded` creates a `BGProcessingTaskRequest`, sets `requiresExternalPower = false`, `requiresNetworkConnectivity = false`, submits to scheduler. Catches and ignores `BGTaskScheduler.Error.unavailable` (happens on simulator).
- The host app MUST add the task identifier to its `Info.plist` under `BGTaskSchedulerPermittedIdentifiers`. Document this in the library README.

CRITICAL: `BGTaskScheduler.shared.register` must be called before `application(_:didFinishLaunchingWithOptions:)` returns. The library should provide a static setup method that the host app calls from `AppDelegate`:

```swift
public static func configure() {
    // registers BGTask, creates shared instance, runs resetStaleProcessing
}
```

### 9. OCRProcessor (Sources/BGOCRProcessor/OCRProcessor.swift)

The main public API. This is an `actor`.

```swift
public actor OCRProcessor {
    public static let shared = OCRProcessor()

    // for testing
    public init(
        queue: PersistentQueue,
        engine: OCREngineProtocol,
        appStateObserver: AppStateObserver,
        bgTaskCoordinator: BGTaskCoordinator
    )

    // === Public API ===
    public var events: AsyncStream<OCREvent>
    public var state: ProcessorState

    public func enqueue(_ paths: [String]) async throws -> String   // returns batchID
    public func cancelBatch(_ batchID: String) async throws
    public func cancelAll() async throws
    public func pauseProcessing()
    public func resumeProcessing()

    public func progress(for batchID: String) async throws -> (completed: Int, total: Int)
    public func unprocessedResults() async throws -> [QueueItem]
    public func markJSProcessed(_ ids: [String]) async throws
    public func availableDiskSpace() -> UInt64
}
```

Processing loop design:

```
The actor maintains a single `processingTask: Task<Void, Never>?`

When `enqueue` is called:
  1. Write paths to PersistentQueue
  2. If processingTask is nil or finished, start a new one
  3. Schedule BGTask if there are pending items

The processingTask runs a loop:
  while not cancelled and not paused:
    1. Read current AppState from AppStateObserver
    2. Get concurrency limit and maxDimension from ConcurrencyPolicy
    3. Check available memory (os_proc_available_memory)
       - If below 30MB, break and re-schedule
    4. Check available disk space
       - If below 50MB, emit .diskSpaceLow error event, break
    5. Dequeue `limit` items from PersistentQueue
       - If none, set state to .idle, break
    6. Process items using withTaskGroup:
       For each item:
         a. Check file exists
         b. Run ImagePipeline.prepare()
         c. Run OCREngine.recognize()
         d. On success: markCompleted in DB, yield OCREvent with .success
         e. On failure: check attemptCount
            - If < 3: markFailed in DB, yield OCREvent with .failure
            - If >= 3: markPermanentlyFailed, yield OCREvent with .failure(.maxRetriesExceeded)
    7. Update ProcessorState
    8. Run autoPurge every 100 processed items
    9. Loop back to step 1 (concurrency limit may have changed)

When AppState changes to .background:
  - Don't cancel in-flight work
  - The loop naturally picks up the new (lower) concurrency limit on next iteration

When AppState changes to .foreground:
  - The loop naturally picks up the new (higher) concurrency limit
  - If processingTask had stopped, resume it
```

Event stream implementation:
- Use `AsyncStream<OCREvent>` with a stored `AsyncStream<OCREvent>.Continuation`
- The `events` property creates the stream lazily on first access
- `continuation?.yield(event)` — if nil (nobody listening), events still go to SQLite. No data loss.
- On `continuation.onTermination`, set continuation to nil

### 10. RN Bridge (Sources/BGOCRProcessorRN/)

#### OCRBridgeModule.swift

```swift
@objc(BGOCRModule)
class BGOCRModule: RCTEventEmitter {

    private var subscription: Task<Void, Never>?
    private var hasListeners = false

    override static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String] {
        ["onOCRResult", "onOCRError", "onBatchProgress"]
    }

    override func startObserving() {
        hasListeners = true
        subscription = Task { [weak self] in
            for await event in await OCRProcessor.shared.events {
                guard let self, self.hasListeners else { break }
                switch event.result {
                case .success:
                    self.sendEvent(withName: "onOCRResult", body: self.eventToDictionary(event))
                case .failure:
                    self.sendEvent(withName: "onOCRError", body: self.eventToDictionary(event))
                }
            }
        }
    }

    override func stopObserving() {
        hasListeners = false
        subscription?.cancel()
        subscription = nil
    }

    @objc func enqueue(_ paths: [String],
                       resolve: @escaping RCTPromiseResolveBlock,
                       reject: @escaping RCTPromiseRejectBlock) {
        Task {
            do {
                let batchID = try await OCRProcessor.shared.enqueue(paths)
                resolve(batchID)
            } catch {
                reject("ENQUEUE_FAILED", error.localizedDescription, error)
            }
        }
    }

    @objc func getUnprocessedResults(_ resolve: @escaping RCTPromiseResolveBlock,
                                     _ reject: @escaping RCTPromiseRejectBlock) {
        Task {
            do {
                let items = try await OCRProcessor.shared.unprocessedResults()
                resolve(items.map { self.queueItemToDictionary($0) })
            } catch {
                reject("QUERY_FAILED", error.localizedDescription, error)
            }
        }
    }

    @objc func markJSProcessed(_ ids: [String]) {
        Task {
            try? await OCRProcessor.shared.markJSProcessed(ids)
        }
    }

    @objc func getProgress(_ batchID: String,
                           resolve: @escaping RCTPromiseResolveBlock,
                           reject: @escaping RCTPromiseRejectBlock) {
        Task {
            do {
                let (completed, total) = try await OCRProcessor.shared.progress(for: batchID)
                resolve(["completed": completed, "total": total])
            } catch {
                reject("PROGRESS_FAILED", error.localizedDescription, error)
            }
        }
    }

    @objc func cancelAll(_ resolve: @escaping RCTPromiseResolveBlock,
                         _ reject: @escaping RCTPromiseRejectBlock) {
        Task {
            do {
                try await OCRProcessor.shared.cancelAll()
                resolve(nil)
            } catch {
                reject("CANCEL_FAILED", error.localizedDescription, error)
            }
        }
    }
}
```

#### OCRBridgeModule.m

```objc
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE(BGOCRModule, RCTEventEmitter)

RCT_EXTERN_METHOD(enqueue:(NSArray *)paths
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(getUnprocessedResults:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(markJSProcessed:(NSArray *)ids)

RCT_EXTERN_METHOD(getProgress:(NSString *)batchID
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(cancelAll:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

@end
```

---

## Edge Cases — MUST Handle in v1

Each of these MUST be handled. Do not leave any as TODOs.

### 1. App killed mid-processing
`resetStaleProcessing()` runs on every `OCRProcessor.configure()` call and at the start of every BGTask handler. Items stuck in `processing` state get reset to `pending` with `attempt_count` incremented. If `attempt_count >= 3`, mark as `permanentlyFailed`.

### 2. Corrupt or unreadable image
The entire pipeline for a single image is wrapped in do/catch. On any error from ImagePipeline or OCREngine, the item is marked `failed` with the error message. An OCREvent with `.failure` result is yielded. Processing continues to the next item.

### 3. Image file deleted before processing
`ImagePipeline.prepare()` checks `FileManager.default.fileExists(atPath:)` as its first step. If missing, throws `.fileNotFound`. The worker marks the item as `permanentlyFailed` (no point retrying a deleted file — do NOT increment attempt_count and retry).

### 4. Disk space exhaustion
Before each processing batch, check `availableDiskSpace()`. If below 50MB, emit a `.diskSpaceLow` error event and pause processing. The processing loop breaks and can be resumed when space is freed.

```swift
func availableDiskSpace() -> UInt64 {
    let attrs = try? FileManager.default.attributesOfFileSystem(
        forPath: NSHomeDirectory()
    )
    return attrs?[.systemFreeSize] as? UInt64 ?? 0
}
```

### 5. Memory pressure in background
Before each image, check `os_proc_available_memory()`. If below 30MB, stop the processing loop gracefully, complete the BGTask, and re-schedule. Do NOT attempt to process — iOS will jetsam-kill you.

```swift
import os

func availableMemory() -> UInt64 {
    return os_proc_available_memory()
}
```

### 6. Duplicate enqueue
The `UNIQUE(image_path, batch_id)` constraint combined with `INSERT OR IGNORE` silently skips duplicates. The `enqueue` method returns the count of actually inserted rows so the caller knows.

### 7. BGTask never runs
This is a communication problem, not a code problem. The `getProgress()` method lets the UI show queue status. The library should not try to work around iOS scheduling — just process in foreground when possible and treat background as best-effort.

### 8. Concurrent DB access (native BGTask + Expo BGTask)
WAL mode handles concurrent reads. For writes, the `SQLITE_BUSY` retry logic in `DatabaseConnection` handles brief contention. Since both tasks write to different rows (native marks `completed`, Expo marks `js_processed`), true conflicts are extremely rare.

### 9. Partial catch-up failure
JS-side responsibility. The bridge exposes per-item `markJSProcessed`. JS should only mark items after successfully writing to its own App DB. The library provides the tools; the consumer controls the transaction boundary.

### 10. Auto-purge race
`markJSProcessed` sets `purge_after = now + 72 hours`. `autoPurge` only deletes where `purge_after IS NOT NULL AND purge_after < now`. 72-hour window gives ample safety margin.

---

## Testing Strategy

### PersistentQueueTests
- Enqueue items, verify they appear with `pending` status
- Dequeue respects limit and FIFO order
- Duplicate enqueue (same path + batchID) inserts only once
- `resetStaleProcessing` moves `processing` → `pending` and increments `attempt_count`
- `resetStaleProcessing` moves items with `attempt_count >= 3` to `permanentlyFailed`
- `markCompleted` updates status and stores result JSON
- `markJSProcessed` sets flag and `purge_after`
- `autoPurge` only deletes rows past their `purge_after` time
- `autoPurge` does NOT delete rows where `js_processed = 0`
- Concurrent dequeue calls don't return the same items (actor serialization)
- Database file is created at expected path with WAL mode

### ImagePipelineTests
- Missing file throws `.fileNotFound`
- Corrupt file data throws `.corruptImage`
- Oversized image is downscaled (verify output dimensions)
- All 8 EXIF orientations produce correctly oriented output
- HEIC, PNG, JPEG formats all succeed
- Output is a valid CGImage

### OCRProcessorTests (using MockOCREngine and in-memory PersistentQueue)
- Enqueue emits events for each processed image
- Failed images produce `.failure` events
- Processing respects concurrency limit
- State transitions: idle → processing → idle
- `cancelAll` stops processing and clears pending items
- `pauseProcessing` / `resumeProcessing` works correctly
- `resetStaleProcessing` is called on init
- Memory pressure check stops the loop (mock `os_proc_available_memory` by injecting a closure)
- Disk space check stops the loop (mock `availableDiskSpace` similarly)

### MockOCREngine
```swift
actor MockOCREngine: OCREngineProtocol {
    var results: [String: Result<OCRResult, OCRError>] = [:]
    var recognizeDelay: Duration = .zero
    var callCount = 0

    func recognize(image: CGImage) async throws -> OCRResult {
        callCount += 1
        if recognizeDelay > .zero {
            try await Task.sleep(for: recognizeDelay)
        }
        // return pre-configured result or default
    }
}
```

---

## Code Style Rules

1. No comments. Zero. The code explains itself through names.
2. No force unwraps (`!`). Every optional is handled explicitly.
3. No `Any` types in public API. Internal only where sqlite3 requires it.
4. All public methods have clear, descriptive names. Prefer `markCompleted(_:resultJSON:)` over `update(_:_:)`.
5. Guard clauses for early returns. No deeply nested if/else.
6. One responsibility per method. If a method does two things, split it.
7. Error types are specific and carry context (the path that was not found, the format that was unsupported).
8. All Date handling uses `Date().timeIntervalSince1970` for storage (REAL in SQLite). Convert back on read.
9. Use `UUID().uuidString` for item IDs and batch IDs.
10. Logging: Use `os.Logger` with subsystem `"com.bgocrprocessor"`. Log at `.debug` for normal operations, `.error` for failures. No print statements.

---

## Build Order

Build in this exact order. Each step must compile and pass its tests before moving on.

1. **Models** — all types in Models/
2. **DatabaseConnection** — raw sqlite3 wrapper + tests for basic CRUD
3. **PersistentQueue** — actor wrapping DatabaseConnection + all PersistentQueueTests
4. **ImagePipeline** — preprocessing + ImagePipelineTests
5. **OCREngine** — Vision wrapper + MockOCREngine
6. **ConcurrencyPolicy** — pure function, trivial
7. **AppStateObserver** — notification listener
8. **BGTaskCoordinator** — BGProcessingTask lifecycle
9. **OCRProcessor** — main actor, wires everything together + OCRProcessorTests
10. **RN Bridge** — thin bridge module, no tests needed (it's just forwarding calls)

---

## What "Done" Looks Like

- `swift build` succeeds with zero warnings
- All tests pass
- `OCRProcessor.shared.enqueue(paths)` works from both native Swift and RN JS
- Events stream in real-time during foreground
- Queue persists across app kills
- Processing resumes via BGTask in background
- Failed/corrupt images are handled gracefully with error events
- Memory and disk space are checked before processing
- `js_processed` handshake ensures no data loss between native and JS
- Auto-purge cleans up after 72 hours
- The entire core library has zero React Native imports
