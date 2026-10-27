import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(StitchWorkspace.self) private var workspace
    @State private var isDropTargeted = false
    @State private var hasAutoStitched = false

    var body: some View {
        @Bindable var workspace = workspace

        NavigationStack {
            // ZStack (rather than Group) keeps the modifiers below attached to a view
            // with stable identity, so .task/.onChange keep firing when the empty state
            // swaps to the screenshot list.
            ZStack {
                if workspace.screenshots.isEmpty {
                    emptyState
                } else {
                    screenshotWorkspace
                }
            }
            .frame(minWidth: 760, minHeight: 540)
            .navigationTitle("OpenStitch")
            .toolbar { toolbarContent }
            .fileImporter(
                isPresented: $workspace.isImporting,
                allowedContentTypes: [.image],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await workspace.add(urls: urls) }
                case .failure(let error):
                    workspace.presentError(error, title: "Couldn’t add screenshots")
                }
            }
            .sheet(isPresented: $workspace.isShowingResult) {
                if let result = workspace.result {
                    ResultView(result: result)
                }
            }
            .alert(
                workspace.alert?.title ?? "",
                isPresented: Binding(
                    get: { workspace.alert != nil },
                    set: { if !$0 { workspace.alert = nil } }
                ),
                presenting: workspace.alert
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
            .overlay {
                if workspace.isBusy {
                    progressOverlay
                }
            }
            .disabled(workspace.isBusy)
            .dropDestination(for: URL.self) { urls, _ in
                let images = urls.filter { ImageLoader.isSupportedImage($0) }
                guard !images.isEmpty else { return false }
                Task { await workspace.add(urls: images) }
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    dropHighlight
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openStitchOpenURLs)) { _ in
                Task {
                    await loadOpenedFiles()
                    await autoStitchIfRequested()
                }
            }
            .onChange(of: workspace.screenshots.count) { _, _ in
                Task { await autoStitchIfRequested() }
            }
            .task {
                await loadOpenedFiles()
                await autoStitchIfRequested()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Make a Long Screenshot", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Choose two or more screenshots with overlapping content, in top-to-bottom order. Everything stays on this Mac.")
        } actions: {
            VStack(spacing: 12) {
                Button {
                    workspace.requestImport()
                } label: {
                    Label("Choose Screenshots…", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("or drag image files into this window")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Workspace

    private var screenshotWorkspace: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(workspace.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                    ScreenshotRow(
                        screenshot: screenshot,
                        index: index,
                        count: workspace.screenshots.count,
                        moveUp: { workspace.move(from: index, by: -1) },
                        moveDown: { workspace.move(from: index, by: 1) },
                        remove: { workspace.remove(at: index) }
                    )
                }
                .onMove { offsets, destination in
                    workspace.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .listStyle(.inset)

            Divider()
            bottomBar
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Keep the screenshots in top-to-bottom order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("\(workspace.screenshots.count) screenshot\(workspace.screenshots.count == 1 ? "" : "s") · drag rows to reorder, or use the arrows")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if workspace.result != nil {
                Button {
                    workspace.isShowingResult = true
                } label: {
                    Label("Show Result", systemImage: "rectangle.portrait.and.arrow.forward")
                }
                .buttonStyle(.bordered)
                .help("Show the stitched long screenshot (⌘E)")
            }

            Button {
                Task { await workspace.stitch() }
            } label: {
                Label("Stitch \(workspace.screenshots.count)", systemImage: "wand.and.stars")
                    .frame(minWidth: 128)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(workspace.screenshots.count < 2)
            .help("Find the overlaps and render the long screenshot (⌘↩)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                workspace.requestImport()
            } label: {
                Label("Add Screenshots", systemImage: "plus")
            }
            .help("Add more screenshots (⌘O)")

            if !workspace.screenshots.isEmpty {
                Button(role: .destructive) {
                    workspace.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Remove all screenshots (⇧⌘⌫)")
            }
        }
    }

    // MARK: - Overlays

    private var progressOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(workspace.isLoading ? "Loading screenshots…" : "Finding overlaps…")
                .font(.callout)
        }
        .padding(26)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .transition(.opacity)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
            .background(
                Color.accentColor.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(10)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    // MARK: - File opening

    /// Drains image URLs queued by the app delegate (Finder "Open With", Dock drops and
    /// command-line launches).
    private func loadOpenedFiles() async {
        guard let urls = AppDelegate.shared?.takePendingURLs(), !urls.isEmpty else { return }
        await workspace.add(urls: urls)
    }

    /// Verification hook: when the app is launched from a script with
    /// `OPENSTITCH_AUTOSTITCH=1`, add the supplied files and immediately stitch them so
    /// screenshots of the result can be captured automatically.
    private func autoStitchIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPENSTITCH_AUTOSTITCH"] == "1" else { return }
        guard !hasAutoStitched else { return }

        // Files opened by the launcher may still be importing when this runs, so give
        // the workspace a short, bounded window to receive them before stitching.
        for _ in 0..<50 {
            if workspace.screenshots.count >= 2, !workspace.isBusy {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard workspace.screenshots.count >= 2, !workspace.isStitching else { return }

        hasAutoStitched = true
        await workspace.stitch()
        #endif
    }
}

#Preview {
    ContentView()
        .environment(StitchWorkspace())
}
