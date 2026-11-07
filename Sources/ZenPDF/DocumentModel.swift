import AppKit
import Observation
import PDFKit
import UniformTypeIdentifiers

/// One entry of the folder workspace, like FileEntry on Windows.
struct FileEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
    var children: [FileEntry]?

    var id: URL { url }
}

enum FileKind {
    case pdf, text, markdown

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "pdf": self = .pdf
        case "txt": self = .text
        case "md", "markdown": self = .markdown
        default: return nil
        }
    }
}

/// The state of the window: the open document, its annotations and history, the tools and the folder.
@MainActor
@Observable
final class DocumentModel {
    static let zoomRange = 0.25...5.0

    // Document
    private(set) var fileURL: URL?
    private(set) var fileName: String?
    private(set) var pdf: PDFDocument?
    /// Content of an open .txt or .md file (nil when a PDF or nothing is open).
    var textContent: String? {
        didSet { if oldValue != nil, textContent != oldValue { isDirty = true } }
    }
    private(set) var isMarkdown = false
    /// Changes whenever another document is opened.
    private(set) var documentID = 0
    private(set) var isDirty = false
    private(set) var pageCount = 0

    var hasDocument: Bool { pdf != nil || textContent != nil }
    var isPDF: Bool { pdf != nil }

    // Annotations
    private(set) var annotations: [Annotation] = []
    var selectedID: String?
    var source = DocumentSource() {
        didSet { if source != oldValue, isPDF { isDirty = true } }
    }
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // Tools
    var activeTool: ToolType = .select {
        didSet {
            if activeTool != .select && activeTool != .cite { selectedID = nil }
        }
    }
    var activeColor = "#e9b949"
    var toolWidths = WidthSpec.defaultWidths()
    var penType: PenType = .ballpoint
    var measureUnit: MeasureUnit = .cm
    var strokeWidth: Double {
        get { toolWidths[activeTool.widthKey] ?? 2 }
        set { toolWidths[activeTool.widthKey] = newValue }
    }
    var isCitationPanelOpen: Bool { activeTool == .cite && isPDF }

    // View
    var zoom = 1.0
    var currentPage = 1
    /// Set to scroll the viewer to a page; the viewer clears it.
    var jumpRequest: Int?
    var isSidebarVisible = true
    /// Filled in by the viewer, for Fit Width and Fit Page.
    var viewportSize: CGSize = .zero

    // Folder workspace
    private(set) var folderURL: URL?
    private(set) var folderTree: [FileEntry] = []

    /// Filled while views render, so it isn't observed.
    @ObservationIgnored private var thumbnails: [Int: NSImage] = [:]

    private enum Keys {
        static let lastFile = "zenpdf.lastFile"
        static let lastFolder = "zenpdf.lastFolder"
        static let appearance = "zenpdf.appearance"
        static let citationStyle = "zenpdf.citationStyle"
    }

    var appearance: AppAppearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "zenpdf.appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance)
            appearance.apply()
        }
    }

    var citationStyle: CitationStyle = CitationStyle(rawValue: UserDefaults.standard.string(forKey: "zenpdf.citationStyle") ?? "") ?? .apa {
        didSet { UserDefaults.standard.set(citationStyle.rawValue, forKey: Keys.citationStyle) }
    }

    // MARK: - Opening

    /// Asks to discard unsaved changes; true if it's fine to continue.
    func confirmDiscard(action: String = "open another document") -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = textContent != nil ? "You have unsaved changes." : "You have unsaved annotations."
        alert.informativeText = "Save them before you \(action)?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .plainText] + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if let folderURL { panel.directoryURL = folderURL }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func showOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    func open(_ url: URL, silent: Bool = false) {
        guard url.standardizedFileURL != fileURL?.standardizedFileURL else { return }
        guard let kind = FileKind(url: url) else { return }
        if !silent && !confirmDiscard() { return }
        do {
            switch kind {
            case .pdf:
                let loaded = try PDFFormat.load(try Data(contentsOf: url))
                reset(url: url)
                pdf = loaded.document
                pageCount = loaded.document.pageCount
                annotations = loaded.annotations
                source = loaded.source ?? metadataSource(loaded.document, name: url.lastPathComponent)
            case .text, .markdown:
                let content = try String(contentsOf: url, encoding: .utf8)
                reset(url: url)
                isMarkdown = kind == .markdown
                textContent = content
                activeTool = .select
            }
            isDirty = false
            UserDefaults.standard.set(url.path, forKey: Keys.lastFile)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            if silent {
                UserDefaults.standard.removeObject(forKey: Keys.lastFile)
            } else {
                showError("Couldn't open \(url.lastPathComponent)", error)
            }
        }
    }

    private func reset(url: URL) {
        fileURL = url
        fileName = url.lastPathComponent
        pdf = nil
        textContent = nil
        isMarkdown = false
        annotations = []
        selectedID = nil
        undoStack = []
        redoStack = []
        thumbnails = [:]
        pageCount = 0
        currentPage = 1
        jumpRequest = nil
        documentID += 1
    }

    /// The PDF's own metadata as a starting point for citations.
    private func metadataSource(_ document: PDFDocument, name: String) -> DocumentSource {
        let attributes = document.documentAttributes ?? [:]
        let fallbackTitle = (name as NSString).deletingPathExtension
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces)
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let year = Citations.year(from: attributes[PDFDocumentAttribute.creationDateAttribute] as? Date) ?? ""
        return DocumentSource(author: author, title: (title?.isEmpty == false ? title! : fallbackTitle), year: year)
    }

    // MARK: - Folder

    func openFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: Keys.lastFolder)
        refreshFolder()
        isSidebarVisible = true
    }

    func refreshFolder() {
        guard let folderURL else { return }
        folderTree = Self.scan(folderURL, depth: 0)
    }

    /// Folders first, then files, by name; only documents ZenPDF opens; six levels deep, like Windows.
    nonisolated static func scan(_ dir: URL, depth: Int) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        var entries: [FileEntry] = []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name == "node_modules" || name == "target" { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                entries.append(FileEntry(url: url, name: name, isDirectory: true, size: 0,
                                         modified: values?.contentModificationDate,
                                         children: depth < 6 ? scan(url, depth: depth + 1) : []))
            } else if FileKind(url: url) != nil {
                entries.append(FileEntry(url: url, name: name, isDirectory: false, size: Int64(values?.fileSize ?? 0),
                                         modified: values?.contentModificationDate, children: nil))
            }
        }
        return entries.sorted {
            $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Reopens the folder and file from last time.
    func restoreSession() {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: Keys.lastFolder) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                openFolder(URL(fileURLWithPath: path))
            }
        }
        if fileURL == nil, let path = defaults.string(forKey: Keys.lastFile) {
            if FileManager.default.fileExists(atPath: path) {
                open(URL(fileURLWithPath: path), silent: true)
            } else {
                defaults.removeObject(forKey: Keys.lastFile)
            }
        }
    }

    // MARK: - Annotations and history

    private func commit(_ next: [Annotation]) {
        undoStack.append(annotations)
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
        redoStack = []
        annotations = next
        isDirty = true
    }

    func add(_ annotation: Annotation) {
        commit(annotations + [annotation])
        // New citations open straight into the panel for editing.
        if annotation.type == .cite { selectedID = annotation.id }
    }

    func update(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }), annotations[index] != annotation else { return }
        var next = annotations
        next[index] = annotation
        commit(next)
    }

    func delete(_ ids: Set<String>) {
        guard annotations.contains(where: { ids.contains($0.id) }) else { return }
        commit(annotations.filter { !ids.contains($0.id) })
        if let selectedID, ids.contains(selectedID) { self.selectedID = nil }
    }

    func deleteSelection() {
        if let selectedID { delete([selectedID]) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        selectedID = nil
        isDirty = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        selectedID = nil
        isDirty = true
    }

    func annotations(onPage page: Int) -> [Annotation] {
        annotations.filter { $0.pageNumber == page }
    }

    var citations: [Annotation] { Citations.sorted(annotations) }
    var citationNumbers: [String: Int] { Citations.numbers(annotations) }

    /// Selects an annotation from a list and scrolls to it.
    func reveal(_ annotation: Annotation) {
        if annotation.type != .cite || activeTool != .cite { activeTool = .select }
        selectedID = annotation.id
        jumpRequest = annotation.pageNumber
    }

    // MARK: - Saving

    @discardableResult
    func save() -> Bool {
        guard hasDocument else { return false }
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        guard hasDocument else { return false }
        let panel = NSSavePanel()
        if isPDF {
            panel.allowedContentTypes = [.pdf]
        } else if let type = UTType(filenameExtension: fileURL?.pathExtension ?? "md") {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = fileName ?? (isPDF ? "document.pdf" : "untitled.md")
        if let directory = fileURL?.deletingLastPathComponent() ?? folderURL { panel.directoryURL = directory }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard write(to: url) else { return false }
        fileURL = url
        fileName = url.lastPathComponent
        UserDefaults.standard.set(url.path, forKey: Keys.lastFile)
        refreshFolder()
        return true
    }

    private func write(to url: URL) -> Bool {
        do {
            if let pdf {
                let saved = try PDFFormat.save(pdf, annotations: annotations, source: source)
                try saved.data.write(to: url, options: .atomic)
                if !saved.keptEditableData {
                    let alert = NSAlert()
                    alert.messageText = "Saved, but the annotations may not stay editable"
                    alert.informativeText = "Other PDF apps show them, but ZenPDF couldn't read its editing data back from the file."
                    alert.runModal()
                }
            } else if let textContent {
                try textContent.write(to: url, atomically: true, encoding: .utf8)
            }
            isDirty = false
            return true
        } catch {
            showError("Couldn't save \(url.lastPathComponent)", error)
            return false
        }
    }

    private var baseName: String {
        ((fileName ?? "document") as NSString).deletingPathExtension
    }

    /// A separate copy with the annotations merged into the pages, for sharing. The working file stays editable.
    func exportFlattened() {
        guard let pdf, let data = pdf.dataRepresentation(), let copy = PDFDocument(data: data) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(baseName)_flattened.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let numbers = citationNumbers
        var citesByPage: [Int: [Annotation]] = [:]
        for annotation in annotations {
            guard let page = copy.page(at: annotation.pageNumber - 1) else { continue }
            if let pdfAnnotation = PDFFormat.makePDFAnnotation(annotation, page: page, citeNumbers: numbers) {
                page.addAnnotation(pdfAnnotation)
            }
            if annotation.type == .cite { citesByPage[annotation.pageNumber, default: []].append(annotation) }
        }
        for (pageNumber, cites) in citesByPage {
            if let page = copy.page(at: pageNumber - 1),
               let footnotes = PDFFormat.makeFootnotes(cites, numbers: numbers, page: page) {
                page.addAnnotation(footnotes)
            }
        }
        guard let out = copy.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true]) else {
            showError("Couldn't export the flattened PDF", nil)
            return
        }
        do {
            try out.write(to: url, options: .atomic)
            refreshFolder()
        } catch {
            showError("Couldn't export the flattened PDF", error)
        }
    }

    func exportPageImage() {
        guard let pdf, let page = pdf.page(at: currentPage - 1) else { return }
        guard let png = PartsRenderer.pngData(page: page, annotations: annotations(onPage: currentPage), numbers: citationNumbers) else {
            showError("Couldn't render page \(currentPage)", nil)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(baseName)_page_\(currentPage).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            showError("Couldn't save the image", error)
        }
    }

    // MARK: - Zoom

    func setZoom(_ value: Double) {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, (value * 100).rounded() / 100))
    }

    func zoomIn() { setZoom(zoom * 1.15) }
    func zoomOut() { setZoom(zoom / 1.15) }

    private static let pagePadding = 32.0

    func fitWidth() {
        guard let pdf, viewportSize.width > 0 else { return }
        let widest = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.map { PageMapper(page: $0).viewWidth }.max() ?? 0
        if widest > 0 { setZoom((viewportSize.width - Self.pagePadding * 2) / widest) }
    }

    func fitPage() {
        guard let pdf, viewportSize.width > 0, let page = pdf.page(at: currentPage - 1) else { return }
        let mapper = PageMapper(page: page)
        setZoom(min((viewportSize.width - Self.pagePadding * 2) / mapper.viewWidth,
                    (viewportSize.height - Self.pagePadding * 2) / mapper.viewHeight))
    }

    // MARK: - Thumbnails

    func thumbnail(page number: Int) -> NSImage? {
        if let image = thumbnails[number] { return image }
        guard let page = pdf?.page(at: number - 1) else { return nil }
        let mapper = PageMapper(page: page)
        let width = 280.0
        let image = page.thumbnail(of: CGSize(width: width, height: width * mapper.viewHeight / max(1, mapper.viewWidth)), for: .cropBox)
        thumbnails[number] = image
        return image
    }

    // MARK: - Errors

    func showError(_ message: String, _ error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        if let error { alert.informativeText = error.localizedDescription }
        alert.runModal()
    }
}
