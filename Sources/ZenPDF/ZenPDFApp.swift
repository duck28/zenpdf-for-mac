import AppKit
import SwiftUI

@main
struct ZenPDFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DocumentModel()

    var body: some Scene {
        // One window. Files opened from Finder or the Dock arrive through onOpenURL; SwiftUI opens the window for
        // them at launch, and handlesExternalEvents sends later ones to the existing window instead of a new one.
        WindowGroup("ZenPDF", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.appearance.apply()
                    // Give a file the app was launched with a moment to arrive before reopening last session's.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        model.restoreSession()
                    }
                }
                .onOpenURL { url in
                    if FileKind(url: url) != nil { model.open(url) }
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1280, height: 840)
        .commands { ZenCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: DocumentModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        return model.confirmDiscard(action: "quit") ? .terminateNow : .terminateCancel
    }
}

struct ZenCommands: Commands {
    let model: DocumentModel

    /// Text fields keep their own undo; everything else undoes annotations.
    private var textViewHasFocus: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }.keyboardShortcut("o")
            Button("Open Folder…") { model.showOpenFolderPanel() }.keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model.save() }.keyboardShortcut("s").disabled(!model.hasDocument)
            Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!model.hasDocument)
            Divider()
            Button("Export Flattened PDF…") { model.exportFlattened() }.disabled(!model.isPDF)
            Button("Export Page as PNG…") { model.exportPageImage() }.disabled(!model.isPDF)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if textViewHasFocus { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { model.undo() }
            }
            .keyboardShortcut("z")
            Button("Redo") {
                if textViewHasFocus { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Annotation") { model.deleteSelection() }
                .disabled(model.selectedID == nil)
        }
        CommandGroup(before: .sidebar) {
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("+")
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("=")
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-")
            Button("Actual Size") { model.setZoom(1) }.keyboardShortcut("0")
            Button("Fit Width") { model.fitWidth() }.disabled(!model.isPDF)
            Button("Fit Page") { model.fitPage() }.disabled(!model.isPDF)
            Divider()
            Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") { model.isSidebarVisible.toggle() }
                .keyboardShortcut("b")
            Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }
        CommandMenu("Tools") {
            ForEach(Self.tools, id: \.tool) { item in
                Button(item.title) { model.activeTool = item.tool }.disabled(!model.isPDF)
            }
        }
    }

    private static let tools: [(tool: ToolType, title: String)] = [
        (.select, "Select (V)"), (.highlighter, "Highlighter (H)"), (.pen, "Pen (P)"), (.text, "Text (T)"),
        (.rect, "Rectangle (R)"), (.circle, "Ellipse (O)"), (.line, "Line (L)"), (.arrow, "Arrow (A)"),
        (.measure, "Ruler (M)"), (.cite, "Citation (C)"), (.eraser, "Eraser (E)"),
    ]
}
