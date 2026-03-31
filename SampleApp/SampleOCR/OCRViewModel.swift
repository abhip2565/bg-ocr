import SwiftUI
import PhotosUI
import BGOCRProcessor

struct ImageResult: Identifiable {
    let id: String
    let imagePath: String
    let text: String
    let boundingBoxes: [BoundingBox]
}

@MainActor
final class OCRViewModel: ObservableObject {

    @Published var selectedPhotos: [PhotosPickerItem] = []
    @Published var savedImagePaths: [String] = []
    @Published var results: [ImageResult] = []
    @Published var isProcessing = false
    @Published var processedCount = 0
    @Published var totalCount = 0
    @Published var error: String?

    private var batchID: String?
    private var eventTask: Task<Void, Never>?

    private var tempDir: String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("SampleOCR")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func loadSelectedPhotos() async {
        savedImagePaths.removeAll()
        results.removeAll()
        error = nil

        for (index, item) in selectedPhotos.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let path = (tempDir as NSString).appendingPathComponent("photo_\(index).jpg")
            try? data.write(to: URL(fileURLWithPath: path))
            savedImagePaths.append(path)
        }
    }

    func startOCR() async {
        guard !savedImagePaths.isEmpty else { return }

        isProcessing = true
        processedCount = 0
        totalCount = savedImagePaths.count
        results.removeAll()
        error = nil

        let processor = OCRProcessor.shared

        // Start listening before enqueue
        eventTask = Task {
            let stream = await processor.events
            for await event in stream {
                self.handleEvent(event)
                if self.processedCount >= self.totalCount { break }
            }
        }

        do {
            batchID = try await processor.enqueue(savedImagePaths)
        } catch {
            self.error = error.localizedDescription
            isProcessing = false
        }
    }

    private func handleEvent(_ event: OCREvent) {
        switch event.result {
        case .success(let ocrResult):
            let result = ImageResult(
                id: event.id,
                imagePath: event.imagePath,
                text: ocrResult.text,
                boundingBoxes: ocrResult.boundingBoxes
            )
            results.append(result)
        case .failure(let ocrError):
            let result = ImageResult(
                id: event.id,
                imagePath: event.imagePath,
                text: "Error: \(ocrError)",
                boundingBoxes: []
            )
            results.append(result)
        }

        processedCount = results.count
        if processedCount >= totalCount {
            isProcessing = false
        }
    }

    func reset() {
        eventTask?.cancel()
        eventTask = nil
        selectedPhotos.removeAll()
        savedImagePaths.removeAll()
        results.removeAll()
        isProcessing = false
        processedCount = 0
        totalCount = 0
        error = nil
    }
}
