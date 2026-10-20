import Foundation

/// Менеджер ждёт ответа в своей панели: вопрос о праве, форма AskUserQuestion или доверие к каталогу. Приложение
/// ответа не даёт (его даёт владелец в строке Claude Code или в терминале), а только сообщает, о чём вопрос.
public struct WaitingNotice: Equatable, Sendable {
    public enum Kind: Sendable { case permission, ask, trust }
    public var kind: Kind
    /// «Менеджер ждёт ответа: …» — вопрос и первая строка команды.
    public var text: String

    static let prefix = "Менеджер ждёт ответа: "

    /// По экрану панели и признакам хаба (они известны и у панелей, которые приложение не стримит); nil — диалога нет,
    /// уведомление снимается сразу, как диалог закрыт.
    public static func from(lines: [StyledLine], asksTrust: Bool, asksPermission: Bool) -> WaitingNotice? {
        if asksTrust || PaneTail.asksFolderTrust(lines.suffix(40).map(\.plain)) {
            return WaitingNotice(kind: .trust, text: prefix + "доверять ли папке проекта")
        }
        if AskForm.isOpen(lines) {
            let q = AskForm.question(lines)
            let opts = AskForm.options(lines)
            var t = prefix + (q ?? "выбор варианта")
            if !opts.isEmpty { t += " (" + opts.prefix(4).joined(separator: " / ") + (opts.count > 4 ? " …" : "") + ")" }
            return WaitingNotice(kind: .ask, text: clip(t, 240))
        }
        if let p = PermissionPrompt.from(lines) {
            var t = prefix + p.question
            if let cmd = p.command { t += " · " + cmd }
            return WaitingNotice(kind: .permission, text: clip(t, 240))
        }
        if asksPermission { return WaitingNotice(kind: .permission, text: prefix + "вопрос о праве вне allow") }
        return nil
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }
}

/// Текст решения владельца по экрану панели агента: чем вопрос отличается от права.
public enum DecisionText {
    /// По строкам экрана: тот же разбор, что делает захват (`PaneScreen`).
    public static func question(name: String, lines: [StyledLine], asksTrust: Bool, dir: String) -> (kind: Decision.Kind, text: String) {
        let s = PaneScreen.read(lines)
        return question(name: name, asksTrust: asksTrust || s.asksTrust, askFormOpen: s.askFormOpen, askQuestion: s.askQuestion, dir: dir)
    }

    /// По разобранному экрану панели (`PaneOutput`: доверие, форма вопроса и её вопрос).
    public static func question(name: String, asksTrust: Bool, askFormOpen: Bool, askQuestion: String?,
                                dir: String) -> (kind: Decision.Kind, text: String) {
        if asksTrust { return (.trust, "\(name) спрашивает, доверяете ли вы папке \(dir)") }
        if askFormOpen {
            return (.ask, name + " задал вопрос" + (askQuestion.map { ": " + $0 } ?? ""))
        }
        return (.permission, "\(name) просит право вне allow — ответ в его панели")
    }
}

extension PermissionPrompt {
    /// Первая строка того, что именно просят выполнить: у Bash — сама команда (последняя строка описания), у правок файла — первая.
    var command: String? {
        guard !detail.isEmpty else { return nil }
        let line = (heading?.hasPrefix("Bash") == true ? detail.last : detail.first) ?? ""
        return line.isEmpty ? nil : line
    }
}

extension AskForm {
    /// Разбор формы по экрану: вопрос и варианты. Над подсказкой идут варианты «N. текст» (с курсором `❯` или без),
    /// у каждого может быть пояснение глубже отступом, между «Type something» и «Chat about this» стоит рамка;
    /// выше — вопрос (строка с нулевым отступом, не вкладка и не рамка).
    private static func parse(_ raw: [String]) -> (question: String?, labels: [String])? {
        guard let hint = raw.lastIndex(where: { $0.contains("Enter to select") }) else { return nil }
        var labels: [String] = []
        var question: String?
        var i = hint - 1
        while i >= 0 {
            let line = raw[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || ScreenMarks.isRule(t) { i -= 1; continue }
            if let m = t.range(of: #"^(❯\s*)?\d+\.\s+"#, options: .regularExpression) {
                labels.insert(String(t[m.upperBound...]), at: 0)
            } else if line.prefix { $0 == " " }.count >= 4 {
                // пояснение к варианту
            } else {
                if !(t.hasPrefix("☐") || t.hasPrefix("☒") || t.hasPrefix("✔") || t.hasPrefix("←")) { question = t }
                break
            }
            i -= 1
        }
        return labels.isEmpty ? nil : (question, labels)
    }

    /// Свои варианты Claude Code в конце каждой формы: ответ в произвольной форме и «обсудить».
    private static let builtIn: Set<String> = ["Type something.", "Type something", "Chat about this"]

    public static func options(_ lines: [StyledLine]) -> [String] {
        (parse(lines.suffix(40).map(\.plain))?.labels ?? []).filter { !builtIn.contains($0) }
    }

    public static func question(_ lines: [StyledLine]) -> String? {
        parse(lines.suffix(40).map(\.plain))?.question
    }
}
