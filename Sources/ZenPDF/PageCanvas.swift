import AppKit
import PDFKit
import SwiftUI

// The page viewer: every page of the PDF in a scrolling column, with ZenPDF's annotations drawn on top and the
// same pointer gestures as the Windows viewer (src/components/PDFViewer.tsx).

/// How long the pointer must rest before a freehand stroke snaps straight.
private let holdToStraighten: TimeInterval = 0.45
/// Movement (screen points) still counted as "holding still".
private let holdTolerance = 4.0
private let handleSize = 8.0
private let pageGap: CGFloat = 16
private let pagePadding: CGFloat = 32
/// The largest page bitmap, in pixels per side. Higher zoom levels scale it up.
private let maxBitmapSide: CGFloat = 4096

struct PDFCanvas: NSViewRepresentable {
    let model: DocumentModel

    func makeNSView(context: Context) -> ViewerScrollView {
        let scrollView = ViewerScrollView()
        scrollView.pagesView.model = model
        return scrollView
    }

    func updateNSView(_ scrollView: ViewerScrollView, context: Context) {
        // Reading these registers them with Observation, so SwiftUI calls this again when they change.
        let documentID = model.documentID
        let zoom = model.zoom
        _ = model.annotations
        _ = model.selectedID
        _ = model.activeTool
        let jump = model.jumpRequest

        let pages = scrollView.pagesView
        if pages.documentID != documentID {
            pages.load(model.pdf, documentID: documentID, zoom: zoom)
        } else if abs(pages.zoom - zoom) > 0.0001 {
            pages.apply(zoom: zoom)
        }
        pages.refresh()
        if let jump {
            pages.scrollTo(page: jump)
            Task { @MainActor in model.jumpRequest = nil }
        }
    }
}

// MARK: - Scroll view

final class ViewerScrollView: NSScrollView {
    let pagesView = PagesView()

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = Zen.viewer
        borderType = .noBorder
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = pagesView
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
                                               object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func boundsChanged() {
        pagesView.visibleAreaChanged()
    }

    override func layout() {
        super.layout()
        pagesView.relayout()
    }

    // ⌘ or ⌃ with the scroll wheel zooms, like Ctrl + wheel on Windows.
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            pagesView.zoom(by: exp(delta), at: event.locationInWindow)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        pagesView.zoom(by: 1 + event.magnification, at: event.locationInWindow)
    }
}

/// Keeps the pages centered when they're narrower than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let documentView, documentView.frame.width < rect.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        return rect
    }
}

// MARK: - Pages

final class PagesView: NSView {
    weak var model: DocumentModel?
    private(set) var documentID = -1
    private(set) var zoom: CGFloat = 1
    private var document: PDFDocument?
    private var pageViews: [PageView] = []
    /// Where a zoom gesture happened, so that point stays put.
    private var pendingAnchor: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Loading and layout

    func load(_ document: PDFDocument?, documentID: Int, zoom: Double) {
        cancelGesture()
        self.document = document
        self.documentID = documentID
        self.zoom = CGFloat(zoom)
        pageViews.forEach { $0.removeFromSuperview() }
        pageViews = []
        if let document {
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let view = PageView(page: page, number: index + 1, owner: self)
                addSubview(view)
                pageViews.append(view)
            }
        }
        relayout()
        enclosingScrollView?.contentView.scroll(to: .zero)
        enclosingScrollView?.reflectScrolledClipView(enclosingScrollView!.contentView)
        visibleAreaChanged()
        window?.makeFirstResponder(self)
    }

    func relayout() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let widest = pageViews.map { $0.pageSize.width * zoom }.max() ?? 0
        let width = max(widest + pagePadding * 2, 1)
        var y = pagePadding
        for view in pageViews {
            let size = NSSize(width: (view.pageSize.width * zoom).rounded(), height: (view.pageSize.height * zoom).rounded())
            view.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
            y += size.height + pageGap
        }
        let height = pageViews.isEmpty ? clip.bounds.height : y - pageGap + pagePadding
        setFrameSize(NSSize(width: width, height: max(height, 1)))
        if let model, model.viewportSize != clip.bounds.size {
            let size = clip.bounds.size
            Task { @MainActor in model.viewportSize = size }
        }
        editorView?.reposition(zoom: zoom)
        visibleAreaChanged()
    }

    func zoom(by factor: CGFloat, at windowPoint: NSPoint) {
        guard let model, model.isPDF else { return }
        pendingAnchor = convert(windowPoint, from: nil)
        model.setZoom(model.zoom * Double(factor))
    }

    /// Changes the zoom, keeping the anchor point (or the middle of the window) over the same spot of the page.
    func apply(zoom newZoom: Double) {
        guard let clip = enclosingScrollView?.contentView else {
            zoom = CGFloat(newZoom)
            return
        }
        let visible = clip.documentVisibleRect
        let anchor = pendingAnchor.flatMap { visible.contains($0) ? $0 : nil } ?? NSPoint(x: visible.midX, y: visible.midY)
        pendingAnchor = nil
        let offset = NSPoint(x: anchor.x - visible.minX, y: anchor.y - visible.minY)

        // Remember the anchor relative to the page under it.
        let view = pageViews.min { distance($0.frame, anchor) < distance($1.frame, anchor) }
        let fraction = view.map { NSPoint(x: ($0.frame.width > 0 ? (anchor.x - $0.frame.minX) / $0.frame.width : 0),
                                          y: ($0.frame.height > 0 ? (anchor.y - $0.frame.minY) / $0.frame.height : 0)) }
        zoom = CGFloat(newZoom)
        relayout()
        pageViews.forEach { $0.zoomChanged() }
        if let view, let fraction {
            let point = NSPoint(x: view.frame.minX + fraction.x * view.frame.width, y: view.frame.minY + fraction.y * view.frame.height)
            clip.scroll(to: NSPoint(x: point.x - offset.x, y: point.y - offset.y))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
        visibleAreaChanged()
    }

    private func distance(_ rect: NSRect, _ p: NSPoint) -> CGFloat {
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return dx * dx + dy * dy
    }

    func scrollTo(page number: Int) {
        guard let view = pageViews.first(where: { $0.number == number }), let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let visible = clip.documentVisibleRect
        // Only scroll if the page isn't mostly in view already.
        if visible.intersection(view.frame).height >= min(view.frame.height, visible.height) * 0.6 { return }
        clip.scroll(to: NSPoint(x: visible.minX, y: max(0, view.frame.minY - pageGap)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Renders the pages in view, frees the bitmaps of pages far away, and tracks the current page.
    func visibleAreaChanged() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let visible = clip.documentVisibleRect
        let nearby = visible.insetBy(dx: 0, dy: -visible.height)
        let scale = window?.backingScaleFactor ?? 2
        var best: (number: Int, overlap: CGFloat)?
        for view in pageViews {
            if view.frame.intersects(nearby) {
                view.requestBitmap(scale: zoom * scale)
            } else {
                view.dropBitmap()
            }
            let overlap = visible.intersection(view.frame).height
            if overlap > (best?.overlap ?? 0) { best = (view.number, overlap) }
        }
        if let model, let best, best.number != model.currentPage {
            Task { @MainActor in model.currentPage = best.number }
        }
    }

    func refresh() {
        pageViews.forEach { $0.needsDisplay = true }
    }

    // MARK: What to draw

    /// The annotations to draw on a page: the saved ones with the gesture in progress applied.
    func displayAnnotations(page: Int) -> [Annotation] {
        guard let model else { return [] }
        var result: [Annotation] = []
        for annotation in model.annotations where annotation.pageNumber == page {
            if erased.contains(annotation.id) || annotation.id == editor?.editingID { continue }
            result.append(preview?.id == annotation.id ? preview! : annotation)
        }
        if let draft, draft.pageNumber == page { result.append(draft) }
        return result
    }

    func selectedAnnotation(page: Int) -> Annotation? {
        guard let model, let id = model.selectedID else { return nil }
        if let preview, preview.id == id { return preview.pageNumber == page ? preview : nil }
        guard let annotation = model.annotations.first(where: { $0.id == id }), annotation.pageNumber == page,
              !erased.contains(id) else { return nil }
        return annotation
    }

    var citationNumbers: [String: Int] { model?.citationNumbers ?? [:] }

    // MARK: - Gestures

    private struct Gesture {
        enum Kind { case move, resize, erase, draw, shape }
        var kind: Kind
        var page: Int
        var start: PagePoint
        var original: Annotation?
        var handle: Handle?
        var straight = false
        var holdAnchor: PagePoint
        var last: PagePoint
    }

    private var gesture: Gesture?
    private var draft: Annotation?
    private var preview: Annotation?
    private var erased = Set<String>()
    private var holdTimer: Timer?

    private func pageView(_ number: Int) -> PageView? {
        pageViews.first { $0.number == number }
    }

    private func topHit(_ page: Int, _ point: PagePoint) -> Annotation? {
        guard let model else { return nil }
        let tolerance = 6 / Double(zoom)
        return model.annotations.last {
            $0.pageNumber == page && !erased.contains($0.id) && AnnotationGeometry.isHit($0, point, tol: tolerance)
        }
    }

    /// The handle of the selected annotation under the pointer, if any.
    private func handleAt(_ page: Int, _ point: PagePoint) -> (handle: Handle, annotation: Annotation)? {
        guard let selected = selectedAnnotation(page: page) else { return nil }
        let r = (handleSize / 2 + 3) / Double(zoom)
        for h in AnnotationGeometry.handlePositions(selected) where abs(point.x - h.x) <= r && abs(point.y - h.y) <= r {
            return (h.handle, selected)
        }
        return nil
    }

    private func buildShape(from start: PagePoint, to end: PagePoint, page: Int, shift: Bool) -> Annotation? {
        guard let model else { return nil }
        let tool = model.activeTool
        var p2 = end
        if shift {
            if tool == .rect || tool == .circle {
                let d = max(abs(end.x - start.x), abs(end.y - start.y))
                let sx: Double = end.x - start.x < 0 ? -1 : 1
                let sy: Double = end.y - start.y < 0 ? -1 : 1
                p2 = PagePoint(x: start.x + sx * d, y: start.y + sy * d)
            } else if tool != .cite {
                let angle = (atan2(end.y - start.y, end.x - start.x) / (Double.pi / 4)).rounded() * (Double.pi / 4)
                let length = hypot(end.x - start.x, end.y - start.y)
                p2 = PagePoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
            }
        }
        guard let type = AnnotationType(rawValue: tool.rawValue) else { return nil }
        var a = Annotation(id: newAnnotationID(tool.rawValue), type: type, pageNumber: page)
        a.strokeColor = model.activeColor
        a.strokeWidth = model.strokeWidth
        switch tool {
        case .rect:
            a.x = min(start.x, p2.x)
            a.y = min(start.y, p2.y)
            a.width = abs(p2.x - start.x)
            a.height = abs(p2.y - start.y)
        case .circle:
            a.x = (start.x + p2.x) / 2
            a.y = (start.y + p2.y) / 2
            a.radiusX = abs(p2.x - start.x) / 2
            a.radiusY = abs(p2.y - start.y) / 2
        case .line, .arrow, .measure:
            a.x1 = start.x
            a.y1 = start.y
            a.x2 = p2.x
            a.y2 = p2.y
            a.unit = model.measureUnit
        case .cite:
            a.color = model.activeColor
            a.x = min(start.x, end.x)
            a.y = min(start.y, end.y)
            a.width = abs(end.x - start.x)
            a.height = abs(end.y - start.y)
        default:
            return nil
        }
        return a
    }

    private func isBigEnough(_ a: Annotation) -> Bool {
        let minimum = 3.0
        switch a.type {
        case .rect: return a.width > minimum || a.height > minimum
        case .cite: return a.width > 8 && a.height > 4
        case .circle: return a.radiusX > minimum / 2 || a.radiusY > minimum / 2
        case .line, .arrow, .measure: return hypot(a.x2 - a.x1, a.y2 - a.y1) > minimum
        default: return true
        }
    }

    private func erase(_ page: Int, _ point: PagePoint) {
        if let hit = topHit(page, point) {
            erased.insert(hit.id)
            pageView(page)?.needsDisplay = true
        }
    }

    func mouseDown(page: Int, point: PagePoint, event: NSEvent) {
        guard let model else { return }
        window?.makeFirstResponder(self)

        if editor != nil {
            // The first click outside an open text editor just commits it.
            commitText()
            return
        }

        let tool = model.activeTool
        if event.clickCount == 2, tool == .select, let hit = topHit(page, point), hit.type == .text {
            startTextEdit(hit)
            return
        }

        if tool == .text {
            if let hit = topHit(page, point), hit.type == .text {
                startTextEdit(hit)
            } else {
                openEditor(TextEditState(page: page, x: point.x, y: point.y, text: "", fontSize: model.strokeWidth,
                                         color: model.activeColor, editingID: nil))
            }
            return
        }

        // Grabbing a handle of the current selection resizes it.
        if tool == .select || tool == .cite, let h = handleAt(page, point) {
            gesture = Gesture(kind: .resize, page: page, start: point, original: h.annotation, handle: h.handle,
                              holdAnchor: point, last: point)
            preview = h.annotation
            return
        }

        switch tool {
        case .select:
            let hit = topHit(page, point)
            model.selectedID = hit?.id
            if let hit {
                gesture = Gesture(kind: .move, page: page, start: point, original: hit, holdAnchor: point, last: point)
                preview = hit
            }
        case .eraser:
            erased = []
            gesture = Gesture(kind: .erase, page: page, start: point, holdAnchor: point, last: point)
            erase(page, point)
        case .pen, .highlighter:
            gesture = Gesture(kind: .draw, page: page, start: point, holdAnchor: point, last: point)
            var a = Annotation(id: newAnnotationID(tool == .pen ? "pen" : "hl"), type: tool == .pen ? .pen : .highlighter,
                               pageNumber: page)
            a.points = [point]
            a.color = model.activeColor
            a.width = model.strokeWidth
            a.opacity = tool == .pen ? 1 : AnnotationGeometry.highlightOpacity
            if tool == .pen { a.penType = model.penType }
            draft = a
            armHoldTimer(page)
            pageView(page)?.needsDisplay = true
        case .cite:
            // Clicking an existing citation selects it (and shows it in the panel).
            if let hit = topHit(page, point), hit.type == .cite {
                model.selectedID = hit.id
                gesture = Gesture(kind: .move, page: page, start: point, original: hit, holdAnchor: point, last: point)
                preview = hit
            } else {
                gesture = Gesture(kind: .shape, page: page, start: point, holdAnchor: point, last: point)
                draft = nil
            }
        case .rect, .circle, .line, .arrow, .measure:
            gesture = Gesture(kind: .shape, page: page, start: point, holdAnchor: point, last: point)
            draft = nil
        case .text:
            break
        }
    }

    func mouseDragged(page: Int, point: PagePoint, event: NSEvent) {
        guard var g = gesture else { return }
        let shift = event.modifierFlags.contains(.shift)
        switch g.kind {
        case .move:
            if let original = g.original {
                preview = AnnotationGeometry.translate(original, dx: point.x - g.start.x, dy: point.y - g.start.y)
            }
        case .resize:
            if let original = g.original, let handle = g.handle {
                preview = AnnotationGeometry.resize(original, handle: handle, to: point, uniform: shift)
            }
        case .erase:
            erase(g.page, point)
        case .draw:
            guard var d = draft, let start = d.points.first else { break }
            g.last = point
            if g.straight {
                d.points = [start, AnnotationGeometry.snapAngle(start, point)]
            } else {
                // Restart the hold timer only on real movement, not hand jitter.
                if hypot(point.x - g.holdAnchor.x, point.y - g.holdAnchor.y) * Double(zoom) > holdTolerance {
                    g.holdAnchor = point
                    gesture = g
                    armHoldTimer(g.page)
                }
                if let last = d.points.last, hypot(point.x - last.x, point.y - last.y) * Double(zoom) >= 1.5 {
                    d.points.append(point)
                }
            }
            draft = d
        case .shape:
            draft = buildShape(from: g.start, to: point, page: g.page, shift: shift)
        }
        gesture = g
        pageView(g.page)?.needsDisplay = true
    }

    // A click between pages commits an open text editor or clears the selection.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if editor != nil {
            commitText()
        } else if model?.activeTool == .select || model?.activeTool == .cite {
            model?.selectedID = nil
        }
    }

    func mouseUp(page: Int, point: PagePoint, event: NSEvent) {
        finishGesture(cancelled: false)
    }

    private func finishGesture(cancelled: Bool) {
        guard let g = gesture, let model else { return }
        gesture = nil
        holdTimer?.invalidate()
        holdTimer = nil
        let finishedDraft = draft
        let finishedPreview = preview
        let erasedIDs = erased
        draft = nil
        preview = nil
        erased = []

        if !cancelled {
            switch g.kind {
            case .move, .resize:
                if let finishedPreview, finishedPreview != g.original { model.update(finishedPreview) }
            case .erase:
                if !erasedIDs.isEmpty { model.delete(erasedIDs) }
            case .draw:
                if let finishedDraft { model.add(finishedDraft) }
            case .shape:
                if let finishedDraft, isBigEnough(finishedDraft) {
                    if finishedDraft.type == .cite { addCitation(finishedDraft) } else { model.add(finishedDraft) }
                } else if model.activeTool == .cite {
                    model.selectedID = nil
                }
            }
        }
        pageView(g.page)?.needsDisplay = true
    }

    func cancelGesture() {
        if gesture != nil { finishGesture(cancelled: true) }
        editorView?.removeFromSuperview()
        editorView = nil
        editor = nil
    }

    /// Hold-to-straighten: if the pointer rests while drawing, the stroke becomes a straight line from its
    /// start in the drawing direction, and its end follows the pointer until release.
    private func armHoldTimer(_ page: Int) {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdToStraighten, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.straightenDraft(page) }
        }
    }

    private func straightenDraft(_ page: Int) {
        holdTimer = nil
        guard var g = gesture, g.kind == .draw, !g.straight, g.page == page, var d = draft, let start = d.points.first else { return }
        // Too short to have a direction.
        if hypot(g.last.x - start.x, g.last.y - start.y) * Double(zoom) < 12 { return }
        g.straight = true
        gesture = g
        d.points = [start, AnnotationGeometry.snapAngle(start, g.last)]
        draft = d
        pageView(page)?.needsDisplay = true
    }

    /// Marks a passage: captures the text under it, then adds the citation.
    private func addCitation(_ citation: Annotation) {
        var c = citation
        if let page = document?.page(at: c.pageNumber - 1) {
            let rect = PageMapper(page: page).mapRect(Bounds(x: c.x, y: c.y, width: c.width, height: c.height))
            c.quote = Citations.cleanCapturedText(page.selection(for: rect)?.string ?? "")
        }
        model?.add(c)
    }

    // MARK: Cursor

    func cursor(page: Int, point: PagePoint) -> NSCursor {
        guard let model else { return .arrow }
        if gesture?.kind == .move { return .closedHand }
        switch model.activeTool {
        case .select:
            if handleAt(page, point) != nil { return .crosshair }
            return topHit(page, point) != nil ? .openHand : .arrow
        case .cite:
            if handleAt(page, point) != nil { return .crosshair }
            if let hit = topHit(page, point), hit.type == .cite { return .pointingHand }
            return .crosshair
        case .text:
            if let hit = topHit(page, point), hit.type == .text { return .pointingHand }
            return .iBeam
        case .eraser:
            return .disappearingItem
        default:
            return .crosshair
        }
    }

    // MARK: Keyboard

    private static let toolKeys: [String: ToolType] = [
        "1": .select, "2": .highlighter, "3": .pen, "4": .text, "5": .rect, "6": .eraser,
        "v": .select, "h": .highlighter, "p": .pen, "t": .text, "r": .rect, "o": .circle, "l": .line,
        "a": .arrow, "m": .measure, "c": .cite, "e": .eraser,
    ]

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            if model.selectedID != nil { model.deleteSelection() } else { super.keyDown(with: event) }
            return
        case 53: // Escape
            if gesture != nil { finishGesture(cancelled: true) } else { model.selectedID = nil }
            return
        default:
            break
        }
        if flags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(), let tool = Self.toolKeys[key] {
            model.activeTool = tool
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Text editing

    struct TextEditState {
        var page: Int
        var x: Double
        var y: Double
        var text: String
        var fontSize: Double
        var color: String
        var editingID: String?
    }

    private var editor: TextEditState?
    private var editorView: AnnotationTextView?

    private func startTextEdit(_ annotation: Annotation) {
        openEditor(TextEditState(page: annotation.pageNumber, x: annotation.x, y: annotation.y, text: annotation.text,
                                 fontSize: annotation.fontSize, color: annotation.color, editingID: annotation.id))
    }

    private func openEditor(_ state: TextEditState) {
        guard let pageView = pageView(state.page) else { return }
        editor = state
        let view = AnnotationTextView(state: state)
        view.onCommit = { [weak self] in self?.commitText() }
        view.onCancel = { [weak self] in self?.closeEditor() }
        pageView.addSubview(view)
        view.reposition(zoom: zoom)
        window?.makeFirstResponder(view)
        editorView = view
        pageView.needsDisplay = true
    }

    private func closeEditor() {
        let page = editor?.page
        editorView?.removeFromSuperview()
        editorView = nil
        editor = nil
        window?.makeFirstResponder(self)
        if let page { pageView(page)?.needsDisplay = true }
    }

    private func commitText() {
        guard let state = editor, let model else { return }
        var text = editorView?.string ?? ""
        while let last = text.last, last.isWhitespace { text.removeLast() }
        closeEditor()
        if let id = state.editingID {
            guard var original = model.annotations.first(where: { $0.id == id }), original.type == .text else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.delete([id])
            } else if text != original.text {
                original.text = text
                model.update(original)
            }
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var a = Annotation(id: newAnnotationID("text"), type: .text, pageNumber: state.page)
        a.x = state.x
        a.y = state.y
        a.text = text
        a.fontSize = state.fontSize
        a.color = state.color
        model.add(a)
    }
}

// MARK: - One page

final class PageView: NSView {
    let page: PDFPage
    let number: Int
    let pageSize: CGSize
    private unowned let owner: PagesView
    private var bitmap: NSImage?
    private var bitmapScale: CGFloat = 0
    private var renderScheduled = false
    private var wantedScale: CGFloat = 0

    init(page: PDFPage, number: Int, owner: PagesView) {
        self.page = page
        self.number = number
        self.pageSize = PageMapper(page: page).viewSize
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var zoom: CGFloat { owner.zoom }

    // MARK: Bitmap

    func requestBitmap(scale: CGFloat) {
        let longest = max(pageSize.width, pageSize.height)
        let target = min(scale, maxBitmapSide / max(longest, 1))
        wantedScale = target
        if bitmap != nil && abs(bitmapScale - target) / target < 0.05 { return }
        guard !renderScheduled else { return }
        renderScheduled = true
        // One page per pass of the run loop, so scrolling stays responsive.
        Task { @MainActor [weak self] in self?.renderBitmap() }
    }

    private func renderBitmap() {
        renderScheduled = false
        guard wantedScale > 0 else { return }
        let scale = wantedScale
        let size = CGSize(width: (pageSize.width * scale).rounded(), height: (pageSize.height * scale).rounded())
        bitmap = page.thumbnail(of: size, for: .cropBox)
        bitmapScale = scale
        needsDisplay = true
    }

    func dropBitmap() {
        bitmap = nil
        bitmapScale = 0
        wantedScale = 0
    }

    func zoomChanged() {
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.white.setFill()
        bounds.fill()
        if let bitmap {
            bitmap.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        ctx.saveGState()
        ctx.scaleBy(x: zoom, y: zoom)
        let annotations = owner.displayAnnotations(page: number)
        let parts = PartsRenderer.pageParts(annotations, numbers: owner.citationNumbers, pageSize: pageSize)
        PartsRenderer.draw(parts, in: ctx, pass: .multiplyOnly)
        PartsRenderer.draw(parts, in: ctx, pass: .normalOnly)
        if let selected = owner.selectedAnnotation(page: number) { drawSelection(selected, in: ctx) }
        ctx.restoreGState()
    }

    private func drawSelection(_ annotation: Annotation, in ctx: CGContext) {
        let z = Double(zoom)
        let b = AnnotationGeometry.bounds(of: annotation)
        let pad = 4 / z
        ctx.saveGState()
        ctx.setStrokeColor(Zen.selection.cgColor)
        ctx.setLineWidth(CGFloat(1 / z))
        ctx.setLineDash(phase: 0, lengths: [CGFloat(4 / z), CGFloat(3 / z)])
        ctx.stroke(CGRect(x: b.x - pad, y: b.y - pad, width: b.width + 2 * pad, height: b.height + 2 * pad))
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(CGFloat(1.5 / z))
        ctx.setFillColor(NSColor.white.cgColor)
        let s = handleSize / z
        for h in AnnotationGeometry.handlePositions(annotation) {
            let rect = CGRect(x: h.x - s / 2, y: h.y - s / 2, width: s, height: s)
            if h.handle.isEndpoint { ctx.addEllipse(in: rect) } else { ctx.addRect(rect) }
            ctx.drawPath(using: .fillStroke)
        }
        ctx.restoreGState()
    }

    // MARK: Events

    private func pagePoint(_ event: NSEvent) -> PagePoint {
        let p = convert(event.locationInWindow, from: nil)
        return PagePoint(x: Double(p.x / zoom), y: Double(p.y / zoom))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        owner.mouseDown(page: number, point: pagePoint(event), event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        owner.mouseDragged(page: number, point: pagePoint(event), event: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner.mouseUp(page: number, point: pagePoint(event), event: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        owner.cursor(page: number, point: pagePoint(event)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        owner.cursor(page: number, point: pagePoint(event)).set()
    }
}

// MARK: - Text editor on the page

final class AnnotationTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let state: PagesView.TextEditState

    init(state: PagesView.TextEditState) {
        self.state = state
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = true
        isVerticallyResizable = true
        textContainerInset = .zero
        drawsBackground = true
        backgroundColor = NSColor.white.withAlphaComponent(0.85)
        textColor = NSColor(cssHex: state.color)
        insertionPointColor = Zen.selection
        wantsLayer = true
        layer?.borderColor = Zen.selection.cgColor
        layer?.borderWidth = 1
        string = state.text
        setAccessibilityPlaceholderValue("Type a note…")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        fatalError("Use init(state:)")
    }

    func reposition(zoom: CGFloat) {
        let size = CGFloat(state.fontSize) * zoom
        font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = size * CGFloat(AnnotationGeometry.textLineHeight)
        paragraph.maximumLineHeight = size * CGFloat(AnnotationGeometry.textLineHeight)
        defaultParagraphStyle = paragraph
        typingAttributes[.paragraphStyle] = paragraph
        textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: (string as NSString).length))
        textStorage?.addAttribute(.font, value: font!, range: NSRange(location: 0, length: (string as NSString).length))
        setFrameOrigin(NSPoint(x: CGFloat(state.x) * zoom, y: CGFloat(state.y) * zoom))
        fit()
    }

    private func fit() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let lineHeight = (font?.pointSize ?? 16) * CGFloat(AnnotationGeometry.textLineHeight)
        setFrameSize(NSSize(width: max(used.width + 4, lineHeight * 4), height: max(used.height, lineHeight)))
    }

    override func didChangeText() {
        super.didChangeText()
        fit()
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onCommit?()
            }
            return
        }
        if selector == #selector(cancelOperation(_:)) {
            onCancel?()
            return
        }
        super.doCommand(by: selector)
    }
}
