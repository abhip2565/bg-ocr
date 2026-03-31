import SwiftUI

struct ResultsListView: View {

    @ObservedObject var viewModel: OCRViewModel

    var body: some View {
        Group {
            if viewModel.isProcessing && viewModel.results.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Processing images...")
                        .foregroundColor(.secondary)
                }
            } else if viewModel.results.isEmpty {
                Text("No results yet")
                    .foregroundColor(.secondary)
            } else {
                List(viewModel.results) { result in
                    NavigationLink {
                        ImageDetailView(result: result)
                    } label: {
                        HStack(spacing: 12) {
                            if let uiImage = UIImage(contentsOfFile: result.imagePath) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.text.isEmpty ? "No text found" : result.text)
                                    .font(.body)
                                    .lineLimit(3)

                                Text("\(result.boundingBoxes.count) text regions")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("Results (\(viewModel.processedCount)/\(viewModel.totalCount))")
    }
}
