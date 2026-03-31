# BGOCRProcessor

A persistent, background-aware OCR processing library for iOS. Queue hundreds of images, close the app, and let the library handle the rest — on-device, no server required.

Built on Apple Vision framework, SQLite persistence, and Swift concurrency.

## Why

Most OCR solutions process one image at a time in the foreground. BGOCRProcessor is designed for batch workloads — receipts, documents, medical records, scanned pages — where you need to queue many images and have them processed reliably, even if the app is backgrounded or killed.

- **Persistent queue** — images are tracked in SQLite. Nothing gets lost.
- **Background execution** — processing continues via `BGProcessingTask` when the app is backgrounded.
- **Kill recovery** — if iOS terminates the app mid-processing, stale items are automatically recovered on next launch.
- **Fully on-device** — uses Apple Vision. No network, no API keys, no privacy concerns.

## Features

- Batch enqueue with grouped batch IDs
- Real-time event stream (`AsyncStream<OCREvent>`) for progress and results
- Bounding box coordinates with confidence scores for each detected text region
- Adaptive concurrency — 4 threads in foreground, 1 in background
- Automatic image downscaling in background to reduce memory pressure
- Memory and disk space checks before processing
- 3-strike retry policy with permanent failure marking
- Auto-purge of old completed items
- React Native bridge (`BGOCRProcessorRN`) included
- 43 tests covering end-to-end flows, unit tests, and recovery scenarios

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/abhip2565/bg-ocr.git", branch: "master")
]
```

Or in Xcode: File > Add Package Dependencies > paste the URL above.

## Setup

### 1. Info.plist

Add the BGTask identifier and background mode:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.bgocrprocessor.processing</string>
</array>
<key>UIBackgroundModes</key>
<array>
    <string>processing</string>
</array>
```

### 2. Configure on launch

Call `configure()` as early as possible — ideally in your `App.init()` or `application(_:didFinishLaunchingWithOptions:)`:

```swift
import BGOCRProcessor

@main
struct MyApp: App {
    init() {
        OCRProcessor.configure()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

This registers the BGTask handler, starts observing app state, and recovers any items left over from a previous session.

## Usage

### Enqueue images

```swift
let processor = OCRProcessor.shared
let batchID = try await processor.enqueue([
    "/path/to/image1.jpg",
    "/path/to/image2.png",
    "/path/to/image3.heic"
])
```

Returns a `batchID` you can use to track progress.

### Listen for results

```swift
let stream = await processor.events

for await event in stream {
    switch event.result {
    case .success(let result):
        print("Text: \(result.text)")
        for box in result.boundingBoxes {
            print("  '\(box.text)' at \(box.normalizedRect) confidence=\(box.confidence)")
        }
    case .failure(let error):
        print("Failed: \(error)")
    }
}
```

Each `OCREvent` includes:
- `id` — unique item identifier
- `imagePath` — path to the source image
- `batchID` — the batch this item belongs to
- `index` / `totalCount` — progress within the batch
- `result` — `Result<OCRResult, OCRError>`
- `timestamp`

### Track progress

```swift
let (completed, total) = try await processor.progress(for: batchID)
```

### Monitor processor state

```swift
for await state in await processor.stateStream {
    switch state {
    case .idle:
        print("Queue empty")
    case .processing(let completed, let total):
        print("Processing \(completed)/\(total)")
    case .paused(let completed, let total):
        print("Paused at \(completed)/\(total)")
    }
}
```

### Pause / Resume

```swift
await processor.pauseProcessing()
await processor.resumeProcessing()
```

### Cancel all

```swift
try await processor.cancelAll()
```

### Retrieve completed results from DB

Useful after a force-kill recovery — fetch results that were completed but not yet consumed:

```swift
let items = try await processor.unprocessedResults()
for item in items {
    print(item.resultJSON ?? "no result")
}

// Mark them as consumed
try await processor.markJSProcessed(items.map { $0.id })
```

## Architecture

```
OCRProcessor (actor)           — public API, orchestrates everything
  PersistentQueue (actor)      — SQLite-backed FIFO queue
    DatabaseConnection         — SQLite3 wrapper with WAL mode + busy retry
  OCREngine                    — Vision framework text recognition
  ImagePipeline                — CGImage loading + downscaling
  AppStateObserver (actor)     — foreground/background/BGTask state tracking
  ConcurrencyPolicy            — adaptive limits based on app state
  BGTaskCoordinator            — BGProcessingTask registration + scheduling
```

### Thread safety

All mutable state lives inside Swift actors (`OCRProcessor`, `PersistentQueue`, `AppStateObserver`). No manual locks. SQLite runs in WAL mode with `SQLITE_BUSY` retry for safe concurrent reads.

### Background execution lifecycle

1. **App foreground** — processes at up to 4 concurrent threads, full-resolution images.
2. **App backgrounded** — iOS gives ~30s grace period. Concurrency drops to 1, images downscaled to 2048px max. A `BGProcessingTask` is scheduled.
3. **iOS suspends app** — processing freezes. Scheduled BGTask fires later (when device is idle/charging).
4. **iOS kills app** — items stuck in "processing" are recovered on next launch via `resetStaleProcessing()`.
5. **User force-kills app** — same recovery on next manual launch. iOS does not run BGTasks for force-killed apps.

### Retry policy

Each item gets 3 attempts. If all 3 fail (including across app kills), the item is marked as permanently failed and won't be retried.

## Bounding Boxes

Bounding box coordinates are normalized (0–1) with origin at **top-left**:

```swift
let box = result.boundingBoxes[0]
// box.normalizedRect.origin.x  — fraction from left edge
// box.normalizedRect.origin.y  — fraction from top edge
// box.normalizedRect.width     — fraction of image width
// box.normalizedRect.height    — fraction of image height
// box.confidence               — 0.0 to 1.0
```

To convert to display coordinates:

```swift
let displayX = box.normalizedRect.origin.x * displayWidth
let displayY = box.normalizedRect.origin.y * displayHeight
let displayW = box.normalizedRect.width * displayWidth
let displayH = box.normalizedRect.height * displayHeight
```

## React Native

A bridge module is included at `BGOCRProcessorRN`. It exposes the library to React Native via native modules.

## Sample App

A complete sample iOS app is included in `SampleApp/`. It demonstrates:

- Photo gallery picker (up to 500 images)
- Batch OCR processing with progress
- Results list with extracted text
- Bounding box overlay on images
- Force-kill recovery

To run:

```bash
cd SampleApp
brew install xcodegen  # if not installed
xcodegen generate
open SampleOCR.xcodeproj
```

## Testing

```bash
xcodebuild test \
  -scheme BGOCRProcessor-Package \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.1'
```

43 tests covering:
- End-to-end OCR processing (single, batch, errors)
- BGTask kill recovery and retry exhaustion
- Image pipeline (JPEG, PNG, HEIC, downscaling, corrupt files)
- Persistent queue operations (enqueue, dequeue, status transitions, purge)
- Processor state management

### Testing BGTask locally

While the app is running in the debugger:

1. Enqueue images and background the app
2. Pause the debugger
3. Run in lldb:
   ```
   e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.bgocrprocessor.processing"]
   ```
4. Resume the debugger

## License

MIT
