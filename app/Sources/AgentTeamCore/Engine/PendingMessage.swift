import Foundation

/// Сообщение владельца, отправленное менеджеру, но ещё не записанное в транскрипт. Пока менеджер занят ходом,
/// Claude Code принимает ввод в очередь и пишет его в файл, когда ход его заберёт (секунды, иногда минуты):
/// без этого сообщение в ленте отсутствует. Лента показывает его сразу с отметкой «в очереди».
public struct PendingMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public var text: String
    public var images: [URL]
    public var sentAt: Date
    /// Удержано приложением: менеджер в ходе, в панель сообщение ещё не уходило. Уходит, когда ход кончится.
    public var held = false
    /// Ход прерван («Стоп», Esc): удержанное само не уходит, пока владелец не решит («↑ сейчас», изменить, убрать).
    public var stopped = false

    /// Срок без хода менеджера, после которого сообщение считается не дошедшим.
    public static let deliveryTimeout: TimeInterval = 120

    /// С какого момента менеджер без хода, а сообщения в транскрипте нет. Пока менеджер в ходе (сообщение ждёт
    /// своей очереди), срок не идёт: `nil`.
    var quietSince: Date?

    /// Менеджер свободен дольше срока, а сообщение так и не появилось в транскрипте.
    public func isUndelivered(now: Date = Date()) -> Bool {
        guard !held, let quietSince else { return false }
        return now.timeIntervalSince(quietSince) > Self.deliveryTimeout
    }

    /// Сообщения владельца, уже бывшие в ленте при отправке: «да» из прошлого хода не снимает отметку.
    var seen: Set<String>

    public init(text: String, images: [URL], sentAt: Date = Date(), seen: Set<String> = []) {
        self.id = UUID().uuidString
        self.text = text
        self.images = images
        self.sentAt = sentAt
        self.seen = seen
    }

    /// Похоже на команду Claude Code: текст начинается с «/имени», картинок нет. Такой текст очередь пишет с
    /// осторожностью: следующее ждёт, пока панель не покажет пустую строку ввода (команда может открыть свой экран).
    /// Командой ли он окажется, решает Claude Code: вызов — запись `<command-name>`, экран — `commandScreen`; иначе
    /// («/tmp не чистится») это обычное сообщение владельца.
    public static func looksLikeCommand(_ text: String, images: [URL]) -> Bool {
        images.isEmpty && commandName(text) != nil
    }

    /// Имя команды в начале текста: «/model opus» → «model»; `nil` — текст не начинается с «/имени».
    public static func commandName(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = t.range(of: #"^/[A-Za-z][\w:-]*(?=\s|$)"#, options: .regularExpression) else { return nil }
        return String(t[r].dropFirst())
    }

    /// Пробелы и переводы строк схлопываются, начало ограничено: Claude Code может иначе переносить длинную вставку.
    /// Подписи «[Image #N]» и обёртки pasted_content тоже не считаются: Claude Code подставляет их сам.
    static func normalize(_ s: String) -> String {
        var t = s
        if t.contains("pasted_content") { t = t.replacingOccurrences(of: #"<\\?/?pasted_content[^>]*>"#, with: "", options: .regularExpression) }
        t = t.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
        return String(t.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200))
    }

    /// Запасное сопоставление: новая запись владельца с тем же числом картинок, текст может быть другим.
    func matchesByOrder(_ e: ChatEntry) -> Bool {
        guard !held, case .owner = e.kind, !seen.contains(e.id) else { return false }
        return e.images.count == images.count
    }

    /// Запись транскрипта — это то самое сообщение: новая, от владельца, тот же текст и столько же картинок. Команда
    /// Claude Code («/model opus», скилл, команда плагина) сообщением владельца не пишется — её запись — вызов
    /// `<command-name>` с тем же именем, а у команды, которой Claude Code не знает, — его ответ «Unknown command».
    public func matches(_ e: ChatEntry) -> Bool {
        guard !held, !seen.contains(e.id) else { return false }
        switch e.kind {
        case let .owner(t):
            return Self.normalize(t) == Self.normalize(text) && e.images.count == images.count
        case let .invoked(name, _, _), let .unknownCommand(name, _):
            return images.isEmpty && Self.commandName(text).map { "/" + $0 == name } == true
        default:
            return false
        }
    }

    /// Ожидающие, которым в показанной ленте ещё нет записи. Лента строится из своего читателя транскрипта, и он может
    /// опередить сверку по `ProjectModel.chat`: запись уже на экране, а карточка ещё стоит рядом. Поэтому
    /// карточка показывается, только если среди записей ленты нет той, что ей соответствует (по одной записи на карточку).
    public static func undelivered(_ pending: [PendingMessage], shown entries: [ChatEntry]) -> [PendingMessage] {
        guard !pending.isEmpty else { return [] }
        let owners = entries.suffix(60).filter {
            switch $0.kind {
            case .owner, .invoked, .unknownCommand: return true
            default: return false
            }
        }
        var used: Set<String> = []
        var done: Set<String> = []
        for p in pending {
            if let e = owners.first(where: { !used.contains($0.id) && p.matches($0) }) { used.insert(e.id); done.insert(p.id) }
        }
        for p in pending where !done.contains(p.id) {
            if let e = owners.first(where: { !used.contains($0.id) && p.matchesByOrder($0) }) { used.insert(e.id); done.insert(p.id) }
        }
        return pending.filter { !done.contains($0.id) }
    }
}
