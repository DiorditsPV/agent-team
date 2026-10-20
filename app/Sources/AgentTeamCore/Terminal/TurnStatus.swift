import Foundation

/// Строка хода Claude Code из панели: «✳ Shimmying… (2m 14s · ↓ 3.1k tokens · thinking with high effort)».
public struct TurnStatus: Equatable, Sendable {
    /// Что делает: глагол спиннера («Shimmying»).
    public var verb: String
    /// Время хода в секундах.
    public var seconds: Int
    /// Токены хода как на экране («3.1k»), если счётчик уже показан.
    public var tokens: String?
    /// Направление счётчика: «↓» (ответ) или «↑» (ввод).
    public var arrow: String?
    /// Пояснение («thinking with high effort»), без подсказки про Esc.
    public var note: String?

    public init(verb: String, seconds: Int, tokens: String? = nil, arrow: String? = nil, note: String? = nil) {
        self.verb = verb
        self.seconds = seconds
        self.tokens = tokens
        self.arrow = arrow
        self.note = note
    }

    /// «1 ч 2 мин», «2 мин 14 с», «45 с».
    public var elapsedText: String {
        if seconds >= 3600 { return "\(seconds / 3600) ч \(seconds % 3600 / 60) мин" }
        return seconds >= 60 ? "\(seconds / 60) мин \(seconds % 60) с" : "\(seconds) с"
    }

    /// Строка хода в панели; `nil`, если менеджер не работает (спиннера нет). Смотрит в хвост экрана над полем ввода.
    public static func from(_ lines: [StyledLine]) -> TurnStatus? {
        for l in PaneTail.content(lines).suffix(8).reversed() {
            if let s = parse(l.plain) { return s }
        }
        return nil
    }

    /// Время хода: «14s», «2m 14s», «1h 2m 3s».
    private static let line = ScreenMarks.regex(
        #"^\s*[^\p{L}\p{N}\s]\s+(\S+?)(?:…|\.\.\.)\s*\((?:(\d+)h\s*)?(?:(\d+)m\s*)?(\d+)s((?:\s*·\s*[^·)]+)*)\)"#)
    private static let counter = ScreenMarks.regex(#"^([↓↑])\s*([\d.,]+k?)\s*tokens?$"#)

    static func parse(_ plain: String) -> TurnStatus? {
        guard let g = ScreenMarks.groups(plain, line), let sec = Int(g[4]) else { return nil }
        var s = TurnStatus(verb: g[1], seconds: (Int(g[2]) ?? 0) * 3600 + (Int(g[3]) ?? 0) * 60 + sec)
        let parts = g[5].split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for p in parts {
            if let t = ScreenMarks.groups(p, counter) {
                s.arrow = t[1]
                s.tokens = t[2]
            } else if !p.localizedCaseInsensitiveContains("esc to interrupt") {
                s.note = p
            }
        }
        return s
    }
}
