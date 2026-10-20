import Foundation

/// Кто есть кто в ленте менеджера: адрес сессии → имя агента и роль менеджера. Собирается из `team status`.
public struct FeedPeers: Equatable, Sendable {
    /// Адрес сессии → «developer #1». При совпадении адресов берётся первый агент, как в списке status.
    public var names: [String: String]
    public var managerRole: String

    public init(names: [String: String] = [:], managerRole: String = "manager") {
        self.names = names
        self.managerRole = managerRole
    }

    public init(agents: [Agent], managerRole: String) {
        var names: [String: String] = [:]
        for a in agents {
            if let addr = a.addr, names[addr] == nil { names[addr] = a.name.replacingOccurrences(of: "#", with: " #") }
        }
        self.init(names: names, managerRole: managerRole)
    }

    /// Адресат SendMessage: имя агента, неизвестный адрес — как есть.
    public func name(forAddress addr: String) -> String { names[addr] ?? addr }

    /// Отправитель входящего: имя агента по адресу, иначе имя из сообщения, иначе адрес.
    public func sender(name: String, addr: String) -> String { names[addr] ?? (name.isEmpty ? addr : name) }
}

/// Строка блока действий в ленте менеджера.
public struct ManagerActionLine: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case send, tracker, tool, question }
    public var id: String
    public var kind: Kind
    public var title: String
    public var quote: String?
    /// По какому переключателю «Что показывать» строка скрывается; `nil` — видна всегда (вопрос менеджера владельцу).
    public var category: FeedCategory?

    public init(id: String, kind: Kind, title: String, quote: String?, category: FeedCategory?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.quote = quote
        self.category = category
    }
}

/// Элемент ленты чата менеджера.
public enum ManagerFeedItem: Identifiable, Equatable, Sendable {
    case owner(ChatEntry, String)
    case actions(String, [ManagerActionLine])
    case reply(ChatEntry, String, showWho: Bool)
    /// Входящее: отправитель, получатель (роль менеджера), текст.
    case incoming(ChatEntry, from: String, to: String, String)
    case turnEnd(ChatEntry, Int)
    case compacted(ChatEntry)
    /// Вывод встроенной команды Claude Code: имя команды и текст.
    case command(ChatEntry, name: String, String)
    /// Вызов скилла или команды плагина: строка «/имя аргументы».
    case commandCall(ChatEntry, String)
    /// Отправлено, в транскрипте ещё нет.
    case queued(PendingMessage)
    /// Ответ, который менеджер пишет: текст с экрана панели, в транскрипте его ещё нет.
    case live(LiveReply)

    public var id: String {
        switch self {
        case .live: return "live-reply"
        case let .queued(p): return "pending-" + p.id
        case let .owner(e, _), let .reply(e, _, _), let .incoming(e, _, _, _), let .turnEnd(e, _), let .compacted(e),
             let .command(e, _, _), let .commandCall(e, _): return e.id
        case let .actions(id, _): return "act-" + id
        }
    }
}

/// Лента менеджера по отрезкам `ThreadFeed`: группировка отрезка не зависит от соседних (отрезок начинается с записи,
/// на которой группировка начинается заново, или с начала подгруженной страницы), поэтому при новом в конце транскрипта пересчитывается только последний
/// отрезок, а не вся загруженная сессия. Отрезок узнаётся по номеру сборки: пересобранный отрезок — новый номер.
public final class ManagerFeedCache {
    private var byBuild: [Int: [ManagerFeedItem]] = [:]
    private var peers: FeedPeers?
    /// Сколько отрезков сгруппировано заново (для замеров и тестов).
    public private(set) var regrouped = 0

    public init() {}

    public func items(_ segments: [ThreadSegment], peers: FeedPeers) -> [ManagerFeedItem] {
        if peers != self.peers {
            byBuild = [:]
            self.peers = peers
        }
        var fresh: [Int: [ManagerFeedItem]] = [:]
        var out: [ManagerFeedItem] = []
        for s in segments {
            let items: [ManagerFeedItem]
            if let cached = byBuild[s.build] {
                items = cached
            } else {
                items = FeedGrouping.manager(s.entries, peers: peers)
                regrouped += 1
            }
            fresh[s.build] = items
            out += items
        }
        byBuild = fresh
        return out
    }
}

/// Группировка лент для показа. У ленты менеджера и ленты агента общий порядок блоков и общий фильтр «Что показывать»,
/// но разный вид сообщений команды: у менеджера SendMessage — строка действия с цитатой, а вопрос владельцу
/// (`AskUserQuestion`) — отдельная строка, видимая всегда; у агента SendMessage — карточка.
public enum FeedGrouping {
    // MARK: лента менеджера

    /// Записи транскрипта менеджера, сгруппированные для показа с учётом набора показа.
    public static func manager(_ entries: [ChatEntry], peers: FeedPeers, visibility v: FeedVisibility) -> [ManagerFeedItem] {
        visible(manager(entries, peers: peers), v)
    }

    /// Записи транскрипта менеджера, сгруппированные для показа, без фильтра. Подряд идущие инструменты — блок действий,
    /// повторы одного инструмента — «×N», подряд идущие обращения к трекеру — одна строка.
    public static func manager(_ entries: [ChatEntry], peers: FeedPeers) -> [ManagerFeedItem] {
        var out: [ManagerFeedItem] = []
        var pending: [ChatEntry] = []
        var replyOpen = false

        func flush() {
            guard let first = pending.first else { return }
            let lines = managerActions(pending, peers: peers)
            if !lines.isEmpty { out.append(.actions(first.id, lines)) }
            pending = []
        }

        for e in entries {
            switch e.kind {
            case .sendMessage, .tracker, .tool:
                pending.append(e)
            case let .owner(t):
                flush()
                out.append(.owner(e, t))
                replyOpen = false
            case let .reply(t):
                flush()
                out.append(.reply(e, t, showWho: !replyOpen))
                replyOpen = true
            case let .incoming(name, addr, text):
                flush()
                out.append(.incoming(e, from: peers.sender(name: name, addr: addr), to: peers.managerRole, text))
                replyOpen = false
            case let .turnEnd(ms):
                flush()
                out.append(.turnEnd(e, ms))
                replyOpen = false
            case .compacted:
                flush()
                out.append(.compacted(e))
                replyOpen = false
            case let .command(name, output):
                flush()
                out.append(.command(e, name: name, output))
                replyOpen = false
            case let .unknownCommand(name, suggestion):
                flush()
                out.append(.command(e, name: name, unknownCommandText(name, suggestion: suggestion)))
                replyOpen = false
            case let .invoked(name, args, prompt):
                guard prompt else { continue }
                flush()
                out.append(.commandCall(e, commandCallText(name, args: args)))
                replyOpen = false
            }
        }
        flush()
        return out
    }

    /// Ответ Claude Code на незнакомую команду — по-русски, с его подсказкой, если она есть.
    public static func unknownCommandText(_ name: String, suggestion: String?) -> String {
        "Claude Code не знает команду \(name)" + (suggestion.map { ". Возможно, имелась в виду \($0)" } ?? "")
    }

    /// «/имя аргументы»: аргументы — одной строкой.
    public static func commandCallText(_ name: String, args: String) -> String {
        let a = args.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? name : name + " " + a
    }

    static func managerActions(_ pending: [ChatEntry], peers: FeedPeers) -> [ManagerActionLine] {
        var lines: [ManagerActionLine] = []
        var i = 0
        while i < pending.count {
            let e = pending[i]
            switch e.kind {
            case let .sendMessage(to, text):
                lines.append(ManagerActionLine(id: e.id, kind: .send, title: "→ \(peers.name(forAddress: to)) · SendMessage",
                                               quote: "«" + text.replacingOccurrences(of: "\n", with: " ") + "»", category: .teamMessage))
                i += 1
            case .tracker:
                let (line, next) = trackerLine(pending, from: i)
                lines.append(ManagerActionLine(id: e.id, kind: .tracker, title: line, quote: nil, category: .tracker))
                i = next
            case let .tool(name, summary) where name == "AskUserQuestion":
                lines.append(ManagerActionLine(id: e.id, kind: .question, title: "вопрос менеджера", quote: summary.isEmpty ? nil : summary, category: nil))
                i += 1
            case .tool:
                let (title, tool, next) = toolLine(pending, from: i)
                lines.append(ManagerActionLine(id: e.id, kind: .tool, title: title, quote: nil, category: FeedVisibility.category(ofTool: tool)))
                i = next
            default:
                i += 1
            }
        }
        return lines
    }

    /// Элементы ленты менеджера с учётом набора показа: скрытые строки действий убираются, блок без строк исчезает целиком,
    /// скрытые сообщения команды, «контекст сжат» и конец хода — тоже. Пустых промежутков не остаётся.
    public static func visible(_ items: [ManagerFeedItem], _ v: FeedVisibility) -> [ManagerFeedItem] {
        guard v != FeedVisibility() else { return items }
        var out: [ManagerFeedItem] = []
        for item in items {
            switch item {
            case let .actions(id, lines):
                if let kept = kept(lines, v, category: \.category) { out.append(kept.count == lines.count ? item : .actions(id, kept)) }
            case .incoming:
                if v.teamMessages { out.append(item) }
            case .compacted:
                if v.compacted { out.append(item) }
            case .turnEnd:
                if v.turnDuration { out.append(item) }
            case .owner, .reply, .queued, .live, .command, .commandCall:
                out.append(item)
            }
        }
        return out
    }

    /// Хвост ленты менеджера: черновик «пишет…» и отправленное, которого ещё нет среди показанных записей. В ленте он
    /// идёт отдельной секцией после основных элементов, чтобы черновик, меняющийся на каждом захвате панели, не давал
    /// ленте новый массив на все строки. Карточка не стоит рядом с уже показанной записью: сверка идёт по самой ленте —
    /// `owners` — отправленное владельцем среди показанных элементов (`owners(_:)`).
    public static func tail(owners: [ChatEntry], pending: [PendingMessage], live: LiveReply?) -> [ManagerFeedItem] {
        var out: [ManagerFeedItem] = []
        if let live { out.append(.live(live)) }
        if !pending.isEmpty { out += PendingMessage.undelivered(pending, shown: owners).map { .queued($0) } }
        return out
    }

    /// Отправленное владельцем среди показанных элементов (сообщения и команды): с ним сверяется очередь.
    public static func owners(_ base: [ManagerFeedItem]) -> [ChatEntry] {
        base.compactMap { item -> ChatEntry? in
            switch item {
            case let .owner(e, _), let .command(e, _, _), let .commandCall(e, _): return e
            default: return nil
            }
        }
    }

    // MARK: лента агента

    /// Записи транскрипта агента, сгруппированные для показа.
    public static func agent(_ entries: [ChatEntry]) -> [ThreadItem] { ThreadGrouping.items(entries) }

    /// Элементы ленты агента с учётом набора показа.
    public static func visible(_ items: [ThreadItem], _ v: FeedVisibility) -> [ThreadItem] { ThreadGrouping.visible(items, v) }

    // MARK: общее

    /// Строки блока, которые остаются видимыми; `nil` — не осталось ни одной, блок исчезает.
    static func kept<L>(_ lines: [L], _ v: FeedVisibility, category: (L) -> FeedCategory?) -> [L]? {
        let shown = lines.filter { category($0).map(v.shows) ?? true }
        return shown.isEmpty ? nil : shown
    }

    /// Подряд идущие обращения к трекеру с позиции `i` — одна строка: «трекер · действие» или «трекер · N запросов · …»
    /// и последняя непустая суть. Возвращает заголовок и позицию за последним обращением.
    static func trackerLine(_ entries: [ChatEntry], from i: Int) -> (String, Int) {
        var j = i
        var actions: [String] = []
        var subject = ""
        while j < entries.count, case let .tracker(a, s) = entries[j].kind {
            if !actions.contains(a) { actions.append(a) }
            if !s.isEmpty { subject = s }
            j += 1
        }
        let n = j - i
        let title = "трекер · " + (n == 1 ? actions[0] : "\(n) \(requestsWord(n)) · " + actions.prefix(3).joined(separator: ", "))
        return (title + (subject.isEmpty ? "" : " · " + subject), j)
    }

    /// Подряд идущие вызовы одного инструмента с позиции `i` — одна строка «Имя ×N · последняя непустая суть».
    /// Возвращает заголовок, имя инструмента и позицию за последним вызовом.
    static func toolLine(_ entries: [ChatEntry], from i: Int) -> (String, String, Int) {
        guard case let .tool(name, summary) = entries[i].kind else { return ("", "", i + 1) }
        var j = i + 1
        var last = summary
        while j < entries.count, case let .tool(n2, s2) = entries[j].kind, n2 == name {
            if !s2.isEmpty { last = s2 }
            j += 1
        }
        let n = j - i
        return (name + (n > 1 ? " ×\(n)" : "") + (last.isEmpty ? "" : " · " + last), name, j)
    }

    /// «запрос», «запроса», «запросов».
    static func requestsWord(_ n: Int) -> String { RussianPlural.word(n, "запрос", "запроса", "запросов") }
}
