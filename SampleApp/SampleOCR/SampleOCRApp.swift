import SwiftUI
import BGOCRProcessor

@main
struct SampleOCRApp: App {

    init() {
        OCRProcessor.configure()
    }

    var body: some Scene {
        WindowGroup {
            GalleryPickerView()
        }
    }
}
