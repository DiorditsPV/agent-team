import Foundation

/// Общие приметы экрана Claude Code — рамки и строка хода — и регулярные выражения, разобранные один раз.
public enum ScreenMarks {
    /// Рамка поля ввода и диалогов: «────» (в ней бывает заголовок сессии, «──── Разработчик ─») или «━━━━».
    /// `menu` — и «▔▔▔▔» над меню вроде /rewind.
    public static func isRule(_ s: String, menu: Bool = false) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("────") || t.hasPrefix("━━━━") || (menu && t.hasPrefix("▔▔▔▔"))
    }

    /// Строка хода со временем: «✻ Stewing… (2m 14s · ↓ 3.1k tokens · esc to interrupt)». `bare` — и первая секунда
    /// хода без скобок («✳ Doodling…»): так она выглядит прямо над полем ввода, а в тексте ответа такая строка может
    /// оказаться пунктом списка.
    public static func isTurnLine(_ plain: String, bare: Bool = false) -> Bool {
        matches(plain, timedTurn) || (bare && matches(plain, bareTurn))
    }

    private static let timedTurn = regex(#"^\s*[^\p{L}\p{N}\s]\s+\S+(…|\.\.\.)\s*\([^)]*\d+\s*[smh]\b[^)]*\)"#)
    private static let bareTurn = regex(#"^\s*[^\p{L}\p{N}\s]\s+\S+(…|\.\.\.)\s*$"#)

    /// Кружок идущего вызова инструмента («⏺ Mid tool run…», «⏺ Advising using …») Claude Code рисует мигающим: в
    /// погашенной фазе на его месте пробел того же цвета. Разбор по тексту строки видел в одной фазе пункт, в другой —
    /// строку продолжения, и граница ответа прыгала между захватами: черновик «пишет…» пропадал и возвращался, высота
    /// чата менялась в такт миганию. Погашенный кружок возвращается на место: строка, которая начинается одним
    /// окрашенным пробелом (цвет текста задан, фона нет), за которым идёт пробел и текст, — это строка с кружком.
    public static func steadyBullets(_ lines: [StyledLine]) -> [StyledLine] {
        var colors = Set<TermColor>()
        return steadyBullets(lines, blinked: &colors)
    }

    /// То же; `blinked` пополняется цветами погашенных кружков — это цвет кружка идущего инструмента в теме панели.
    public static func steadyBullets(_ lines: [StyledLine], blinked: inout Set<TermColor>) -> [StyledLine] {
        lines.map { line in
            guard line.runs.count >= 2, line.runs[0].text == " ", let fg = line.runs[0].style.fg, line.runs[0].style.bg == nil,
                  line.runs[1].text.hasPrefix(" "), line.runs[1].text.dropFirst().first.map({ !$0.isWhitespace }) == true
            else { return line }
            blinked.insert(fg)
            var l = line
            l.runs[0].text = "⏺"
            return l
        }
    }

    /// Строка с кружком цвета идущего инструмента (`toolColors` — цвета, которыми кружок мигал).
    public static func isToolBullet(_ line: StyledLine, toolColors: Set<TermColor>) -> Bool {
        guard !toolColors.isEmpty,
              let run = line.runs.first(where: { !$0.text.allSatisfy { $0 == " " } }), run.text.hasPrefix("⏺") ||
                run.text.drop(while: { $0 == " " }).hasPrefix("⏺"),
              let fg = run.style.fg else { return false }
        return toolColors.contains(fg)
    }

    // MARK: регулярные выражения

    /// Выражение разбирается один раз: сборка `NSRegularExpression` стоит около 60 мкс, а строки экрана проверяются
    /// многократно на каждый захват и каждую перерисовку.
    static func regex(_ pattern: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        // Шаблоны — константы кода: ошибка в них ловится первым же тестом.
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    static func matches(_ s: String, _ re: NSRegularExpression) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Группы первого совпадения (0 — всё совпадение; несовпавшая группа — пустая строка).
    static func groups(_ s: String, _ re: NSRegularExpression) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}
