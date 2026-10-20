import Foundation

/// Форма `AskUserQuestion`, как она видна на экране панели: какие пункты видны, где курсор и какие пункты отмечены.
/// Сам вопрос целиком берётся из источника (`OpenQuestionSource`): верх формы в узкой панели срезан, а с экрана
/// приложению нужно только место курсора и сверка, что экран показывает тот же вопрос.
public struct AskFormScreen: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var number: Int
        /// Текст строки пункта без номера и отметки: подпись варианта (в узкой панели — её начало), «Type something.»
        /// или набранный в нём ответ, «Chat about this».
        public var text: String
        /// Отметка множественного выбора: `[✔]` — true, `[ ]` — false, у пункта без отметки — nil.
        public var checked: Bool?
    }

    /// Видимые пункты «N. …» по порядку.
    public var items: [Item]
    /// Номер пункта под курсором `❯`; `nil` — курсор на срезанном сверху пункте.
    public var cursor: Int?
    /// Экран проверки ответов («Review your answers»): вопросов на нём нет, он умещается в панель сам.
    public var review: Bool
    /// Вкладки формы («☐ Защита», «←  ☒ Сервер  ☐ Срок  ✔ Submit  →») на экране. Их нет — Claude Code не уместил форму
    /// в панель и срезал её верх вместе с вопросом.
    public var tabsVisible: Bool

    /// Верх формы срезан: вопроса на экране нет.
    public var clipped: Bool { !review && !tabsVisible }

    /// Форма в строках экрана (без стилей); `nil`, если формы нет.
    public static func read(_ plain: [String]) -> AskFormScreen? {
        let review = plain.contains { $0.contains("Review your answers") || $0.contains("Ready to submit your answers") }
        guard review || AskForm.hintIndex(plain) != nil else { return nil }
        var items: [Item] = []
        var cursor: Int?
        let tabs = plain.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return ["☐", "☒", "←"].contains { t.hasPrefix($0) }
        }
        for line in plain {
            let l = line.replacingOccurrences(of: "\u{a0}", with: " ")
            // Пункт: «❯ 3. …» или «  3. …». Пояснения сдвинуты дальше и под образец не попадают.
            guard let m = l.range(of: #"^[❯ ] ?(\d+)\. "#, options: .regularExpression) else { continue }
            let head = l[m]
            guard let n = Int(head.filter(\.isNumber)) else { continue }
            var text = String(l[m.upperBound...]).trimmingCharacters(in: .whitespaces)
            var checked: Bool?
            if text.hasPrefix("[ ]") { checked = false; text = String(text.dropFirst(3)) }
            else if text.hasPrefix("[✔]") || text.hasPrefix("[✓]") { checked = true; text = String(text.dropFirst(3)) }
            items.append(Item(number: n, text: text.trimmingCharacters(in: .whitespaces), checked: checked))
            if head.hasPrefix("❯") { cursor = n }
        }
        return AskFormScreen(items: items, cursor: cursor, review: review, tabsVisible: tabs)
    }

    /// Число вариантов вопроса на экране: «Chat about this» идёт под номером n+2. Без этой строки — `nil`.
    public var optionCount: Int? {
        items.last { $0.text.hasPrefix("Chat about this") }.map { $0.number - 2 }
    }

    /// Номер вопроса источника, чью вкладку показывает экран; `nil` — экран с источником не сходится (другой вопрос,
    /// устаревший источник) или это экран проверки ответов.
    public func questionIndex(in q: PendingQuestion) -> Int? {
        guard !review, let n = optionCount, n > 0 else { return nil }
        let visible = items.filter { $0.number <= n }
        let matching = q.questions.indices.filter { i in
            let opts = q.questions[i].options
            guard opts.count == n else { return false }
            return visible.allSatisfy { Self.sameLabel(opts[$0.number - 1].label, $0.text) }
        }
        return matching.first
    }

    /// Первый по порядку источников вопрос, чью вкладку показывает экран, и номер этой вкладки.
    public func pick(_ candidates: [PendingQuestion]) -> (question: PendingQuestion, index: Int)? {
        for q in candidates { if let i = questionIndex(in: q) { return (q, i) } }
        return nil
    }

    /// Строка пункта на экране — подпись варианта или её начало (длинная подпись переносится в узкой панели).
    static func sameLabel(_ label: String, _ shown: String) -> Bool {
        let l = label.trimmingCharacters(in: .whitespaces), s = shown.trimmingCharacters(in: CharacterSet(charactersIn: " …"))
        guard !s.isEmpty else { return false }
        return l.hasPrefix(s) || s.hasPrefix(l)
    }

    /// Где курсор относительно вопроса из `n` вариантов.
    public func cursorKind(options n: Int) -> AskCursor {
        guard let c = cursor else { return .hidden }
        if c <= n { return .option(c) }
        return c == n + 1 ? .typeSomething : .chat
    }
}

/// Положение курсора формы.
public enum AskCursor: Equatable, Sendable {
    /// На варианте с номером.
    case option(Int)
    /// В поле «Type something» (свой ответ).
    case typeSomething
    /// На «Chat about this».
    case chat
    /// На пункте, срезанном сверху: это всегда вариант — «Type something» и «Chat about this» стоят внизу формы и видны.
    case hidden
}

/// Клавиши формы `AskUserQuestion`, которые приложение шлёт в панель. Проверено на живом claude 2.1.295:
/// - цифра пункта, пока курсор на варианте: вариант выбирается сразу (в форме из нескольких вопросов — с переходом
///   к следующей вкладке; во множественном выборе цифра переключает отметку), цифра «Type something» ставит курсор
///   в поле, цифра «Chat about this» сразу уводит вопрос в чат;
/// - в поле «Type something» цифра уходит текстом, на «Chat about this» не действует;
/// - ↑ с «Chat about this» ведёт на «Type something», с него — на последний вариант.
/// Поэтому перед цифрой курсор уводится ↑ на вариант.
public enum AskKeys {
    /// Уход курсора на вариант, после которого цифра и стрелки вкладок работают.
    public static func leave(_ cursor: AskCursor) -> [String] {
        switch cursor {
        case .option, .hidden: []
        case .typeSomething: ["Up"]
        case .chat: ["Up", "Up"]
        }
    }

    /// Выбор пункта `number`: 1…n — варианты, n+1 — «Type something», n+2 — «Chat about this».
    public static func choose(_ number: Int, cursor: AskCursor) -> [String] {
        leave(cursor) + [String(number)]
    }

    /// Свой ответ: курсор в поле «Type something» вопроса из `n` вариантов; текст и Enter идут следом.
    public static func ownAnswer(options n: Int, cursor: AskCursor) -> [String] {
        cursor == .typeSomething ? [] : choose(n + 1, cursor: cursor)
    }

    /// Переход между вкладками вопросов: на `delta` вправо (плюс) или влево (минус).
    public static func tab(_ delta: Int, cursor: AskCursor) -> [String] {
        guard delta != 0 else { return [] }
        return leave(cursor) + Array(repeating: delta > 0 ? "Right" : "Left", count: abs(delta))
    }
}
