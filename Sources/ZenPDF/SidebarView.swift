import AppKit
import SwiftUI

/// Files in the open folder, page thumbnails and the list of annotations, like the Windows sidebar.
struct SidebarView: View {
    @Bindable var model: DocumentModel
    @State private var tab: Tab = .files
    @State private var filter = ""

    enum Tab: Hashable { case files, pages, notes }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Files").tag(Tab.files)
                Text("Pages").tag(Tab.pages)
                Text(model.annotations.isEmpty ? "Notes" : "Notes \(model.annotations.count)").tag(Tab.notes)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            switch tab {
            case .files: files
            case .pages: pages
            case .notes: notes
            }
        }
        .background(Color.zenSurface)
    }

    // MARK: Files

    @ViewBuilder private var files: some View {
        if let folder = model.folderURL {
            HStack(spacing: 4) {
                Text(folder.lastPathComponent.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.2)
                    .foregroundStyle(Color.zenInk3)
                    .lineLimit(1)
                    .help(folder.path)
                Spacer()
                Button { model.refreshFolder() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(ZenIconButtonStyle(width: 24)).help("Refresh")
                Button { model.showOpenFolderPanel() } label: { Image(systemName: "folder") }
                    .buttonStyle(ZenIconButtonStyle(width: 24)).help("Change folder")
            }
            .padding(.horizontal, 12)

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            let entries = filtered(model.folderTree)
            if entries.isEmpty {
                Text(filter.isEmpty ? "No documents in this folder." : "Nothing matches.")
                    .font(.system(size: 12)).foregroundStyle(Color.zenInk3)
                    .frame(maxWidth: .infinity).padding(16)
                Spacer()
            } else {
                List(entries, children: \.children) { entry in
                    FileRow(entry: entry, isCurrent: entry.url.standardizedFileURL == model.fileURL?.standardizedFileURL)
                        .contentShape(Rectangle())
                        .onTapGesture { if !entry.isDirectory { model.open(entry.url) } }
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        } else {
            VStack(spacing: 12) {
                Text("Open a folder to browse its documents.")
                    .font(.system(size: 12)).foregroundStyle(Color.zenInk3)
                    .multilineTextAlignment(.center)
                Button { model.showOpenFolderPanel() } label: { Label("Open Folder", systemImage: "folder") }
                    .buttonStyle(ZenButtonStyle())
            }
            .padding(20)
            Spacer()
        }
    }

    /// Files whose name contains the filter, with the folders leading to them.
    private func filtered(_ entries: [FileEntry]) -> [FileEntry] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.compactMap { entry in
            if entry.isDirectory {
                let children = filtered(entry.children ?? [])
                if children.isEmpty { return nil }
                var copy = entry
                copy.children = children
                return copy
            }
            return entry.name.localizedCaseInsensitiveContains(query) ? entry : nil
        }
    }

    // MARK: Pages

    @ViewBuilder private var pages: some View {
        if model.isPDF {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(1...max(1, model.pageCount), id: \.self) { number in
                            PageThumbnail(model: model, number: number)
                                .id(number)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: model.currentPage) { _, page in
                    withAnimation { proxy.scrollTo(page, anchor: .center) }
                }
            }
        } else {
            Text("No document open.").font(.system(size: 12)).foregroundStyle(Color.zenInk3).padding(16)
            Spacer()
        }
    }

    // MARK: Notes

    @ViewBuilder private var notes: some View {
        if model.annotations.isEmpty {
            Text(model.isPDF ? "No annotations yet." : "No document open.")
                .font(.system(size: 12)).foregroundStyle(Color.zenInk3).padding(16)
            Spacer()
        } else {
            List {
                ForEach(groupedByPage, id: \.page) { group in
                    Section("Page \(group.page)") {
                        ForEach(group.annotations) { annotation in
                            NoteRow(annotation: annotation, isSelected: annotation.id == model.selectedID,
                                    onDelete: { model.delete([annotation.id]) })
                                .contentShape(Rectangle())
                                .onTapGesture { model.reveal(annotation) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var groupedByPage: [(page: Int, annotations: [Annotation])] {
        Dictionary(grouping: model.annotations, by: \.pageNumber)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let isCurrent: Bool

    private var symbol: String {
        if entry.isDirectory { return "folder" }
        switch FileKind(url: entry.url) {
        case .pdf: return "doc.richtext"
        case .markdown: return "doc.plaintext"
        default: return "doc.text"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.zenInk3).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 12)).foregroundStyle(Color.zenInk).lineLimit(1).truncationMode(.middle)
                if !entry.isDirectory {
                    Text(details).font(.system(size: 10)).foregroundStyle(Color.zenInk3)
                }
            }
            Spacer(minLength: 4)
            if isCurrent { AccentDot() }
        }
        .padding(.vertical, 2)
        .help(entry.url.path)
    }

    private var details: String {
        var parts = [ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)]
        if let modified = entry.modified { parts.append(modified.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

private struct PageThumbnail: View {
    let model: DocumentModel
    let number: Int

    var body: some View {
        let isCurrent = model.currentPage == number
        Button { model.jumpRequest = number } label: {
            VStack(spacing: 6) {
                Group {
                    if let image = model.thumbnail(page: number) {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        Rectangle().fill(Color.white).aspectRatio(0.75, contentMode: .fit)
                    }
                }
                .background(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(isCurrent ? Color.zenAccent : Color.zenLine,
                                                                        lineWidth: isCurrent ? 2 : 1))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                Text("\(number)").font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.zenInk : Color.zenInk3)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 150)
    }
}

private struct NoteRow: View {
    let annotation: Annotation
    let isSelected: Bool
    let onDelete: () -> Void
    @State private var isHovered = false

    private var summary: String {
        switch annotation.type {
        case .text: return annotation.text
        case .cite: return annotation.quote.isEmpty ? annotation.note : "“\(annotation.quote)”"
        case .measure: return formatMeasurement(hypot(annotation.x2 - annotation.x1, annotation.y2 - annotation.y1), annotation.unit)
        default: return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(cssHex: annotation.displayColor)).frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(Color.zenLine, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(annotation.type.label).font(.system(size: 12)).foregroundStyle(Color.zenInk)
                if !summary.isEmpty {
                    Text(summary).font(.system(size: 11)).foregroundStyle(Color.zenInk3).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(ZenIconButtonStyle(width: 22))
                .opacity(isHovered || isSelected ? 1 : 0)
                .help("Delete")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.zenRaised : .clear))
        .onHover { isHovered = $0 }
    }
}
