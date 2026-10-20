import Foundation

/// Что видно на экране панели, разобранное один раз на захват (вне главного потока): строка хода, вопросы, форма,
/// набранное в строке ввода, ответ, который менеджер пишет сейчас. Виды читают поля, а не разбирают строки в `body`.
public struct PaneScreen: Equatable, Sendable {
    public var turn: TurnStatus?
    public var asksTrust = false
    /// Запрос права (инструмент вне allow) или другой вопрос с выбором.
    public var asksPermission = false
    /// Открыта форма вопроса с вариантами (AskUserQuestion).
    public var askFormOpen = false
    /// Вопрос открытой формы.
    public var askQuestion: String?
    /// В строке ввода набран текст (бледная подсказка-заглушка — не текст).
    public var inputTyped = false
    /// Строка ввода Claude Code на экране (пустая или с текстом).
    public var inputLine = false
    /// О чём панель ждёт ответа (подпись для менеджера); `nil` — диалога нет.
    public var notice: WaitingNotice?
    /// Текстовый блок, который пишется сейчас (черновик «пишет…»); считается по просьбе (`read(_:reply:)`).
    public var reply: LiveReply?
    /// Открыт экран встроенной команды Claude Code (`/mcp`, `/config`…, `CommandScreen`): строки ввода нет, панель
    /// показывается как есть, клавиши идут в неё.
    public var commandScreen = false

    public init() {}

    /// `reply` — разобрать и черновик ответа: он нужен только чату менеджера и стоит больше остального разбора.
    /// `toolColors` — цвета кружка идущего инструмента в этой панели (строка инструмента — не черновик ответа).
    public static func read(_ lines: [StyledLine], reply: Bool = true, toolColors: Set<TermColor> = []) -> PaneScreen {
        var s = PaneScreen()
        let tail = lines.suffix(40).map(\.plain)
        s.asksTrust = PaneTail.asksFolderTrust(tail)
        s.asksPermission = !s.asksTrust && PaneTail.asksPermission(tail)
        s.turn = TurnStatus.from(lines)
        s.askFormOpen = AskForm.isOpen(tail: tail)
        if s.askFormOpen { s.askQuestion = AskForm.question(lines) }
        let typed = LiveInput.typedText(lines)
        s.inputLine = typed != nil
        s.inputTyped = !(typed ?? "").isEmpty
        s.commandScreen = CommandScreen.isOpen(lines.map(\.plain))
        // Без признаков диалога (доверие, право, форма, подсказка «Esc to cancel») подписи нет — разбор не нужен.
        if s.asksTrust || s.asksPermission || s.askFormOpen || tail.contains(where: { $0.contains(PermissionPrompt.cancelHint) }) {
            s.notice = WaitingNotice.from(lines: lines, asksTrust: s.asksTrust, asksPermission: s.asksPermission)
        }
        // Ответ на экране бывает только без диалога и без экрана команды: текст панели — не черновик ответа.
        if reply, s.notice == nil, !s.commandScreen { s.reply = LiveReply.extract(lines, toolColors: toolColors) }
        return s
    }
}
