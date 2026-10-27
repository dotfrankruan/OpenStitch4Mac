import AppKit

extension Notification.Name {
    /// Posted when image files should be added to the current workspace.
    static let openStitchOpenURLs = Notification.Name("OpenStitchOpenURLs")
}

/// Handles files opened from Finder ("Open With"), dropped on the Dock icon, or
/// passed on the command line, which is also how the UI verification scripts drive
/// the app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var pendingURLs: [URL] = []

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Paths passed directly to the executable, e.g. when screenshots are generated
        // and fed to the app by a script: `OpenStitch.app/Contents/MacOS/OpenStitch a.png b.png`.
        let arguments = ProcessInfo.processInfo.arguments.dropFirst()
        let urls = arguments
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: $0) }
            .filter { ImageLoader.isSupportedImage($0) }
        if !urls.isEmpty {
            enqueue(urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let images = urls.filter { ImageLoader.isSupportedImage($0) }
        guard !images.isEmpty else { return }
        enqueue(images)
    }

    /// Returns and clears the queued URLs. ContentView drains this on appear so files
    /// opened before the window exists are not lost.
    func takePendingURLs() -> [URL] {
        defer { pendingURLs.removeAll() }
        return pendingURLs
    }

    private func enqueue(_ urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        NotificationCenter.default.post(name: .openStitchOpenURLs, object: urls)
    }
}
