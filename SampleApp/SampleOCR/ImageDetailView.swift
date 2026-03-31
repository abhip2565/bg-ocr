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

    /// Vision normalizedRect has origin at bottom-left. Convert to top-left display coordinates.
    private func convertRect(_ normalized: CGRect, imageSize: CGSize, displaySize: CGSize) -> CGRect {
        let scaleX = displaySize.width / imageSize.width
        let scaleY = displaySize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let x = normalized.origin.x * imageSize.width * scale
        let y = (1 - normalized.origin.y - normalized.height) * imageSize.height * scale
        let w = normalized.width * imageSize.width * scale
        let h = normalized.height * imageSize.height * scale

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
