import SwiftUI
import PhotosUI

struct GalleryPickerView: View {

    @StateObject private var viewModel = OCRViewModel()
    @State private var showResults = false
    @State private var showPreview = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PhotosPicker(
                    selection: $viewModel.selectedPhotos,
                    maxSelectionCount: 500,
                    matching: .images
                ) {
                    Label("Select Photos", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(12)
                }
                .onChange(of: viewModel.selectedPhotos) { _ in
                    Task { await viewModel.loadSelectedPhotos() }
                    showPreview = viewModel.selectedPhotos.count <= 20
                }

                if !viewModel.savedImagePaths.isEmpty {
                    if viewModel.savedImagePaths.count > 20 {
                        Toggle("Show Previews", isOn: $showPreview)
                            .padding(.horizontal)
                    }

                    if showPreview {
                        ScrollView {
                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 100), spacing: 8)
                            ], spacing: 8) {
                                ForEach(viewModel.savedImagePaths, id: \.self) { path in
                                    if let uiImage = UIImage(contentsOfFile: path) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 100, height: 100)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    Text("\(viewModel.savedImagePaths.count) photos selected")
                        .foregroundColor(.secondary)

                    Button {
                        Task {
                            await viewModel.startOCR()
                            showResults = true
                        }
                    } label: {
                        HStack {
                            if viewModel.isProcessing {
                                ProgressView()
                                    .tint(.white)
                                Text("Processing \(viewModel.processedCount)/\(viewModel.totalCount)")
                            } else {
                                Image(systemName: "text.viewfinder")
                                Text("Start OCR")
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(viewModel.isProcessing ? Color.gray : Color.blue)
                        .cornerRadius(12)
                    }
                    .disabled(viewModel.isProcessing)
                }

                if viewModel.recoveredCount > 0 {
                    VStack(spacing: 8) {
                        Text("Recovered \(viewModel.recoveredCount) items from previous session")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                        if viewModel.isProcessing {
                            ProgressView("Processing \(viewModel.processedCount)/\(viewModel.totalCount)")
                        }
                        if !viewModel.results.isEmpty {
                            Button("View Results") { showResults = true }
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(12)
                }

                if let error = viewModel.error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("OCR Sample")
            .task { await viewModel.checkForRecoveredItems() }
            .toolbar {
                if !viewModel.savedImagePaths.isEmpty {
                    Button("Clear") { viewModel.reset() }
                }
            }
            .navigationDestination(isPresented: $showResults) {
                ResultsListView(viewModel: viewModel)
            }
        }
    }
}
