import Foundation

/// Вопрос Claude Code с нумерованными вариантами, как он нарисован в панели: право на действие
/// («Do you want to proceed?»), одобрение плана. Варианты и порядок — те же, что в терминале; нажатие цифры
/// выбирает вариант, Esc отменяет.
public struct PermissionPrompt: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var number: Int
        public var label: String
        /// Строка выделена курсором (`❯`).
        public var selected: Bool
    }

    /// Заголовок диалога («Bash command», «Edit file»), если есть.
    public var heading: String?
    /// Что именно просит сделать: описание и команда.
    public var detail: [String]
    public var question: String
    public var options: [Option]

    /// Признак открытого диалога внизу экрана: подсказка «Esc to cancel». У вопроса `AskUserQuestion` подсказка
    /// другая («Enter to select») — это отдельная форма (`AskForm`).
    public static let cancelHint = "Esc to cancel"

    /// Вопрос в хвосте экрана панели; `nil`, если диалога нет. Вопрос о доверии каталогу не разбирается: его решает
    /// владелец в терминале, приложение кнопок для него не рисует.
    public static func from(_ lines: [StyledLine]) -> PermissionPrompt? {
        let tail = lines.suffix(40).map { $0.plain.trimmingCharacters(in: .whitespaces) }
        guard let hint = tail.lastIndex(where: { $0.contains(cancelHint) }),
              AskForm.hintIndex(tail) == nil,       // подсказка формы бывает на двух строках
              !PaneTail.asksFolderTrust(tail) else { return nil }
        // Варианты — подряд идущие «N. текст» над подсказкой (строки продолжения без номера склеиваются).
        var options: [Option] = []
        var i = hint - 1
        var pendingLabel: [String] = []
        while i >= 0 {
            let line = tail[i]
            if line.isEmpty { i -= 1; continue }
            if let m = line.range(of: #"^(❯\s*)?(\d+)\.\s+"#, options: .regularExpression) {
                let head = String(line[m])
                let number = Int(head.filter(\.isNumber)) ?? 0
                let label = ([String(line[m.upperBound...])] + pendingLabel).joined(separator: " ")
                options.insert(Option(number: number, label: label, selected: head.hasPrefix("❯")), at: 0)
                pendingLabel = []
                i -= 1
                continue
            }
            if options.isEmpty || line.hasSuffix("?") { break }
            pendingLabel.insert(line, at: 0)       // перенос длинного варианта на следующую строку
            i -= 1
        }
        guard options.count >= 2, options.first?.number == 1,
              i >= 0, tail[i].hasSuffix("?") else { return nil }
        let question = tail[i]
        var detail: [String] = []
        var heading: String?
        var j = i - 1
        while j >= 0, !ScreenMarks.isRule(tail[j]) {
            let l = tail[j]
            if !l.isEmpty, !l.hasPrefix("╌"), !l.hasPrefix("Tip:") { detail.insert(l, at: 0) }
            j -= 1
        }
        if j >= 0, let first = detail.first, detail.count > 1 { heading = first; detail.removeFirst() }
        return PermissionPrompt(heading: heading, detail: detail, question: question, options: options)
    }
}

/// Форма `AskUserQuestion` в панели: открыта ли она сейчас (для границы живой части строки ввода).
public enum AskForm {
    /// Форма сейчас открыта в панели: подсказка «Enter to select» и «Esc to cancel» или экран проверки ответов.
    public static func isOpen(_ lines: [StyledLine]) -> Bool { isOpen(tail: lines.suffix(40).map(\.plain)) }

    /// То же по 40 последним строкам экрана без стилей.
    static func isOpen(tail: [String]) -> Bool {
        hintIndex(tail) != nil || tail.contains { $0.contains("Review your answers") || $0.contains("Ready to submit your answers") }
    }

    /// Последняя строка подсказки формы: «Enter to select · ↑/↓ to navigate · Esc to cancel». В узкой панели или
    /// с добавкой («ctrl+g to edit in VS Code», пока курсор в «Type something»; «Tab/Arrow keys» у формы из нескольких
    /// вопросов) подсказка переносится на вторую строку: «Enter to select» бывает строкой выше, а «Esc to cancel»
    /// разрывается переносом («… · Esc» и «to cancel»).
    public static func hintIndex(_ plain: [String]) -> Int? {
        let hint = PermissionPrompt.cancelHint
        func pair(_ i: Int) -> String {
            i > 0 ? plain[i - 1].trimmingCharacters(in: .whitespaces) + " " + plain[i].trimmingCharacters(in: .whitespaces) : plain[i]
        }
        // Разрыв: «Esc to cancel» есть только в склейке, а не в строке выше (иначе строка под подсказкой сошла бы за неё).
        guard let esc = plain.indices.last(where: { i in
            plain[i].contains(hint) || (pair(i).contains(hint) && !plain[i - 1].contains(hint))
        }) else { return nil }
        return pair(esc).contains("Enter to select") ? esc : nil
    }
}
