import AppKit
import CoreText
import PDFKit

/// Draws render parts (AnnotationGeometry) into a CoreGraphics context whose coordinates are page units:
/// PDF points, origin at the top-left of the page, y pointing down.
enum PartsRenderer {
    static func cgPath(_ cmds: [PathCmd]) -> CGPath {
        let path = CGMutablePath()
        for cmd in cmds {
            switch cmd {
            case let .move(x, y): path.move(to: CGPoint(x: x, y: y))
            case let .line(x, y):
                if path.isEmpty { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            case let .quad(cx, cy, x, y):
                path.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: cx, y: cy))
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    enum Pass { case all, multiplyOnly, normalOnly }

    /// Draws `parts`. Highlights (multiply parts) blend with the page like ink, so draw them first.
    static func draw(_ parts: [RenderPart], in ctx: CGContext, pass: Pass = .all) {
        for part in parts {
            switch part {
            case let .path(cmds, stroke, fill, multiply):
                if pass == .multiplyOnly && !multiply { continue }
                if pass == .normalOnly && multiply { continue }
                let path = cgPath(cmds)
                ctx.saveGState()
                if multiply { ctx.setBlendMode(.multiply) }
                if let fill {
                    ctx.setAlpha(CGFloat(fill.opacity ?? 1))
                    ctx.setFillColor(ColorHex.cgColor(fill.color))
                    ctx.addPath(path)
                    ctx.fillPath()
                }
                if let stroke, stroke.width > 0 {
                    ctx.setAlpha(CGFloat(stroke.opacity ?? 1))
                    ctx.setStrokeColor(ColorHex.cgColor(stroke.color))
                    ctx.setLineWidth(CGFloat(stroke.width))
                    ctx.setLineCap(stroke.cap.cgLineCap)
                    ctx.setLineJoin(.round)
                    if let dash = stroke.dash, !dash.isEmpty {
                        ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
                    }
                    ctx.addPath(path)
                    ctx.strokePath()
                }
                ctx.restoreGState()
            case let .text(text, x, y, size, color, bold):
                if pass == .multiplyOnly || text.isEmpty { continue }
                let line = TextMeasure.line(text, size: size, bold: bold, color: ColorHex.cgColor(color))
                ctx.saveGState()
                // The context is y-down, so flip the glyphs back upright.
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        }
    }

    /// Everything ZenPDF draws on one page: the annotations, then the generated citation footnotes.
    static func pageParts(_ annotations: [Annotation], numbers: [String: Int], pageSize: CGSize) -> [RenderPart] {
        var parts = annotations.flatMap { AnnotationGeometry.parts(for: $0, citeNumbers: numbers) }
        let cites = annotations.filter { $0.type == .cite }
        if !cites.isEmpty {
            parts += AnnotationGeometry.footnoteParts(cites, numbers: numbers,
                                                      pageWidth: Double(pageSize.width), pageHeight: Double(pageSize.height))
        }
        return parts
    }

    /// Renders a page with its annotations to a PNG, `scale` pixels per point.
    static func pngData(page: PDFPage, annotations: [Annotation], numbers: [String: Int], scale: CGFloat = 2) -> Data? {
        let mapper = PageMapper(page: page)
        let size = mapper.viewSize
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = page.thumbnail(of: CGSize(width: CGFloat(width), height: CGFloat(height)), for: .cropBox)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let parts = pageParts(annotations, numbers: numbers, pageSize: size)
        draw(parts, in: ctx, pass: .multiplyOnly)
        draw(parts, in: ctx, pass: .normalOnly)

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
