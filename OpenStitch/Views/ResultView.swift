import AppKit
import CoreGraphics
import SwiftUI

/// Modal preview of the stitched long screenshot with the macOS equivalents of the
/// iOS save/share actions.
struct ResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: StitchResult

    @State private var temporaryFileURL: URL?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            LongImagePreview(image: result.image)
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
                .task { await prepareShareFile() }
        }
        .frame(minWidth: 900, minHeight: 640)
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
        ImageExporter.savePNGWithPanel(
            result.image,
            suggestedName: ImageLoader.suggestedFileName()
        ) { outcome in
            switch outcome {
            case .success(let url):
                message = "Saved to \(url.path)."
            case .failure(is CancellationError):
                // The user dismissed the save panel; nothing to report.
                break
            case .failure(let error):
                message = "The image could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func copyToPasteboard() {
        if ImageExporter.copyToPasteboard(result.image) {
            message = "The long screenshot was copied to the clipboard."
        } else {
            message = "The image could not be copied to the clipboard."
        }
    }

    // MARK: - Sharing

    /// The PNG is exported to the temporary directory up front so `ShareLink` and
    /// "Open in Preview" can hand a real file to the system. The file lives in the
    /// OS-managed temp directory and is cleaned up by the system.
    private func prepareShareFile() async {
        let image = result.image
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            try? ImageLoader.writeTemporaryPNG(image)
        }.value
        temporaryFileURL = url
    }
}
