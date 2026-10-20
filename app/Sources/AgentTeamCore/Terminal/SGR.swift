import Foundation

/// Цвет терминала: индекс палитры 0–255 или RGB.
public enum TermColor: Equatable, Hashable, Sendable {
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TermStyle: Equatable, Hashable, Sendable {
    public var fg: TermColor?
    public var bg: TermColor?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false
    public var inverse = false
    /// Лёгкая подложка: фон рисуется бледным тоном (выделение сообщений команды), текст остаётся цветом темы.
    public var soft = false
    public init() {}
}

public struct StyledRun: Equatable, Sendable {
    public var text: String
    public var style: TermStyle
    public init(text: String, style: TermStyle) {
        self.text = text
        self.style = style
    }
}

/// Строка вывода панели как последовательность отрезков со стилем.
public struct StyledLine: Equatable, Sendable {
    public var runs: [StyledRun]
    public var plain: String { runs.map(\.text).joined() }
    public var isBlank: Bool { plain.allSatisfy { $0 == " " || $0 == "\u{a0}" } }
    public init(runs: [StyledRun]) { self.runs = runs }
}

/// Разбор ANSI SGR (`ESC[…m`) из `capture-pane -e`. Прочие последовательности отбрасываются:
/// capture-pane выдаёт готовый экран, курсорных команд в нём нет.
public enum SGRParser {
    public static func parse(_ text: String) -> [StyledLine] {
        var style = TermStyle()
        var lines: [StyledLine] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var runs: [StyledRun] = []
            var current = ""
            let scalars = Array(raw.unicodeScalars)
            var i = 0
            func flush() {
                if !current.isEmpty {
                    if let last = runs.last, last.style == style {
                        runs[runs.count - 1].text += current
                    } else {
                        runs.append(StyledRun(text: current, style: style))
                    }
                    current = ""
                }
            }
            while i < scalars.count {
                let c = scalars[i]
                if c == "\u{1B}" {
                    if i + 1 < scalars.count, scalars[i + 1] == "[" {
                        var j = i + 2
                        var params = ""
                        while j < scalars.count, !(0x40...0x7E).contains(scalars[j].value) {
                            params.unicodeScalars.append(scalars[j])
                            j += 1
                        }
                        if j < scalars.count, scalars[j] == "m" {
                            flush()
                            apply(params, to: &style)
                        }
                        i = j + 1
                        continue
                    }
                    if i + 1 < scalars.count, scalars[i + 1] == "]" {
                        // OSC до BEL или ESC \
                        var j = i + 2
                        while j < scalars.count, scalars[j] != "\u{07}" {
                            if scalars[j] == "\u{1B}", j + 1 < scalars.count, scalars[j + 1] == "\\" { j += 1; break }
                            j += 1
                        }
                        i = j + 1
                        continue
                    }
                    i += 2
                    continue
                }
                if c == "\r" || (c.value < 0x20 && c != "\t") {
                    i += 1
                    continue
                }
                current.unicodeScalars.append(c)
                i += 1
            }
            flush()
            lines.append(StyledLine(runs: runs))
        }
        return lines
    }

    static func apply(_ params: String, to s: inout TermStyle) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: s = TermStyle()
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4: s.underline = true
            case 7: s.inverse = true
            case 22: s.bold = false; s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 27: s.inverse = false
            case 30...37: s.fg = .indexed(UInt8(c - 30))
            case 39: s.fg = nil
            case 40...47: s.bg = .indexed(UInt8(c - 40))
            case 49: s.bg = nil
            case 90...97: s.fg = .indexed(UInt8(c - 90 + 8))
            case 100...107: s.bg = .indexed(UInt8(c - 100 + 8))
            case 38, 48:
                var color: TermColor?
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    color = .indexed(UInt8(clamping: codes[i + 2]))
                    i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    color = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4]))
                    i += 4
                }
                if c == 38 { s.fg = color } else { s.bg = color }
            default: break
            }
            i += 1
        }
    }
}
