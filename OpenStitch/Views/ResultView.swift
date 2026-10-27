import AppKit
import SwiftUI

/// Modal preview of the stitched long screenshot with the macOS equivalents of the
/// iOS save/share actions.
struct ResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: StitchResult

    @State private var preview: CGImage?
    @State private var temporaryFileURL: URL?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            previewContent
                .navigationTitle("Long Screenshot")
                .safeAreaInset(edge: .bottom) { actionBar }
                .alert(
                    "Long Screenshot",
                    isPresented: Binding(
                        get: { message != nil },
                        set: { if !$0 { message = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(message ?? "")
                }
                .task { await prepare() }
                .onDisappear { cleanupTemporaryFile() }
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewContent: some View {
        if let preview {
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    let fitWidth = max(240, proxy.size.width - 48)
                    let scale = min(1, fitWidth / CGFloat(preview.width))
                    let displayWidth = CGFloat(preview.width) * scale
                    let displayHeight = CGFloat(preview.height) * scale

                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: displayWidth, height: displayHeight)
                        .padding(24)
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height,
                            alignment: .center
                        )
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        } else {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Preparing preview…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Label("\(result.width) × \(result.height) px", systemImage: "aspectratio")
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(result.overlaps.count + 1) screenshots")
                if !result.overlaps.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(overlapSummary)
                        .lineLimit(1)
                }
                Spacer()
                Text("Exports keep full resolution")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    copyToPasteboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the image to the clipboard")

                if let temporaryFileURL {
                    ShareLink(item: temporaryFileURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share the PNG with another app")

                    Button {
                        ImageExporter.openInPreview(temporaryFileURL)
                    } label: {
                        Label("Open in Preview", systemImage: "eye")
                    }
                    .help("Open the exported PNG in Preview")
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    savePNG()
                } label: {
                    Label("Save PNG…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save the full-resolution PNG (⌘S)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var overlapSummary: String {
        let shown = result.overlaps.prefix(6).map(String.init).joined(separator: ", ")
        let suffix = result.overlaps.count > 6 ? "…" : ""
        return "overlaps: \(shown)\(suffix) px"
    }

    // MARK: - Actions

    private func savePNG() {
        do {
            let url = try ImageExporter.savePNGWithPanel(
                result.image,
                suggestedName: ImageLoader.suggestedFileName()
            )
            message = "Saved to \(url.path)."
        } catch is CancellationError {
            // The user dismissed the save panel; no message needed.
        } catch {
            message = "The image could not be saved: \(error.localizedDescription)"
        }
    }

    private func copyToPasteboard() {
        if ImageExporter.copyToPasteboard(result.image) {
            message = "The long screenshot was copied to the clipboard."
        } else {
            message = "The image could not be copied to the clipboard."
        }
    }

    // MARK: - Preview preparation

    private func prepare() async {
        let image = result.image
        let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedResult in
            // A downscaled copy keeps SwiftUI rendering fast for very tall results while
            // the full-resolution image is used for every export.
            let preview = ImageLoader.downscaled(image, maxDimension: 6000)
            let url = try? ImageLoader.writeTemporaryPNG(image)
            return PreparedResult(preview: SendableImage(cgImage: preview), temporaryURL: url)
        }.value

        preview = prepared.preview.cgImage
        temporaryFileURL = prepared.temporaryURL
    }

    private func cleanupTemporaryFile() {
        guard let temporaryFileURL else { return }
        try? FileManager.default.removeItem(at: temporaryFileURL)
        self.temporaryFileURL = nil
    }
}

private struct PreparedResult: Sendable {
    let preview: SendableImage
    let temporaryURL: URL?
}
