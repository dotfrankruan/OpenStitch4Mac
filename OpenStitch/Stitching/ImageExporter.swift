import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Save panel, clipboard and Finder hand-off helpers (the macOS equivalent of the
/// iOS "Save to Photos" / share sheet flow).
@MainActor
enum ImageExporter {
    /// Presents a save panel and writes the full-resolution PNG after the user picks a
    /// location. The panel is app-modal and floats above the result sheet, which keeps
    /// the sheet's own modal session untouched.
    static func savePNGWithPanel(
        _ image: CGImage,
        suggestedName: String,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Long Screenshot"
        panel.message = "Choose where to save the stitched PNG. Full resolution is preserved."

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                Task { @MainActor in
                    completion(.failure(CancellationError()))
                }
                return
            }
            // Encoding a very tall PNG can take a moment; keep it off the main thread.
            Task.detached(priority: .userInitiated) {
                do {
                    try ImageLoader.writePNG(image, to: url)
                    await MainActor.run {
                        completion(.success(url))
                    }
                } catch {
                    await MainActor.run {
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    /// Copies the stitched image to the general pasteboard so it can be pasted into
    /// other apps straight away (mirrors the iOS share target).
    static func copyToPasteboard(_ image: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        return pasteboard.writeObjects([nsImage])
    }

    static func openInPreview(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
