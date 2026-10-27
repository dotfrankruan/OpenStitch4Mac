import CoreGraphics
import Foundation
import Observation

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Observable state for the single stitching workspace.
@MainActor
@Observable
final class StitchWorkspace {
    struct Screenshot: Identifiable {
        let id = UUID()
        let url: URL
        let pixelWidth: Int
        let pixelHeight: Int
        /// Small copy used by the list; the full-resolution image is only decoded while stitching.
        let thumbnail: CGImage

        var fileName: String { url.lastPathComponent }
    }

    private(set) var screenshots: [Screenshot] = []
    private(set) var result: StitchResult?

    var isLoading = false
    var isStitching = false
    var isImporting = false
    var isShowingResult = false
    var alert: AlertMessage?

    let maximumSelectionCount = 20

    var isBusy: Bool { isLoading || isStitching }
    var canStitch: Bool { screenshots.count >= 2 && !isBusy }

    // MARK: - Importing

    func requestImport() {
        isImporting = true
    }

    /// Imports image files in the order given. Files that cannot be decoded are skipped
    /// and reported, matching the iOS app's explicit-error behaviour.
    func add(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        isLoading = true
        alert = nil
        defer { isLoading = false }

        var notices: [String] = []
        var candidates = urls.filter(ImageLoader.isSupportedImage)
        guard !candidates.isEmpty else {
            alert = AlertMessage(
                title: "Couldn’t add screenshots",
                message: "Those files do not look like supported images."
            )
            return
        }
        if candidates.count > maximumSelectionCount {
            candidates = Array(candidates.prefix(maximumSelectionCount))
            notices.append("You can add up to \(maximumSelectionCount) screenshots at once, so only the first \(maximumSelectionCount) files were added.")
        }

        let imported = await Task.detached(priority: .userInitiated) { () -> [ImportedScreenshot] in
            var items: [ImportedScreenshot] = []
            items.reserveCapacity(candidates.count)
            for url in candidates {
                guard let metadata = ImageLoader.metadata(for: url),
                      let thumbnail = ImageLoader.thumbnail(url: url) else {
                    continue
                }
                items.append(
                    ImportedScreenshot(
                        url: url,
                        pixelWidth: metadata.pixelWidth,
                        pixelHeight: metadata.pixelHeight,
                        thumbnail: SendableImage(cgImage: thumbnail)
                    )
                )
            }
            return items
        }.value

        guard !imported.isEmpty else {
            alert = AlertMessage(
                title: "Couldn’t add screenshots",
                message: "The selected files could not be opened as images."
            )
            return
        }
        if imported.count < candidates.count {
            notices.append("Some files could not be read and were skipped.")
        }

        screenshots.append(contentsOf: imported.map { item in
            Screenshot(
                url: item.url,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                thumbnail: item.thumbnail.cgImage
            )
        })
        result = nil

        if !notices.isEmpty {
            alert = AlertMessage(title: "Import finished with warnings", message: notices.joined(separator: "\n\n"))
        }
    }

    // MARK: - Editing

    func remove(at index: Int) {
        guard screenshots.indices.contains(index) else { return }
        screenshots.remove(at: index)
        result = nil
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        screenshots.move(fromOffsets: offsets, toOffset: destination)
        result = nil
    }

    func move(from index: Int, by offset: Int) {
        let destination = index + offset
        guard screenshots.indices.contains(index), screenshots.indices.contains(destination) else { return }
        screenshots.swapAt(index, destination)
        result = nil
    }

    func clear() {
        screenshots.removeAll()
        result = nil
        alert = nil
        isShowingResult = false
    }

    // MARK: - Stitching

    func stitch() async {
        guard screenshots.count >= 2 else {
            presentError(StitchError.notEnoughImages)
            return
        }

        isStitching = true
        result = nil
        defer { isStitching = false }
        // Give SwiftUI a chance to render the progress indicator before the CPU work starts.
        await Task.yield()

        let urls = screenshots.map(\.url)
        do {
            let boxed = try await Task.detached(priority: .userInitiated) { () -> SendableBox<StitchResult> in
                var images: [CGImage] = []
                images.reserveCapacity(urls.count)
                for (index, url) in urls.enumerated() {
                    guard let image = ImageLoader.loadImage(url: url) else {
                        throw StitchError.unreadableImage(index)
                    }
                    images.append(image)
                }
                return SendableBox(value: try ImageStitcher().stitch(images))
            }.value

            result = boxed.value
            isShowingResult = true
        } catch {
            presentError(error)
        }
    }

    func presentError(_ error: Error, title: String = "Couldn’t stitch screenshots") {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert = AlertMessage(title: title, message: message)
    }

    func dismissResult() {
        isShowingResult = false
    }
}

/// Value type returned by the background import task.
private struct ImportedScreenshot: Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    let thumbnail: SendableImage
}
