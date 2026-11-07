import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: DocumentModel

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.isSidebarVisible ? .all : .detailOnly },
            set: { model.isSidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            detail
                .toolbar { toolbar }
                .inspector(isPresented: Binding(
                    get: { model.isCitationPanelOpen },
                    set: { if !$0 && model.activeTool == .cite { model.activeTool = .select } }
                )) {
                    CitationPanel(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                }
        }
        .navigationTitle(model.fileName ?? "ZenPDF")
        .navigationSubtitle(model.isDirty ? "Edited" : "")
        .background(WindowCloseGuard { _ in model.confirmDiscard(action: "close the window") })
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { FileKind(url: $0) != nil }) else { return false }
            model.open(url)
            return true
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder private var detail: some View {
        if model.isPDF {
            ZStack(alignment: .top) {
                PDFCanvas(model: model)
                    .ignoresSafeArea(edges: .bottom)
                ToolDock(model: model)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
            }
            .background(Color.zenViewer)
        } else if model.textContent != nil {
            TextDocumentView(model: model)
        } else {
            WelcomeView(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if model.isDirty { AccentDot().help("Unsaved changes") }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.hasDocument {
                HStack(spacing: 0) {
                    Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out (⌘−)")
                    Button { model.setZoom(1) } label: {
                        Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 44)
                    }
                    .help("Actual size (⌘0)")
                    Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in (⌘+, or ⌘ and scroll)")
                }
                if model.isPDF {
                    Menu {
                        Button("Fit Width") { model.fitWidth() }
                        Button("Fit Page") { model.fitPage() }
                    } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Fit")
                }
            }
            Button { model.showOpenPanel() } label: { Image(systemName: "folder") }
                .help("Open a PDF, text or Markdown file (⌘O)")
            Button { model.save() } label: { Image(systemName: "square.and.arrow.down") }
                .disabled(!model.hasDocument)
                .help(model.isPDF ? "Save. Annotations stay editable. (⌘S)" : "Save (⌘S)")
            if model.isPDF {
                Menu {
                    Button("Flattened PDF…") { model.exportFlattened() }
                    Button("Page as PNG…") { model.exportPageImage() }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export")
            }
        }
    }
}

/// One mark, one line, two actions.
struct WelcomeView: View {
    let model: DocumentModel

    var body: some View {
        VStack(spacing: 0) {
            ZenLogo(size: 88).padding(.bottom, 32)
            Text("ZENPDF").font(.system(size: 22, weight: .light)).tracking(4.4).foregroundStyle(Color.zenInk)
                .padding(.bottom, 8)
            Text("Read, mark and cite — quietly.").font(.system(size: 13)).foregroundStyle(Color.zenInk3)
                .padding(.bottom, 40)
            HStack(spacing: 8) {
                Button { model.showOpenPanel() } label: { Label("Open File", systemImage: "doc") }
                    .buttonStyle(ZenButtonStyle(prominent: true))
                Button { model.showOpenFolderPanel() } label: { Label("Open Folder", systemImage: "folder") }
                    .buttonStyle(ZenButtonStyle())
            }
            Text("or drop a PDF, text or Markdown file here · ⌘O")
                .font(.system(size: 11)).tracking(0.4).foregroundStyle(Color.zenInk3)
                .padding(.top, 64)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.zenApp)
    }
}
