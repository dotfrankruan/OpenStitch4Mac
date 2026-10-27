import SwiftUI

@main
struct OpenStitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace = StitchWorkspace()

    var body: some Scene {
        // A single window keeps OpenStitch focused: no "New Window" menu item and no
        // pile-up of restored windows on relaunch.
        Window("OpenStitch", id: "main") {
            ContentView()
                .environment(workspace)
        }
        .defaultSize(width: 980, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Screenshots…") {
                    workspace.requestImport()
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Stitch") {
                Button("Stitch Screenshots") {
                    Task { await workspace.stitch() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!workspace.canStitch)

                Button("Show Result") {
                    workspace.isShowingResult = true
                }
                .keyboardShortcut("e")
                .disabled(workspace.result == nil)

                Divider()

                Button("Clear Screenshots") {
                    workspace.clear()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(workspace.screenshots.isEmpty)
            }
        }
    }
}
