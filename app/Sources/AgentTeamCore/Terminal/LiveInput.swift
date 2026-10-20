import Foundation

/// Нижняя часть панели Claude Code, которую приложение показывает под лентой чата вживую: строка ввода с рамками
/// и строкой статуса, меню подсказок над ней (`/`, `@`) и диалоги прав и выбора.
public enum LiveInput {
    /// Предельная высота показываемой части.
    public static let maxRows = 24

    /// Текст, набранный в строке ввода Claude Code: строки между двумя последними рамками экрана, после «❯». Бледный
    /// текст — подсказка-заглушка пустой строки, не набранное. `nil` — строки ввода на экране нет (диалог, меню).
    public static func typedText(_ lines: [StyledLine]) -> String? {
        let rules = lines.indices.filter { ScreenMarks.isRule(lines[$0].plain) }
        guard rules.count >= 2 else { return nil }
        let top = rules[rules.count - 2], bottom = rules[rules.count - 1]
        guard bottom - top > 1, lines[top + 1].plain.hasPrefix("❯") else { return nil }
        var text = ""
        for (k, line) in lines[(top + 1)..<bottom].enumerated() {
            var runs = line.runs
            if k == 0, let first = runs.first {
                // Знак строки ввода и пробел после него.
                var t = Substring(first.text)
                if t.hasPrefix("❯") { t = t.dropFirst() }
                runs[0].text = String(t)
            }
            text += runs.filter { !$0.style.dim }.map(\.text).joined() + "\n"
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{a0}")))
    }

    /// Индекс первой строки нижней части в `lines` (после чистки служебного); `nil`, если строки ввода на экране нет.
    ///
    /// Признаки:
    /// - экран встроенной команды (`/mcp`, `/config`, `/status`…, `CommandScreen`): панель от верхней рамки «▔▔▔▔» до
    ///   конца экрана, целиком — без предела `maxRows`, её место подбирает вид;
    /// - диалог (право, форма выбора): строка рамки `────` прямо над его заголовком, часть идёт до конца экрана;
    /// - строка ввода: две последние рамки на экране, между ними одна и больше строк (ввод в несколько строк или
    ///   режим `!`); часть начинается с верхней из них;
    /// - меню подсказок: сплошной блок непустых строк прямо над верхней рамкой с пунктами «❯», «◇», «/», «@».
    public static func start(_ lines: [StyledLine]) -> Int? {
        let plain = lines.map { $0.plain.trimmingCharacters(in: .whitespaces) }
        // Экран команды — по строкам как есть: рамка экрана стоит в нулевом столбце, цитата рамки — с отступом.
        if let top = CommandScreen.top(lines.map(\.plain)) { return top }
        // Рамки: «────» у поля ввода и диалогов, «▔▔▔▔» у меню вроде /rewind.
        func isRule(_ s: String) -> Bool { ScreenMarks.isRule(s, menu: true) }
        let rules = plain.indices.filter { isRule(plain[$0]) }
        guard let last = rules.last else { return nil }

        // Диалог или меню (право, форма выбора, /rewind): подсказка «Esc to cancel» внизу экрана и ниже неё нет
        // пары рамок поля ввода; рамка над диалогом — начало части.
        let tailFrom = max(0, plain.count - 40)
        // Подсказка формы бывает разорвана переносом посреди «Esc to cancel»: её ищет AskForm.
        let formHint = AskForm.hintIndex(plain).flatMap { $0 >= tailFrom ? $0 : nil }
        let plainHint = (tailFrom..<plain.count).last(where: { plain[$0].contains(PermissionPrompt.cancelHint) || plain[$0].contains("Ready to submit your answers") })
        if let hint = [formHint, plainHint].compactMap({ $0 }).max(),
           rules.filter({ $0 > hint }).count <= 1 {     // у формы выбора под подсказкой бывает одна замыкающая рамка
            // Форма выбора: начало — её вкладки («☐ Вопрос») с рамкой над ними, как бы далеко они ни были. Рамка посреди
            // формы (перед «Chat about this») началом не считается. Вкладок на экране нет — Claude Code не уместил форму
            // в панель и обрезал её сверху: форма занимает экран с первой строки.
            if AskForm.hintIndex(plain) == hint {
                return formTop(plain, hint: hint, isRule: isRule) ?? 0
            }
            // Право и меню: верхняя из рамок в пределах 16 строк над подсказкой.
            if let top = rules.first(where: { $0 < hint && hint - $0 <= 16 }) {
                return clamp(top, count: used(plain))
            }
        }

        // Строка ввода: пара рамок, между ними ввод.
        guard rules.count >= 2, let upper = rules.dropLast().last,
              last - upper > 1, last - upper <= 12,
              plain[(upper + 1)..<last].contains(where: { !$0.isEmpty }) else { return nil }
        var start = upper
        // Меню подсказок над рамкой: блок без пустых строк.
        var j = upper - 1
        while j >= 0, !plain[j].isEmpty, upper - j <= 14 { j -= 1 }
        if j + 1 < upper {
            let block = plain[(j + 1)..<upper]
            if block.contains(where: { $0.hasPrefix("❯") || $0.hasPrefix("◇") || $0.hasPrefix("/") || $0.hasPrefix("@") }) {
                start = j + 1
            }
        }
        // Строка хода («✻ Stewing… (5s · esc to interrupt)») над рамкой входит в часть: Esc прерывает ход.
        var k = start - 1
        var skipped = 0
        // Между строкой хода и рамкой бывают пустые строки, «Tip:» и плашки Claude Code.
        while k >= 0, skipped < 6, plain[k].isEmpty || PaneDigest.isNoise(lines[k].plain) || lines[k].plain.contains("new message") || lines[k].plain.contains("Auto-update") {
            k -= 1
            skipped += 1
        }
        if k >= 0, isSpinner(lines[k].plain) { start = k }
        return clamp(start, count: used(plain))
    }

    /// Строка хода: со временем и токенами или первая секунда хода («✳ Doodling…»).
    static func isSpinner(_ plain: String) -> Bool { ScreenMarks.isTurnLine(plain, bare: true) }

    /// Первая строка формы выбора: рамка над вкладками (`☐ Вопрос`, `← ☐ A  ☐ B  ✔ Submit →`), а без неё сами вкладки;
    /// `nil`, если вкладок над подсказкой нет.
    private static func formTop(_ plain: [String], hint: Int, isRule: (String) -> Bool) -> Int? {
        guard let tabs = (0..<hint).last(where: { i in ["☐", "☒", "✔", "←"].contains { plain[i].hasPrefix($0) } }) else { return nil }
        return tabs > 0 && isRule(plain[tabs - 1]) ? tabs - 1 : tabs
    }

    private static func clamp(_ start: Int, count: Int) -> Int { max(start, count - maxRows) }

    /// Число строк до последней непустой: под экраном захват добавляет пустые строки до высоты панели.
    private static func used(_ plain: [String]) -> Int {
        (plain.lastIndex { !$0.isEmpty }.map { $0 + 1 }) ?? 0
    }

    /// Номер выбранного пункта формы или меню: строка «❯ 3. …».
    static func selectedNumber(_ plain: String) -> Int? {
        let t = plain.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("❯"), let m = t.range(of: #"^❯\s*(\d+)\."#, options: .regularExpression) else { return nil }
        return Int(t[m].filter(\.isNumber))
    }

    /// Часть, которая умещается в `limit` строк. Форма выше места прокручивается: низ (последняя рамка, «Chat about
    /// this», подсказка) стоит на месте, а середина показывает пункт с курсором `❯` и его пояснение; над и под окном —
    /// строки «выше/ниже ещё N». `source` — номер строки части для каждой показанной (`nil` у подписей): по нему
    /// ставится курсор.
    public static func fit(_ rows: [StyledLine], limit: Int) -> (rows: [StyledLine], source: [Int?]) {
        let limit = max(limit, 12)
        guard rows.count > limit else { return (rows, Array(rows.indices)) }
        let plain = rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
        // Низ: от последней рамки, если она в пределах шести строк от конца, иначе четыре последние строки.
        let lastRule = plain.indices.last { ScreenMarks.isRule(plain[$0], menu: true) }
        let footerStart = lastRule.flatMap { rows.count - $0 <= 6 && $0 > 0 ? $0 : nil } ?? max(1, rows.count - 4)
        let body = footerStart
        let avail = limit - (rows.count - footerStart) - 2      // два места под «ещё N»
        let selected = plain[..<body].firstIndex { selectedNumber($0) != nil }
        var from: Int
        if let selected {
            from = min(max(0, selected - avail / 4), body - avail)
        } else {
            from = body - avail                                    // курсор в низу или вне части: виден конец тела
        }
        from = max(0, from)
        let to = min(body, from + avail)
        var out: [StyledLine] = []
        var source: [Int?] = []
        if from > 0 { out.append(note("▲ выше ещё \(from) стр.")); source.append(nil) }
        out.append(contentsOf: rows[from..<to]); source.append(contentsOf: (from..<to).map { $0 })
        if to < body { out.append(note("▼ ниже ещё \(body - to) стр.")); source.append(nil) }
        out.append(contentsOf: rows[footerStart...]); source.append(contentsOf: (footerStart..<rows.count).map { $0 })
        return (out, source)
    }

    private static func note(_ text: String) -> StyledLine {
        var st = TermStyle()
        st.dim = true
        return StyledLine(runs: [StyledRun(text: "  " + text, style: st)])
    }

    /// Низ экрана, на котором нет ни строки ввода, ни диалога, ни экрана команды (экран Claude Code, которого приложение не
    /// знает): последние `maxRows` строк до последней непустой — владелец видит, что в панели, и отвечает клавишами.
    /// `nil` — экран пуст.
    public static func tail(_ lines: [StyledLine]) -> (rows: [StyledLine], offset: Int)? {
        let n = used(lines.map { $0.plain.trimmingCharacters(in: .whitespaces) })
        guard n > 0 else { return nil }
        let from = max(0, n - maxRows)
        return (Array(lines[from..<n]), from)
    }

    /// Строки нижней части и сколько их срезано сверху (для положения курсора).
    public static func region(_ lines: [StyledLine]) -> (rows: [StyledLine], offset: Int)? {
        let clean = lines
        guard let s = start(clean) else { return nil }
        var rows = Array(clean[s...])
        while let l = rows.last, l.isBlank { rows.removeLast() }
        // Форма кончается подсказкой: ниже бывают пустые строки высокой панели и рамка с именем сессии, к форме они не
        // относятся, а внизу должны стоять «Chat about this» и подсказка.
        if let h = AskForm.hintIndex(rows.map(\.plain)) { rows.removeSubrange((h + 1)...) }
        // Форма не уместилась в панель tmux: Claude Code обрезал её сверху и рисует только низ. Если курсора `❯` на
        // экране нет, он стоит на одном из обрезанных пунктов — об этом подпись, иначе кажется, что выбора нет.
        let plain = rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
        if AskForm.hintIndex(plain) != nil, s == 0,
           !plain.contains(where: { $0.hasPrefix("☐") || $0.hasPrefix("←") }),
           !plain.contains(where: { selectedNumber($0) != nil }),
           let firstShown = plain.compactMap({ line in line.range(of: #"^\d+(?=\.)"#, options: .regularExpression).flatMap { Int(line[$0]) } }).first,
           firstShown > 1 {
            let which = firstShown == 2 ? "скрытом пункте 1" : "одном из скрытых пунктов 1–\(firstShown - 1)"
            rows.insert(note("▲ курсор на \(which): форма выше панели tmux"), at: 0)
            return (rows, s - 1)
        }
        return (rows, s)
    }
}
