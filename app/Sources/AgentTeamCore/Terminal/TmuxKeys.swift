import Foundation

public struct KeyMods: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyMods(rawValue: 1)
    public static let control = KeyMods(rawValue: 2)
    public static let option = KeyMods(rawValue: 4)
}

/// Служебные клавиши, которые приложение переводит в имена клавиш tmux (`send-keys`).
public enum SpecialKey: Sendable {
    case enter, escape, tab, backspace, deleteForward, up, down, left, right, home, end, pageUp, pageDown
}

/// Перевод нажатий в клавиши tmux. Что tmux получает, то и Claude Code видит как с клавиатуры терминала.
public enum TmuxKeys {
    /// Клавиши для `send-keys`; `nil` — сочетание не передаётся. Shift+Enter в терминалах без расширенных клавиш —
    /// «\» и Enter: так Claude Code переносит строку.
    public static func keys(_ k: SpecialKey, _ m: KeyMods = []) -> [String]? {
        switch k {
        case .enter: return m.contains(.shift) || m.contains(.option) ? ["\\", "Enter"] : ["Enter"]
        case .escape: return ["Escape"]
        case .tab: return m.contains(.shift) ? ["BTab"] : ["Tab"]
        case .backspace: return [m.contains(.option) ? "M-BSpace" : "BSpace"]
        case .deleteForward: return ["DC"]
        case .up: return [prefix(m) + "Up"]
        case .down: return [prefix(m) + "Down"]
        case .left: return [prefix(m) + "Left"]
        case .right: return [prefix(m) + "Right"]
        case .home: return ["Home"]
        case .end: return ["End"]
        case .pageUp: return ["PageUp"]
        case .pageDown: return ["PageDown"]
        }
    }

    private static func prefix(_ m: KeyMods) -> String {
        if m.contains(.option) { return "M-" }
        if m.contains(.control) { return "C-" }
        if m.contains(.shift) { return "S-" }
        return ""
    }

    /// Ctrl+буква: «C-a»…«C-z». Остальные символы с Ctrl не передаются.
    public static func control(_ ch: Character) -> String? {
        guard let a = ch.lowercased().first, ("a"..."z").contains(a) else { return nil }
        return "C-\(a)"
    }

    /// Ctrl+буква по нажатию: латинская буква раскладки (так Ctrl+C на Dvorak — это «C» Dvorak), а нелатинская буква
    /// (кириллица, греческий) — буква той же клавиши в ANSI-раскладке. На русской Ctrl+C даёт «с», и без клавиши
    /// сочетание терялось. Знак препинания на месте ANSI-буквы (Ctrl+, на AZERTY, Ctrl+; на Dvorak) не передаётся:
    /// иначе он ушёл бы управляющим кодом, Ctrl+, — как C-m, то есть Enter.
    public static func control(characters: String?, keyCode: UInt16) -> String? {
        guard let ch = characters?.first else { return nil }
        if let k = control(ch) { return k }
        guard ch.isLetter else { return nil }
        return ansiLetters[keyCode].map { "C-\($0)" }
    }

    /// Буквы клавиш ANSI-раскладки по `keyCode` (kVK_ANSI_A…kVK_ANSI_Z): номер клавиши не зависит от раскладки.
    static let ansiLetters: [UInt16: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l", 46: "m",
        45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
    ]
}
