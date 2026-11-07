import SwiftUI

/// Edits an open .txt or .md file. Markdown has an edit, split and preview view, like src/components/TextEditor.tsx.
struct TextDocumentView: View {
    @Bindable var model: DocumentModel
    @AppStorage("zenpdf.markdownMode") private var mode: Mode = .split

    enum Mode: String, CaseIterable, Identifiable {
        case edit, split, preview
        var id: Self { self }

        var label: String {
            switch self {
            case .edit: return "Edit"
            case .split: return "Split"
            case .preview: return "Preview"
            }
        }

        var symbol: String {
            switch self {
            case .edit: return "pencil"
            case .split: return "rectangle.split.2x1"
            case .preview: return "eye"
            }
        }
    }

    private var text: Binding<String> {
        Binding(get: { model.textContent ?? "" }, set: { model.textContent = $0 })
    }

    private var fontSize: CGFloat { 14 * CGFloat(model.zoom) }

    var body: some View {
        VStack(spacing: 0) {
            if model.isMarkdown {
                HStack(spacing: 2) {
                    ForEach(Mode.allCases) { m in
                        Button { mode = m } label: { Image(systemName: m.symbol) }
                            .buttonStyle(ZenIconButtonStyle(active: mode == m))
                            .help(m.label)
                    }
                }
                .padding(4)
                .glassSurface(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 10)
            }

            if model.isMarkdown && mode != .edit {
                HStack(spacing: 0) {
                    if mode == .split {
                        editor
                        Hairline(vertical: true).frame(maxHeight: .infinity)
                    }
                    ScrollView {
                        MarkdownView(source: model.textContent ?? "", fontSize: fontSize)
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(32)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                editor
            }
        }
        .background(Color.zenSurface)
        .id(model.documentID)
    }

    private var editor: some View {
        TextEditor(text: text)
            .font(.system(size: fontSize, design: model.isMarkdown ? .monospaced : .default))
            .foregroundStyle(Color.zenInk)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small Markdown renderer: headings, paragraphs, lists, quotes, code blocks and rules, with inline styles
/// (bold, italic, code, links) from Foundation's Markdown parser.
struct MarkdownView: View {
    let source: String
    let fontSize: CGFloat

    enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, indent: Int)
        case numbered(String, String, indent: Int)
        case quote(String)
        case code(String)
        case rule
    }

    /// "---", "***" or "___" (spaces allowed between).
    static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    static func blocks(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in source.components(separatedBy: .newlines) {
            if code != nil {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(raw)
                }
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            let indent = (raw.prefix { $0 == " " || $0 == "\t" }.count) / 2
            if line.hasPrefix("```") {
                flush()
                code = []
            } else if line.isEmpty {
                flush()
            } else if let match = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flush()
                blocks.append(.heading(match.1.count, String(match.2)))
            } else if isRule(line) {
                flush()
                blocks.append(.rule)
            } else if let match = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flush()
                blocks.append(.bullet(String(match.1), indent: indent))
            } else if let match = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush()
                blocks.append(.numbered(String(match.1), String(match.2), indent: indent))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
        return Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.7) {
            ForEach(Array(Self.blocks(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    inline(text)
                        .font(.system(size: fontSize * [2, 1.6, 1.3, 1.15, 1.05, 1][min(level, 6) - 1], weight: .semibold))
                        .padding(.top, fontSize * 0.4)
                case let .paragraph(text):
                    inline(text).font(.system(size: fontSize)).lineSpacing(fontSize * 0.25)
                case let .bullet(text, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        inline(text)
                    }
                    .font(.system(size: fontSize))
                    .padding(.leading, CGFloat(indent) * fontSize * 1.4)
                case let .numbered(number, text, indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(number).").monospacedDigit()
                        inline(text)
                    }
                    .font(.system(size: fontSize))
                    .padding(.leading, CGFloat(indent) * fontSize * 1.4)
                case let .quote(text):
                    inline(text)
                        .font(.system(size: fontSize))
                        .foregroundStyle(Color.zenInk2)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.zenLine).frame(width: 3) }
                case let .code(text):
                    Text(text)
                        .font(.system(size: fontSize * 0.9, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.zenRaised))
                case .rule:
                    Hairline()
                }
            }
        }
        .foregroundStyle(Color.zenInk)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
