#if canImport(React)
import Foundation
import BGOCRProcessor
import React

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

    private func eventToDictionary(_ event: OCREvent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": event.id,
            "imagePath": event.imagePath,
            "batchID": event.batchID,
            "index": event.index,
            "totalCount": event.totalCount,
            "timestamp": event.timestamp.timeIntervalSince1970
        ]

        switch event.result {
        case .success(let result):
            dict["text"] = result.text
            dict["boundingBoxes"] = result.boundingBoxes.map { box in
                [
                    "text": box.text,
                    "x": box.normalizedRect.origin.x,
                    "y": box.normalizedRect.origin.y,
                    "width": box.normalizedRect.size.width,
                    "height": box.normalizedRect.size.height,
                    "confidence": box.confidence
                ] as [String: Any]
            }
        case .failure(let error):
            dict["error"] = error.localizedDescription
        }

        return dict
    }

    private func queueItemToDictionary(_ item: QueueItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id,
            "imagePath": item.imagePath,
            "batchID": item.batchID,
            "status": item.status.rawValue,
            "attemptCount": item.attemptCount,
            "jsProcessed": item.jsProcessed,
            "createdAt": item.createdAt.timeIntervalSince1970,
            "updatedAt": item.updatedAt.timeIntervalSince1970
        ]

        if let resultJSON = item.resultJSON {
            dict["resultJSON"] = resultJSON
        }
        if let errorMessage = item.errorMessage {
            dict["errorMessage"] = errorMessage
        }

        return dict
    }
}
#endif
