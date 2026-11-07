import AppKit
import CoreText

// Shared annotation geometry, ported from src/utils/annotations.ts in ZenPDF for Windows.
//
// Every annotation is turned into a list of render parts (vector paths and text runs). The canvas, the
// PNG export and the flattened PDF export all draw those same parts, so what you see is what gets saved.

enum PathCmd {
    case move(Double, Double)
    case line(Double, Double)
    /// Control point, then end point.
    case quad(Double, Double, Double, Double)
    /// Two control points, then end point.
    case cubic(Double, Double, Double, Double, Double, Double)
    case close
}

enum LineCap {
    case round, butt, square

    var cgLineCap: CGLineCap {
        switch self {
        case .round: return .round
        case .butt: return .butt
        case .square: return .square
        }
    }
}

struct StrokeStyleSpec {
    var color: String
    var width: Double
    var cap: LineCap
    var dash: [Double]? = nil
    var opacity: Double? = nil
}

struct FillStyleSpec {
    var color: String
    var opacity: Double? = nil
}

enum RenderPart {
    case path(cmds: [PathCmd], stroke: StrokeStyleSpec?, fill: FillStyleSpec?, multiply: Bool)
    /// `y` is the baseline.
    case text(String, x: Double, y: Double, size: Double, color: String, bold: Bool)
}

struct Bounds: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum Handle: String {
    case nw, n, ne, e, se, s, sw, w, p1, p2

    var isCorner: Bool { rawValue.count == 2 && self != .p1 && self != .p2 }
    var isEndpoint: Bool { self == .p1 || self == .p2 }
}

/// Text width in page units, measured with Helvetica like the PDF fonts on Windows.
enum TextMeasure {
    static func font(size: Double, bold: Bool) -> CTFont {
        CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, CGFloat(size), nil)
    }

    static func line(_ text: String, size: Double, bold: Bool, color: CGColor? = nil) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
        ]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        let string = NSAttributedString(string: text, attributes: attributes)
        return CTLineCreateWithAttributedString(string as CFAttributedString)
    }

    static func width(_ text: String, size: Double, bold: Bool = false) -> Double {
        guard !text.isEmpty else { return 0 }
        return Double(CTLineGetTypographicBounds(line(text, size: size, bold: bold), nil, nil, nil))
    }
}

enum AnnotationGeometry {
    static let textLineHeight = 1.2
    /// First baseline offset from the top, in em.
    static let textBaseline = 0.8
    static let highlightOpacity = 0.4

    private static let measureTick = 6.0
    private static let measureLabelSize = 9.0
    private static let citeBadgeSize = 8.0

    // MARK: Paths

    /// Freehand stroke smoothed with quadratic curves through segment midpoints.
    static func smoothPath(_ points: [PagePoint]) -> [PathCmd] {
        guard let first = points.first else { return [] }
        let pts = points.count == 1 ? [first, PagePoint(x: first.x + 0.01, y: first.y)] : points
        var cmds: [PathCmd] = [.move(pts[0].x, pts[0].y)]
        if pts.count == 2 {
            cmds.append(.line(pts[1].x, pts[1].y))
            return cmds
        }
        for i in 1..<(pts.count - 1) {
            let mx = (pts[i].x + pts[i + 1].x) / 2
            let my = (pts[i].y + pts[i + 1].y) / 2
            cmds.append(.quad(pts[i].x, pts[i].y, mx, my))
        }
        let last = pts[pts.count - 1]
        cmds.append(.line(last.x, last.y))
        return cmds
    }

    /// Calligraphic stroke: a flat nib held at 45° swept along the points.
    private static func nibPath(_ points: [PagePoint], width: Double) -> [PathCmd] {
        guard let first = points.first else { return [] }
        let angle = -Double.pi / 4
        let nx = cos(angle) * width / 2
        let ny = sin(angle) * width / 2
        let pts = points.count == 1 ? [first, PagePoint(x: first.x + 0.01, y: first.y)] : points
        var cmds: [PathCmd] = []
        for i in 0..<(pts.count - 1) {
            let a = pts[i]
            let b = pts[i + 1]
            var quad = [
                PagePoint(x: a.x + nx, y: a.y + ny),
                PagePoint(x: b.x + nx, y: b.y + ny),
                PagePoint(x: b.x - nx, y: b.y - ny),
                PagePoint(x: a.x - nx, y: a.y - ny),
            ]
            // Shoelace: force positive orientation so the union fills cleanly with the nonzero rule.
            var area = 0.0
            for k in 0..<4 {
                let p = quad[k]
                let q = quad[(k + 1) % 4]
                area += p.x * q.y - q.x * p.y
            }
            if area < 0 { quad.reverse() }
            cmds.append(.move(quad[0].x, quad[0].y))
            for k in 1..<4 { cmds.append(.line(quad[k].x, quad[k].y)) }
            cmds.append(.close)
        }
        return cmds
    }

    static func rectPath(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [PathCmd] {
        [.move(x, y), .line(x + w, y), .line(x + w, y + h), .line(x, y + h), .close]
    }

    static func ellipsePath(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> [PathCmd] {
        let k = 0.5522847498
        let ox = rx * k
        let oy = ry * k
        return [
            .move(cx + rx, cy),
            .cubic(cx + rx, cy + oy, cx + ox, cy + ry, cx, cy + ry),
            .cubic(cx - ox, cy + ry, cx - rx, cy + oy, cx - rx, cy),
            .cubic(cx - rx, cy - oy, cx - ox, cy - ry, cx, cy - ry),
            .cubic(cx + ox, cy - ry, cx + rx, cy - oy, cx + rx, cy),
            .close,
        ]
    }

    static func arrowHeadLength(_ strokeWidth: Double) -> Double { max(10, strokeWidth * 4) }

    static func textLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Label box for a ruler annotation.
    private static func measureLabel(_ ann: Annotation) -> (text: String, x: Double, y: Double, w: Double, h: Double) {
        let text = formatMeasurement(hypot(ann.x2 - ann.x1, ann.y2 - ann.y1), ann.unit)
        let w = TextMeasure.width(text, size: measureLabelSize, bold: true) + 8
        let h = measureLabelSize + 6
        let mx = (ann.x1 + ann.x2) / 2
        let my = (ann.y1 + ann.y2) / 2
        return (text, mx - w / 2, my - h - 4, w, h)
    }

    // MARK: Render parts

    static func parts(for ann: Annotation, citeNumbers: [String: Int] = [:]) -> [RenderPart] {
        switch ann.type {
        case .pen:
            let w = ann.width
            switch ann.penType {
            case .fountain:
                return [
                    .path(cmds: nibPath(ann.points, width: w * 2), stroke: nil, fill: FillStyleSpec(color: ann.color), multiply: false),
                    // A hairline core keeps strokes parallel to the nib from vanishing.
                    .path(cmds: smoothPath(ann.points),
                          stroke: StrokeStyleSpec(color: ann.color, width: max(0.4, w * 0.25), cap: .round), fill: nil, multiply: false),
                ]
            case .marker:
                return [.path(cmds: smoothPath(ann.points),
                              stroke: StrokeStyleSpec(color: ann.color, width: w * 1.5, cap: .square, opacity: 0.85),
                              fill: nil, multiply: false)]
            case .pencil:
                let jitter = max(0.3, w * 0.25)
                let shifted = ann.points.enumerated().map { i, p in
                    PagePoint(x: p.x + (i % 2 == 1 ? jitter : -jitter) * 0.5, y: p.y + jitter * 0.5)
                }
                return [
                    .path(cmds: smoothPath(ann.points),
                          stroke: StrokeStyleSpec(color: ann.color, width: w * 0.8, cap: .round, opacity: 0.55), fill: nil, multiply: false),
                    .path(cmds: smoothPath(shifted),
                          stroke: StrokeStyleSpec(color: ann.color, width: w * 0.5, cap: .round, opacity: 0.35), fill: nil, multiply: false),
                ]
            case .dashed:
                return [.path(cmds: smoothPath(ann.points),
                              stroke: StrokeStyleSpec(color: ann.color, width: w, cap: .butt, dash: [w * 3 + 2, w * 2 + 2]),
                              fill: nil, multiply: false)]
            case .ballpoint:
                return [.path(cmds: smoothPath(ann.points),
                              stroke: StrokeStyleSpec(color: ann.color, width: w, cap: .round, opacity: ann.opacity),
                              fill: nil, multiply: false)]
            }
        case .highlighter:
            return [.path(cmds: smoothPath(ann.points),
                          stroke: StrokeStyleSpec(color: ann.color, width: ann.width, cap: .butt, opacity: ann.opacity),
                          fill: nil, multiply: true)]
        case .rect:
            return [.path(cmds: rectPath(ann.x, ann.y, ann.width, ann.height),
                          stroke: StrokeStyleSpec(color: ann.strokeColor, width: ann.strokeWidth, cap: .round),
                          fill: ann.fillColor.map { FillStyleSpec(color: $0) }, multiply: false)]
        case .circle:
            return [.path(cmds: ellipsePath(ann.x, ann.y, abs(ann.radiusX), abs(ann.radiusY)),
                          stroke: StrokeStyleSpec(color: ann.strokeColor, width: ann.strokeWidth, cap: .round),
                          fill: ann.fillColor.map { FillStyleSpec(color: $0) }, multiply: false)]
        case .line, .arrow:
            var cmds: [PathCmd] = [.move(ann.x1, ann.y1), .line(ann.x2, ann.y2)]
            if ann.type == .arrow {
                let angle = atan2(ann.y2 - ann.y1, ann.x2 - ann.x1)
                let len = arrowHeadLength(ann.strokeWidth)
                for da in [-Double.pi / 6, Double.pi / 6] {
                    cmds.append(.move(ann.x2, ann.y2))
                    cmds.append(.line(ann.x2 - len * cos(angle + da), ann.y2 - len * sin(angle + da)))
                }
            }
            return [.path(cmds: cmds, stroke: StrokeStyleSpec(color: ann.strokeColor, width: ann.strokeWidth, cap: .round),
                          fill: nil, multiply: false)]
        case .measure:
            let len = hypot(ann.x2 - ann.x1, ann.y2 - ann.y1)
            let safeLen = len == 0 ? 1 : len
            // Perpendicular unit vector for the end ticks.
            let px = -(ann.y2 - ann.y1) / safeLen
            let py = (ann.x2 - ann.x1) / safeLen
            var cmds: [PathCmd] = [.move(ann.x1, ann.y1), .line(ann.x2, ann.y2)]
            for (x, y) in [(ann.x1, ann.y1), (ann.x2, ann.y2)] {
                cmds.append(.move(x + px * measureTick, y + py * measureTick))
                cmds.append(.line(x - px * measureTick, y - py * measureTick))
            }
            let label = measureLabel(ann)
            return [
                .path(cmds: cmds, stroke: StrokeStyleSpec(color: ann.strokeColor, width: ann.strokeWidth, cap: .butt),
                      fill: nil, multiply: false),
                .path(cmds: rectPath(label.x, label.y, label.w, label.h),
                      stroke: StrokeStyleSpec(color: ann.strokeColor, width: 0.5, cap: .butt),
                      fill: FillStyleSpec(color: "#ffffff", opacity: 0.9), multiply: false),
                .text(label.text, x: label.x + 4, y: label.y + label.h - 4.5, size: measureLabelSize, color: ann.strokeColor, bold: true),
            ]
        case .cite:
            var parts: [RenderPart] = [
                // A light tint over the marked passage.
                .path(cmds: rectPath(ann.x, ann.y, ann.width, ann.height), stroke: nil,
                      fill: FillStyleSpec(color: ann.color, opacity: 0.12), multiply: true),
                // Margin bracket.
                .path(cmds: [.move(ann.x - 2, ann.y), .line(ann.x - 5, ann.y), .line(ann.x - 5, ann.y + ann.height),
                             .line(ann.x - 2, ann.y + ann.height)],
                      stroke: StrokeStyleSpec(color: ann.color, width: 1.5, cap: .butt), fill: nil, multiply: false),
            ]
            if let n = citeNumbers[ann.id] {
                let text = String(n)
                let bw = max(TextMeasure.width(text, size: citeBadgeSize, bold: true) + 6, citeBadgeSize + 5)
                let bh = citeBadgeSize + 5
                let bx = ann.x + ann.width + 3
                let by = ann.y - bh / 2
                let r = bh / 2
                parts.append(.path(cmds: [
                    .move(bx + r, by),
                    .line(bx + bw - r, by),
                    .quad(bx + bw, by, bx + bw, by + r),
                    .quad(bx + bw, by + bh, bx + bw - r, by + bh),
                    .line(bx + r, by + bh),
                    .quad(bx, by + bh, bx, by + r),
                    .quad(bx, by, bx + r, by),
                    .close,
                ], stroke: nil, fill: FillStyleSpec(color: ann.color), multiply: false))
                let tw = TextMeasure.width(text, size: citeBadgeSize, bold: true)
                parts.append(.text(text, x: bx + (bw - tw) / 2, y: by + bh - 3, size: citeBadgeSize, color: "#ffffff", bold: true))
            }
            return parts
        case .text:
            return textLines(ann.text).enumerated().map { i, line in
                RenderPart.text(line, x: ann.x, y: ann.y + ann.fontSize * (textBaseline + Double(i) * textLineHeight),
                      size: ann.fontSize, color: ann.color, bold: false)
            }
        }
    }

    // MARK: Footnotes

    private static let footnoteSize = 8.0
    private static let footnoteLeading = 10.0
    private static let footnoteMarginX = 40.0
    private static let footnoteMarginBottom = 22.0
    private static let footnoteIndent = 12.0

    static func wrapText(_ text: String, maxWidth: Double, size: Double) -> [String] {
        var out: [String] = []
        for paragraph in textLines(text) {
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var line = ""
            for word in words {
                let candidate = line.isEmpty ? word : "\(line) \(word)"
                if TextMeasure.width(candidate, size: size) <= maxWidth || line.isEmpty {
                    line = candidate
                } else {
                    out.append(line)
                    line = word
                }
            }
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    /// Footnotes for the citations on one page, stacked above the bottom margin on a white panel.
    static func footnoteParts(_ cites: [Annotation], numbers: [String: Int], pageWidth: Double, pageHeight: Double) -> [RenderPart] {
        let withNotes = cites
            .filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { (numbers[$0.id] ?? 0) < (numbers[$1.id] ?? 0) }
        guard !withNotes.isEmpty else { return [] }

        let maxWidth = pageWidth - footnoteMarginX * 2 - footnoteIndent
        let blocks = withNotes.map { c in
            (n: numbers[c.id] ?? 0, color: c.color,
             lines: wrapText(c.note.trimmingCharacters(in: .whitespacesAndNewlines), maxWidth: maxWidth, size: footnoteSize))
        }
        let totalLines = blocks.reduce(0) { $0 + $1.lines.count }
        let blockHeight = Double(totalLines) * footnoteLeading + 8
        let top = pageHeight - footnoteMarginBottom - blockHeight
        let left = footnoteMarginX

        var parts: [RenderPart] = [
            .path(cmds: rectPath(left - 4, top - 4, pageWidth - 2 * footnoteMarginX + 8, blockHeight + 6),
                  stroke: nil, fill: FillStyleSpec(color: "#ffffff", opacity: 0.92), multiply: false),
            .path(cmds: [.move(left, top), .line(left + min(140, (pageWidth - 2 * footnoteMarginX) / 3), top)],
                  stroke: StrokeStyleSpec(color: "#475569", width: 0.5, cap: .butt), fill: nil, multiply: false),
        ]
        var y = top + 4 + footnoteSize
        for block in blocks {
            parts.append(.text(String(block.n), x: left, y: y - 2, size: footnoteSize - 1.5, color: block.color, bold: true))
            for line in block.lines {
                parts.append(.text(line, x: left + footnoteIndent, y: y, size: footnoteSize, color: "#1e293b", bold: false))
                y += footnoteLeading
            }
        }
        return parts
    }

    // MARK: Bounds and hit testing

    private static func boundsOf(_ xs: [Double], _ ys: [Double], pad: Double) -> Bounds {
        let minX = (xs.min() ?? 0) - pad
        let minY = (ys.min() ?? 0) - pad
        let maxX = (xs.max() ?? 0) + pad
        let maxY = (ys.max() ?? 0) + pad
        return Bounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func bounds(of ann: Annotation) -> Bounds {
        switch ann.type {
        case .pen, .highlighter:
            let pad = ann.type == .pen && ann.penType == .fountain ? ann.width : ann.width / 2
            return boundsOf(ann.points.map(\.x), ann.points.map(\.y), pad: pad)
        case .rect:
            return boundsOf([ann.x, ann.x + ann.width], [ann.y, ann.y + ann.height], pad: ann.strokeWidth / 2)
        case .circle:
            let rx = abs(ann.radiusX)
            let ry = abs(ann.radiusY)
            return boundsOf([ann.x - rx, ann.x + rx], [ann.y - ry, ann.y + ry], pad: ann.strokeWidth / 2)
        case .line, .arrow:
            let pad = ann.type == .arrow ? arrowHeadLength(ann.strokeWidth) : ann.strokeWidth
            return boundsOf([ann.x1, ann.x2], [ann.y1, ann.y2], pad: pad)
        case .measure:
            let l = measureLabel(ann)
            return boundsOf([ann.x1, ann.x2, l.x, l.x + l.w], [ann.y1, ann.y2, l.y, l.y + l.h], pad: measureTick)
        case .cite:
            return boundsOf([ann.x - 6, ann.x + ann.width + 16], [ann.y - 8, ann.y + ann.height], pad: 0)
        case .text:
            let lines = textLines(ann.text)
            let width = max(lines.map { TextMeasure.width($0, size: ann.fontSize) }.max() ?? 0, ann.fontSize)
            return Bounds(x: ann.x, y: ann.y, width: width, height: Double(lines.count) * ann.fontSize * textLineHeight)
        }
    }

    private static func distToSegment(_ p: PagePoint, _ a: PagePoint, _ b: PagePoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func inBounds(_ p: PagePoint, _ b: Bounds, _ tol: Double) -> Bool {
        p.x >= b.x - tol && p.x <= b.x + b.width + tol && p.y >= b.y - tol && p.y <= b.y + b.height + tol
    }

    /// Hit test in page units; `tol` is the click tolerance in page units.
    static func isHit(_ ann: Annotation, _ p: PagePoint, tol: Double) -> Bool {
        switch ann.type {
        case .pen, .highlighter:
            let r = (ann.type == .pen && ann.penType == .fountain ? ann.width : ann.width / 2) + tol
            guard let first = ann.points.first else { return false }
            if ann.points.count == 1 { return hypot(p.x - first.x, p.y - first.y) <= r }
            for i in 0..<(ann.points.count - 1) where distToSegment(p, ann.points[i], ann.points[i + 1]) <= r {
                return true
            }
            return false
        case .circle:
            let rx = abs(ann.radiusX) + tol
            let ry = abs(ann.radiusY) + tol
            let dx = (p.x - ann.x) / rx
            let dy = (p.y - ann.y) / ry
            return dx * dx + dy * dy <= 1
        case .line, .arrow:
            return distToSegment(p, PagePoint(x: ann.x1, y: ann.y1), PagePoint(x: ann.x2, y: ann.y2)) <= ann.strokeWidth / 2 + tol
        case .measure:
            if distToSegment(p, PagePoint(x: ann.x1, y: ann.y1), PagePoint(x: ann.x2, y: ann.y2)) <= ann.strokeWidth / 2 + tol {
                return true
            }
            let l = measureLabel(ann)
            return inBounds(p, Bounds(x: l.x, y: l.y, width: l.w, height: l.h), tol)
        default:
            return inBounds(p, bounds(of: ann), tol)
        }
    }

    static func translate(_ ann: Annotation, dx: Double, dy: Double) -> Annotation {
        var a = ann
        switch ann.type {
        case .pen, .highlighter:
            a.points = ann.points.map { PagePoint(x: $0.x + dx, y: $0.y + dy) }
        case .line, .arrow, .measure:
            a.x1 += dx
            a.y1 += dy
            a.x2 += dx
            a.y2 += dy
        default:
            a.x += dx
            a.y += dy
        }
        return a
    }

    // MARK: Resizing

    private static func hasEndpoints(_ a: Annotation) -> Bool {
        a.type == .line || a.type == .arrow || a.type == .measure
    }

    /// The box the user resizes (unpadded geometry, not the selection outline).
    static func geometryBox(_ ann: Annotation) -> Bounds {
        switch ann.type {
        case .pen, .highlighter:
            return boundsOf(ann.points.map(\.x), ann.points.map(\.y), pad: 0)
        case .rect, .cite:
            return Bounds(x: ann.x, y: ann.y, width: ann.width, height: ann.height)
        case .circle:
            return Bounds(x: ann.x - abs(ann.radiusX), y: ann.y - abs(ann.radiusY),
                          width: abs(ann.radiusX) * 2, height: abs(ann.radiusY) * 2)
        case .text:
            return bounds(of: ann)
        case .line, .arrow, .measure:
            return boundsOf([ann.x1, ann.x2], [ann.y1, ann.y2], pad: 0)
        }
    }

    static func handlePositions(_ ann: Annotation) -> [(handle: Handle, x: Double, y: Double)] {
        if hasEndpoints(ann) {
            return [(handle: .p1, x: ann.x1, y: ann.y1), (handle: .p2, x: ann.x2, y: ann.y2)]
        }
        let b = geometryBox(ann)
        let l = b.x
        let t = b.y
        let r = b.x + b.width
        let bt = b.y + b.height
        let mx = l + b.width / 2
        let my = t + b.height / 2
        let corners: [(handle: Handle, x: Double, y: Double)] = [
            (handle: .nw, x: l, y: t), (handle: .ne, x: r, y: t), (handle: .se, x: r, y: bt), (handle: .sw, x: l, y: bt),
        ]
        // Text scales uniformly from its corners; flat strokes have no height to drag.
        if ann.type == .text { return corners }
        var edges: [(handle: Handle, x: Double, y: Double)] = []
        if b.height > 0.5 { edges += [(handle: .e, x: r, y: my), (handle: .w, x: l, y: my)] }
        if b.width > 0.5 { edges += [(handle: .n, x: mx, y: t), (handle: .s, x: mx, y: bt)] }
        return corners + edges
    }

    /// Snaps the direction from `a` to `b` onto 0/45/90° when within `tolDeg` (all directions if tolDeg ≥ 22.5).
    static func snapAngle(_ a: PagePoint, _ b: PagePoint, tolDeg: Double = 5) -> PagePoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = hypot(dx, dy)
        if len == 0 { return b }
        let angle = atan2(dy, dx)
        let step = Double.pi / 4
        let snapped = (angle / step).rounded() * step
        if abs(snapped - angle) > tolDeg * Double.pi / 180 { return b }
        return PagePoint(x: a.x + len * cos(snapped), y: a.y + len * sin(snapped))
    }

    /// Resizes an annotation by dragging one of its handles to `pt`. `uniform` keeps the aspect ratio
    /// (Shift, and always for text).
    static func resize(_ orig: Annotation, handle: Handle, to pt: PagePoint, uniform: Bool) -> Annotation {
        var out = orig
        if hasEndpoints(orig) {
            if handle == .p1 {
                let p = uniform ? snapAngle(PagePoint(x: orig.x2, y: orig.y2), pt, tolDeg: 23) : pt
                out.x1 = p.x
                out.y1 = p.y
            } else {
                let p = uniform ? snapAngle(PagePoint(x: orig.x1, y: orig.y1), pt, tolDeg: 23) : pt
                out.x2 = p.x
                out.y2 = p.y
            }
            return out
        }

        let ob = geometryBox(orig)
        var l = ob.x
        var t = ob.y
        var r = ob.x + ob.width
        var b = ob.y + ob.height
        let name = handle.rawValue
        if name.contains("w") { l = pt.x }
        if name.contains("e") { r = pt.x }
        if name.contains("n") { t = pt.y }
        if name.contains("s") { b = pt.y }

        let isText = orig.type == .text
        if (uniform || isText) && handle.isCorner && ob.width > 0 && ob.height > 0 {
            let s = max(abs(r - l) / ob.width, abs(b - t) / ob.height, 0.05)
            if name.contains("w") { l = r - ob.width * s } else { r = l + ob.width * s }
            if name.contains("n") { t = b - ob.height * s } else { b = t + ob.height * s }
        }

        // A signed scale lets strokes mirror when dragged past the opposite edge.
        let sx = ob.width > 0 ? (r - l) / ob.width : 1
        let sy = ob.height > 0 ? (b - t) / ob.height : 1
        let mapX = { (x: Double) -> Double in ob.width > 0 ? l + (x - ob.x) * sx : x + (l - ob.x) }
        let mapY = { (y: Double) -> Double in ob.height > 0 ? t + (y - ob.y) * sy : y + (t - ob.y) }
        let nx = min(l, r)
        let ny = min(t, b)
        let nw = max(1, abs(r - l))
        let nh = max(1, abs(b - t))

        switch orig.type {
        case .rect, .cite:
            out.x = nx
            out.y = ny
            out.width = nw
            out.height = nh
        case .circle:
            out.x = nx + nw / 2
            out.y = ny + nh / 2
            out.radiusX = nw / 2
            out.radiusY = nh / 2
        case .pen, .highlighter:
            out.points = orig.points.map { PagePoint(x: mapX($0.x), y: mapY($0.y)) }
        case .text:
            out.x = nx
            out.y = ny
            out.fontSize = min(200, max(4, (orig.fontSize * abs(sx) * 10).rounded() / 10))
        default:
            break
        }
        return out
    }
}
