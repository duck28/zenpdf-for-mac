import Foundation

// Citation numbering and formatting, ported from src/utils/citations.ts in ZenPDF for Windows.

enum Citations {
    /// Citations in reading order (page, then top to bottom, left to right).
    static func sorted(_ annotations: [Annotation]) -> [Annotation] {
        annotations
            .filter { $0.type == .cite }
            .sorted { a, b in
                if a.pageNumber != b.pageNumber { return a.pageNumber < b.pageNumber }
                if a.y != b.y { return a.y < b.y }
                return a.x < b.x
            }
    }

    /// Footnote numbers follow reading order across the whole document.
    static func numbers(_ annotations: [Annotation]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, c) in sorted(annotations).enumerated() { map[c.id] = i + 1 }
        return map
    }

    static func page(_ c: Annotation) -> String {
        let label = c.pageLabel?.trimmingCharacters(in: .whitespaces) ?? ""
        return label.isEmpty ? String(c.pageNumber) : label
    }

    // MARK: Text helpers

    private static func clean(_ s: String) -> String {
        replace(s.trimmingCharacters(in: .whitespacesAndNewlines), #"\s+"#, with: " ")
    }

    private static func stripEndDot(_ s: String) -> String {
        replace(s, #"[.\s]+$"#, with: "")
    }

    static func replace(_ s: String, _ pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return s
        }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func split(_ s: String, _ pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [s] }
        var parts: [String] = []
        var last = s.startIndex
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let range = Range(match.range, in: s) else { continue }
            parts.append(String(s[last..<range.lowerBound]))
            last = range.upperBound
        }
        parts.append(String(s[last...]))
        return parts
    }

    /// "Jane Doe; John Smith" or "Doe, Jane and Smith, John" → list of authors.
    private static func splitAuthors(_ author: String) -> [String] {
        split(author, #"\s*;\s*|\s+and\s+|\s*&\s*"#).map(clean).filter { !$0.isEmpty }
    }

    /// Returns (family, given).
    private static func nameParts(_ name: String) -> (String, String) {
        if name.contains(",") {
            // Like JavaScript's split(',', 2): anything after a second comma is dropped.
            let pieces = name.components(separatedBy: ",")
            return (clean(pieces[0]), clean(pieces[1]))
        }
        let parts = name.components(separatedBy: " ")
        if parts.count == 1 { return (parts[0], "") }
        return (parts[parts.count - 1], parts.dropLast().joined(separator: " "))
    }

    private static func initials(_ given: String) -> String {
        given.split(whereSeparator: { $0 == "-" || $0.isWhitespace })
            .compactMap { part -> String? in
                guard let letter = part.first else { return nil }
                return String(letter).uppercased() + "."
            }
            .joined(separator: " ")
    }

    private static func apaAuthors(_ authors: [String]) -> String {
        let fmt = authors.map { a -> String in
            let (family, given) = nameParts(a)
            return given.isEmpty ? family : "\(family), \(initials(given))"
        }
        if fmt.count <= 1 { return fmt.first ?? "" }
        return "\(fmt.dropLast().joined(separator: ", ")), & \(fmt[fmt.count - 1])"
    }

    /// "Smith, John" → "John Smith" (later authors are written in natural order).
    private static func naturalName(_ name: String) -> String {
        let (family, given) = nameParts(name)
        return given.isEmpty ? family : "\(given) \(family)"
    }

    private static func invertedFirst(_ name: String) -> String {
        let (family, given) = nameParts(name)
        return given.isEmpty ? family : "\(family), \(given)"
    }

    private static func mlaAuthors(_ authors: [String]) -> String {
        guard let firstAuthor = authors.first else { return "" }
        let first = invertedFirst(firstAuthor)
        if authors.count == 1 { return first }
        if authors.count == 2 { return "\(first), and \(naturalName(authors[1]))" }
        return "\(first), et al."
    }

    private static func chicagoAuthors(_ authors: [String]) -> String {
        guard let firstAuthor = authors.first else { return "" }
        let first = invertedFirst(firstAuthor)
        if authors.count == 1 { return first }
        let rest = authors.dropFirst().map(naturalName)
        return "\(first), \(rest.dropLast().map { "\($0), " }.joined())and \(rest[rest.count - 1])"
    }

    private static func shortAuthor(_ authors: [String], joiner: String) -> String {
        guard let firstAuthor = authors.first else { return "" }
        let family = nameParts(firstAuthor).0
        if authors.count == 1 { return family }
        if authors.count == 2 { return "\(family) \(joiner) \(nameParts(authors[1]).0)" }
        return "\(family) et al."
    }

    private static func pagePrefix(_ page: String) -> String {
        matches(page, "[-–,]") ? "pp." : "p."
    }

    // MARK: Formatting

    /// Full reference for the marked passage.
    static func format(_ style: CitationStyle, source src: DocumentSource, page: String) -> String {
        let authors = splitAuthors(src.author)
        let cleanedTitle = stripEndDot(clean(src.title))
        let title = cleanedTitle.isEmpty ? "Untitled document" : cleanedTitle
        let year = clean(src.year)
        let publisher = stripEndDot(clean(src.publisher))
        let url = clean(src.url)

        switch style {
        case .apa:
            let who = authors.isEmpty ? title : apaAuthors(authors)
            let parts = [
                "\(stripEndDot(who)). (\(year.isEmpty ? "n.d." : year)).",
                authors.isEmpty ? "" : "\(title).",
                publisher.isEmpty ? "" : "\(publisher).",
                url,
            ]
            return "\(parts.filter { !$0.isEmpty }.joined(separator: " ")) (\(pagePrefix(page)) \(page))"
        case .mla:
            let parts = [
                authors.isEmpty ? "" : "\(stripEndDot(mlaAuthors(authors))).",
                "\(title).",
                [publisher, year].filter { !$0.isEmpty }.joined(separator: ", "),
            ].filter { !$0.isEmpty }
            var s = parts.joined(separator: " ")
            s = "\(stripEndDot(s)), \(pagePrefix(page)) \(page)."
            if !url.isEmpty { s += " \(url)." }
            return s
        case .chicago:
            // Chicago notes-bibliography style footnote.
            let who = authors.isEmpty ? "" : "\(stripEndDot(chicagoAuthors(authors))), "
            let pub = [publisher, year].filter { !$0.isEmpty }.joined(separator: ", ")
            return "\(who)\(title)\(pub.isEmpty ? "" : " (\(pub))"), \(page).\(url.isEmpty ? "" : " \(url).")"
        case .bibtex:
            let keyAuthor = authors.isEmpty ? (title.components(separatedBy: " ").first ?? "") : nameParts(authors[0]).0
            let rawKey = replace("\(keyAuthor)\(year)", "[^A-Za-z0-9]", with: "").lowercased()
            let key = rawKey.isEmpty ? "source" : rawKey
            let pages: String
            if let range = page.range(of: "[–-]", options: .regularExpression) {
                pages = page.replacingCharacters(in: range, with: "--")
            } else {
                pages = page
            }
            let fields: [(String, String)] = [
                ("author", authors.joined(separator: " and ")),
                ("title", title),
                ("year", year),
                ("publisher", publisher),
                ("url", url),
                ("pages", pages),
            ]
            let body = fields.filter { !$0.1.isEmpty }.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
            return "@misc{\(key),\n\(body)\n}"
        }
    }

    /// Short in-text citation, such as (Doe, 2020, p. 4).
    static func inText(_ style: CitationStyle, source src: DocumentSource, page: String) -> String {
        let authors = splitAuthors(src.author)
        var who = shortAuthor(authors, joiner: style == .apa ? "&" : "and")
        if who.isEmpty {
            let t = stripEndDot(clean(src.title))
            who = "\"\(t.isEmpty ? "Untitled" : t)\""
        }
        let cleanedYear = clean(src.year)
        let year = cleanedYear.isEmpty ? "n.d." : cleanedYear
        switch style {
        case .mla: return "(\(who) \(page))"
        case .chicago: return "(\(who) \(year), \(page))"
        default: return "(\(who), \(year), \(pagePrefix(page)) \(page))"
        }
    }

    /// The quote of the marked passage followed by its in-text citation.
    static func quote(_ style: CitationStyle, source src: DocumentSource, citation c: Annotation) -> String {
        let quote = clean(c.quote)
        let cite = inText(style == .bibtex ? .apa : style, source: src, page: page(c))
        return quote.isEmpty ? cite : "“\(quote)” \(cite)"
    }

    static func matchesQuery(_ c: Annotation, query: String, number n: Int) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        let hay = "\(c.quote)\n\(c.note)\np. \(page(c))\n#\(n) [\(n)]".lowercased()
        return q.split(whereSeparator: { $0.isWhitespace }).allSatisfy { hay.contains($0) }
    }

    /// Cleans text captured from the page: rejoins hyphenated words and collapses whitespace.
    static func cleanCapturedText(_ text: String) -> String {
        var s = replace(text, #"-\n(?=\p{Ll})"#, with: "")
        s = replace(s, #"\s*\n\s*"#, with: " ")
        s = replace(s, #"\s{2,}"#, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses a PDF date or year text into a year.
    static func year(from date: Date?) -> String? {
        guard let date else { return nil }
        return String(Calendar(identifier: .gregorian).component(.year, from: date))
    }
}
