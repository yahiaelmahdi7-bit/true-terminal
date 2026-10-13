import Foundation

/// Minimal block-level Markdown: enough for Claude's reports. Inline formatting is left to
/// `AttributedString(markdown:)` at render time.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case code(String)
    case table([String])
    case list([Item])
    case paragraph(String)

    struct Item: Equatable { var marker: String; var text: String; var indent: Int }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var items: [Item] = []
        var table: [String] = []
        var lines = source.components(separatedBy: "\n")[...]

        func flush() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
        }

        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let l = lines.popFirst() {
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    code.append(l)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if t.isEmpty {
                flush()
            } else if t.hasPrefix("|") {
                if table.isEmpty { flush() }
                table.append(line)
            } else if let h = heading(t) {
                flush(); blocks.append(h)
            } else if let item = listItem(line) {
                if items.isEmpty { flush() }
                items.append(item)
            } else if !items.isEmpty, line.hasPrefix(" ") {
                items[items.count - 1].text += "\n" + t          // wrapped list-item text
            } else {
                if !items.isEmpty || !table.isEmpty { flush() }
                para.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ t: String) -> MarkdownBlock? {
        var n = 0
        for c in t { if c == "#" { n += 1 } else { break } }
        guard (1...6).contains(n), t.dropFirst(n).first == " " else { return nil }
        return .heading(level: n, text: t.dropFirst(n).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " }.count
        let t = line.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: /^([-*+])\s+(.*)$/) { return Item(marker: "•", text: String(m.2), indent: indent) }
        if let m = t.firstMatch(of: /^(\d+[.)])\s+(.*)$/) { return Item(marker: String(m.1), text: String(m.2), indent: indent) }
        return nil
    }
}
