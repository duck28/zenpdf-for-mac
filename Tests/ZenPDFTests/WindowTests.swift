import AppKit
import SwiftUI
import XCTest
@testable import ZenPDF

/// Runs the real window with a PDF and drives it with mouse and key events, as a user would.
/// Set ZENPDF_SNAPSHOTS to a folder to also get PNGs of the window.
@MainActor
final class WindowTests: XCTestCase {
    private var window: NSWindow!
    private var model: DocumentModel!
    private var fileURL: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.removeObject(forKey: "zenpdf.lastFile")
        UserDefaults.standard.removeObject(forKey: "zenpdf.lastFolder")

        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "windows-saved", withExtension: "pdf", subdirectory: "Fixtures"))
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("zenpdf-window-test-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: fixture, to: fileURL)

        model = DocumentModel()
        model.open(fileURL, silent: true)
        XCTAssertTrue(model.isPDF)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        window.makeKeyAndOrderFront(nil)
        spin(1.0)
    }

    override func tearDown() async throws {
        window?.close()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: Helpers

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView? = nil) -> [T] {
        let root = view ?? window.contentView!
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for sub in root.subviews { found += find(type, in: sub) }
        return found
    }

    private func page(_ number: Int) throws -> PageView {
        try XCTUnwrap(find(PageView.self).first { $0.number == number }, "page \(number) isn't in the window")
    }

    /// A point on a page (page units) in window coordinates.
    private func windowPoint(_ page: PageView, _ x: Double, _ y: Double) -> NSPoint {
        let zoom = CGFloat(model.zoom)
        return page.convert(NSPoint(x: CGFloat(x) * zoom, y: CGFloat(y) * zoom), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                       pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(event)
    }

    private func drag(_ page: PageView, _ points: [(Double, Double)], flags: NSEvent.ModifierFlags = [], pause: TimeInterval = 0) {
        guard let first = points.first else { return }
        mouse(.leftMouseDown, windowPoint(page, first.0, first.1), flags: flags)
        for p in points.dropFirst() {
            mouse(.leftMouseDragged, windowPoint(page, p.0, p.1), flags: flags)
            if pause > 0 { spin(pause) }
        }
        mouse(.leftMouseUp, windowPoint(page, points.last!.0, points.last!.1), flags: flags)
        spin(0.1)
    }

    private func snapshot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ZENPDF_SNAPSHOTS"], let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    // MARK: Tests

    func testShowsThePagesAndTheirAnnotations() throws {
        XCTAssertEqual(find(PageView.self).count, 2)
        let first = try page(1)
        XCTAssertGreaterThan(first.frame.width, 100)
        XCTAssertEqual(model.annotations.count, 6)
        snapshot("1-opened")
    }

    func testDrawingShapesTextAndErasing() throws {
        let first = try page(1)
        let start = model.annotations.count

        model.activeTool = .pen
        drag(first, [(100, 400), (140, 420), (180, 410), (220, 430)])
        XCTAssertEqual(model.annotations.count, start + 1)
        XCTAssertEqual(model.annotations.last?.type, .pen)
        XCTAssertGreaterThanOrEqual(model.annotations.last?.points.count ?? 0, 3)

        // Holding still straightens the stroke.
        model.activeTool = .highlighter
        drag(first, [(100, 480), (160, 484), (220, 482), (220, 482)], pause: 0.6)
        XCTAssertEqual(model.annotations.last?.type, .highlighter)
        XCTAssertEqual(model.annotations.last?.points.count, 2)

        // Shift makes a square.
        model.activeTool = .rect
        drag(first, [(300, 400), (360, 420), (380, 430)], flags: .shift)
        let square = try XCTUnwrap(model.annotations.last)
        XCTAssertEqual(square.type, .rect)
        XCTAssertEqual(square.width, square.height, accuracy: 0.01)

        model.activeTool = .arrow
        drag(first, [(300, 500), (400, 560)])
        XCTAssertEqual(model.annotations.last?.type, .arrow)

        // Text: click, type, Return.
        model.activeTool = .text
        mouse(.leftMouseDown, windowPoint(first, 100, 530))
        mouse(.leftMouseUp, windowPoint(first, 100, 530))
        spin(0.1)
        let editor = try XCTUnwrap(find(AnnotationTextView.self).first, "no text editor opened")
        editor.insertText("Hello from the Mac", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        spin(0.1)
        XCTAssertEqual(model.annotations.last?.type, .text)
        XCTAssertEqual(model.annotations.last?.text, "Hello from the Mac")
        XCTAssertTrue(find(AnnotationTextView.self).isEmpty)
        snapshot("2-drawn")

        // Undo and redo.
        let count = model.annotations.count
        model.undo()
        XCTAssertEqual(model.annotations.count, count - 1)
        model.redo()
        XCTAssertEqual(model.annotations.count, count)

        // The eraser removes what it touches.
        model.activeTool = .eraser
        drag(first, [(300, 495), (350, 530), (400, 562)])
        XCTAssertFalse(model.annotations.contains { $0.type == .arrow && $0.pageNumber == 1 && $0.x1 == 300 })

        // Saving keeps everything, and the file opens again with the same annotations.
        let expected = model.annotations
        XCTAssertTrue(model.save())
        XCTAssertFalse(model.isDirty)
        let reopened = try PDFFormat.load(Data(contentsOf: fileURL))
        XCTAssertEqual(reopened.annotations.count, expected.count)
        for a in expected { XCTAssertEqual(reopened.annotations.first { $0.id == a.id }, a, a.id) }
    }

    func testSelectMoveAndDelete() throws {
        let first = try page(1)
        model.activeTool = .rect
        drag(first, [(300, 380), (400, 440)])
        let rect = try XCTUnwrap(model.annotations.last)

        model.activeTool = .select
        drag(first, [(300, 410), (330, 430), (350, 450)])
        XCTAssertEqual(model.selectedID, rect.id)
        let moved = try XCTUnwrap(model.annotations.first { $0.id == rect.id })
        XCTAssertEqual(moved.x, rect.x + 50, accuracy: 0.5)
        XCTAssertEqual(moved.y, rect.y + 40, accuracy: 0.5)
        snapshot("3-selected")

        let pages = try XCTUnwrap(find(PagesView.self).first)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51)!
        pages.keyDown(with: delete)
        XCTAssertFalse(model.annotations.contains { $0.id == rect.id })

        // Tool keys.
        let h = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                 context: nil, characters: "h", charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4)!
        pages.keyDown(with: h)
        XCTAssertEqual(model.activeTool, .highlighter)
    }

    func testCitationCapturesTextAndOpensThePanel() throws {
        let first = try page(1)
        model.activeTool = .cite
        spin(0.5) // the citation panel opens and the page moves
        drag(first, [(60, 360), (300, 400)])
        let cite = try XCTUnwrap(model.annotations.last)
        XCTAssertEqual(cite.type, .cite)
        XCTAssertEqual(model.selectedID, cite.id)
        XCTAssertTrue(model.isCitationPanelOpen)
        spin(0.3)
        snapshot("4-citation")
    }

    func testZoomKeepsPagesLaidOut() throws {
        let width = try page(1).frame.width
        model.setZoom(2)
        spin(0.3)
        XCTAssertEqual(try page(1).frame.width, width * 2, accuracy: 2)
        model.fitWidth()
        spin(0.3)
        XCTAssertGreaterThan(model.zoom, 0.25)
        snapshot("5-zoomed")
    }
}
