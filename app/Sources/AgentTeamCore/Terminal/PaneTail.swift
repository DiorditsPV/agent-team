import Foundation

/// Хвост панели агента: что показать в сетке и не ждёт ли агент человека.
public enum PaneTail {
    /// Отрезает поле ввода Claude Code и строку статуса под ним: всё от линии из «─»
    /// над строкой с «❯» и ниже. Затем убирает пустые строки по краям и служебное Claude Code (`PaneNoise`).
    public static func content(_ raw: [StyledLine]) -> [StyledLine] {
        let lines = PaneNoise.strip(raw)       // плашка «N new messages» и «Auto-update failed» — и на панелях, и на экране агента
        var end = lines.count
        if let prompt = lines.lastIndex(where: { $0.plain.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) {
            var cut = prompt
            if prompt > 0, ScreenMarks.isRule(lines[prompt - 1].plain) { cut = prompt - 1 }
            // Под полем ввода — рамка и статус; выше поля ввода — вывод.
            end = cut
        }
        var slice = Array(lines[0..<end])
        while let last = slice.last, last.isBlank { slice.removeLast() }
        while let first = slice.first, first.isBlank { slice.removeFirst() }
        return slice
    }

    /// Последние `n` строк вывода; подряд идущие пустые строки схлопываются в одну.
    public static func tail(_ lines: [StyledLine], count n: Int) -> [StyledLine] {
        var body: [StyledLine] = []
        for l in content(lines) {
            if l.isBlank, body.last?.isBlank == true { continue }
            body.append(l)
        }
        return Array(body.suffix(n))
    }

    /// Признаки вопроса о доверии к каталогу (тексты Claude Code, см. docs/agent-guide.md, шаг 8).
    public static let trustMarkers = ["Do you trust", "Quick safety check", "trust this folder", "Доверяете"]

    /// Запрос права или вопрос с выбором в хвосте панели. Те же признаки, что у waiting_human в CLI:
    /// приложение видит их и у скрытых панелей, не дожидаясь следующего team status.
    public static let permissionPatterns = [
        #"Do you want to (proceed|make this edit|create|allow|run|overwrite)"#,
        #"Would you like to proceed"#,
        #"❯\s*1\.\s*Yes"#,
        // Форма AskUserQuestion: подсказка «Enter to select · … · Esc to cancel» и экран проверки ответов.
        #"Enter to select[^\n]*(\n[^\n]*)?Esc to cancel"#,
        #"Ready to submit your answers"#,
    ]
    private static let permissionRegexes = permissionPatterns.map { ScreenMarks.regex($0, caseInsensitive: true) }
    // Одна «Esc to cancel» без вопроса — не решение владельца: так подписаны и меню, которые владелец открыл сам
    // (/rewind, /resume, /model), поэтому по ней одной «ждёт человека» не ставится.

    /// Строки экрана без пустого хвоста: захват панели дополняет экран пустыми строками до её высоты, а диалог
    /// Claude Code не всегда прижат к низу, поэтому «последние строки» считаются от последней непустой.
    static func withoutBlankTail(_ plain: [String]) -> [String] {
        var end = plain.count
        while end > 0, plain[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        return Array(plain[..<end])
    }

    public static func asksPermission(_ plain: [String]) -> Bool {
        let lines = withoutBlankTail(plain).suffix(15)
        // Подсказка «Enter to select · … · Esc to cancel» в узкой панели переносится на вторую строку: ищем и в склейке.
        let texts = [lines.joined(separator: "\n"), lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")]
        return permissionRegexes.contains { re in texts.contains { ScreenMarks.matches($0, re) } }
    }

    public static func asksFolderTrust(_ plain: [String]) -> Bool {
        withoutBlankTail(plain).suffix(40).contains { line in trustMarkers.contains { line.localizedCaseInsensitiveContains($0) } }
    }
}
