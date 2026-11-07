import AppKit
import PDFKit

// Reading and writing ZenPDF annotations in PDF files, in the same on-file format as ZenPDF for Windows
// (src/utils/pdfAnnotations.ts):
//
// - Every annotation is a real PDF annotation (/Ink, /Square, /Circle, /Line, /FreeText), so any viewer shows it.
// - The editable ZenPDF data sits on that annotation under the private key /ZenPDF, as the text
//   {"v":1,"annotation":{…}}, and /NM is the annotation's id.
// - Citation footnotes are one generated /FreeText annotation per page, marked with /ZenPDFFootnotes.
// - The citation source is JSON under /ZenPDFSource in the document catalog.
//
// On opening, those annotations are lifted out of the pages (so they aren't drawn twice) and become editable again.

/// Maps page units (rotation applied, origin top-left of the crop box, y down) to PDF user space,
/// exactly like makePageMapper in src/utils/pdfExport.ts.
struct PageMapper {
    let crop: CGRect
    let rotation: Int

    init(page: PDFPage) {
        crop = page.bounds(for: .cropBox)
        rotation = ((page.rotation % 360) + 360) % 360
    }

    init(crop: CGRect, rotation: Int) {
        self.crop = crop
        self.rotation = ((rotation % 360) + 360) % 360
    }

    var isSwapped: Bool { rotation == 90 || rotation == 270 }
    var viewWidth: Double { Double(isSwapped ? crop.height : crop.width) }
    var viewHeight: Double { Double(isSwapped ? crop.width : crop.height) }
    var viewSize: CGSize { CGSize(width: viewWidth, height: viewHeight) }

    func map(_ vx: Double, _ vy: Double) -> CGPoint {
        let x0 = Double(crop.minX)
        let y0 = Double(crop.minY)
        let w = Double(crop.width)
        let h = Double(crop.height)
        switch rotation {
        case 90: return CGPoint(x: x0 + vy, y: y0 + vx)
        case 180: return CGPoint(x: x0 + w - vx, y: y0 + vy)
        case 270: return CGPoint(x: x0 + w - vy, y: y0 + h - vx)
        default: return CGPoint(x: x0 + vx, y: y0 + h - vy)
        }
    }

    /// The inverse: PDF user space to page units.
    func unmap(_ p: CGPoint) -> PagePoint {
        let x0 = Double(crop.minX)
        let y0 = Double(crop.minY)
        let w = Double(crop.width)
        let h = Double(crop.height)
        let ux = Double(p.x)
        let uy = Double(p.y)
        switch rotation {
        case 90: return PagePoint(x: uy - y0, y: ux - x0)
        case 180: return PagePoint(x: x0 + w - ux, y: uy - y0)
        case 270: return PagePoint(x: y0 + h - uy, y: x0 + w - ux)
        default: return PagePoint(x: ux - x0, y: y0 + h - uy)
        }
    }

    /// The bounding box in user space of a rectangle in page units.
    func mapRect(_ b: Bounds) -> CGRect {
        let corners = [map(b.x, b.y), map(b.x + b.width, b.y), map(b.x, b.y + b.height), map(b.x + b.width, b.y + b.height)]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }
}

enum PDFFormat {
    static let dataKey = "ZenPDF"
    static let footnotesKey = "ZenPDFFootnotes"
    static let sourceKey = "ZenPDFSource"
    static let formatVersion = 1

    private static let pdfDataKey = PDFAnnotationKey(rawValue: "/" + dataKey)
    private static let pdfFootnotesKey = PDFAnnotationKey(rawValue: "/" + footnotesKey)

    enum LoadError: LocalizedError {
        case unreadable, locked

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file isn't a PDF ZenPDF can read."
            case .locked: return "The PDF is password protected."
            }
        }
    }

    struct Loaded {
        let document: PDFDocument
        let annotations: [Annotation]
        let source: DocumentSource?
    }

    private struct Envelope: Codable {
        var v: Int?
        var annotation: Annotation
    }

    // MARK: - Scanning (CoreGraphics reads the raw PDF objects reliably)

    struct ScannedPage {
        var annotations: [Annotation] = []
        /// /NM of every ZenPDF annotation on the page.
        var names: Set<String> = []
        /// /Rect of the generated footnote annotations.
        var footnoteRects: [CGRect] = []
    }

    struct Scan {
        var pages: [ScannedPage] = []
        var source: DocumentSource?

        var annotationCount: Int { pages.reduce(0) { $0 + $1.annotations.count } }
    }

    private static func string(_ dict: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dict, key, &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
    }

    private static func rect(_ dict: CGPDFDictionaryRef) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dict, "Rect", &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var v = [CGFloat](repeating: 0, count: 4)
        for i in 0..<4 {
            var n: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, i, &n) else { return nil }
            v[i] = n
        }
        return CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }

    static func decodeAnnotation(_ json: String) -> Annotation? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.annotation
    }

    static func decodeSource(_ json: String) -> DocumentSource? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocumentSource.self, from: data)
    }

    /// Finds the ZenPDF data in a PDF file without changing anything.
    static func scan(_ data: Data) -> Scan {
        var scan = Scan()
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return scan }
        if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        guard doc.isUnlocked else { return scan }

        var seen = Set<String>()
        for index in 0..<doc.numberOfPages {
            var page = ScannedPage()
            defer { scan.pages.append(page) }
            guard let cgPage = doc.page(at: index + 1), let pageDict = cgPage.dictionary else { continue }
            var annots: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(pageDict, "Annots", &annots), let annots else { continue }
            for i in 0..<CGPDFArrayGetCount(annots) {
                var dict: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(annots, i, &dict), let dict else { continue }
                if let json = string(dict, dataKey) {
                    if let name = string(dict, "NM") { page.names.insert(name) }
                    if var ann = decodeAnnotation(json) {
                        // The page the annotation sits on wins (pages may have been reordered elsewhere).
                        ann.pageNumber = index + 1
                        page.names.insert(ann.id)
                        if seen.contains(ann.id) { ann.id = "\(ann.id)_\(index)_\(i)" }
                        seen.insert(ann.id)
                        page.annotations.append(ann)
                    }
                } else {
                    var marker: CGPDFObjectRef?
                    if CGPDFDictionaryGetObject(dict, footnotesKey, &marker), let r = rect(dict) {
                        page.footnoteRects.append(r)
                    }
                }
            }
        }
        if let catalog = doc.catalog, let json = string(catalog, sourceKey) {
            scan.source = decodeSource(json)
        }
        return scan
    }

    // MARK: - Loading

    /// Opens a PDF: ZenPDF annotations saved in it are taken off the pages and returned as editable annotations.
    static func load(_ data: Data) throws -> Loaded {
        guard let document = PDFDocument(data: data) else { throw LoadError.unreadable }
        if document.isLocked && !document.unlock(withPassword: "") { throw LoadError.locked }
        let scan = scan(data)
        strip(document, scan: scan)
        return Loaded(document: document, annotations: scan.pages.flatMap(\.annotations), source: scan.source)
    }

    /// Removes the ZenPDF annotations (and their footnotes) from the pages of `document`.
    static func strip(_ document: PDFDocument, scan: Scan) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let scanned = index < scan.pages.count ? scan.pages[index] : ScannedPage()
            for annotation in page.annotations where isZenPDF(annotation, scanned: scanned) {
                if let popup = annotation.popup { page.removeAnnotation(popup) }
                page.removeAnnotation(annotation)
            }
        }
    }

    private static func isZenPDF(_ annotation: PDFAnnotation, scanned: ScannedPage) -> Bool {
        if annotation.value(forAnnotationKey: pdfDataKey) != nil { return true }
        if annotation.value(forAnnotationKey: pdfFootnotesKey) != nil { return true }
        if let name = annotation.value(forAnnotationKey: .name) as? String, scanned.names.contains(name) { return true }
        let bounds = annotation.bounds
        return scanned.footnoteRects.contains { r in
            abs(r.minX - bounds.minX) < 0.5 && abs(r.minY - bounds.minY) < 0.5
                && abs(r.width - bounds.width) < 0.5 && abs(r.height - bounds.height) < 0.5
        }
    }

    // MARK: - Saving

    /// JSON with every non-ASCII character escaped, so the PDF string is plain ASCII however it's written.
    static func asciiJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value), let json = String(data: data, encoding: .utf8) else { return nil }
        var out = ""
        out.reserveCapacity(json.utf16.count)
        for unit in json.utf16 {
            if unit < 0x80 {
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            } else {
                out += String(format: "\\u%04x", unit)
            }
        }
        return out
    }

    private static func describe(_ ann: Annotation) -> String {
        switch ann.type {
        case .text: return ann.text
        case .cite: return [ann.note, ann.quote.isEmpty ? "" : "“\(ann.quote)”"].filter { !$0.isEmpty }.joined(separator: "\n\n")
        default: return ""
        }
    }

    /// The area render parts cover, in page units (like buildAppearance on Windows).
    static func partsBounds(_ parts: [RenderPart]) -> Bounds? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func extend(_ x: Double, _ y: Double, _ pad: Double) {
            minX = min(minX, x - pad)
            minY = min(minY, y - pad)
            maxX = max(maxX, x + pad)
            maxY = max(maxY, y + pad)
        }
        for part in parts {
            switch part {
            case let .text(text, x, y, size, _, bold):
                guard !text.isEmpty else { continue }
                extend(x, y - size, 1)
                extend(x + TextMeasure.width(text, size: size, bold: bold), y + size * 0.3, 1)
            case let .path(cmds, stroke, _, _):
                let pad = (stroke?.width ?? 0) / 2 + 1
                for cmd in cmds {
                    switch cmd {
                    case let .move(x, y), let .line(x, y): extend(x, y, pad)
                    case let .quad(cx, cy, x, y):
                        extend(cx, cy, pad)
                        extend(x, y, pad)
                    case let .cubic(c1x, c1y, c2x, c2y, x, y):
                        extend(c1x, c1y, pad)
                        extend(c2x, c2y, pad)
                        extend(x, y, pad)
                    case .close: break
                    }
                }
            }
        }
        guard minX.isFinite else { return nil }
        return Bounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A path in user space, relative to `origin` (PDFKit's annotation space).
    private static func bezierPath(_ cmds: [PathCmd], mapper: PageMapper, origin: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        func p(_ x: Double, _ y: Double) -> NSPoint {
            let u = mapper.map(x, y)
            return NSPoint(x: u.x - origin.x, y: u.y - origin.y)
        }
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        for cmd in cmds {
            switch cmd {
            case let .move(x, y):
                path.move(to: p(x, y))
                cx = x; cy = y; sx = x; sy = y
            case let .line(x, y):
                path.line(to: p(x, y))
                cx = x; cy = y
            case let .quad(qx, qy, x, y):
                // Exact quadratic → cubic conversion.
                path.curve(to: p(x, y),
                           controlPoint1: p(cx + 2 / 3 * (qx - cx), cy + 2 / 3 * (qy - cy)),
                           controlPoint2: p(x + 2 / 3 * (qx - x), y + 2 / 3 * (qy - y)))
                cx = x; cy = y
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                path.curve(to: p(x, y), controlPoint1: p(c1x, c1y), controlPoint2: p(c2x, c2y))
                cx = x; cy = y
            case .close:
                path.close()
                cx = sx; cy = sy
            }
        }
        return path
    }

    private static func border(_ width: Double) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = CGFloat(width)
        return border
    }

    /// Builds the PDF annotation for one ZenPDF annotation; nil if it can't be encoded.
    static func makePDFAnnotation(_ ann: Annotation, page: PDFPage, citeNumbers: [String: Int]) -> PDFAnnotation? {
        let mapper = PageMapper(page: page)
        let parts = AnnotationGeometry.parts(for: ann, citeNumbers: citeNumbers)
        guard let area = partsBounds(parts) ?? Optional(AnnotationGeometry.bounds(of: ann)),
              let json = asciiJSON(Envelope(v: formatVersion, annotation: ann)) else { return nil }
        var rect = mapper.mapRect(area)
        if rect.width < 1 { rect.size.width = 1 }
        if rect.height < 1 { rect.size.height = 1 }

        let subtype: PDFAnnotationSubtype
        switch ann.type {
        case .pen, .highlighter: subtype = .ink
        case .rect, .cite: subtype = .square
        case .circle: subtype = .circle
        case .line, .arrow, .measure: subtype = .line
        case .text: subtype = .freeText
        }
        let a = PDFAnnotation(bounds: rect, forType: subtype, withProperties: nil)
        let color = NSColor(cssHex: ann.displayColor)

        switch ann.type {
        case .pen, .highlighter:
            a.color = ann.type == .highlighter ? color.withAlphaComponent(CGFloat(ann.opacity)) : color
            a.border = border(ann.width)
            a.add(bezierPath(AnnotationGeometry.smoothPath(ann.points), mapper: mapper, origin: rect.origin))
        case .rect, .circle:
            a.color = color
            a.border = border(ann.strokeWidth)
            if let fill = ann.fillColor { a.interiorColor = NSColor(cssHex: fill) }
        case .cite:
            a.color = color
            a.border = border(0)
            a.interiorColor = color.withAlphaComponent(0.12)
            _ = a.setValue("Citation \(citeNumbers[ann.id].map(String.init) ?? "")"
                .trimmingCharacters(in: .whitespaces), forAnnotationKey: .subject)
        case .line, .arrow, .measure:
            a.color = color
            a.border = border(ann.strokeWidth)
            let start = mapper.map(ann.x1, ann.y1)
            let end = mapper.map(ann.x2, ann.y2)
            a.startPoint = NSPoint(x: start.x - rect.minX, y: start.y - rect.minY)
            a.endPoint = NSPoint(x: end.x - rect.minX, y: end.y - rect.minY)
            if ann.type == .arrow { a.endLineStyle = .openArrow }
        case .text:
            a.color = .clear
            a.fontColor = color
            a.font = NSFont(name: "Helvetica", size: CGFloat(ann.fontSize)) ?? NSFont.systemFont(ofSize: CGFloat(ann.fontSize))
            a.border = border(0)
        }

        let contents = describe(ann)
        if !contents.isEmpty { a.contents = contents }
        a.modificationDate = Date()
        a.shouldPrint = true
        _ = a.setValue(ann.id, forAnnotationKey: .name)
        _ = a.setValue(json, forAnnotationKey: pdfDataKey)
        return a
    }

    /// The generated footnote annotation for the citations on one page.
    static func makeFootnotes(_ cites: [Annotation], numbers: [String: Int], page: PDFPage) -> PDFAnnotation? {
        let mapper = PageMapper(page: page)
        let parts = AnnotationGeometry.footnoteParts(cites, numbers: numbers, pageWidth: mapper.viewWidth, pageHeight: mapper.viewHeight)
        guard !parts.isEmpty, let area = partsBounds(parts) else { return nil }
        let text = cites
            .filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { (numbers[$0.id] ?? 0) < (numbers[$1.id] ?? 0) }
            .map { "\(numbers[$0.id] ?? 0). \($0.note.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "\n")
        let a = PDFAnnotation(bounds: mapper.mapRect(area), forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = NSFont(name: "Helvetica", size: 8) ?? NSFont.systemFont(ofSize: 8)
        a.fontColor = NSColor(hex: 0x1E293B)
        a.color = NSColor.white.withAlphaComponent(0.92)
        a.border = border(0)
        a.shouldPrint = true
        _ = a.setValue(NSNumber(value: true), forAnnotationKey: pdfFootnotesKey)
        return a
    }

    struct Saved {
        let data: Data
        /// Whether the editable ZenPDF data could be read back from the written file.
        let keptEditableData: Bool
    }

    /// Writes `annotations` into a copy of `document` (which holds no ZenPDF annotations) as editable PDF
    /// annotations, and the citation source into the catalog. `document` is left as it was.
    static func save(_ document: PDFDocument, annotations: [Annotation], source: DocumentSource?) throws -> Saved {
        let numbers = Citations.numbers(annotations)
        var added: [(PDFPage, PDFAnnotation)] = []
        defer { for (page, a) in added { page.removeAnnotation(a) } }

        var citesByPage: [Int: [Annotation]] = [:]
        var written = 0
        for ann in annotations {
            let index = ann.pageNumber - 1
            guard index >= 0, index < document.pageCount, let page = document.page(at: index) else { continue }
            guard let a = makePDFAnnotation(ann, page: page, citeNumbers: numbers) else { continue }
            page.addAnnotation(a)
            added.append((page, a))
            written += 1
            if ann.type == .cite { citesByPage[ann.pageNumber, default: []].append(ann) }
        }
        for (pageNumber, cites) in citesByPage {
            guard let page = document.page(at: pageNumber - 1),
                  let a = makeFootnotes(cites, numbers: numbers, page: page) else { continue }
            page.addAnnotation(a)
            added.append((page, a))
        }

        guard var data = document.dataRepresentation() else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "PDFKit couldn't write the document."])
        }
        if let source, !source.isEmpty, let json = asciiJSON(source),
           let updated = IncrementalUpdate.settingCatalogText(data, key: sourceKey, text: json) {
            data = updated
        }
        let kept = written == 0 || scan(data).annotationCount >= written
        return Saved(data: data, keptEditableData: kept)
    }
}

// MARK: - Catalog entry

/// PDFKit can't write keys into the document catalog, so the citation source is added with a small
/// incremental update (a new revision of the catalog object appended to the file), which every PDF reader
/// understands. Returns nil if the file's structure isn't the classic cross-reference table PDFKit writes.
enum IncrementalUpdate {
    private static func find(_ bytes: [UInt8], _ needle: String, before end: Int? = nil) -> Int? {
        let n = Array(needle.utf8)
        var i = min(end ?? bytes.count, bytes.count) - n.count
        while i >= 0 {
            if bytes[i] == n[0] && Array(bytes[i..<(i + n.count)]) == n { return i }
            i -= 1
        }
        return nil
    }

    private static func isWhite(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00 }

    private static func skipWhite(_ bytes: [UInt8], _ i: inout Int) {
        while i < bytes.count && isWhite(bytes[i]) { i += 1 }
    }

    private static func token(_ bytes: [UInt8], _ i: inout Int) -> String {
        skipWhite(bytes, &i)
        let start = i
        while i < bytes.count && !isWhite(bytes[i]) { i += 1 }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    /// Index just past a literal string starting at `i` (which points at "(").
    private static func skipLiteralString(_ bytes: [UInt8], _ i: Int) -> Int {
        var depth = 0
        var j = i
        while j < bytes.count {
            let b = bytes[j]
            if b == UInt8(ascii: "\\") { j += 2; continue }
            if b == UInt8(ascii: "(") { depth += 1 }
            if b == UInt8(ascii: ")") {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return bytes.count
    }

    /// Index just past the dictionary starting at `i` (which points at "<<"), or nil.
    static func dictionaryEnd(_ bytes: [UInt8], from i: Int) -> Int? {
        var depth = 0
        var j = i
        while j < bytes.count {
            let b = bytes[j]
            let next: UInt8 = j + 1 < bytes.count ? bytes[j + 1] : 0
            if b == UInt8(ascii: "(") {
                j = skipLiteralString(bytes, j)
            } else if b == UInt8(ascii: "<") && next == UInt8(ascii: "<") {
                depth += 1
                j += 2
            } else if b == UInt8(ascii: ">") && next == UInt8(ascii: ">") {
                depth -= 1
                j += 2
                if depth == 0 { return j }
            } else if b == UInt8(ascii: "<") {
                while j < bytes.count && bytes[j] != UInt8(ascii: ">") { j += 1 }
                j += 1
            } else if b == UInt8(ascii: "%") {
                while j < bytes.count && bytes[j] != 0x0A && bytes[j] != 0x0D { j += 1 }
            } else {
                j += 1
            }
        }
        return nil
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// Byte offset of object `num` from the newest cross-reference table, or by searching the file.
    private static func objectOffset(_ bytes: [UInt8], num: Int, gen: Int, xref: Int) -> Int? {
        var i = xref
        if token(bytes, &i) == "xref" {
            while true {
                var probe = i
                let first = token(bytes, &probe)
                guard let start = Int(first), let count = Int(token(bytes, &probe)) else { break }
                i = probe
                for k in 0..<count {
                    let offset = token(bytes, &i)
                    _ = token(bytes, &i)
                    let kind = token(bytes, &i)
                    if start + k == num, kind == "n", let value = Int(offset) { return value }
                }
            }
        }
        // Fallback: the last "num gen obj" in the file.
        guard let found = find(bytes, "\(num) \(gen) obj") else { return nil }
        return found
    }

    /// Removes `/key value` from a dictionary's bytes.
    private static func removingEntry(_ dict: [UInt8], key: String) -> [UInt8] {
        guard let k = find(dict, "/\(key)") else { return dict }
        var j = k + key.utf8.count + 1
        // Only an exact key, not a longer name that starts the same way.
        if j < dict.count, !isWhite(dict[j]), dict[j] != UInt8(ascii: "<"), dict[j] != UInt8(ascii: "(") { return dict }
        skipWhite(dict, &j)
        if j < dict.count && dict[j] == UInt8(ascii: "(") {
            j = skipLiteralString(dict, j)
        } else if j < dict.count && dict[j] == UInt8(ascii: "<") {
            while j < dict.count && dict[j] != UInt8(ascii: ">") { j += 1 }
            j += 1
        } else {
            return dict
        }
        return Array(dict[..<k]) + Array(dict[min(j, dict.count)...])
    }

    /// A PDF text string: UTF-16BE with a byte order mark, as hex (what pdf-lib's PDFHexString.fromText writes).
    static func hexText(_ text: String) -> String {
        "<FEFF" + text.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    static func settingCatalogText(_ data: Data, key: String, text: String) -> Data? {
        let bytes = [UInt8](data)
        guard let startxref = find(bytes, "startxref") else { return nil }
        var i = startxref + "startxref".utf8.count
        guard let prevXref = Int(token(bytes, &i)) else { return nil }
        guard let trailerAt = find(bytes, "trailer", before: startxref) else { return nil }
        guard let dictStart = firstDict(bytes, from: trailerAt), dictStart < startxref,
              let dictEnd = dictionaryEnd(bytes, from: dictStart) else { return nil }
        let trailer = String(decoding: bytes[dictStart..<dictEnd], as: UTF8.self)

        guard let root = firstMatch(trailer, #"/Root\s+(\d+)\s+(\d+)\s+R"#),
              let num = Int(root[1]), let gen = Int(root[2]),
              let sizeMatch = firstMatch(trailer, #"/Size\s+(\d+)"#), let size = Int(sizeMatch[1]) else { return nil }
        let info = firstMatch(trailer, #"/Info\s+\d+\s+\d+\s+R"#)?[0]
        let ids = firstMatch(trailer, #"/ID\s*\[[^\]]*\]"#)?[0]

        guard let objectAt = objectOffset(bytes, num: num, gen: gen, xref: prevXref), objectAt < bytes.count,
              let catalogStart = firstDict(bytes, from: objectAt),
              let catalogEnd = dictionaryEnd(bytes, from: catalogStart) else { return nil }
        var catalog = removingEntry(Array(bytes[catalogStart..<catalogEnd]), key: key)
        guard catalog.count >= 4 else { return nil }
        catalog.removeLast(2) // ">>"
        catalog += Array(" /\(key) \(hexText(text)) >>".utf8)

        var out = data
        if let last = bytes.last, last != 0x0A && last != 0x0D { out.append(0x0A) }
        let objectOffset = out.count
        out.append(contentsOf: Array("\(num) \(gen) obj\n".utf8))
        out.append(contentsOf: catalog)
        out.append(contentsOf: Array("\nendobj\n".utf8))
        let xrefOffset = out.count
        var tail = "xref\n\(num) 1\n"
        tail += String(format: "%010d %05d n\r\n", objectOffset, gen)
        tail += "trailer\n<< /Size \(size) /Root \(num) \(gen) R"
        if let info { tail += " \(info)" }
        if let ids { tail += " \(ids)" }
        tail += " /Prev \(prevXref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(contentsOf: Array(tail.utf8))
        return out
    }

    /// Index of the first "<<" at or after `i`.
    private static func firstDict(_ bytes: [UInt8], from i: Int) -> Int? {
        var j = i
        while j + 1 < bytes.count {
            if bytes[j] == UInt8(ascii: "<") && bytes[j + 1] == UInt8(ascii: "<") { return j }
            j += 1
        }
        return nil
    }
}
