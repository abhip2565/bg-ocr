import SwiftUI
import BGOCRProcessor

struct ImageDetailView: View {

    let result: ImageResult
    @State private var showBoxes = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let uiImage = UIImage(contentsOfFile: result.imagePath) {
                    GeometryReader { geo in
                        let imageSize = uiImage.size
                        let displaySize = fitSize(imageSize: imageSize, in: geo.size)

                        ZStack(alignment: .topLeading) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: displaySize.width, height: displaySize.height)

                            if showBoxes {
                                ForEach(Array(result.boundingBoxes.enumerated()), id: \.offset) { _, box in
                                    let rect = convertRect(
                                        box.normalizedRect,
                                        imageSize: imageSize,
                                        displaySize: displaySize
                                    )
                                    Rectangle()
                                        .stroke(Color.red, lineWidth: 2)
                                        .background(Color.red.opacity(0.1))
                                        .frame(width: rect.width, height: rect.height)
                                        .position(x: rect.midX, y: rect.midY)
                                }
                            }
                        }
                        .frame(width: displaySize.width, height: displaySize.height)
                        .frame(maxWidth: .infinity)
                    }
                    .aspectRatio(uiImage.size.width / uiImage.size.height, contentMode: .fit)
                }

                Toggle("Show Bounding Boxes", isOn: $showBoxes)
                    .padding(.horizontal)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Extracted Text")
                        .font(.headline)

                    Text(result.text.isEmpty ? "No text found" : result.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)

                    Text("\(result.boundingBoxes.count) text regions detected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle("Detail")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// normalizedRect is already in top-left origin (converted in OCREngine). Just scale to display size.
    private func convertRect(_ normalized: CGRect, imageSize: CGSize, displaySize: CGSize) -> CGRect {
        let x = normalized.origin.x * displaySize.width
        let y = normalized.origin.y * displaySize.height
        let w = normalized.width * displaySize.width
        let h = normalized.height * displaySize.height

        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func fitSize(imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let scaleX = containerSize.width / imageSize.width
        let scaleY = containerSize.height / imageSize.height
        let scale = min(scaleX, scaleY)
        return CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
    }
}
