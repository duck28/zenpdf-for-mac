import Foundation

// The annotation model, field for field the same as ZenPDF for Windows (src/types/index.ts).
// Saved files carry each annotation as this JSON, so both apps can edit what the other saved.
//
// All coordinates are "page units": PDF points with the page's rotation applied, origin at the
// top-left of the crop box and y pointing down (the pdf.js viewport at scale 1).

enum ToolType: String, CaseIterable, Identifiable {
    case select, pen, highlighter, text, rect, circle, line, arrow, measure, cite, eraser

    var id: Self { self }

    /// Tools that draw a shape by dragging from corner to corner (or end to end).
    var isShape: Bool {
        switch self {
        case .rect, .circle, .line, .arrow, .measure, .cite: return true
        default: return false
        }
    }

    /// Tools that share one width setting (as on Windows).
    var widthKey: ToolType {
        switch self {
        case .circle, .line, .arrow: return .rect
        default: return self
        }
    }
}

enum AnnotationType: String, Codable, CaseIterable {
    case pen, highlighter, text, rect, circle, line, arrow, measure, cite

    var label: String {
        switch self {
        case .pen: return "Ink"
        case .highlighter: return "Highlight"
        case .text: return "Text"
        case .rect: return "Rectangle"
        case .circle: return "Ellipse"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .measure: return "Measurement"
        case .cite: return "Citation"
        }
    }
}

enum PenType: String, Codable, CaseIterable, Identifiable {
    case ballpoint, fountain, marker, pencil, dashed

    var id: Self { self }

    var label: String {
        switch self {
        case .ballpoint: return "Ballpoint"
        case .fountain: return "Fountain"
        case .marker: return "Marker"
        case .pencil: return "Pencil"
        case .dashed: return "Dashed"
        }
    }

    var hint: String {
        switch self {
        case .ballpoint: return "Smooth, even line"
        case .fountain: return "Calligraphic, angled nib"
        case .marker: return "Bold, flat, slightly translucent"
        case .pencil: return "Soft, textured graphite"
        case .dashed: return "Dashed line"
        }
    }

    var symbol: String {
        switch self {
        case .ballpoint: return "pencil.tip"
        case .fountain: return "paintbrush.pointed"
        case .marker: return "paintbrush"
        case .pencil: return "pencil"
        case .dashed: return "scribble"
        }
    }
}

enum MeasureUnit: String, Codable, CaseIterable, Identifiable {
    case cm, mm
    case inch = "in"

    var id: Self { self }
}

enum CitationStyle: String, CaseIterable, Identifiable {
    case apa, mla, chicago, bibtex

    var id: Self { self }

    var label: String {
        switch self {
        case .apa: return "APA 7"
        case .mla: return "MLA 9"
        case .chicago: return "Chicago"
        case .bibtex: return "BibTeX"
        }
    }
}

struct PagePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

/// Bibliographic information about the open document, used for citations.
struct DocumentSource: Codable, Equatable {
    var author = ""
    var title = ""
    var year = ""
    var publisher = ""
    var url = ""

    var isEmpty: Bool {
        [author, title, year, publisher, url].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    init(author: String = "", title: String = "", year: String = "", publisher: String = "", url: String = "") {
        self.author = author
        self.title = title
        self.year = year
        self.publisher = publisher
        self.url = url
    }

    // Lenient like Windows: missing or non-string fields become empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func field(_ key: CodingKeys) -> String {
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let d = try? c.decode(Double.self, forKey: key) { return String(Int(d)) }
            return ""
        }
        author = field(.author)
        title = field(.title)
        year = field(.year)
        publisher = field(.publisher)
        url = field(.url)
    }
}

/// One annotation. Which fields are used depends on `type`, exactly like the TypeScript union on Windows;
/// encoding writes only the fields of that type.
struct Annotation: Codable, Identifiable, Equatable {
    var id: String
    var type: AnnotationType
    /// 1-based.
    var pageNumber: Int
    /// Milliseconds since 1970, like JavaScript's Date.now().
    var createdAt: Double

    // pen, highlighter
    var points: [PagePoint] = []
    var opacity: Double = 1
    var penType: PenType = .ballpoint

    // pen, highlighter, text, cite
    var color = "#000000"

    // pen and highlighter use `width` for the stroke width; rect and cite for the box width.
    var width: Double = 0
    var height: Double = 0

    // text, rect, circle, cite
    var x: Double = 0
    var y: Double = 0

    // text
    var text = ""
    var fontSize: Double = 16
    var bgColor: String?

    // rect, circle, line, arrow, measure
    var strokeColor = "#000000"
    var strokeWidth: Double = 2
    var fillColor: String?

    // circle (x, y is the center)
    var radiusX: Double = 0
    var radiusY: Double = 0

    // line, arrow, measure
    var x1: Double = 0
    var y1: Double = 0
    var x2: Double = 0
    var y2: Double = 0
    var unit: MeasureUnit = .cm

    // cite
    var note = ""
    var quote = ""
    var pageLabel: String?

    init(id: String, type: AnnotationType, pageNumber: Int, createdAt: Double = Annotation.now()) {
        self.id = id
        self.type = type
        self.pageNumber = pageNumber
        self.createdAt = createdAt
    }

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// The color shown in lists: `color` or `strokeColor`, as on Windows.
    var displayColor: String {
        switch type {
        case .pen, .highlighter, .text, .cite: return color
        default: return strokeColor
        }
    }

    // MARK: Coding

    enum CodingKeys: String, CodingKey {
        case id, type, pageNumber, createdAt
        case points, color, width, opacity, penType
        case x, y, text, fontSize, bgColor
        case height, strokeColor, strokeWidth, fillColor
        case radiusX, radiusY
        case x1, y1, x2, y2, unit
        case note, quote, pageLabel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(AnnotationType.self, forKey: .type)
        pageNumber = (try? c.decode(Int.self, forKey: .pageNumber))
            ?? Int((try? c.decode(Double.self, forKey: .pageNumber)) ?? 1)
        createdAt = (try? c.decode(Double.self, forKey: .createdAt)) ?? Annotation.now()

        func number(_ key: CodingKeys, _ fallback: Double) -> Double {
            guard let value = try? c.decode(Double.self, forKey: key), value.isFinite else { return fallback }
            return value
        }
        func string(_ key: CodingKeys, _ fallback: String) -> String {
            (try? c.decode(String.self, forKey: key)) ?? fallback
        }

        points = ((try? c.decode([PagePoint].self, forKey: .points)) ?? []).filter { $0.x.isFinite && $0.y.isFinite }
        color = string(.color, "#000000")
        width = number(.width, 0)
        height = number(.height, 0)
        opacity = number(.opacity, type == .highlighter ? AnnotationGeometry.highlightOpacity : 1)
        penType = (try? c.decode(PenType.self, forKey: .penType)) ?? .ballpoint
        x = number(.x, 0)
        y = number(.y, 0)
        text = string(.text, "")
        fontSize = number(.fontSize, 16)
        bgColor = try? c.decode(String.self, forKey: .bgColor)
        strokeColor = string(.strokeColor, "#000000")
        strokeWidth = number(.strokeWidth, 2)
        fillColor = try? c.decode(String.self, forKey: .fillColor)
        radiusX = number(.radiusX, 0)
        radiusY = number(.radiusY, 0)
        x1 = number(.x1, 0)
        y1 = number(.y1, 0)
        x2 = number(.x2, 0)
        y2 = number(.y2, 0)
        unit = (try? c.decode(MeasureUnit.self, forKey: .unit)) ?? .cm
        note = string(.note, "")
        quote = string(.quote, "")
        pageLabel = try? c.decode(String.self, forKey: .pageLabel)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(pageNumber, forKey: .pageNumber)
        try c.encode(createdAt, forKey: .createdAt)
        switch type {
        case .pen, .highlighter:
            try c.encode(points, forKey: .points)
            try c.encode(color, forKey: .color)
            try c.encode(width, forKey: .width)
            try c.encode(opacity, forKey: .opacity)
            if type == .pen { try c.encode(penType, forKey: .penType) }
        case .text:
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(text, forKey: .text)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(color, forKey: .color)
            try c.encodeIfPresent(bgColor, forKey: .bgColor)
        case .rect:
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(strokeColor, forKey: .strokeColor)
            try c.encode(strokeWidth, forKey: .strokeWidth)
            try c.encodeIfPresent(fillColor, forKey: .fillColor)
        case .circle:
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(radiusX, forKey: .radiusX)
            try c.encode(radiusY, forKey: .radiusY)
            try c.encode(strokeColor, forKey: .strokeColor)
            try c.encode(strokeWidth, forKey: .strokeWidth)
            try c.encodeIfPresent(fillColor, forKey: .fillColor)
        case .line, .arrow, .measure:
            try c.encode(x1, forKey: .x1)
            try c.encode(y1, forKey: .y1)
            try c.encode(x2, forKey: .x2)
            try c.encode(y2, forKey: .y2)
            try c.encode(strokeColor, forKey: .strokeColor)
            try c.encode(strokeWidth, forKey: .strokeWidth)
            if type == .measure { try c.encode(unit, forKey: .unit) }
        case .cite:
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
            try c.encode(color, forKey: .color)
            try c.encode(note, forKey: .note)
            try c.encode(quote, forKey: .quote)
            try c.encodeIfPresent(pageLabel, forKey: .pageLabel)
        }
    }
}

/// New annotation ids look like the Windows ones: `pen_lq3k2a1b_x7k2m9`.
func newAnnotationID(_ prefix: String) -> String {
    let millis = Int(Date().timeIntervalSince1970 * 1000)
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let random = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    return "\(prefix)_\(String(millis, radix: 36))_\(random)"
}

// MARK: - Tool settings (src/utils/tools.ts)

/// What the thickness slider controls for a tool, and its range.
struct WidthSpec {
    let min: Double
    let max: Double
    let step: Double
    let defaultValue: Double
    let label: String
    let unit: String

    static let stroke = WidthSpec(min: 0.5, max: 20, step: 0.5, defaultValue: 2, label: "Thickness", unit: "pt")

    static func forTool(_ tool: ToolType) -> WidthSpec? {
        switch tool {
        case .pen, .rect, .circle, .line, .arrow: return .stroke
        case .highlighter: return WidthSpec(min: 4, max: 48, step: 1, defaultValue: 16, label: "Thickness", unit: "pt")
        case .text: return WidthSpec(min: 6, max: 72, step: 1, defaultValue: 16, label: "Font size", unit: "pt")
        case .measure: return WidthSpec(min: 0.5, max: 6, step: 0.5, defaultValue: 1, label: "Thickness", unit: "pt")
        default: return nil
        }
    }

    static func defaultWidths() -> [ToolType: Double] {
        var widths: [ToolType: Double] = [:]
        for tool in ToolType.allCases {
            if let spec = forTool(tool) { widths[tool.widthKey] = spec.defaultValue }
        }
        return widths
    }
}

/// The palette from the Windows tool dock.
let presetColors: [(hex: String, name: String)] = [
    ("#1f1e1c", "Sumi ink"),
    ("#b9432f", "Vermilion"),
    ("#3f6e8c", "Indigo dye"),
    ("#5b7f4a", "Moss"),
    ("#e9b949", "Highlighter gold"),
    ("#d97aa6", "Sakura"),
    ("#8a6fb0", "Wisteria"),
    ("#ffffff", "White"),
]

/// Page units are PDF points (1/72 inch).
func formatMeasurement(_ points: Double, _ unit: MeasureUnit) -> String {
    let inches = points / 72
    switch unit {
    case .inch: return String(format: "%.2f in", inches)
    case .mm: return String(format: "%.1f mm", inches * 25.4)
    case .cm: return String(format: "%.2f cm", inches * 2.54)
    }
}
