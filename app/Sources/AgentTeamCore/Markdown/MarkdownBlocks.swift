import Foundation

/// Выравнивание колонки таблицы по строке-разделителю: `:---`, `:---:`, `---:`.
public enum MDAlignment: Sendable, Equatable {
    case none, left, center, right
}

public struct MDTable: Sendable, Equatable {
    public var header: [String]
    public var alignments: [MDAlignment]
    /// Строки тела дополнены или обрезаны до числа колонок шапки.
    public var rows: [[String]]

    public init(header: [String], alignments: [MDAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

public struct MDListItem: Sendable, Equatable {
    /// Маркер как в исходнике: `-`, `*`, `1.`, `2)`.
    public var marker: String
    /// `nil` — обычный пункт; `false` — `[ ]`; `true` — `[x]`.
    public var task: Bool?
    /// Первый абзац пункта, инлайн-разметка не разобрана.
    public var text: String
    /// Вложенное: списки, код, абзацы после первого.
    public var children: [MDBlock]

    public init(marker: String, task: Bool? = nil, text: String, children: [MDBlock] = []) {
        self.marker = marker
        self.task = task
        self.text = text
        self.children = children
    }
}

/// Блок ответа модели. Строки хранят инлайн-разметку как есть: её разбирает `MDInline`.
public enum MDBlock: Sendable, Equatable {
    case heading(level: Int, text: String)
    /// Строка целиком жирная («**Итог.**») — подзаголовок над следующим текстом.
    case lead(String)
    case paragraph(String)
    case list(ordered: Bool, items: [MDListItem])
    case quote([MDBlock])
    case rule
    case code(language: String?, text: String)
    case table(MDTable)
}

/// Разбор Markdown ответа на блоки. Что не распознано, остаётся абзацем с исходным текстом.
public enum MDParser {
    public static func parse(_ text: String) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { expandTabs(String($0)) }
        return blocks(lines, leadAllowed: true)
    }

    /// Разбор с кешем по тексту: лента перерисовывается часто, а сообщение не меняется.
    public static func cached(_ text: String) -> [MDBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Box(blocks), forKey: key, cost: text.utf16.count)
        return blocks
    }

    private final class Box {
        let blocks: [MDBlock]
        init(_ b: [MDBlock]) { blocks = b }
    }

    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 8_000_000
        return c
    }()

    // MARK: блоки

    static func blocks(_ lines: [String], leadAllowed: Bool) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        var i = 0

        func flush() {
            guard !para.isEmpty else { return }
            out.append(.paragraph(para.joined(separator: "\n")))
            para = []
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); i += 1; continue }

            if let f = fence(raw) {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if closesFence(lines[i], f) { i += 1; break }
                    body.append(dedent(lines[i], by: f.indent))
                    i += 1
                }
                out.append(.code(language: f.language, text: body.joined(separator: "\n")))
                continue
            }
            if let h = heading(line) {
                flush()
                out.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }
            if i + 1 < lines.count, let t = tableHead(line, delimiter: lines[i + 1]) {
                flush()
                var table = t
                i += 2
                while i < lines.count {
                    let r = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !r.isEmpty, hasPipe(r) else { break }
                    var cells = splitCells(r)
                    if cells.count < table.header.count {
                        cells += Array(repeating: "", count: table.header.count - cells.count)
                    }
                    table.rows.append(Array(cells.prefix(table.header.count)))
                    i += 1
                }
                out.append(.table(table))
                continue
            }
            if isRule(line) {
                flush()
                out.append(.rule)
                i += 1
                continue
            }
            if line.hasPrefix(">") {
                flush()
                var body: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    var rest = q.dropFirst()
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    body.append(String(rest))
                    i += 1
                }
                out.append(.quote(blocks(body, leadAllowed: true)))
                continue
            }
            if listMarker(raw) != nil {
                flush()
                out.append(list(lines, &i))
                continue
            }
            if leadAllowed, para.isEmpty, isWholeBold(line) {
                out.append(.lead(String(line.dropFirst(2).dropLast(2))))
                i += 1
                continue
            }
            para.append(line)
            i += 1
        }
        flush()
        return out
    }

    // MARK: списки

    struct Marker {
        var indent: Int
        var marker: String
        var ordered: Bool
        var contentOffset: Int
        var rest: String
    }

    static func listMarker(_ raw: String) -> Marker? {
        let indent = raw.prefix { $0 == " " }.count
        let s = raw.dropFirst(indent)
        guard let c = s.first else { return nil }
        var marker: Substring
        if "-*+•—".contains(c) {
            marker = s.prefix(1)
        } else if c.isASCII, c.isNumber {
            let digits = s.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9 else { return nil }
            let after = s.dropFirst(digits.count)
            guard let p = after.first, p == "." || p == ")" else { return nil }
            marker = s.prefix(digits.count + 1)
        } else {
            return nil
        }
        let after = s.dropFirst(marker.count)
        let spaces = after.prefix { $0 == " " }.count
        let rest = after.dropFirst(spaces)
        // Маркер без пробела после — не пункт («-1», «**жирное**»); пустой пункт допустим.
        guard spaces > 0 || after.isEmpty else { return nil }
        let pad = (spaces == 0 || spaces > 4) ? 1 : spaces
        let ordered = !"-*+•—".contains(c)
        return Marker(indent: indent, marker: String(marker), ordered: ordered,
                      contentOffset: indent + marker.count + pad, rest: String(rest))
    }

    private static func list(_ lines: [String], _ i: inout Int) -> MDBlock {
        let first = listMarker(lines[i])!
        var items: [MDListItem] = []
        while i < lines.count, let m = listMarker(lines[i]), m.ordered == first.ordered, m.indent <= first.indent + 1 {
            var body = [m.rest]
            i += 1
            while i < lines.count {
                let raw = lines[i]
                let line = raw.trimmingCharacters(in: .whitespaces)
                let indent = raw.prefix { $0 == " " }.count
                if line.isEmpty {
                    // Пустая строка внутри пункта, если дальше идёт его же отступ.
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    guard j < lines.count, lines[j].prefix(while: { $0 == " " }).count > m.indent,
                          listMarker(lines[j]).map({ $0.indent > m.indent }) ?? true else { break }
                    body.append("")
                    i += 1
                    continue
                }
                if indent > m.indent {
                    body.append(dedent(raw, by: min(indent, m.contentOffset)))
                    i += 1
                    continue
                }
                // Ленивое продолжение: строка без отступа сразу после текста пункта.
                if listMarker(raw) == nil, let last = body.last, !last.trimmingCharacters(in: .whitespaces).isEmpty,
                   !startsBlock(line), !(i + 1 < lines.count && tableHead(line, delimiter: lines[i + 1]) != nil) {
                    body.append(line)
                    i += 1
                    continue
                }
                break
            }
            var task: Bool?
            if let first = body.first {
                for (box, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where first == box || first.hasPrefix(box + " ") {
                    task = done
                    body[0] = String(first.dropFirst(box.count).drop { $0 == " " })
                    break
                }
            }
            var parsed = blocks(body, leadAllowed: false)
            var text = ""
            if case let .paragraph(t)? = parsed.first {
                text = t
                parsed.removeFirst()
            }
            items.append(MDListItem(marker: m.marker, task: task, text: text, children: parsed))
            // Пустые строки между пунктами одного списка.
            var j = i
            while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
            if j > i, j < lines.count, let n = listMarker(lines[j]), n.ordered == first.ordered, n.indent <= first.indent + 1 {
                i = j
            }
        }
        return .list(ordered: first.ordered, items: items)
    }

    // MARK: таблицы

    static func hasPipe(_ s: String) -> Bool {
        var prev: Character = " "
        for c in s {
            if c == "|", prev != "\\" { return true }
            prev = c
        }
        return false
    }

    /// Ячейки строки таблицы: ведущая и замыкающая черта необязательны, `\|` — черта внутри ячейки.
    static func splitCells(_ line: String) -> [String] {
        var s = Substring(line.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|") { s = s.dropLast() }
        var cells: [String] = []
        var cur = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\" {
                if let n = it.next() {
                    if n == "|" { cur.append("|") } else { cur.append(c); cur.append(n) }
                } else {
                    cur.append(c)
                }
            } else if c == "|" {
                cells.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(c)
            }
        }
        cells.append(cur.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func tableHead(_ line: String, delimiter: String) -> MDTable? {
        guard hasPipe(line) else { return nil }
        let d = delimiter.trimmingCharacters(in: .whitespaces)
        guard d.contains("-"), d.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let header = splitCells(line)
        let marks = splitCells(d)
        guard marks.count == header.count, hasPipe(d) || header.count > 1 else { return nil }
        var aligns: [MDAlignment] = []
        for m in marks {
            let core = m.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (m.hasPrefix(":"), m.hasSuffix(":")) {
            case (true, true): aligns.append(.center)
            case (true, false): aligns.append(.left)
            case (false, true): aligns.append(.right)
            default: aligns.append(.none)
            }
        }
        return MDTable(header: header, alignments: aligns, rows: [])
    }

    // MARK: прочие блоки

    struct Fence {
        var char: Character
        var count: Int
        var indent: Int
        var language: String?
    }

    static func fence(_ raw: String) -> Fence? {
        let indent = raw.prefix { $0 == " " }.count
        guard indent < 4 else { return nil }
        let s = raw.dropFirst(indent)
        guard let c = s.first, c == "`" || c == "~" else { return nil }
        let n = s.prefix { $0 == c }.count
        guard n >= 3 else { return nil }
        let info = s.dropFirst(n).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        let lang = info.split(separator: " ").first.map(String.init)
        return Fence(char: c, count: n, indent: indent, language: lang)
    }

    static func closesFence(_ raw: String, _ f: Fence) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let n = s.prefix { $0 == f.char }.count
        return n >= f.count && n == s.count
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let n = line.prefix { $0 == "#" }.count
        guard (1...6).contains(n) else { return nil }
        let rest = line.dropFirst(n)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Замыкающие решётки «## Итог ##» — не часть текста.
        if let r = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(r) }
        return (n, text)
    }

    static func isRule(_ line: String) -> Bool {
        guard let c = line.first, "-*_".contains(c) else { return false }
        let marks = line.filter { $0 != " " }
        return marks.count >= 3 && marks.allSatisfy { $0 == c }
    }

    static func isWholeBold(_ line: String) -> Bool {
        line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 && !line.dropFirst(2).dropLast(2).contains("**")
    }

    static func startsBlock(_ line: String) -> Bool {
        heading(line) != nil || fence(line) != nil || isRule(line) || line.hasPrefix(">")
    }

    static func dedent(_ raw: String, by n: Int) -> String {
        let spaces = min(n, raw.prefix { $0 == " " }.count)
        return String(raw.dropFirst(spaces))
    }

    static func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        for c in s {
            if c == "\t" {
                out += String(repeating: " ", count: 4 - out.count % 4)
            } else {
                out.append(c)
            }
        }
        return out
    }
}
