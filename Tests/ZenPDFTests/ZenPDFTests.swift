import PDFKit
import XCTest
@testable import ZenPDF

/// A blank A4 PDF with `pages` pages, made with CoreGraphics.
func blankPDF(pages: Int = 2, rotation: Int = 0) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for _ in 0..<pages {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 72, y: 700, width: 200, height: 20))
        ctx.endPDFPage()
    }
    ctx.closePDF()
    if rotation == 0 { return data as Data }
    let document = PDFDocument(data: data as Data)!
    for i in 0..<document.pageCount { document.page(at: i)!.rotation = rotation }
    return document.dataRepresentation()!
}

func sampleAnnotations() -> [Annotation] {
    var pen = Annotation(id: "pen_1", type: .pen, pageNumber: 1)
    pen.points = [PagePoint(x: 100, y: 100), PagePoint(x: 150, y: 120), PagePoint(x: 200, y: 110)]
    pen.color = "#b9432f"
    pen.width = 2
    pen.penType = .fountain

    var highlight = Annotation(id: "hl_1", type: .highlighter, pageNumber: 1)
    highlight.points = [PagePoint(x: 80, y: 130), PagePoint(x: 280, y: 130)]
    highlight.color = "#e9b949"
    highlight.width = 16
    highlight.opacity = AnnotationGeometry.highlightOpacity

    var text = Annotation(id: "text_1", type: .text, pageNumber: 2)
    text.x = 60
    text.y = 300
    text.text = "Grüße, ZenPDF ✓\nsecond line"
    text.fontSize = 14
    text.color = "#1f1e1c"

    var rect = Annotation(id: "rect_1", type: .rect, pageNumber: 2)
    rect.x = 50
    rect.y = 50
    rect.width = 120
    rect.height = 60
    rect.strokeColor = "#3f6e8c"
    rect.strokeWidth = 2

    var measure = Annotation(id: "measure_1", type: .measure, pageNumber: 2)
    measure.x1 = 100
    measure.y1 = 500
    measure.x2 = 172
    measure.y2 = 500
    measure.unit = .inch

    var cite = Annotation(id: "cite_1", type: .cite, pageNumber: 1)
    cite.x = 70
    cite.y = 115
    cite.width = 210
    cite.height = 30
    cite.color = "#b9432f"
    cite.note = "An important passage."
    cite.quote = "Quoted text"
    return [pen, highlight, text, rect, measure, cite]
}

final class PDFFormatTests: XCTestCase {
    func testSaveAndReopenKeepsAnnotationsEditable() throws {
        let loaded = try PDFFormat.load(blankPDF())
        XCTAssertTrue(loaded.annotations.isEmpty)

        let annotations = sampleAnnotations()
        let source = DocumentSource(author: "Doe, Jane", title: "A Study", year: "2024", publisher: "Press", url: "")
        let saved = try PDFFormat.save(loaded.document, annotations: annotations, source: source)
        XCTAssertTrue(saved.keptEditableData)

        let reopened = try PDFFormat.load(saved.data)
        XCTAssertEqual(reopened.annotations.count, annotations.count)
        for original in annotations {
            let copy = try XCTUnwrap(reopened.annotations.first { $0.id == original.id }, original.id)
            XCTAssertEqual(copy, original, original.id)
        }
        XCTAssertEqual(reopened.source, source)

        // The ZenPDF annotations are lifted off the pages, so they aren't drawn twice.
        for i in 0..<reopened.document.pageCount {
            XCTAssertTrue(reopened.document.page(at: i)!.annotations.isEmpty, "page \(i + 1)")
        }
    }

    /// Fixtures/windows-saved.pdf was written by ZenPDF for Windows (saveAnnotationsToPdf in
    /// src/utils/pdfAnnotations.ts), with the annotations in windows-saved.json.
    func testOpensFilesSavedOnWindows() throws {
        let pdfURL = try XCTUnwrap(Bundle.module.url(forResource: "windows-saved", withExtension: "pdf", subdirectory: "Fixtures"))
        let jsonURL = try XCTUnwrap(Bundle.module.url(forResource: "windows-saved", withExtension: "json", subdirectory: "Fixtures"))
        let expected = try JSONDecoder().decode([Annotation].self, from: Data(contentsOf: jsonURL))
        let loaded = try PDFFormat.load(Data(contentsOf: pdfURL))
        XCTAssertEqual(loaded.annotations.count, expected.count)
        for annotation in expected {
            XCTAssertEqual(loaded.annotations.first { $0.id == annotation.id }, annotation, annotation.id)
        }
        XCTAssertEqual(loaded.source?.title, "Windows Fixture")
        XCTAssertEqual(loaded.source?.author, "Doe, Jane")
        for i in 0..<loaded.document.pageCount {
            XCTAssertTrue(loaded.document.page(at: i)!.annotations.isEmpty, "page \(i + 1) still has ZenPDF annotations")
        }
    }

    /// Writes a file saved by the Mac app for the Windows side of the compatibility check (see README).
    func testWritesMacFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["ZENPDF_MAC_FIXTURE"] else { throw XCTSkip("Set ZENPDF_MAC_FIXTURE") }
        let annotations = sampleAnnotations()
        let saved = try PDFFormat.save(try PDFFormat.load(blankPDF()).document, annotations: annotations,
                                       source: DocumentSource(author: "Doe, Jane", title: "Mac Fixture", year: "2025"))
        try saved.data.write(to: URL(fileURLWithPath: path))
        try JSONEncoder().encode(annotations).write(to: URL(fileURLWithPath: path + ".json"))
    }

    func testSavingTwiceDoesNotDuplicate() throws {
        let first = try PDFFormat.save(try PDFFormat.load(blankPDF()).document, annotations: sampleAnnotations(), source: nil)
        let again = try PDFFormat.load(first.data)
        let second = try PDFFormat.save(again.document, annotations: again.annotations, source: nil)
        XCTAssertEqual(try PDFFormat.load(second.data).annotations.count, sampleAnnotations().count)
    }

    func testSaveLeavesTheWorkingDocumentClean() throws {
        let document = try PDFFormat.load(blankPDF()).document
        _ = try PDFFormat.save(document, annotations: sampleAnnotations(), source: nil)
        for i in 0..<document.pageCount { XCTAssertTrue(document.page(at: i)!.annotations.isEmpty) }
    }

    func testOtherViewersSeeRealAnnotations() throws {
        let saved = try PDFFormat.save(try PDFFormat.load(blankPDF()).document, annotations: sampleAnnotations(), source: nil)
        let plain = try XCTUnwrap(PDFDocument(data: saved.data))
        let count = (0..<plain.pageCount).reduce(0) { $0 + plain.page(at: $1)!.annotations.count }
        // Six annotations plus one footnote annotation for the citation.
        XCTAssertGreaterThanOrEqual(count, 7)
    }

    func testRotatedPagesRoundTrip() throws {
        for rotation in [90, 180, 270] {
            let loaded = try PDFFormat.load(blankPDF(pages: 1, rotation: rotation))
            var rect = Annotation(id: "rect_r\(rotation)", type: .rect, pageNumber: 1)
            rect.x = 40
            rect.y = 60
            rect.width = 100
            rect.height = 50
            let saved = try PDFFormat.save(loaded.document, annotations: [rect], source: nil)
            XCTAssertEqual(try PDFFormat.load(saved.data).annotations, [rect], "rotation \(rotation)")
        }
    }

    func testPageMapperRoundTrip() throws {
        for rotation in [0, 90, 180, 270] {
            let mapper = PageMapper(crop: CGRect(x: 10, y: 20, width: 595, height: 842), rotation: rotation)
            let p = mapper.unmap(mapper.map(123, 456))
            XCTAssertEqual(p.x, 123, accuracy: 0.001)
            XCTAssertEqual(p.y, 456, accuracy: 0.001)
        }
    }

    func testFlattenedExportHasNoEditableData() throws {
        let loaded = try PDFFormat.load(blankPDF())
        let copy = try XCTUnwrap(PDFDocument(data: loaded.document.dataRepresentation()!))
        for annotation in sampleAnnotations() {
            let page = copy.page(at: annotation.pageNumber - 1)!
            page.addAnnotation(try XCTUnwrap(PDFFormat.makePDFAnnotation(annotation, page: page, citeNumbers: [:])))
        }
        let flat = try XCTUnwrap(copy.dataRepresentation(options: [PDFDocumentWriteOption.burnInAnnotationsOption: true]))
        XCTAssertEqual(PDFFormat.scan(flat).annotationCount, 0)
    }

    func testPNGExport() throws {
        let loaded = try PDFFormat.load(blankPDF(pages: 1))
        let png = try XCTUnwrap(PartsRenderer.pngData(page: loaded.document.page(at: 0)!, annotations: sampleAnnotations(),
                                                      numbers: Citations.numbers(sampleAnnotations())))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 1190)
        XCTAssertEqual(image.pixelsHigh, 1684)
    }
}

final class AnnotationTests: XCTestCase {
    func testJSONMatchesWindowsFieldNames() throws {
        var rect = Annotation(id: "rect_x", type: .rect, pageNumber: 3, createdAt: 1_700_000_000_000)
        rect.x = 1
        rect.y = 2
        rect.width = 3
        rect.height = 4
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rect)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["id", "type", "pageNumber", "createdAt", "x", "y", "width", "height", "strokeColor", "strokeWidth"])
    }

    func testDecodesWindowsJSON() throws {
        let json = #"{"id":"pen_lq3k2a1b_x7k2m9","type":"pen","pageNumber":1,"createdAt":1700000000000,"points":[{"x":1,"y":2},{"x":3,"y":4}],"color":"#000000","width":2,"opacity":1,"penType":"pencil"}"#
        let a = try JSONDecoder().decode(Annotation.self, from: Data(json.utf8))
        XCTAssertEqual(a.type, .pen)
        XCTAssertEqual(a.penType, .pencil)
        XCTAssertEqual(a.points.count, 2)
    }

    func testHitAndTranslate() {
        var line = Annotation(id: "line_1", type: .line, pageNumber: 1)
        line.x1 = 0
        line.y1 = 0
        line.x2 = 100
        line.y2 = 0
        XCTAssertTrue(AnnotationGeometry.isHit(line, PagePoint(x: 50, y: 2), tol: 4))
        XCTAssertFalse(AnnotationGeometry.isHit(line, PagePoint(x: 50, y: 40), tol: 4))
        let moved = AnnotationGeometry.translate(line, dx: 10, dy: 5)
        XCTAssertEqual(moved.x1, 10)
        XCTAssertEqual(moved.y2, 5)
    }

    func testMeasurementFormatting() {
        XCTAssertEqual(formatMeasurement(72, .inch), "1.00 in")
        XCTAssertEqual(formatMeasurement(72, .cm), "2.54 cm")
        XCTAssertEqual(formatMeasurement(72, .mm), "25.4 mm")
    }
}

final class CitationTests: XCTestCase {
    let source = DocumentSource(author: "Doe, Jane; Smith, John", title: "A Study of Things", year: "2024",
                                publisher: "University Press", url: "")

    func testNumbersFollowPageOrder() {
        var a = Annotation(id: "a", type: .cite, pageNumber: 2)
        a.y = 10
        var b = Annotation(id: "b", type: .cite, pageNumber: 1)
        b.y = 500
        var c = Annotation(id: "c", type: .cite, pageNumber: 1)
        c.y = 100
        XCTAssertEqual(Citations.numbers([a, b, c]), ["c": 1, "b": 2, "a": 3])
    }

    func testStylesMentionTheSource() {
        for style in CitationStyle.allCases {
            let reference = Citations.format(style, source: source, page: "12")
            XCTAssertTrue(reference.contains("Doe"), "\(style): \(reference)")
            XCTAssertTrue(reference.contains("2024"), "\(style): \(reference)")
        }
        XCTAssertTrue(Citations.format(.bibtex, source: source, page: "12").hasPrefix("@"))
    }
}

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let blocks = MarkdownView.blocks("# Title\n\nSome *text*\ncontinues.\n\n- one\n- two\n1. first\n> quote\n---\n```\ncode\n```")
        XCTAssertEqual(blocks, [
            .heading(1, "Title"),
            .paragraph("Some *text* continues."),
            .bullet("one", indent: 0),
            .bullet("two", indent: 0),
            .numbered("1", "first", indent: 0),
            .quote("quote"),
            .rule,
            .code("code"),
        ])
    }
}
