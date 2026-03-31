# BGOCRProcessor — Architecture Diagrams

## 1. Component Dependency Graph

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BGOCRProcessorRN (Target)                        │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    OCRBridgeModule                            │  │
│  │  (RCTEventEmitter — bridges RN ↔ Swift)                      │  │
│  │  enqueue / cancelAll / getProgress / getUnprocessedResults    │  │
│  │  markJSProcessed / event streaming                           │  │
│  └──────────────────────────┬────────────────────────────────────┘  │
└─────────────────────────────┼───────────────────────────────────────┘
                              │ uses
┌─────────────────────────────▼───────────────────────────────────────┐
│                    BGOCRProcessor (Core Target)                      │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                     OCRProcessor (actor)                      │   │
│  │           Central orchestrator — singleton (.shared)          │   │
│  └───┬──────────┬──────────┬──────────┬──────────┬──────────────┘   │
│      │          │          │          │          │                   │
│      ▼          ▼          ▼          ▼          ▼                   │
│ ┌─────────┐┌─────────┐┌────────┐┌──────────┐┌──────────────────┐   │
│ │Persistent││  Image  ││  OCR   ││AppState  ││ BGTask           │   │
│ │Queue     ││Pipeline ││Engine  ││Observer  ││ Coordinator      │   │
│ │(actor)   ││(struct) ││(struct)││(actor)   ││ (class, Sendable)│   │
│ └────┬─────┘└─────────┘└────────┘└──────────┘└──────────────────┘   │
│      │                                                               │
│      ▼                                                               │
│ ┌─────────────────┐   ┌──────────────────┐   ┌────────────────┐    │
│ │DatabaseConnection│   │ConcurrencyPolicy │   │    Models       │    │
│ │(class, SQLite3)  │   │(struct, static)  │   │ QueueItem       │    │
│ └─────────────────┘   └──────────────────┘   │ OCRResult       │    │
│                                               │ OCREvent        │    │
│                                               │ OCRError        │    │
│                                               │ ProcessorState  │    │
│                                               │ BoundingBox     │    │
│                                               │ AppState        │    │
│                                               └────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Initialization / Configure Flow

```
App Launch (AppDelegate)
        │
        ▼
OCRProcessor.configure()
        │
        ├──→ OCRProcessor.shared (lazy singleton init)
        │         │
        │         ├── PersistentQueue(databasePath:)
        │         │         └── DatabaseConnection(path:)
        │         │               └── sqlite3_open → PRAGMA WAL
        │         │
        │         ├── OCREngine()
        │         ├── AppStateObserver()
        │         ├── BGTaskCoordinator()
        │         └── ImagePipeline()
        │
        ├──→ queue.resetStaleProcessing()
        │         └── Items stuck in .processing → .pending (retry)
        │                                        → .permanentlyFailed (if attempts ≥ 3)
        │
        ├──→ bgTaskCoordinator.register(processor:)
        │         └── BGTaskScheduler.shared.register(taskIdentifier)
        │
        ├──→ appStateObserver.startObserving()
        │         └── Listens: didBecomeActive → .foreground
        │                      didEnterBackground → .background
        │
        └──→ startStateObservation()
                  └── On .foreground transition → resumeIfPendingWork()
```

---

## 3. Enqueue & Processing Pipeline

```
RN / Swift caller
        │
        ▼
enqueue(paths) ──→ returns batchID (UUID)
        │
        ├──→ queue.enqueue(paths, batchID)
        │         └── INSERT OR IGNORE into SQLite (dedup by image_path+batch_id)
        │
        ├──→ startProcessingIfNeeded()
        │         └── Spawns processingLoop() Task if none running
        │
        └──→ bgTaskCoordinator.scheduleIfNeeded()
                  └── Submit BGProcessingTaskRequest
```

```
processingLoop()
        │
        ▼
┌───────────────────────────────────────────────────────────────┐
│  while !cancelled && !paused:                                 │
│                                                               │
│  1. Check app state → get concurrency limit & max dimension   │
│     ┌─────────────────────────────────────────────────┐       │
│     │ ConcurrencyPolicy.limit(for:)                   │       │
│     │   .foreground  → min(CPU cores, 4)              │       │
│     │   .background  → 1                              │       │
│     │ ConcurrencyPolicy.maxImageDimension(for:)       │       │
│     │   .foreground  → 4096                           │       │
│     │   .background  → 2048                           │       │
│     └─────────────────────────────────────────────────┘       │
│                                                               │
│  2. Guard: memory ≥ 30MB  (else break, schedule BGTask)       │
│  3. Guard: disk   ≥ 50MB  (else break, emit error event)     │
│                                                               │
│  4. queue.dequeue(limit: concurrencyLimit)                    │
│     └── SELECT pending items, mark .processing                │
│                                                               │
│  5. Process items concurrently (TaskGroup):                   │
│     ┌─────────────────────────────────────────────────┐       │
│     │  processItem(item, maxDimension)                │       │
│     │    │                                            │       │
│     │    ├── Check file exists                        │       │
│     │    ├── ImagePipeline.prepare()                  │       │
│     │    │     ├── Load CGImage from disk             │       │
│     │    │     ├── Read EXIF orientation              │       │
│     │    │     ├── Apply orientation transform        │       │
│     │    │     └── Resize if > maxDimension           │       │
│     │    ├── OCREngine.recognize(image:)              │       │
│     │    │     └── VNRecognizeTextRequest (accurate)  │       │
│     │    │           → OCRResult { text, boxes[] }    │       │
│     │    ├── queue.markCompleted(resultJSON)           │       │
│     │    └── emitEvent(OCREvent)                      │       │
│     └─────────────────────────────────────────────────┘       │
│                                                               │
│  6. Auto-purge every 100 items processed                      │
│     └── DELETE items where js_processed=1 & purge_after < now │
│                                                               │
│  7. Update state → .processing(completed, total)              │
│                                                               │
│  Loop until: no more pending items → .idle                    │
│              paused → .paused(completed, total)               │
└───────────────────────────────────────────────────────────────┘
```

---

## 4. Error Handling & Retry Flow

```
processItem() fails
        │
        ▼
  attemptCount + 1
        │
        ├── < 3 attempts ──→ queue.markFailed()
        │                     status → .failed
        │                     (will be retried on next cycle / app relaunch)
        │
        └── ≥ 3 attempts ──→ queue.markPermanentlyFailed()
                              status → .permanentlyFailed
                              emit .maxRetriesExceeded event

Specific error mappings:
  ├── File not found      → .permanentlyFailed (no retry)
  ├── Unsupported format  → OCRError.unsupportedFormat
  ├── Corrupt image       → OCRError.corruptImage
  ├── Vision failure      → OCRError.ocrFailed
  └── Disk space low      → OCRError.diskSpaceLow (loop breaks)
```

---

## 5. Queue Item State Machine

```
          enqueue()
              │
              ▼
        ┌──────────┐
        │  PENDING  │ ◄──── resetStaleProcessing() (if attempts < 3)
        │  (0)      │
        └─────┬─────┘
              │ dequeue()
              ▼
        ┌──────────────┐
        │  PROCESSING   │
        │  (1)          │
        └──┬─────┬──┬──┘
           │     │  │
   success │     │  │ failure (attempts < 3)
           │     │  │
           ▼     │  ▼
   ┌───────────┐ │ ┌────────┐
   │ COMPLETED │ │ │ FAILED │ ──→ (picked up as pending
   │ (2)       │ │ │ (3)    │      on next resetStale)
   └─────┬─────┘ │ └────────┘
         │       │
  markJS │       │ failure (attempts ≥ 3)
Processed│       │   OR file not found
         ▼       ▼
   ┌───────────────────────┐
   │ js_processed = 1      │
   │ purge_after = now+72h │
   └─────────┬─────────────┘
             │ autoPurge()
             ▼               ┌─────────────────────┐
        (DELETED)            │ PERMANENTLY_FAILED   │
                             │ (4)                  │
                             └─────────────────────┘
```

---

## 6. Background Task Lifecycle

```
App enters background
        │
        ▼
AppStateObserver → .background
ConcurrencyPolicy → limit=1, maxDim=2048
        │
        ▼
iOS wakes app for BGProcessingTask
        │
        ▼
BGTaskCoordinator handler fires
        │
        ├── appStateObserver.overrideState(.backgroundTask)
        ├── processor.resumeProcessing()
        │
        ├── [processes items with limit=1]
        │
        ├── expirationHandler → processor.pauseProcessing()
        │
        ├── Waits for .idle or .paused state
        │
        ├── If pending > 0 → scheduleIfNeeded() (re-schedule)
        │
        └── task.setTaskCompleted(success: true)
```

---

## 7. React Native Bridge Event Flow

```
OCRBridgeModule (RCTEventEmitter)
        │
        │  startObserving()
        │    └── subscribes to OCRProcessor.shared.events
        │
        │  for await event in events:
        │    ├── .success → sendEvent("onOCRResult", body)
        │    └── .failure → sendEvent("onOCRError", body)
        │
        │  Exposed Methods:
        │    ├── enqueue([paths])      → Promise<batchID>
        │    ├── getProgress(batchID)  → Promise<{completed, total}>
        │    ├── getUnprocessedResults → Promise<[QueueItem]>
        │    ├── markJSProcessed([ids])→ void (fire & forget)
        │    └── cancelAll()           → Promise<void>
        │
        │  stopObserving()
        │    └── cancels event subscription Task
```

---

## 8. Data Flow Summary

```
[Image Paths]
      │
      ▼
  Enqueue ──→ SQLite Queue ──→ Dequeue (batch)
                                    │
                              ┌─────┴─────┐
                              ▼           ▼    (concurrent, up to 4)
                         ImagePipeline  ImagePipeline
                              │           │
                         Load + EXIF  Load + EXIF
                         + Resize     + Resize
                              │           │
                         OCREngine    OCREngine
                         (Vision)     (Vision)
                              │           │
                              ▼           ▼
                         OCRResult    OCRResult
                              │           │
                              └─────┬─────┘
                                    │
                              Store in SQLite
                              Emit OCREvent
                                    │
                           ┌────────┴────────┐
                           ▼                 ▼
                     Swift caller     RN Bridge
                     (stateStream)    (onOCRResult)
                                      (onOCRError)
                                           │
                                    markJSProcessed
                                           │
                                    purge_after = +72h
                                           │
                                    autoPurge (deleted)
```
