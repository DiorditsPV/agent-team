import Foundation

/// Служебное Claude Code, которое не нужно ни на панелях «Команды», ни на экране агента:
/// плашка «N new messages (click) ↓» и строка «Auto-update failed».
public enum PaneNoise {
    /// Строки с убранным служебным. Плашка вырезается отрезком (рядом бывает вывод), строка про автообновление
    /// — целиком вместе с хвостом, который перенесло на следующую строку. Замыкающие пробелы без фона срезаются:
    /// ими Claude Code выравнивает служебные строки вправо.
    public static func strip(_ lines: [StyledLine]) -> [StyledLine] {
        var out: [StyledLine] = []
        out.reserveCapacity(lines.count)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let plain = line.plain
            if plain.localizedCaseInsensitiveContains("Auto-update") && plain.localizedCaseInsensitiveContains("failed") {
                i += 1
                // Перенесённый хвост подсказки: «laude doctor» после «… · Run c».
                if i < lines.count {
                    let tail = lines[i].plain.trimmingCharacters(in: .whitespaces)
                    if !tail.isEmpty, updateHints.contains(where: { $0.hasSuffix(tail) }) { i += 1 }
                }
                continue
            }
            i += 1
            guard plain.contains("new message") else {
                out.append(trimTrailing(line))
                continue
            }
            let cleaned = trimTrailing(removePlaque(line))
            // Строка, состоявшая только из плашки, уходит целиком.
            if cleaned.isBlank, !line.isBlank { continue }
            out.append(cleaned)
        }
        return out
    }

    static let updateHints = ["Run claude doctor", "Try claude doctor or npm i -g @anthropic-ai/claude-code", "claude doctor"]

    static func removePlaque(_ line: StyledLine) -> StyledLine {
        var runs: [StyledRun] = []
        for var r in line.runs {
            if r.text.contains("new message") {
                r.text = r.text.replacingOccurrences(of: #"[\s⋯]*\d+ new messages? \(click\)[\s↓⬇]*"#, with: "", options: .regularExpression)
            }
            if !r.text.isEmpty { runs.append(r) }
        }
        return StyledLine(runs: runs)
    }

    static func trimTrailing(_ line: StyledLine) -> StyledLine {
        var runs = line.runs
        while let last = runs.last, last.style.bg == nil, !last.style.inverse {
            let trimmed = last.text.replacingOccurrences(of: #"[\s\x{a0}]+$"#, with: "", options: .regularExpression)
            if trimmed == last.text { break }
            if trimmed.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = trimmed; break }
        }
        return runs.count == line.runs.count && runs == line.runs ? line : StyledLine(runs: runs)
    }
}

/// Что показать в панели «Команды»: наверху — что агент делает сейчас, под ним — несколько строк его последнего текста.
public struct PaneDigest: Equatable, Sendable {
    public enum Kind: Sendable { case spinner, action }

    public var headline: StyledLine?
    public var headlineKind: Kind?
    /// Последнее сообщение команды, если оно свежее последнего текста агента: одна выделенная строка под заголовком.
    public var message: StyledLine?
    public var body: [StyledLine]

    public init(headline: StyledLine? = nil, headlineKind: Kind? = nil, message: StyledLine? = nil, body: [StyledLine] = []) {
        self.headline = headline
        self.headlineKind = headlineKind
        self.message = message
        self.body = body
    }

    /// Все строки сверху вниз, как их рисует панель.
    public var rows: [StyledLine] { (headline.map { [$0] } ?? []) + (message.map { [$0] } ?? []) + body }

    /// Дайджест из строк захвата. Новых захватов не требует: считается из того, что уже получено.
    public static func make(_ lines: [StyledLine], bodyLines: Int = 5, roster: TeamRoster = TeamRoster()) -> PaneDigest {
        var kept: [StyledLine] = []
        for l in PaneTail.content(lines) where !l.isBlank && !isNoise(l.plain) {
            kept.append(alignedLeft(l))
        }

        var headIndex: Int?
        var kind: Kind?
        if let i = kept.indices.reversed().prefix(8).first(where: { isSpinner(kept[$0].plain) }) {
            headIndex = i
            kind = .spinner
        } else if let i = kept.lastIndex(where: { isAction($0.plain) }) {
            headIndex = i
            kind = .action
        }

        let rest = kept.enumerated().filter { $0.offset != headIndex }.map(\.element)
        var body = lastTextBlock(kept, skipping: headIndex)
        if body.isEmpty { body = rest.filter { !isBullet($0.plain) || !isAction($0.plain) } }
        // Сообщение команды — отдельной строкой, если оно позже последнего текста агента; из текста оно убирается.
        let textStart = kept.indices.reversed().first { i in i != headIndex && isBullet(kept[i].plain) && !isAction(kept[i].plain) }
        var message: StyledLine?
        if let m = kept.lastIndex(where: { TeamMessages.isMessage($0.plain) }), m > (textStart ?? -1) {
            message = TeamMessages.decorate(kept[m], roster: roster)
        }
        body = body.filter { !TeamMessages.isMessage($0.plain) || message == nil }
        let room = message == nil ? bodyLines : max(1, bodyLines - 1)
        return PaneDigest(headline: headIndex.map { kept[$0] }, headlineKind: kind, message: message,
                          body: TeamMessages.decorate(Array(body.suffix(room)), roster: roster))
    }

    // MARK: распознавание

    static func isNoise(_ plain: String) -> Bool {
        let t = plain.trimmingCharacters(in: .whitespaces)
        if ScreenMarks.matches(t, tip) { return true }
        if t.contains("Compacted while idle") || t.contains("Conversation compacted") { return true }
        if t.contains("shift+tab to cycle") || t.hasPrefix("⏵⏵") || t.contains("? for shortcuts") { return true }
        if t.hasPrefix("["), t.contains("] "), t.contains(" ctx ") { return true }
        if ScreenMarks.isRule(t) { return true }
        return false
    }

    private static let tip = ScreenMarks.regex(#"^[^\p{L}\p{N}]*Tip:"#)
    private static let toolCall = ScreenMarks.regex(#"^\s*(⏺\s+)?[A-Z][A-Za-z]*\(.*\)?\s*$"#)
    private static let toolSummary = ScreenMarks.regex(#"^\s*(Ran|Read|Searched for|Edited|Wrote|Listed|Fetched|Updated) \d+ "#)

    /// «✻ Stewing… (2m 14s · ↓ 3.1k tokens · esc to interrupt)».
    static func isSpinner(_ plain: String) -> Bool { ScreenMarks.isTurnLine(plain) }

    /// Вызов инструмента: «⏺ Read(src/x)» или сводка «Ran 2 shell commands».
    static func isAction(_ plain: String) -> Bool {
        ScreenMarks.matches(plain, toolCall) && plain.contains("(") || ScreenMarks.matches(plain, toolSummary)
    }

    static func isBullet(_ plain: String) -> Bool { plain.trimmingCharacters(in: .whitespaces).hasPrefix("⏺") }

    static func isResult(_ plain: String) -> Bool {
        let t = plain.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("⎿") || t.hasPrefix("└")
    }

    /// Последний текст агента: от «⏺ слова» до следующего вызова инструмента или результата.
    static func lastTextBlock(_ kept: [StyledLine], skipping head: Int?) -> [StyledLine] {
        guard let start = kept.indices.reversed().first(where: { i in
            i != head && isBullet(kept[i].plain) && !isAction(kept[i].plain)
        }) else { return [] }
        var block: [StyledLine] = [dropBullet(kept[start])]
        var j = start + 1
        while j < kept.count {
            let p = kept[j].plain
            if j == head || isBullet(p) || isResult(p) || isAction(p) || isSpinner(p) || TeamMessages.isMessage(p) { break }
            block.append(dropIndent(kept[j], 2))
            j += 1
        }
        return block
    }

    // MARK: правка строк

    /// Выравнивание вправо пробелами («                    текст») — в панели прижимаем влево.
    static func alignedLeft(_ l: StyledLine) -> StyledLine {
        let lead = l.plain.prefix { $0 == " " }.count
        return lead >= 12 ? dropIndent(l, lead) : l
    }

    static func dropIndent(_ l: StyledLine, _ n: Int) -> StyledLine {
        var left = n
        var runs: [StyledRun] = []
        for var r in l.runs {
            if left > 0 {
                let spaces = r.text.prefix { $0 == " " }.count
                let cut = min(left, spaces)
                r.text.removeFirst(cut)
                left -= cut
                if cut < spaces || !r.text.isEmpty { left = 0 }
            }
            if !r.text.isEmpty { runs.append(r) }
        }
        return StyledLine(runs: runs)
    }

    static func dropBullet(_ l: StyledLine) -> StyledLine {
        var runs = dropIndent(l, 64).runs
        if let first = runs.first, first.text.hasPrefix("⏺") {
            var text = first.text
            text.removeFirst()
            text = String(text.drop { $0 == " " })
            if text.isEmpty { runs.removeFirst() } else { runs[0].text = text }
            if text.isEmpty, let next = runs.first { runs[0].text = String(next.text.drop { $0 == " " }) }
        }
        return StyledLine(runs: runs.filter { !$0.text.isEmpty })
    }
}
