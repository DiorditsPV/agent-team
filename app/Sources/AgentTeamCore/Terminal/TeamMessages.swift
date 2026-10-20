import Foundation

/// Участники команды для подписей сообщений: роль, заголовок сессии, адрес и цвет роли.
public struct TeamRoster: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String        // «роль#n»
        public var role: String
        public var title: String?
        public var address: String?
        public var color: TermColor?

        public init(name: String, role: String, title: String? = nil, address: String? = nil, color: TermColor? = nil) {
            self.name = name
            self.role = role
            self.title = title
            self.address = address
            self.color = color
        }
    }

    public var entries: [Entry]
    public init(_ entries: [Entry] = []) { self.entries = entries }

    /// Подпись отправителя в строке «› Message from @<имя>»: Claude Code показывает заголовок сессии, длинный —
    /// с многоточием («Разработчик-приложен…»). Сравнение без регистра, дефис и подчёркивание — как пробел.
    public func entry(displayName: String) -> Entry? {
        let want = Self.normalize(displayName)
        guard !want.isEmpty else { return nil }
        return entries.first { e in
            [e.title, e.role, e.name].compactMap { $0 }.map(Self.normalize).contains { $0 == want || $0.hasPrefix(want) }
        }
    }

    public func entry(address: String) -> Entry? {
        entries.first { $0.address == address }
    }

    static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("…") || t.hasSuffix("...") { t = String(t.dropLast(t.hasSuffix("…") ? 1 : 3)) }
        let spaced = t.lowercased().map { "-_".contains($0) ? " " : $0 }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }
}

/// Сообщение между членами команды в выводе Claude Code.
public enum TeamMessage: Equatable, Sendable {
    /// «› Message from @<имя>: текст (ctrl+o to expand)».
    case incoming(from: String, text: String)
    /// Результат вызова SendMessage: «⎿ “краткое содержание” → <адрес>».
    case outgoing(to: String, summary: String)
}

public enum TeamMessages {
    /// Распознавание одной строки вывода (без стилей).
    public static func parse(_ plain: String) -> TeamMessage? {
        let line = plain.trimmingCharacters(in: .whitespaces)
        if let m = ScreenMarks.groups(line, incoming) {
            var text = m[2].trimmingCharacters(in: .whitespaces)
            if let r = text.range(of: #"\s*\(ctrl\+o to expand\)\s*$"#, options: .regularExpression) { text.removeSubrange(r) }
            return .incoming(from: m[1], text: text)
        }
        if let m = ScreenMarks.groups(line, outgoing) {
            return .outgoing(to: m[2], summary: m[1])
        }
        return nil
    }

    public static func isMessage(_ plain: String) -> Bool { parse(plain) != nil }

    // Проверяются на каждой строке хвоста панели при каждой перерисовке карточки.
    private static let incoming = ScreenMarks.regex(#"^[›>]\s*Message from @(.+?):\s+(.*)$"#)
    private static let outgoing = ScreenMarks.regex(#"^⎿\s+[“"](.+)[”"]\s+→\s+(\S+)$"#)

    /// Строка сообщения для показа: полоса цвета роли слева, направление («←» от кого, «→» кому) и имя жирным,
    /// текст с лёгкой подложкой того же цвета. Основной цвет текста остаётся цветом темы — читается в любой теме.
    public static func decorate(_ line: StyledLine, roster: TeamRoster) -> StyledLine {
        guard let message = parse(line.plain) else { return line }
        let arrow: String, label: String, text: String
        let entry: TeamRoster.Entry?
        switch message {
        case let .incoming(from, t):
            entry = roster.entry(displayName: from)
            arrow = "←"
            label = entry?.name ?? from
            text = t
        case let .outgoing(to, s):
            entry = roster.entry(address: to)
            arrow = "→"
            label = entry?.name ?? shortAddress(to)
            text = s
        }
        let color = entry?.color ?? .indexed(8)
        var stripe = TermStyle()
        stripe.fg = color
        stripe.bold = true
        var tint = TermStyle()
        tint.bg = color
        tint.soft = true
        var name = tint
        name.bold = true
        return StyledLine(runs: [
            StyledRun(text: "▌", style: stripe),
            StyledRun(text: " \(arrow) ", style: name),
            StyledRun(text: label, style: name),
            StyledRun(text: "  " + text, style: tint),
        ])
    }

    public static func decorate(_ lines: [StyledLine], roster: TeamRoster) -> [StyledLine] {
        lines.map { decorate($0, roster: roster) }
    }

    /// Адрес сокета без каталога: «uds:/tmp/cc-socks/61266.sock» → «61266».
    static func shortAddress(_ a: String) -> String {
        let file = (a as NSString).lastPathComponent
        return file.hasSuffix(".sock") ? String(file.dropLast(5)) : file
    }
}
