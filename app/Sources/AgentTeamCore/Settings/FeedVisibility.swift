import Foundation

/// Вид элемента ленты, который можно скрыть в «Настройках».
public enum FeedCategory: Sendable, CaseIterable {
    case bash, files, otherTool, teamMessage, tracker, compacted, turnDuration
}

/// Что показывать в ленте: чате менеджера, «Диалоге» агента и тредах панелей. По умолчанию показано всё.
/// Фильтр применяется при показе, не при разборе транскрипта: переключатель действует сразу.
public struct FeedVisibility: Codable, Equatable, Sendable {
    public var bash = true
    /// Read, Edit, MultiEdit, Write, NotebookEdit.
    public var files = true
    public var otherTools = true
    /// Сообщения команды: входящие и SendMessage.
    public var teamMessages = true
    public var tracker = true
    /// Разделитель «контекст сжат».
    public var compacted = true
    /// Строка «12 с · 13:44» в конце хода.
    public var turnDuration = true
    /// Живая строка хода («Stewing… 2 мин») со «Стоп».
    public var turnStatus = true
    /// Черновик ответа «пишет…» из панели.
    public var draft = true

    public init() {}

    private enum Keys: String, CodingKey { case bash, files, otherTools, teamMessages, tracker, compacted, turnDuration, turnStatus, draft }

    /// Недостающие и испорченные поля — «показывать»: скрытое должно быть выбрано явно.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: Keys.self) else { return }
        func flag(_ k: Keys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? true }
        bash = flag(.bash); files = flag(.files); otherTools = flag(.otherTools); teamMessages = flag(.teamMessages)
        tracker = flag(.tracker); compacted = flag(.compacted); turnDuration = flag(.turnDuration)
        turnStatus = flag(.turnStatus); draft = flag(.draft)
    }

    /// Отпечаток набора флагов: смена показа резко меняет высоты ленты, и вид по нему пересоздаёт ленивую ленту.
    public var key: String {
        [bash, files, otherTools, teamMessages, tracker, compacted, turnDuration, turnStatus, draft].map { $0 ? "1" : "0" }.joined()
    }

    public func shows(_ c: FeedCategory) -> Bool {
        switch c {
        case .bash: return bash
        case .files: return files
        case .otherTool: return otherTools
        case .teamMessage: return teamMessages
        case .tracker: return tracker
        case .compacted: return compacted
        case .turnDuration: return turnDuration
        }
    }

    /// Вид инструмента по имени: Bash, чтение и правка файлов, прочие.
    public static func category(ofTool name: String) -> FeedCategory {
        switch name {
        case "Bash": return .bash
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit": return .files
        default: return .otherTool
        }
    }
}
