import AppKit
import SwiftUI

/// The citations of the document with their footnotes and references, like src/components/CitationPanel.tsx.
struct CitationPanel: View {
    @Bindable var model: DocumentModel
    @State private var query = ""
    @State private var showsSource = false

    private var numbers: [String: Int] { model.citationNumbers }

    private var filtered: [Annotation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = model.citations
        guard !q.isEmpty else { return all }
        return all.filter { Citations.matchesQuery($0, query: q, number: numbers[$0.id] ?? 0) }
    }

    private var sourceMissing: Bool {
        model.source.author.trimmingCharacters(in: .whitespaces).isEmpty
            || model.source.year.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Citations").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.zenInk)
                Spacer()
                Picker("Citation style", selection: $model.citationStyle) {
                    ForEach(CitationStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 100)
                .help("Citation style")
            }
            .padding(12)

            TextField("Search quotes, footnotes, pages…", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            sourceSection
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if model.citations.isEmpty {
                            Text("Drag a box over a paragraph to mark it. Its text is captured automatically and a numbered footnote is added to the page.")
                                .font(.system(size: 12)).foregroundStyle(Color.zenInk3)
                                .padding(12)
                        } else if filtered.isEmpty {
                            Text("No citations match.").font(.system(size: 12)).foregroundStyle(Color.zenInk3).padding(12)
                        }
                        ForEach(filtered) { citation in
                            CitationRow(model: model, citation: citation, number: numbers[citation.id] ?? 0,
                                        isSelected: citation.id == model.selectedID)
                                .id(citation.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selectedID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }

            if !model.citations.isEmpty {
                Divider()
                HStack {
                    Text("\(filtered.count) of \(model.citations.count) shown")
                        .font(.system(size: 11)).foregroundStyle(Color.zenInk3)
                    Spacer()
                    Button("Copy all footnotes") { copyToPasteboard(allFootnotes) }
                        .buttonStyle(ZenButtonStyle())
                        .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(Color.zenSurface)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { showsSource.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showsSource ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text("Source document").font(.system(size: 12, weight: .medium))
                    if sourceMissing { AccentDot().help("Author or year missing") }
                    Spacer()
                }
                .foregroundStyle(Color.zenInk2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsSource {
                sourceField("Author(s), e.g. Doe, Jane; Smith, John", \.author)
                sourceField("Title", \.title)
                sourceField("Year", \.year)
                sourceField("Publisher / journal", \.publisher)
                sourceField("URL or DOI", \.url)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func sourceField(_ placeholder: String, _ key: WritableKeyPath<DocumentSource, String>) -> some View {
        TextField(placeholder, text: Binding(get: { model.source[keyPath: key] }, set: { model.source[keyPath: key] = $0 }))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
    }

    private var allFootnotes: String {
        let style: CitationStyle = model.citationStyle == .bibtex ? .chicago : model.citationStyle
        return model.citations.map { c in
            let note = c.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let reference = Citations.format(style, source: model.source, page: Citations.page(c))
            return "\(numbers[c.id] ?? 0). \(reference)\(note.isEmpty ? "" : " \(note)")"
        }.joined(separator: "\n")
    }
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct CitationRow: View {
    @Bindable var model: DocumentModel
    let citation: Annotation
    let number: Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Circle().fill(Color(cssHex: citation.color)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(citation.quote.isEmpty ? "No text captured" : "“\(citation.quote)”")
                        .font(.system(size: 12))
                        .foregroundStyle(citation.quote.isEmpty ? Color.zenInk3 : Color.zenInk)
                        .lineLimit(isSelected ? nil : 3)
                    if !isSelected && !citation.note.isEmpty {
                        Text(citation.note).font(.system(size: 11)).foregroundStyle(Color.zenInk2).lineLimit(2)
                    }
                    Text("Page \(Citations.page(citation))").font(.system(size: 10)).foregroundStyle(Color.zenInk3)
                }
            }

            if isSelected { editor }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.zenRaised : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.zenLine : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(citation) }
    }

    @ViewBuilder private var editor: some View {
        let reference = Citations.format(model.citationStyle, source: model.source, page: Citations.page(citation))
        VStack(alignment: .leading, spacing: 8) {
            field("Footnote") {
                CommitField(text: citation.note, placeholder: "Footnote text printed at the bottom of the page…", multiline: true) {
                    var c = citation
                    c.note = $0
                    model.update(c)
                }
            }
            field("Quoted text") {
                CommitField(text: citation.quote, placeholder: "", multiline: true) {
                    var c = citation
                    c.quote = $0
                    model.update(c)
                }
            }
            field("Page label") {
                CommitField(text: citation.pageLabel ?? "", placeholder: "\(citation.pageNumber)", multiline: false) {
                    var c = citation
                    let label = $0.trimmingCharacters(in: .whitespaces)
                    c.pageLabel = label.isEmpty ? nil : label
                    model.update(c)
                }
            }
            field("\(model.citationStyle.label) reference") {
                Text(reference)
                    .font(.system(size: 11, design: model.citationStyle == .bibtex ? .monospaced : .default))
                    .foregroundStyle(Color.zenInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.zenSurface))
                if model.citationStyle != .bibtex {
                    Text("In text: \(Citations.inText(model.citationStyle, source: model.source, page: Citations.page(citation)))")
                        .font(.system(size: 10)).foregroundStyle(Color.zenInk3)
                }
            }
            HStack(spacing: 4) {
                Button("Copy reference") { copyToPasteboard(reference) }.buttonStyle(ZenButtonStyle(prominent: true))
                Button("Copy quote") { copyToPasteboard(Citations.quote(model.citationStyle, source: model.source, citation: citation)) }
                    .buttonStyle(ZenButtonStyle())
                Spacer()
                Button { model.delete([citation.id]) } label: { Image(systemName: "trash") }
                    .buttonStyle(ZenIconButtonStyle())
                    .help("Delete citation")
            }
            .controlSize(.small)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .medium)).tracking(0.8).foregroundStyle(Color.zenInk3)
            content()
        }
    }
}

/// A text field that reports its value when editing ends, so typing doesn't add an undo step per key.
struct CommitField: View {
    let text: String
    let placeholder: String
    let multiline: Bool
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if multiline {
                TextField(placeholder, text: $draft, axis: .vertical).lineLimit(2...8)
            } else {
                TextField(placeholder, text: $draft)
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .focused($focused)
        .onAppear { draft = text }
        .onChange(of: text) { _, value in if !focused { draft = value } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onSubmit(commit)
        .onDisappear(perform: commit)
    }

    private func commit() {
        if draft != text { onCommit(draft) }
    }
}
