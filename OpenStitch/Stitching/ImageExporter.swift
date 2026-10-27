import AppKit
import CoreGraphics
import UniformTypeIdentifiers

/// Save panel, clipboard and Finder hand-off helpers (the macOS equivalent of the
/// iOS "Save to Photos" / share sheet flow).
@MainActor
enum ImageExporter {
    /// Shows a save panel and writes a PNG at the user's chosen location.
    /// Throws `CancellationError` when the user dismisses the panel.
    @discardableResult
    static func savePNGWithPanel(_ image: CGImage, suggestedName: String) throws -> URL {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Long Screenshot"
        panel.message = "Choose where to save the stitched PNG. Full resolution is preserved."

        guard panel.runModal() == .OK, let url = panel.url else {
            throw CancellationError()
        }
        try ImageLoader.writePNG(image, to: url)
        return url
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
