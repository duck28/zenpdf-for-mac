import SwiftUI

/// The floating tool dock above the page, like the one in ZenPDF for Windows (src/components/Toolbar.tsx).
struct ToolDock: View {
    @Bindable var model: DocumentModel
    @State private var showsColors = false
    @State private var showsPens = false
    @State private var showsShapes = false

    private static let shapes: [(tool: ToolType, symbol: String, label: String)] = [
        (.rect, "square", "Rectangle (R)"),
        (.circle, "circle", "Ellipse (O)"),
        (.line, "line.diagonal", "Line (L)"),
        (.arrow, "arrow.up.right", "Arrow (A)"),
    ]

    private var shapeTool: (tool: ToolType, symbol: String, label: String) {
        Self.shapes.first { $0.tool == model.activeTool } ?? Self.shapes[0]
    }

    var body: some View {
        HStack(spacing: 2) {
            tool(.select, "cursorarrow", "Select, move and resize (V). Double-click text to edit.")
            tool(.highlighter, "highlighter", "Highlighter (H). Hold still to straighten.")
            penButton
            tool(.text, "textformat", "Text (T)")
            shapeButton
            tool(.measure, "ruler", "Ruler (M). Shift snaps to 45°.")
            tool(.cite, "quote.opening", "Citation (C). Mark a paragraph to add a footnote.")
            tool(.eraser, "eraser", "Eraser (E). Click or drag.")

            if model.activeTool != .select && model.activeTool != .eraser {
                Hairline(vertical: true).padding(.horizontal, 4)
                colorButton
                if let spec = WidthSpec.forTool(model.activeTool) { widthControl(spec) }
                if model.activeTool == .measure { unitPicker }
            }

            Hairline(vertical: true).padding(.horizontal, 4)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(ZenIconButtonStyle())
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(ZenIconButtonStyle())
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func tool(_ tool: ToolType, _ symbol: String, _ help: String) -> some View {
        Button { model.activeTool = tool } label: { Image(systemName: symbol) }
            .buttonStyle(ZenIconButtonStyle(active: model.activeTool == tool))
            .help(help)
    }

    private var penButton: some View {
        HStack(spacing: 0) {
            Button { model.activeTool = .pen } label: { Image(systemName: model.penType.symbol) }
                .buttonStyle(ZenIconButtonStyle(active: model.activeTool == .pen))
                .help("Pen (P): \(model.penType.label). Hold still to straighten.")
            Button { showsPens.toggle() } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
                .buttonStyle(ZenIconButtonStyle(width: 14))
                .help("Pen type")
                .popover(isPresented: $showsPens, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(PenType.allCases) { pen in
                            Button {
                                model.penType = pen
                                model.activeTool = .pen
                                showsPens = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: pen.symbol).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pen.label).foregroundStyle(Color.zenInk)
                                        Text(pen.hint).font(.system(size: 11)).foregroundStyle(Color.zenInk3)
                                    }
                                    Spacer(minLength: 8)
                                    if pen == model.penType { AccentDot() }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .frame(width: 240)
                }
        }
    }

    private var shapeButton: some View {
        HStack(spacing: 0) {
            Button { model.activeTool = shapeTool.tool } label: { Image(systemName: shapeTool.symbol) }
                .buttonStyle(ZenIconButtonStyle(active: [.rect, .circle, .line, .arrow].contains(model.activeTool)))
                .help(shapeTool.label)
            Button { showsShapes.toggle() } label: { Image(systemName: "chevron.down").font(.system(size: 8)) }
                .buttonStyle(ZenIconButtonStyle(width: 14))
                .help("Shapes")
                .popover(isPresented: $showsShapes, arrowEdge: .bottom) {
                    HStack(spacing: 2) {
                        ForEach(Self.shapes, id: \.tool) { shape in
                            Button {
                                model.activeTool = shape.tool
                                showsShapes = false
                            } label: { Image(systemName: shape.symbol) }
                                .buttonStyle(ZenIconButtonStyle(active: model.activeTool == shape.tool))
                                .help(shape.label)
                        }
                    }
                    .padding(6)
                }
        }
    }

    private var colorButton: some View {
        Button { showsColors.toggle() } label: {
            Circle()
                .fill(Color(cssHex: model.activeColor))
                .overlay(Circle().strokeBorder(Color.zenLine, lineWidth: 1))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(ZenIconButtonStyle())
        .help("Color")
        .popover(isPresented: $showsColors, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 4), spacing: 8) {
                    ForEach(presetColors, id: \.hex) { color in
                        Button {
                            model.activeColor = color.hex
                            showsColors = false
                        } label: {
                            Circle()
                                .fill(Color(cssHex: color.hex))
                                .overlay(Circle().strokeBorder(Color.zenLine, lineWidth: 1))
                                .overlay(Circle().strokeBorder(Color.zenAccent, lineWidth: 2).padding(-3)
                                    .opacity(model.activeColor.lowercased() == color.hex ? 1 : 0))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help(color.name)
                    }
                }
                ColorPicker("Custom color", selection: Binding(
                    get: { Color(cssHex: model.activeColor) },
                    set: { model.activeColor = NSColor($0).cssHex }
                ))
                .font(.system(size: 12))
                .foregroundStyle(Color.zenInk2)
            }
            .padding(12)
        }
    }

    private func widthControl(_ spec: WidthSpec) -> some View {
        HStack(spacing: 6) {
            Slider(value: Binding(
                get: { min(spec.max, max(spec.min, model.strokeWidth)) },
                set: { model.strokeWidth = ($0 / spec.step).rounded() * spec.step }
            ), in: spec.min...spec.max)
            .controlSize(.small)
            .frame(width: 84)
            Text(model.strokeWidth.formatted(.number.precision(.fractionLength(0...1))))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.zenInk2)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .help("\(spec.label) (\(spec.min.formatted())–\(spec.max.formatted()) \(spec.unit))")
    }

    private var unitPicker: some View {
        Picker("Unit", selection: $model.measureUnit) {
            ForEach(MeasureUnit.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 96)
        .help("Measurement unit")
    }
}
