import Foundation
import Observation

// MARK: лента по отрезкам

/// Отрезок ленты: от точки сброса (задача, ввод, конец хода) или от начала подгруженной страницы до следующей.
/// Группировка отрезка не зависит от предыдущих, поэтому при новом в транскрипте пересчитывается только последний
/// отрезок, а подгрузка начала не трогает показанные.
public struct ThreadSegment: Identifiable, Equatable, Sendable {
    public var id: String
    public var entries: [ChatEntry]
    /// Элементы показа этого отрезка (группировка ленты агента); у ленты менеджера пусты — она группирует отрезок по
    /// своим правилам (`FeedGrouping.manager`).
    public var items: [ThreadItem]
    /// Номер сборки отрезка: новый у каждого пересобранного отрезка. По нему ленты кешируют свою группировку отрезка.
    public let build: Int

    init(entries: [ChatEntry], grouped: Bool = true) {
        id = entries.first?.id ?? ""
        self.entries = entries
        items = grouped ? ThreadGrouping.items(entries) : []
        build = Self.counter.next()
    }

    private static let counter = BuildCounter()

    /// Отрезки равны по содержимому; номер сборки — не содержимое.
    public static func == (a: ThreadSegment, b: ThreadSegment) -> Bool { a.id == b.id && a.entries == b.entries && a.items == b.items }
}

/// Счётчик сборок отрезков: отрезки собираются и на главном потоке, и в тестах на других.
final class BuildCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Лента агента: записи по отрезкам и плоский список элементов для `LazyVStack`. Новое в конце и догруженное
/// начало пересобирают только крайние отрезки и заменяют их элементы на месте.
public struct ThreadFeed: Equatable, Sendable {
    public private(set) var segments: [ThreadSegment] = []
    public private(set) var items: [ThreadItem] = []
    /// Все записи подряд. Хранятся, а не собираются из отрезков: ленту менеджера читают несколько потребителей
    /// на каждое обновление (сверка очереди, история ввода, черновик).
    public private(set) var entries: [ChatEntry] = []
    public var count: Int { entries.count }
    /// Считать ли группировку ленты агента (`items`): лента менеджера её не показывает.
    public let grouped: Bool

    public init(_ entries: [ChatEntry] = [], grouped: Bool = true) {
        self.grouped = grouped
        segments = Self.split(entries, grouped: grouped)
        items = segments.flatMap(\.items)
        self.entries = entries
    }

    /// Записи, перед которыми группировка начинается заново: незакрытые действия сбрасываются, подпись
    /// автора ответа показывается снова.
    public static func isBoundary(_ kind: ChatKind) -> Bool {
        switch kind {
        case .owner, .incoming, .turnEnd, .compacted, .command, .unknownCommand: return true
        case let .invoked(_, _, prompt): return prompt
        case .sendMessage, .tracker, .tool, .reply: return false
        }
    }

    public static func split(_ entries: [ChatEntry], grouped: Bool = true) -> [ThreadSegment] {
        var groups: [[ChatEntry]] = []
        for e in entries {
            if groups.isEmpty || isBoundary(e.kind) { groups.append([e]) } else { groups[groups.count - 1].append(e) }
        }
        return groups.map { ThreadSegment(entries: $0, grouped: grouped) }
    }

    /// Записи с позиции `index` (во всей ленте) заменяются на `tail`. Пересчитываются только отрезки,
    /// начиная с того, в котором лежит `index`.
    public mutating func replaceTail(from index: Int, with tail: [ChatEntry]) {
        let index = min(max(index, 0), count)
        let count = self.count
        var k = segments.count
        var start = count
        var dropItems = 0
        // Отрезок, в котором лежит запись перед `index`: новая запись может продолжать его, а не начинать свой.
        while k > 0, start > index || (start == index && index > 0) {
            k -= 1
            start -= segments[k].entries.count
            dropItems += segments[k].items.count
        }
        var head: [ChatEntry] = []
        if k < segments.count { head = Array(segments[k].entries.prefix(index - start)) }
        let fresh = Self.split(head + tail, grouped: grouped)
        segments.replaceSubrange(k..., with: fresh)
        items.replaceSubrange((items.count - dropItems)..., with: fresh.flatMap(\.items))
        entries.replaceSubrange(index..., with: tail)
    }

    /// Более ранние записи — в начало, своими отрезками. Уже показанные отрезки и их элементы не меняются: граница
    /// страницы — тоже начало отрезка. Иначе ранний ответ того же отрезка снимал бы подпись автора у показанного
    /// ответа, а ранние действия сливались бы с показанным блоком действий (у блока другой id и высота), и строка, которую
    /// владелец читает, уезжала бы на изменение высоты. Цена — на стыке страниц подпись автора может повториться, а блок
    /// действий — стоять двумя. Возвращает id прежнего первого элемента: он остаётся в ленте.
    @discardableResult
    public mutating func prepend(_ earlier: [ChatEntry]) -> String? {
        let oldFirst = items.first?.id
        guard !earlier.isEmpty else { return oldFirst }
        let fresh = Self.split(earlier, grouped: grouped)
        segments.insert(contentsOf: fresh, at: 0)
        items.insert(contentsOf: fresh.flatMap(\.items), at: 0)
        entries.insert(contentsOf: earlier, at: 0)
        return oldFirst
    }
}

// MARK: группировка для показа

/// Строка действия: обращение к трекеру или прочий инструмент.
public struct ThreadAction: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case tracker, tool }
    public var id: String
    public var kind: Kind
    public var title: String
    /// Имя инструмента (для `.tool`): по нему строка относится к Bash, файлам или прочим.
    public var tool: String?

    public var category: FeedCategory {
        kind == .tracker ? .tracker : FeedVisibility.category(ofTool: tool ?? "")
    }
}

public enum ThreadItem: Identifiable, Equatable, Sendable {
    /// Ввод в панель агента (первая инструкция, вставка team send, набранное вручную).
    case input(ChatEntry, String)
    /// Сообщение команды агенту: имя отправителя (или адрес), адрес и текст.
    case incoming(ChatEntry, from: String, addr: String, String)
    /// Сообщение агента команде через SendMessage: адресат (адрес или имя) и текст.
    case send(ChatEntry, to: String, String)
    case actions(String, [ThreadAction])
    case reply(ChatEntry, String, showWho: Bool)
    case turnEnd(ChatEntry, Int)
    case compacted(ChatEntry)
    /// Вывод встроенной команды Claude Code: имя команды и текст.
    case command(ChatEntry, name: String, String)
    /// Вызов скилла или команды плагина: строка «/имя аргументы».
    case commandCall(ChatEntry, String)

    public var id: String {
        switch self {
        case let .input(e, _), let .reply(e, _, _), let .incoming(e, _, _, _), let .send(e, _, _), let .turnEnd(e, _), let .compacted(e),
             let .command(e, _, _), let .commandCall(e, _): return e.id
        case let .actions(id, _): return "act-" + id
        }
    }
}

/// Группировка ленты: подряд идущие инструменты — компактный блок, повторы одного инструмента — «×N».
/// Сообщения команды (входящие и SendMessage) стоят отдельно: по ним видно, кто кому что поручил.
public enum ThreadGrouping {
    public static func items(_ entries: [ChatEntry]) -> [ThreadItem] {
        var out: [ThreadItem] = []
        var pending: [ChatEntry] = []
        var replyOpen = false

        func flush() {
            guard let first = pending.first else { return }
            out.append(.actions(first.id, actions(pending)))
            pending = []
        }

        for e in entries {
            switch e.kind {
            case .tracker, .tool:
                pending.append(e)
            case let .sendMessage(to, text):
                flush()
                out.append(.send(e, to: to, text))
                replyOpen = false
            case let .owner(t):
                flush()
                out.append(.input(e, t))
                replyOpen = false
            case let .reply(t):
                flush()
                out.append(.reply(e, t, showWho: !replyOpen))
                replyOpen = true
            case let .incoming(from, addr, text):
                flush()
                out.append(.incoming(e, from: from, addr: addr, text))
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
                out.append(.command(e, name: name, FeedGrouping.unknownCommandText(name, suggestion: suggestion)))
                replyOpen = false
            case let .invoked(name, args, prompt):
                guard prompt else { continue }
                flush()
                out.append(.commandCall(e, FeedGrouping.commandCallText(name, args: args)))
                replyOpen = false
            }
        }
        flush()
        return out
    }

    /// Элементы ленты с учётом настройки показа: скрытые строки действий убираются, блок без строк исчезает целиком,
    /// скрытые сообщения команды, «контекст сжат» и строка хода — тоже. Пустых промежутков не остаётся.
    public static func visible(_ items: [ThreadItem], _ v: FeedVisibility) -> [ThreadItem] {
        guard v != FeedVisibility() else { return items }
        var out: [ThreadItem] = []
        for item in items {
            switch item {
            case .incoming, .send:
                if v.teamMessages { out.append(item) }
            case .compacted:
                if v.compacted { out.append(item) }
            case .turnEnd:
                if v.turnDuration { out.append(item) }
            case let .actions(id, lines):
                if let kept = FeedGrouping.kept(lines, v, category: \.category) { out.append(kept.count == lines.count ? item : .actions(id, kept)) }
            case .input, .reply, .command, .commandCall:
                out.append(item)
            }
        }
        return out
    }

    static func actions(_ pending: [ChatEntry]) -> [ThreadAction] {
        var lines: [ThreadAction] = []
        var i = 0
        while i < pending.count {
            let e = pending[i]
            switch e.kind {
            case .tracker:
                let (title, next) = FeedGrouping.trackerLine(pending, from: i)
                lines.append(ThreadAction(id: e.id, kind: .tracker, title: title))
                i = next
            case .tool:
                let (title, tool, next) = FeedGrouping.toolLine(pending, from: i)
                lines.append(ThreadAction(id: e.id, kind: .tool, title: title, tool: tool))
                i = next
            default:
                i += 1
            }
        }
        return lines
    }
}

// MARK: модель ленты агента

/// Лента агента из его транскрипта. Транскрипт читается, только пока модель запущена: экран открыт.
/// Разбор идёт на очереди наблюдателя; на главный поток приходят готовые записи.
@MainActor
@Observable
public final class AgentThreadModel {
    public enum Phase: Equatable, Sendable {
        case idle
        /// В status у агента нет session_id.
        case noSession
        /// Файла транскрипта ещё нет.
        case waiting
        case ready
    }

    public private(set) var phase: Phase = .idle
    public private(set) var feed: ThreadFeed
    /// Лента агента группирует записи для показа (`ThreadFeed.items`); лента менеджера — нет, у неё своя группировка.
    public let groupsItems: Bool
    public private(set) var hasEarlier = false
    public private(set) var loadingEarlier = false
    /// Растёт, когда меняются записи в конце транскрипта (не при догрузке начала и не при смене одного лишь хода
    /// или контекста): по ней лента кеширует группировку и решает, пришло ли новое.
    public private(set) var liveRevision = 0
    /// Сколько записей добавило последнее живое обновление: одна — обычное следование за новым, больше — пачка
    /// (так приходит накопленное, пока приложение было в фоне).
    @ObservationIgnored public private(set) var lastLiveAppended = 0
    /// Ревизия растёт с каждой догрузкой начала (место прокрутки держит FeedScroller по своей закреплённой строке).
    public private(set) var prependRevision = 0
    /// Модель и заполнение контекста по последнему ответу и идёт ли ход — по живому куску (первая страница и дописанное).
    public private(set) var usage: UsageInfo?
    public private(set) var turnInProgress = false
    /// Вопрос `AskUserQuestion` без ответа в живом куске транскрипта (`OpenQuestionSource`).
    public private(set) var openQuestion: PendingQuestion?
    /// Сессия, файл которой читается сейчас: после `continued-in` — продолжение, а не сессия запуска.
    public private(set) var sessionID: String?

    /// Вызывается после каждого изменения живого куска (новые записи, ход, контекст) — не после догрузки начала.
    @ObservationIgnored public var onLiveUpdate: (() -> Void)?

    /// Сколько записей держать на экране сразу после открытия: если последняя страница дала меньше,
    /// догружаются более ранние.
    public var minimumInitialEntries = 24

    @ObservationIgnored private var follower: TranscriptFollower?
    @ObservationIgnored private var generation = 0
    /// Записи до начала живого куска: позиция живого куска во всей ленте.
    @ObservationIgnored private var historyCount = 0

    /// `groupsItems: false` — лента менеджера: группировка агента ей не нужна.
    public init(groupsItems: Bool = true) {
        self.groupsItems = groupsItems
        feed = ThreadFeed(grouped: groupsItems)
    }

    /// Замер (проверочный запуск): сколько раз запускалась модель и за сколько после запуска пришли первые записи.
    nonisolated(unsafe) public static var benchStarts = 0
    nonisolated(unsafe) public static var benchFirstData: [Double] = []
    /// Стенд истории: ранняя страница пришла, лента ещё не изменилась (кадр «до» пробы по кадру). В обычной работе пуст.
    nonisolated(unsafe) public static var benchWillPrepend: (@MainActor (AgentThreadModel) -> Void)?
    /// Замер пишется только в проверочном запуске: в обычной работе список рос бы с каждым запуском модели.
    static let benchRecording = AppDefaults.isProbeRun(CommandLine.arguments)
    @ObservationIgnored private var benchStartedAt: Double?

    public var isRunning: Bool { follower != nil }

    /// Каталог и сессии цепочки, которые уже привели к читаемому файлу: повторный запуск с любой из них не нужен.
    @ObservationIgnored private var startedCWD: String?
    @ObservationIgnored private var chain: Set<String> = []
    @ObservationIgnored private var home = TranscriptParser.claudeHome
    @ObservationIgnored private var pageBytes: UInt64 = 256 << 10
    @ObservationIgnored private var firstPageBytes: UInt64?

    /// Запускает чтение, если оно ещё не идёт для этой сессии. Повторный вызов для той же сессии (или для другой сессии
    /// той же цепочки `continued-in`) ничего не делает: модель, пережившая сворачивание панели, не читает транскрипт
    /// заново и сразу показывает готовую ленту.
    public func ensureStarted(sessionID: String?, cwd: String?, home: String = TranscriptParser.claudeHome,
                              firstPageBytes: UInt64? = nil) {
        if isRunning, cwd == startedCWD, let sessionID, chain.contains(sessionID) { return }
        start(sessionID: sessionID, cwd: cwd, home: home, firstPageBytes: firstPageBytes)
    }

    /// Читает ли модель файл, к которому ведёт эта сессия (та же или звено той же цепочки).
    public func follows(sessionID: String) -> Bool { isRunning && chain.contains(sessionID) }

    public func start(sessionID: String?, cwd: String?, home: String = TranscriptParser.claudeHome, pageBytes: UInt64 = 256 << 10,
                      firstPageBytes: UInt64? = nil) {
        stop()
        startedCWD = cwd
        self.home = home
        guard let sessionID, !sessionID.isEmpty else {
            phase = .noSession
            return
        }
        let url = TranscriptParser.locate(cwd: cwd, sessionID: sessionID, home: home)
            ?? cwd.map { TranscriptParser.transcriptURL(cwd: $0, sessionID: sessionID, home: home) }
        guard let url else {
            phase = .waiting
            return
        }
        start(url: url, pageBytes: pageBytes, firstPageBytes: firstPageBytes)
        chain.insert(sessionID)
    }

    /// `firstPageBytes` — первая страница с конца файла, если она должна быть больше остальных.
    public func start(url: URL, pageBytes: UInt64 = 256 << 10, firstPageBytes: UInt64? = nil) {
        stop()
        self.pageBytes = pageBytes
        self.firstPageBytes = firstPageBytes
        let sid = url.deletingPathExtension().lastPathComponent
        sessionID = sid
        chain = [sid]
        generation += 1
        let gen = generation
        Self.benchStarts += 1
        benchStartedAt = Self.benchRecording ? ProcessInfo.processInfo.systemUptime : nil
        let f = TranscriptFollower(url: url, pageBytes: pageBytes, firstPageBytes: firstPageBytes)
        let parsing = ThreadParsing()
        follower = f
        f.start { [weak self] event in
            let updates = parsing.handle(event)
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for update in updates {
                        guard let self, self.generation == gen else { return }
                        self.apply(update)
                    }
                }
            }
        }
    }

    /// Claude Code продолжил сессию в новом файле (`/clear`, продолжение после сжатия): запись `continued-in` в конце
    /// старого. Лента переходит на новый файл; сессии цепочки запоминаются, чтобы `ensureStarted` со старой сессией
    /// (её ещё помнит status) не вернул ленту назад.
    private func continueIn(_ next: String) {
        guard !chain.contains(next) else { return }
        guard let url = TranscriptParser.locate(cwd: startedCWD, sessionID: next, home: home)
                ?? startedCWD.map({ TranscriptParser.transcriptURL(cwd: $0, sessionID: next, home: home) }) else { return }
        let known = chain
        let wasPaused = paused
        start(url: url, pageBytes: pageBytes, firstPageBytes: firstPageBytes)
        chain.formUnion(known)
        if wasPaused { suspend() }
    }

    /// Снимает наблюдение. После возврата модель больше не меняется.
    public func stop() {
        generation += 1
        chain = []
        follower?.stop()
        follower = nil
        paused = false
        loadingEarlier = false
    }

    /// Пауза чтения (проект ушёл с экрана): лента остаётся, новые записи придут после `resume()`.
    public func suspend() {
        guard let follower, !paused else { return }
        paused = true
        follower.suspend()
        loadingEarlier = false
    }

    public func resume() {
        guard let follower, paused else { return }
        paused = false
        follower.resume()
    }

    public var isSuspended: Bool { paused }
    @ObservationIgnored private var paused = false

    public func loadEarlier() {
        guard let follower, !paused, hasEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        follower.loadEarlier()
    }

    /// Есть ли запись с таким id среди загруженных.
    public func contains(entryID id: String) -> Bool {
        feed.segments.contains { $0.entries.contains { $0.id == id } }
    }

    /// Подгружает страницы начала, пока запись не окажется в ленте. `false` — записи нет во всей сессии
    /// (начало достигнуто) или чтение остановлено. Страницы идут по одной: каждая ждёт предыдущую.
    public func loadEarlier(until id: String, pageTimeout: TimeInterval = 5) async -> Bool {
        let gen = generation
        while !contains(entryID: id) {
            guard isRunning, generation == gen, hasEarlier else { return false }
            let before = prependRevision
            loadEarlier()
            let deadline = Date().addingTimeInterval(pageTimeout)
            while prependRevision == before, isRunning, generation == gen, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            if prependRevision == before { return contains(entryID: id) }
        }
        return true
    }

    private func apply(_ u: ThreadParsing.Update) {
        switch u {
        case .waiting:
            phase = .waiting
            feed = ThreadFeed(grouped: groupsItems)
            historyCount = 0
            hasEarlier = false
            usage = nil
            turnInProgress = false
            openQuestion = nil
            onLiveUpdate?()
        case let .reset(entries, earlier, state):
            if let t = benchStartedAt { Self.benchFirstData.append((ProcessInfo.processInfo.systemUptime - t) * 1000); benchStartedAt = nil }
            phase = .ready
            feed = ThreadFeed(entries, grouped: groupsItems)
            historyCount = 0
            hasEarlier = earlier
            loadingEarlier = false
            apply(state)
            liveRevision += 1
            onLiveUpdate?()
        case let .live(from, tail, state):
            if let from {
                let before = feed.count
                feed.replaceTail(from: historyCount + from, with: tail)
                lastLiveAppended = max(0, feed.count - before)
                liveRevision += 1
            }
            apply(state)
            onLiveUpdate?()
        case let .continued(next):
            continueIn(next)
            return
        case let .earlier(entries, earlier):
            Self.benchWillPrepend?(self)
            feed.prepend(entries)
            historyCount += entries.count
            hasEarlier = earlier
            loadingEarlier = false
            prependRevision += 1
        }
        if hasEarlier, !loadingEarlier, feed.count < minimumInitialEntries { loadEarlier() }
    }

    private func apply(_ state: ThreadParsing.LiveState) {
        if usage != state.usage { usage = state.usage }
        if turnInProgress != state.busy { turnInProgress = state.busy }
        if openQuestion != state.question { openQuestion = state.question }
    }
}

extension AgentThreadModel: OpenQuestionSource {}

/// Разбор событий наблюдателя на его очереди: живой кусок ведёт один парсер, каждая ранняя страница — свой.
final class ThreadParsing: @unchecked Sendable {
    /// Состояние живого куска: контекст по последнему ответу и идёт ли ход.
    struct LiveState: Equatable, Sendable {
        var usage: UsageInfo?
        var busy: Bool
        var question: PendingQuestion?
    }

    enum Update: Sendable {
        case waiting
        case reset([ChatEntry], hasEarlier: Bool, LiveState)
        /// Записи живого куска с позиции `from` заменены на `tail`; `from == nil` — записи те же, сменилось состояние
        /// (например, прерывание закончило ход, не добавив записи).
        case live(from: Int?, tail: [ChatEntry], LiveState)
        case earlier([ChatEntry], hasEarlier: Bool)
        /// В конец файла записан переход в другую сессию.
        case continued(String)
    }

    private var live = ThreadParsing.parser()
    private var emitted: [ChatEntry] = []
    private var emittedState = LiveState(usage: nil, busy: false)

    private var state: LiveState { LiveState(usage: live.usage, busy: live.turnInProgress, question: live.openQuestion) }

    private static func parser() -> TranscriptParser {
        var p = TranscriptParser()
        p.maxEntries = .max      // лента агента — вся сессия
        return p
    }

    func handle(_ event: TranscriptFollower.Event) -> [Update] {
        switch event {
        case .waiting:
            live = Self.parser()
            emitted = []
            emittedState = state
            return [.waiting]
        case let .opened(lines, hasEarlier):
            live = Self.parser()
            live.feed(lines: lines.map { Substring($0) })
            _ = live.takeChangedFrom()
            emitted = live.entries
            emittedState = state
            return [.reset(emitted, hasEarlier: hasEarlier, emittedState)]
        case let .appended(lines):
            live.feed(lines: lines.map { Substring($0) })
            let now = live.entries
            // Разбор меняет не только конец: соседние блоки ответа склеиваются в последнюю запись. Сверка идёт с самой
            // ранней записи, которую разбор тронул, а не с начала ленты: каждая строка транскрипта не сравнивает всю сессию.
            var from = min(live.takeChangedFrom() ?? now.count, emitted.count)
            while from < min(now.count, emitted.count), now[from] == emitted[from] { from += 1 }
            let changed = from < now.count || now.count != emitted.count
            var out: [Update] = []
            if changed || state != emittedState {
                emitted = now
                emittedState = state
                out.append(.live(from: changed ? from : nil, tail: changed ? Array(now[from...]) : [], emittedState))
            }
            if let next = Self.continuation(in: lines) { out.append(.continued(next)) }
            return out
        case let .earlier(lines, hasEarlier):
            var p = Self.parser()
            p.feed(lines: lines.map { Substring($0) })
            return [.earlier(p.entries, hasEarlier: hasEarlier)]
        }
    }

    /// Сессия из записи `continued-in` среди дописанных строк.
    static func continuation(in lines: [String]) -> String? {
        for line in lines.reversed() where line.hasPrefix(#"{"type":"continued-in""#) {
            if let r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
               let id = r["continuedInSessionId"] as? String, !id.isEmpty { return id }
        }
        return nil
    }
}

// MARK: следование за концом

/// Следует ли лента за концом: решается положением, а не тем, как владелец туда попал. Низ виден (расстояние
/// до конца в пределах допуска) — лента следует; не виден — не следует, а новое копится под кнопкой «Новые ↓».
public struct ThreadFollow: Equatable, Sendable {
    public static let tolerance: CGFloat = 32

    public private(set) var follows = true
    public private(set) var unseen = false

    public init() {}

    /// Положение прокрутки изменилось (колесо, ползунок, клавиши, тачпад, прокрутка из кода).
    public mutating func scrolled(distanceFromBottom d: CGFloat) {
        follows = d <= Self.tolerance
        if follows { unseen = false }
    }

    /// Сдвиг при неизменной высоте содержимого. `end` — расстояние до конца, до которого лента стоит в конце (нижний
    /// отступ ленты и полпикселя округления окна прокрутки); `byOwner` — сдвиг сделал владелец (колесо, трекпад,
    /// перетаскивание, клавиши).
    /// - Владелец сдвинул ленту прочь от конца — следование снимается сразу, на любом расстоянии: допуск у конца шагу
    ///   владельца вверх не помеха. Иначе медленный трекпад (несколько пунктов за событие) оставался бы в допуске,
    ///   и каждый рост содержимого во время хода возвращал бы ленту в конец. Порог — меньше пикселя: самый медленный
    ///   трекпад на Retina сдвигает ленту на 0,5 pt за событие, а шум раскладки сюда не попадает — он без ввода.
    /// - Идущая к концу прокрутка (наша, плавная) следование не снимает, даже пока до конца ещё дальше допуска.
    /// - Лента, которая не следует, в допуске выше конца сама следовать не начинает (раскладка, успокоение после роста):
    ///   только движением к концу или встав в конец. Иначе шаг владельца вверх в пределах допуска отменялся бы
    ///   следующим ростом.
    public mutating func scrolled(distanceFromBottom d: CGFloat, from previous: CGFloat, byOwner: Bool = false, end: CGFloat = 0) {
        if byOwner, d > previous + 0.1, d > end { follows = false; return }
        if follows, d > Self.tolerance, d <= previous + 1 { return }
        if !follows, d > end, d >= previous - 0.1 { return }
        scrolled(distanceFromBottom: d)
    }

    /// Сдвиг границ при неизменной высоте, который лента принимает за раскладку, а не за владельца: ушёл от конца сразу
    /// после роста (SwiftUI сам переставляет границы: якорь, подгрузка сверху) и без недавнего ввода владельца.
    /// Ввод владельца (колесо, перетаскивание, клавиши) всегда решает: иначе при событиях чаще, чем раз в окно роста,
    /// жест вверх попадал бы в окно, следование не снималось и лента возвращала читающего к концу.
    public static func isLayoutShift(distance d: CGFloat, previous p: CGFloat, sinceGrowth: TimeInterval, sinceUserInput: TimeInterval) -> Bool {
        d > p + 1 && sinceGrowth < growthWindow && sinceUserInput > userInputWindow
    }

    public static let growthWindow: TimeInterval = 0.3
    public static let userInputWindow: TimeInterval = 0.4
    /// Живая прокрутка AppKit, которая столько секунд не двигала ленту, считается законченной: конец её может не
    /// прийти, и лента не должна остаться «листаемой» навсегда.
    public static let liveScrollStale: TimeInterval = 3

    /// В конец транскрипта пришло новое.
    public mutating func arrived() {
        if !follows { unseen = true }
    }

    /// Нужно ли после роста содержимого (новое, выросшие строки) уехать к концу.
    public var shouldStickToEnd: Bool { follows }

    /// Кнопка «Новые ↓».
    public mutating func jumpedToEnd() {
        follows = true
        unseen = false
    }
}
