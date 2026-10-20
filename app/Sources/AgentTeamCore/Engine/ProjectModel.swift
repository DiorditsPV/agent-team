import CoreServices
import Foundation
import Observation

/// Данные выбранного проекта. Обновляются по событиям: старт, выбор проекта, изменение файлов
/// `.team/` и `agents/`, изменение панелей tmux, действие пользователя. Таймера нет.
@MainActor
@Observable
public final class ProjectModel {
    public let repo: String
    public let session: String
    public var name: String { status?.project ?? String(session.dropFirst(TmuxListing.teamPrefix.count)) }

    public private(set) var status: TeamStatus?
    public private(set) var statusError: String?
    /// CLI не знает --json (старая версия team).
    public private(set) var legacyCLI = false
    @ObservationIgnored public var onLegacyCLI: (() -> Void)?
    public private(set) var roles: [RoleInfo] = []
    public private(set) var rolesError: String?
    /// Роли из файла вместо ответа `team roles --json` (проверочный запуск `--roles-json`).
    public var rolesOverride: [RoleInfo]?
    /// Несохранённые правки ролей проекта по имени роли. Живут в модели проекта, а не в экране: экран «Роли»
    /// пересоздаётся при каждой смене раздела, и правка в его состоянии пропадала молча.
    public private(set) var roleEdits: [String: RoleEdits] = [:]
    /// Роли, правка которых сейчас уходит в `team role set`: повторное сохранение до ответа не отправляется.
    public private(set) var savingRoles: Set<String> = []
    /// Режим запуска, выбранный в списке ролей: ожидание team.yaml, ошибки у строк, вариант «вручную».
    public private(set) var roleStarts = RoleStartEdits()
    public private(set) var handoffs: [Handoff] = []
    public private(set) var check: CheckReport?
    public private(set) var checkTime: Date?
    public private(set) var checkRunning = false
    /// Сбой самой проверки: нет CLI, непонятный ответ, ошибка в stderr. Замечания check — в `check`.
    public private(set) var checkError: String?
    public private(set) var events: [TeamEvent] = []
    public private(set) var teamYAML = TeamYAMLSummary(layout: nil, manager: nil, tracker: nil, worktreeRoot: nil, starts: [:])
    /// Запись в панель менеджера: очередь, отправка, Esc — один путь.
    public let outbox = ManagerOutbox()

    /// Роль менеджера: из status, до него — из team.yaml.
    public var managerRole: String { status?.manager?.role ?? teamYAML.manager ?? "manager" }

    /// Живая панель менеджера — по списку панелей tmux, а не по кешу status.
    public var managerPaneID: String? {
        let role = managerRole
        return livePanes?().first { p in
            !p.dead && (p.role == role || p.role.split(separator: "#").first.map(String.init) == role)
        }?.paneID
    }

    /// Сессия менеджера: один читатель его транскрипта на проект. Лента, `chat`, контекст и ход менеджера — отсюда.
    /// Читатель засыпает и просыпается вместе с проектом.
    /// Группировка ленты агента менеджеру не нужна: чат группирует отрезки по своим правилам (FeedGrouping.manager).
    public let managerThread = AgentThreadModel(groupsItems: false)
    /// Записи чата менеджера: вся загруженная часть сессии (последняя страница в 3 МБ и догруженное начало).
    public var chat: [ChatEntry] { frozenChat ?? managerThread.feed.entries }
    /// Открытый вопрос менеджера целиком (`OpenQuestionSource`) по порядку источников: поле `question` из `team status`,
    /// затем неотвеченный вызов в транскрипте. Какой из них показать, решает сверка с экраном панели.
    public var managerQuestions: [PendingQuestion] {
        PendingQuestion.all(of: [StatusQuestionSource(agent: status?.manager), managerThread])
    }
    /// Меняется при каждой смене записей чата: по нему кешируется группировка ленты (не пересчитывается без нужды).
    public var chatRevision: String {
        frozenChat == nil ? "t\(managerThread.liveRevision).\(managerThread.prependRevision)" : "f\(frozenRevision)"
    }
    /// Проверочный запуск: чат подменён синтетической лентой и не перезаписывается чтением транскрипта.
    public var chatFrozen: Bool { frozenChat != nil }
    private var frozenChat: [ChatEntry]?
    /// Отрезки чата для ленты: группировка кешируется по отрезку, пересчитывается только изменившийся.
    public var chatSegments: [ThreadSegment] { frozenSegments ?? managerThread.feed.segments }
    private var frozenSegments: [ThreadSegment]?
    @ObservationIgnored private var frozenRevision = 0

    /// Для замера длинной ленты (`AGENT_TEAM_CHAT_BENCH`): подставляет записи вместо транскрипта и замораживает чат.
    public func benchFreezeChat(_ entries: [ChatEntry]) {
        frozenRevision += 1
        frozenChat = entries
        frozenSegments = ThreadFeed.split(entries, grouped: false)
    }

    /// Первая страница транскрипта менеджера: та же глубина, что у истории ввода и сверки очереди по хвосту в 3 МБ.
    public static let managerFirstPage: UInt64 = Diag.firstPage ?? 3 << 20
    /// Отправленное, но ещё не попавшее в транскрипт: показывается в ленте с отметкой «в очереди».
    public private(set) var pending: [PendingMessage] = [] {
        // Очередь опустела у проекта не на экране — читатель менеджера засыпает, как у всех скрытых проектов.
        didSet { if !active, heldCount == 0, managerThread.isRunning, !managerThread.isSuspended { managerThread.suspend() } }
    }

    /// Удержанных сообщений менеджеру. Пока они есть, чтение транскрипта менеджера не усыпляется (конец хода из него
    /// и отпускает очередь), модель не вытесняется из кэша, а выход из приложения спрашивает владельца.
    public var heldCount: Int { pending.filter(\.held).count }
    public var usage: UsageInfo? { managerThread.usage }
    /// Последнее действие и ход каждого живого агента — из хвоста его транскрипта (обновляется вместе со status).
    public private(set) var activity: [String: AgentActivity] = [:]
    public internal(set) var managerBusy = false
    public private(set) var lastActionMessage: String?
    /// Итог «Восстановить роль» по агенту (`restoreRole`).
    public private(set) var roleRestore: [String: RoleRestore] = [:]
    public private(set) var busyActions: Set<String> = []

    @ObservationIgnored public var cli: TeamCLI?
    /// Живые панели tmux сессии проекта: по ним «Команда» рисуется до прихода status.
    @ObservationIgnored public var livePanes: (@MainActor () -> [PaneInfo])?
    @ObservationIgnored private var watcher: FSWatcher?
    @ObservationIgnored private var eventsTail: JSONLTail?
    @ObservationIgnored private var transcriptSession: String?
    @ObservationIgnored private var pendingRefresh: Set<Refresh> = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private let defaults: UserDefaults

    enum Refresh: Hashable { case status, roles, handoffs, yaml }

    /// Домашний каталог Claude Code (транскрипты в `.claude/projects`); тесты подставляют свой.
    @ObservationIgnored let claudeHome: String

    public init(repo: String, session: String, cli: TeamCLI?, defaults: UserDefaults = AppDefaults.store,
                claudeHome: String = TranscriptParser.claudeHome) {
        self.claudeHome = claudeHome
        self.repo = repo
        self.session = session
        self.cli = cli
        self.defaults = defaults
        managerThread.minimumInitialEntries = 0
        outbox.project = self
        // Описание команды — сразу, одним чтением файла: по нему панели из tmux отличают менеджера от агентов.
        teamYAML = TeamYAMLSummary.parse((try? String(contentsOfFile: repo + "/agents/team.yaml", encoding: .utf8)) ?? "")
    }

    // MARK: жизненный цикл

    /// Модель открытого проекта: наблюдатели, хвосты и загрузки работают. Невыбранная модель из кэша приостановлена.
    public private(set) var active = false

    public func start() {
        active = true
        // Чат — параллельно со status: session_id менеджера из .team/state.json, status его потом подтвердит.
        openManagerFromState()
        schedule([.status, .roles, .handoffs, .yaml], delay: 0)
        startWatching()
        startEventsTail()
        startActivityPoll()
        Task { await runCheck() }
    }

    /// Проект ушёл с экрана, модель осталась в кэше: наблюдатели, хвосты и отложенные загрузки останавливаются,
    /// данные сохраняются.
    public func suspend() {
        guard active else { return }
        active = false
        lastFSEvent = watcher?.lastEventID ?? lastFSEvent
        watcher?.stop()
        watcher = nil
        activityPoll?.cancel()
        activityPoll = nil
        subagentPoll?.cancel()
        subagentPoll = nil
        eventsTail?.suspend()
        // С удержанными в очереди читатель менеджера не спит: иначе ход «не кончится» и очередь встанет, пока
        // владелец не вернётся к проекту.
        if heldCount == 0 { managerThread.suspend() }
        agentThreads.values.forEach { $0.suspend() }
    }

    /// Проект снова на экране: хвосты продолжают с места, изменения файлов за паузу приходят из истории FSEvents,
    /// status перечитывается с прежним потолком частоты.
    public func resume() {
        guard !active else { return }
        active = true
        startWatching(since: lastFSEvent)
        startActivityPoll()
        startSubagentPoll()
        readSubagents()
        eventsTail?.resume()
        if managerThread.isRunning { managerThread.resume() } else { followManagerTranscript() }
        agentThreads.values.forEach { $0.resume() }
        requestStatus(after: 0)
        if !pendingRefresh.isEmpty { schedule(pendingRefresh, delay: 0) }
    }

    /// Есть ли у модели живые наблюдатели (для проверки, что невыбранная не работает).
    public var hasLiveWatchers: Bool {
        watcher != nil || activityPoll != nil || subagentPoll != nil
            || (eventsTail.map { !$0.isSuspended } ?? false) || (managerThread.isRunning && !managerThread.isSuspended)
            || agentThreads.values.contains { $0.isRunning && !$0.isSuspended }
    }

    public func stop() {
        active = false
        activityPoll?.cancel()
        activityPoll = nil
        subagentPoll?.cancel()
        subagentPoll = nil
        subagentWatch = [:]
        watcher?.stop()
        watcher = nil
        eventsTail?.stop()
        eventsTail = nil
        managerThread.stop()
        agentThreads.values.forEach { $0.stop() }
        agentThreads = [:]
    }

    @ObservationIgnored private var lastFSEvent: FSEventStreamEventId?

    private func startWatching(since: FSEventStreamEventId? = nil) {
        let fm = FileManager.default
        let paths = [repo + "/.team", repo + "/agents"].filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        let repo = self.repo
        watcher = FSWatcher(paths: paths, since: since) { [weak self] changed in
            var r: Set<Refresh> = []
            for p in changed {
                let rel = p.hasPrefix(repo + "/") ? String(p.dropFirst(repo.count + 1)) : p
                if rel.hasPrefix(".team/events.jsonl") { continue }          // журнал читает хвост сам
                if rel.hasPrefix(".team/handoffs") { r.insert(.handoffs) }
                else if rel.hasPrefix(".team/state.json") { r.insert(.status) }
                else if rel.hasPrefix(".team/build") { r.insert(.roles) }
                else if rel.hasPrefix("agents/") || rel == "agents" {
                    r.formUnion([.roles, .status, .yaml])
                } else if rel.hasPrefix(".team") { r.insert(.status) }
            }
            guard !r.isEmpty else { return }
            Task { @MainActor in self?.schedule(r, delay: 0.3) }
        }
    }

    private func startEventsTail() {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(".team/events.jsonl")
        let tail = JSONLTail(url: url, initialBytes: 1 << 20)
        tail.start { [weak self] lines in
            let decoder = JSONDecoder()
            let evs = lines.compactMap { try? decoder.decode(TeamEvent.self, from: Data($0.utf8)) }
            Task { @MainActor in
                guard let self, !evs.isEmpty else { return }
                // Новые сверху; лента ограничена, чтобы не расти бесконечно.
                self.events = Array((evs.reversed() + self.events).prefix(2000))
            }
        }
        eventsTail = tail
    }

    // MARK: обновление по событиям

    /// Пришло изменение панелей tmux этой сессии.
    public func tmuxStructureChanged() {
        pruneAgentThreads()
        requestStatus(after: 0.3)
    }

    // MARK: ленты агентов

    /// Ленты агентов проекта по имени агента: панель «Команды» и вкладка «Диалог» показывают одну модель, она
    /// переживает сворачивание панели и уход на экран агента и засыпает вместе с проектом.
    @ObservationIgnored private var agentThreads: [String: AgentThreadModel] = [:]

    /// Модель ленты агента; создаётся при первом обращении, читать начинает `openAgentThread`.
    public func agentThread(_ name: String) -> AgentThreadModel {
        if let m = agentThreads[name] { return m }
        let m = AgentThreadModel()
        // Лента агента уже читает его транскрипт: её событие обновляет и статус — без опроса и без отставания от ленты.
        m.onLiveUpdate = { [weak self] in self?.agentThreadUpdated(name) }
        agentThreads[name] = m
        return m
    }

    /// Лента агента читает его текущую сессию; повторный вызов для той же сессии (или её цепочки) ничего не делает.
    /// У спящего проекта модель сразу засыпает.
    @discardableResult
    public func openAgentThread(_ agent: Agent) -> AgentThreadModel {
        let m = agentThread(agent.name)
        m.ensureStarted(sessionID: agent.sessionID, cwd: agent.cwd, home: claudeHome)
        if !active { m.suspend() }
        return m
    }

    /// Ленты ушедших агентов не держатся: агента нет ни в status, ни среди панелей сессии.
    func pruneAgentThreads() {
        guard !agentThreads.isEmpty else { return }
        let keep = Set(teamAgents.map(\.name)).union((status?.agents ?? []).map(\.name))
        for (name, m) in agentThreads where !keep.contains(name) {
            m.stop()
            agentThreads.removeValue(forKey: name)
        }
    }

    /// Сколько лент агентов держит проект (для проверок).
    var agentThreadCount: Int { agentThreads.count }

    @ObservationIgnored private var lastStatusLoad: Date = .distantPast
    @ObservationIgnored private var statusScheduled = false
    @ObservationIgnored private var statusLoading = false
    @ObservationIgnored private var statusReloadPending = false
    /// Потолок частоты team status на всех путях, кроме действия владельца: вызов стоит около 0,1 с CPU.
    public static let statusInterval: TimeInterval = 15

    /// Панель агента что-то вывела: состояние «ждёт человека» могло смениться.
    public func paneActivity() { requestStatus(after: 3) }

    /// status перечитывается не раньше `delay` и не чаще раза в `statusInterval`.
    func requestStatus(after delay: TimeInterval) {
        guard !statusScheduled else { return }
        statusScheduled = true
        let wait = max(delay, Self.statusInterval - Date().timeIntervalSince(lastStatusLoad))
        Task { @MainActor in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            statusScheduled = false
            // Приостановленная модель не вызывает team: status перечитается при возвращении на экран.
            guard active else { return }
            await loadStatus()
        }
    }

    /// Действие владельца: status сразу, в обход потолка.
    func forceStatus() {
        Task { @MainActor in await loadStatus() }
    }

    public func refreshAll() { schedule([.status, .roles, .handoffs, .yaml], delay: 0) }

    func schedule(_ what: Set<Refresh>, delay: TimeInterval) {
        if what.contains(.status) { requestStatus(after: delay) }
        let rest = what.subtracting([.status])
        guard !rest.isEmpty else { return }
        pendingRefresh.formUnion(rest)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            refreshScheduled = false
            guard active else { return }       // отложенное дождётся resume (события придут из истории FSEvents)
            let todo = pendingRefresh
            pendingRefresh = []
            await withTaskGroup(of: Void.self) { g in
                if todo.contains(.roles) { g.addTask { await self.loadRoles() } }
                if todo.contains(.handoffs) { g.addTask { await self.loadHandoffs() } }
                if todo.contains(.yaml) { g.addTask { await self.loadYAML() } }
            }
        }
    }

    private func loadStatus() async {
        guard let cli else { statusError = "Не найден инструмент team: укажите путь в настройках"; return }
        // Загрузка уже идёт (например, по событию), а владелец выполнил действие: перечитать ещё раз по окончании,
        // иначе итог действия потерялся бы до следующего события.
        guard !statusLoading else { statusReloadPending = true; return }
        statusLoading = true
        defer {
            statusLoading = false
            if statusReloadPending {
                statusReloadPending = false
                Task { @MainActor in await loadStatus() }
            }
        }
        lastStatusLoad = Date()
        do {
            let s = try await cli.status(cwd: repo)
            SwitchClock.shared.markNow("status", session)
            statusArrived(s)
        } catch {
            let wasHeld = managerWriteHeld
            statusError = Self.describe(error)
            // status не читается (старый CLI, сбой): проверки роли не будет, очередь не ждёт её вечно.
            if wasHeld, !managerWriteHeld { outbox.flush() }
            if case let TeamCLIError.failed(_, message) = error, Self.isLegacy(message), !legacyCLI {
                legacyCLI = true
                onLegacyCLI?()
            }
        }
    }

    /// Ответ `team status` получен: агенты, активность, сессия менеджера.
    func statusArrived(_ s: TeamStatus) {
        let wasHeld = managerWriteHeld
        if s != status { status = s }
        // Первый status пришёл или сессию роли вернули в панель менеджера: очередь, стоявшая из-за этого, двигается сама.
        if wasHeld, !managerWriteHeld { outbox.flush() }
        // Итог «Восстановить роль» живёт, пока агент без роли: когда роль вернулась, следующая плашка начнётся без него.
        let notRole = Set(s.agents.filter(\.notRole).map(\.name))
        for name in roleRestore.keys where !notRole.contains(name) { roleRestore[name] = nil }
        pruneAgentThreads()
        refreshActivity(s.agents)
        statusError = nil
        legacyCLI = false
        followManagerTranscript()
        if watcher == nil { startWatching() }
    }

    /// Опрос транскриптов: неизменившийся файл — только stat, дописанный — разбор новых строк (`ActivityTracker`).
    @ObservationIgnored private var activityTracker = ActivityTracker()
    @ObservationIgnored private var activityPoll: Task<Void, Never>?
    @ObservationIgnored private var activityReading = false
    @ObservationIgnored private var activityQueued: Set<String> = []
    @ObservationIgnored private var activityQueuedFull = false

    /// Как часто сверяются транскрипты живых агентов. Проверка — stat файла; хвост читается только у изменившихся.
    /// Без опроса активность обновлялась лишь вместе с team status (смена панелей, «ждёт человека», действие
    /// владельца), и законченный ход держал «работает» до следующего такого события.
    public static let activityInterval: TimeInterval = 5

    private func startActivityPoll() {
        activityPoll?.cancel()
        activityPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.activityInterval * 1_000_000_000))
                guard let self else { return }
                guard self.active, let agents = self.status?.agents else { continue }
                // Агенты с открытой лентой обновляются её событиями; таймер — только для остальных.
                self.refreshActivity(agents.filter { !self.hasLiveThread($0.name) }, partial: true)
            }
        }
    }

    // MARK: субагенты

    /// Работающие субагенты сессий, чьи полосы сейчас на экране, по id сессии.
    public private(set) var subagents: [String: BackgroundAgents] = [:]
    @ObservationIgnored private var subagentWatch: [String: (cwd: String?, count: Int)] = [:]
    @ObservationIgnored private var subagentPoll: Task<Void, Never>?
    @ObservationIgnored private var subagentReading = false
    /// Видно ли окно приложения: свёрнутое или перекрытое окно субагентов не опрашивает (задаёт AppModel).
    @ObservationIgnored public var appVisible: () -> Bool = { true }
    /// Каталог субагентов меняется без событий, которые приложение уже получает: опрос раз в 2 с, один на проект,
    /// только пока проект на экране, окно видно и хоть одна полоса показана.
    public static let subagentInterval: TimeInterval = 2

    /// Полоса субагентов сессии появилась (`true`) или ушла с экрана (`false`).
    public func watchSubagents(sessionID: String, cwd: String?, _ on: Bool) {
        var w = subagentWatch[sessionID] ?? (cwd, 0)
        w.count += on ? 1 : -1
        if let cwd { w.cwd = cwd }
        if w.count > 0 {
            subagentWatch[sessionID] = w
            if on { readSubagents() }           // новая полоса — сразу, не через 2 с
        } else {
            subagentWatch[sessionID] = nil
            subagents[sessionID] = nil
        }
        startSubagentPoll()
    }

    private func startSubagentPoll() {
        guard active, !subagentWatch.isEmpty else {
            subagentPoll?.cancel()
            subagentPoll = nil
            return
        }
        guard subagentPoll == nil else { return }
        subagentPoll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.subagentInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                if self.appVisible() { self.readSubagents() }
            }
        }
    }

    private func readSubagents() {
        guard active, !subagentReading, !subagentWatch.isEmpty else { return }
        subagentReading = true
        let targets = subagentWatch.map { (sessionID: $0.key, cwd: $0.value.cwd) }
        let home = claudeHome
        Task.detached(priority: .utility) { [weak self] in
            var found: [String: BackgroundAgents] = [:]
            for t in targets {
                found[t.sessionID] = TranscriptParser.locate(cwd: t.cwd, sessionID: t.sessionID, home: home)
                    .map { BackgroundAgents.read(transcript: $0) } ?? BackgroundAgents.none
            }
            await MainActor.run { [found] in
                guard let self else { return }
                self.subagentReading = false
                for (sid, a) in found where self.subagentWatch[sid] != nil && self.subagents[sid] != a { self.subagents[sid] = a }
            }
        }
    }

    /// Лента агента читает транскрипт и не спит.
    private func hasLiveThread(_ name: String) -> Bool {
        agentThreads[name].map { $0.isRunning && !$0.isSuspended } ?? false
    }

    /// Лента агента получила новые строки: статус дочитывает те же новые байты.
    private func agentThreadUpdated(_ name: String) {
        guard active, let a = status?.agents.first(where: { $0.name == name }) else { return }
        refreshActivity([a], partial: true)
    }

    /// Хвосты транскриптов читаются вне главного потока: после каждого team status (все агенты), по событию ленты
    /// агента и раз в `activityInterval` для агентов без открытой ленты. `partial` — обновить только этих агентов,
    /// остальные итоги остаются. Пока идёт чтение, новые просьбы копятся и читаются следом.
    private func refreshActivity(_ agents: [Agent], partial: Bool = false) {
        let alive = agents.filter(\.alive)
        guard !activityReading else {
            activityQueued.formUnion(alive.map(\.name))
            if !partial { activityQueuedFull = true }
            return
        }
        activityReading = true
        let targets = alive.compactMap { a in a.sessionID.map { (name: a.name, sessionID: $0, cwd: a.cwd) } }
        var tracker = activityTracker
        let home = claudeHome
        Task.detached(priority: .utility) { [weak self] in
            let found = tracker.refresh(targets, home: home, keepOthers: partial)
            await MainActor.run { [found, tracker] in
                guard let self else { return }
                self.activityReading = false
                self.activityTracker = tracker
                var next = partial ? self.activity : [:]
                if partial { for t in targets { next[t.name] = found[t.name] } } else { next = found }
                if self.activity != next { self.activity = next }
                // Просьбы, пришедшие во время чтения.
                let full = self.activityQueuedFull, names = self.activityQueued
                self.activityQueued = []
                self.activityQueuedFull = false
                if full, let all = self.status?.agents { self.refreshActivity(all) }
                else if !names.isEmpty { self.refreshActivity((self.status?.agents ?? []).filter { names.contains($0.name) }, partial: true) }
            }
        }
    }

    static func isLegacy(_ message: String) -> Bool {
        message.contains("invalid choice") || message.contains("unrecognized arguments")
    }

    private func loadRoles() async {
        if let o = rolesOverride { if o != roles { roles = o }; rolesError = nil; syncRoleStarts(); return }
        guard let cli else { return }
        do {
            let r = try await cli.roles(cwd: repo)
            if r != roles { roles = r }
            rolesError = nil
            syncRoleStarts()
        } catch {
            rolesError = Self.describe(error)
        }
    }

    private func loadHandoffs() async {
        guard let cli else { return }
        if let h = try? await cli.handoffs(cwd: repo) {
            let sorted = h.sorted { $0.ts > $1.ts }
            if sorted != handoffs { handoffs = sorted }
        }
    }

    private func loadYAML() async {
        let path = repo + "/agents/team.yaml"
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        teamYAML = TeamYAMLSummary.parse(text)
        syncRoleStarts()
    }

    /// Правка автоостановки в ячейке настроек: `team set idle_stop_minutes`, затем team.yaml перечитывается.
    /// Ошибка остаётся в `idleStopError` рядом с полем.
    public private(set) var idleStopSaving = false
    public private(set) var idleStopError: String?

    @discardableResult
    public func setIdleStop(_ input: IdleStopInput) async -> Bool {
        idleStopError = nil
        guard input != .invalid else { idleStopError = "Нужно " + IdleStopInput.hint; return false }
        guard let cli else { idleStopError = "Не найден инструмент team"; return false }
        idleStopSaving = true
        defer { idleStopSaving = false }
        do {
            _ = try await cli.setIdleStop(input, cwd: repo)
            await loadYAML()
            return true
        } catch {
            idleStopError = Self.describe(error)
            return false
        }
    }

    public func clearIdleStopError() { idleStopError = nil }

    /// Автоостановка: один вызов `team reap --json`. Вызывается всегда: порог и `off` решает CLI (при `off` отдаёт `[]`), закешированный team.yaml мог устареть; ошибка вызова — в журнал
    /// приложения без показа. Остановленных агентов CLI сам записывает в events.jsonl (тип down, «остановлена: простой N мин»):
    /// журнал проекта показывает их строкой «Остановка». Возвращает остановленных.
    @discardableResult
    public func reapTick() async -> [ReapEntry] {
        guard let cli, !reaping else { return [] }
        reaping = true
        defer { reaping = false }
        let keep = Reap.keepNames(manager: managerRole, hasQueue: !pending.isEmpty, hasDraft: !draft.isEmpty || !draftImages.isEmpty)
        let stopped = await Reap.run(cli: cli, repo: repo, session: session, keep: keep)
        if !stopped.isEmpty { forceStatus() }
        return stopped
    }
    @ObservationIgnored private var reaping = false

    public func runCheck() async {
        guard let cli else { checkError = "Не найден инструмент team: укажите путь в настройках"; return }
        checkRunning = true
        defer { checkRunning = false }
        do {
            check = try await cli.check(cwd: repo)
            checkTime = Date()
            checkError = nil
        } catch {
            checkError = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let TeamCLIError.failed(_, message):
            if isLegacy(message) {
                return "Эта версия team не отдаёт JSON — укажите в настройках инструмент с поддержкой --json"
            }
            return message.isEmpty ? "team завершился с ошибкой" : message
        case TeamCLIError.badJSON:
            return "team вернул непонятный ответ"
        default:
            return "\(error)"
        }
    }

    // MARK: чат с менеджером

    /// `team status` назвал сессию менеджера. Сессия той же цепочки `continued-in`, что уже читается (state.json помнит
    /// сессию запуска, status — текущую), чтения не перезапускает.
    private func followManagerTranscript() {
        guard let m = status?.manager, let sid = m.sessionID else { return }
        if loadedPinKey != pinKey { loadPins() }
        if managerThread.follows(sessionID: sid) {
            transcriptSession = sid
            return
        }
        // Та же сессия, но файл не открыт: state.json не знал каталога, и искать было негде — status его называет.
        guard sid != transcriptSession || !managerThread.isRunning else { return }
        startTranscript(sessionID: sid, cwd: m.cwd)
    }

    /// Менеджер по кешу инструмента `.team/state.json` (`<роль>#1` или `<роль>` → session_id, cwd) — без ожидания status.
    private func openManagerFromState() {
        guard transcriptSession == nil, let (sid, cwd) = Self.managerSession(repo: repo, managerRole: teamYAML.manager ?? "manager") else { return }
        launchSession = Self.managerLaunchSession(repo: repo, managerRole: teamYAML.manager ?? "manager") ?? sid
        startTranscript(sessionID: sid, cwd: cwd)
    }

    /// Сессия запуска менеджера из state.json (поле `launch_session_id`; у старого CLI его нет).
    nonisolated static func managerLaunchSession(repo: String, managerRole: String) -> String? {
        guard let data = FileManager.default.contents(atPath: repo + "/.team/state.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = (obj[managerRole + "#1"] ?? obj[managerRole]) as? [String: Any],
              let sid = entry["launch_session_id"] as? String, !sid.isEmpty else { return nil }
        return sid
    }

    nonisolated static func managerSession(repo: String, managerRole: String) -> (String, String?)? {
        guard let data = FileManager.default.contents(atPath: repo + "/.team/state.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Ключ — «роль#1»; состояние, записанное до номеров агентов, — просто «роль».
              let entry = (obj[managerRole + "#1"] ?? obj[managerRole]) as? [String: Any],
              let sid = entry["session_id"] as? String, !sid.isEmpty else { return nil }
        return (sid, entry["cwd"] as? String)
    }

    /// Старый CLI без --json: менеджер найден по живой панели (@team_role), транскрипт — самый свежий
    /// в каталоге проекта Claude для её каталога.
    public func useLiveManager(cwd: String) {
        // Только для CLI без --json. С новым CLI ждём session_id из status: самый свежий транскрипт каталога
        // может оказаться чужой сессией в том же репозитории.
        guard status == nil, legacyCLI, transcriptSession == nil else { return }
        startTranscript(sessionID: nil, cwd: cwd)
    }

    /// Сессия менеджера сменилась: читатель открывает её файл (по цепочке `continued-in` до конца) или ждёт его появления.
    private func startTranscript(sessionID sid: String?, cwd: String?) {
        transcriptSession = sid ?? cwd.map { "cwd:" + $0 }
        loadPins()
        managerThread.onLiveUpdate = { [weak self] in self?.managerUpdated() }
        if let sid {
            managerThread.start(sessionID: sid, cwd: cwd, home: claudeHome, firstPageBytes: Self.managerFirstPage)
        } else if let cwd, let url = TranscriptParser.newest(cwd: cwd, home: claudeHome) {
            managerThread.start(url: url, firstPageBytes: Self.managerFirstPage)
        } else {
            managerThread.stop()
        }
        if !active { managerThread.suspend() }
    }

    /// Живой кусок транскрипта менеджера изменился: ход, очередь и срок «не дошло» сверяются по нему.
    /// Пока файла нет (сессия поднимается), ход остаётся прежним: иначе удержанные сообщения ушли бы в панель,
    /// где Claude Code ещё запускается.
    private func managerUpdated() {
        if managerThread.phase == .ready { managerBusy = managerThread.turnInProgress }
        reconcilePending()
        trackQuiet()
        outbox.flush()
    }

    /// Сообщение ушло в панель менеджера: до записи в транскрипт оно живёт в `pending`. Возвращает номер для отмены.
    @discardableResult
    public func addPending(text: String, images: [URL], held: Bool = false, alsoSeen: Set<String> = []) -> String {
        var p = PendingMessage(text: text, images: images, seen: ownerEntryIDs().union(alsoSeen))
        p.held = held
        p.quietSince = (managerBusy || held) ? nil : Date()
        pending.append(p)
        return p.id
    }

    /// Записи владельца и вызовы команд, уже бывшие в ленте: по ним отправленное сообщение не сверяется.
    private func ownerEntryIDs() -> Set<String> {
        Set(chat.filter {
            switch $0.kind {
            case .owner, .invoked, .unknownCommand: return true
            default: return false
            }
        }.map(\.id))
    }

    // MARK: очередь приложения

    /// Удержанное сообщение ушло в панель: теперь оно ждёт записи в транскрипте, срок «не дошло» идёт.
    public func markSent(_ id: String, alsoSeen: Set<String> = []) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].held = false
        pending[i].stopped = false
        pending[i].seen = ownerEntryIDs().union(alsoSeen)
        pending[i].quietSince = managerBusy ? nil : Date()
    }

    /// Какое удержанное сообщение отправить сейчас: менеджер без хода, ход не прерывали, прежнее отправленное уже
    /// в транскрипте (иначе второе ушло бы раньше, чем лента увидела первое) или потеряно.
    /// `allowed` — какие из удержанных могут уйти сами (при строке Claude Code — только явные действия).
    public func nextHeldToSend(now: Date = Date(), where allowed: (PendingMessage) -> Bool = { _ in true }) -> PendingMessage? {
        guard !managerBusy else { return nil }
        if pending.contains(where: { !$0.held && !$0.isUndelivered(now: now) }) { return nil }
        return pending.first { $0.held && !$0.stopped && allowed($0) }
    }

    /// Отправка не состоялась, сообщение снова ждёт в очереди (перед записью в панели оказался экран команды).
    func holdAgain(_ id: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[i].held = true
        pending[i].quietSince = nil
    }

    /// «Стоп» или Esc: ход прерван, очередь сама не уходит.
    public func stopQueue() {
        for i in pending.indices where pending[i].held { pending[i].stopped = true }
    }

    /// «↑ сейчас» у одного сообщения: остальные удержанные снова ждут конца хода.
    public func releaseOthers(except id: String) {
        for i in pending.indices where pending[i].held && pending[i].id != id { pending[i].stopped = false }
    }

    /// «✎ изменить»: сообщение уходит из очереди, текст и картинки возвращаются владельцу в поле.
    public func takeForEdit(_ id: String) -> PendingMessage? {
        guard let i = pending.firstIndex(where: { $0.id == id && $0.held }) else { return nil }
        defer { outbox.flush() }
        return pending.remove(at: i)
    }

    public var hasHeld: Bool { pending.contains { $0.held } }

    /// Срок «не дошло» идёт только пока менеджер без хода: в ходе обнуляется, после хода начинается заново.
    func trackQuiet(now: Date = Date()) {
        for i in pending.indices where !pending[i].held {
            if managerBusy { pending[i].quietSince = nil } else if pending[i].quietSince == nil { pending[i].quietSince = now }
        }
    }

    /// Для снимков: ожидающие сообщения «старше» на столько секунд (проверка вида «не дошло» без двух минут ожидания).
    public func backdatePending(_ seconds: TimeInterval) {
        for i in pending.indices { pending[i].quietSince = pending[i].quietSince.map { $0 - seconds } }
    }

    /// Для тестов: активность агента из транскрипта.
    func setActivityForTest(_ name: String, _ a: AgentActivity?) { activity[name] = a }

    /// Для тестов.
    func setSeenForTest(id: String, seen: Set<String>) {
        if let i = pending.firstIndex(where: { $0.id == id }) { pending[i].seen = seen }
    }

    public func dropPending(_ id: String) {
        removePending(id)
        outbox.flush()
    }

    /// Снять сообщение, не продвигая очередь.
    func removePending(_ id: String) { pending.removeAll { $0.id == id } }

    /// Запись транскрипта сняла отметку «в очереди»: на каждое ожидающее сообщение — одна запись, по порядку.
    /// Сверка идёт по той же ленте, что на экране: читатель транскрипта один.
    public func reconcilePending() { reconcilePending(against: Array(chat.suffix(600))) }

    func reconcilePending(against entries: [ChatEntry]) {
        guard !pending.isEmpty else { return }
        // Сначала по тексту, затем по порядку: Claude Code может изменить текст (обёртка вставки, подписи картинок),
        // но первая новая запись владельца с тем же числом картинок после отправки — это оно.
        var used: Set<String> = []
        var done: Set<String> = []
        for p in pending {
            if let e = entries.first(where: { !used.contains($0.id) && p.matches($0) }) { used.insert(e.id); done.insert(p.id) }
        }
        for p in pending where !done.contains(p.id) {
            if let e = entries.first(where: { !used.contains($0.id) && p.matchesByOrder($0) }) { used.insert(e.id); done.insert(p.id) }
        }
        pending.removeAll { done.contains($0.id) }
    }

    // MARK: закреплённое

    /// Закреплённые записи чата менеджера текущей сессии, в порядке закрепления.
    public private(set) var pins: [PinnedEntry] = []
    /// Просьба прокрутить ленту к записи (шапка → лента).
    public var pinJump: PinJump?

    /// Закреплённое хранится по сессии запуска менеджера: продолжение сессии в новом файле не теряет закреплённого.
    private var pinKey: String { PinStore.key(repo: repo, session: status?.manager?.launchSessionID ?? launchSession ?? transcriptSession) }
    /// Сессия из state.json (после `/clear` — уже текущая, не запуска), пока status не назвал сессию запуска.
    @ObservationIgnored private var launchSession: String?

    /// Ключ, по которому закреплённое загружено: status может назвать сессию запуска иначе, чем state.json
    /// (там после `/clear` уже текущая сессия), и тогда закреплённое перечитывается.
    @ObservationIgnored private var loadedPinKey: String?

    func loadPins() {
        loadedPinKey = pinKey
        pins = PinStore.load(defaults, key: pinKey)
    }

    public func isPinned(_ id: String) -> Bool { pins.contains { $0.id == id } }

    /// Закрепить запись или открепить, если закреплена. Нельзя закрепить строки инструментов и конец хода.
    public func togglePin(_ e: ChatEntry) {
        if let i = pins.firstIndex(where: { $0.id == e.id }) {
            pins.remove(at: i)
        } else if let excerpt = PinnedEntry.excerpt(of: e.kind) {
            pins.append(PinnedEntry(id: e.id, excerpt: excerpt, time: e.time))
        } else {
            return
        }
        PinStore.save(pins, defaults, key: pinKey)
    }

    /// Закрепить запись по готовой карточке (запись может быть вне загруженной части ленты).
    public func addPin(_ pin: PinnedEntry) {
        guard !isPinned(pin.id) else { return }
        pins.append(pin)
        PinStore.save(pins, defaults, key: pinKey)
    }

    public func unpin(_ id: String) {
        pins.removeAll { $0.id == id }
        PinStore.save(pins, defaults, key: pinKey)
    }

    public func requestJump(to id: String) { pinJump = PinJump(id: id) }

    /// Картинки черновика: файлы в кеше приложения, ждут отправки вместе с текстом.
    public var draftImages: [URL] = []

    public var draft: String {
        get { defaults.string(forKey: "draft." + repo) ?? "" }
        set { defaults.set(newValue, forKey: "draft." + repo) }
    }

    /// Текст, вернувшийся владельцу (взят на правку, не ушёл), встаёт в начало черновика, перед набранным.
    public static func draft(returning text: String, before draft: String) -> String {
        text.isEmpty ? draft : draft.isEmpty ? text : text + "\n" + draft
    }

    /// Не ушедшее возвращается в сохраняемый черновик проекта: владелец увидит его в поле, в том числе после
    /// перезапуска приложения.
    public func returnToDraft(_ text: String, images: [URL]) {
        draft = Self.draft(returning: text, before: draft)
        draftImages = images + draftImages
    }

    /// Выход по сигналу, без владельца: удержанные, которые не удалось отправить, уходят в черновик.
    public func returnHeldToDraft() {
        let held = pending.filter(\.held)
        guard !held.isEmpty else { return }
        returnToDraft(held.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n"), images: held.flatMap(\.images))
        for p in held { removePending(p.id) }
    }

    // MARK: действия

    @discardableResult
    public func act(_ key: String, _ args: [String]) async -> Bool {
        guard let cli else { lastActionMessage = "Не найден инструмент team"; return false }
        busyActions.insert(key)
        defer { busyActions.remove(key) }
        do {
            let out = try await cli.action(args, cwd: repo)
            lastActionMessage = out.split(separator: "\n").last.map(String.init)
            forceStatus()
            schedule([.roles, .handoffs], delay: 0)
            return true
        } catch {
            lastActionMessage = Self.describe(error)
            return false
        }
    }

    public func spawn(role: String) async { await act("spawn:" + role, ["spawn", role]) }
    @discardableResult
    public func up() async -> Bool { await act("up", ["up"]) }
    @discardableResult
    public func restart(_ agent: String, fresh: Bool) async -> Bool {
        await act("restart:" + agent, ["restart", agent] + (fresh ? ["--fresh"] : []))
    }

    /// В панели менеджера не сессия его роли (`role_check.ok == false` у менеджера): запись в панель стоит — сообщение
    /// ушло бы разговору без роли.
    public var managerNotRole: Bool { status?.manager?.notRole == true }

    /// Первого ответа `team status` ещё нет: чья сессия в панели менеджера, неизвестно. Запись ждёт его — иначе очередь,
    /// поставленная до него, ушла бы в панель, которую status через полсекунды показал бы чужой. Ответ с ошибкой тоже
    /// снимает ожидание: проверки роли тогда нет.
    public var awaitingFirstStatus: Bool { cli != nil && status == nil && statusError == nil }

    /// Запись в панель менеджера стоит: в ней не сессия роли или проверки ещё не было.
    public var managerWriteHeld: Bool { managerNotRole || awaitingFirstStatus }

    /// Свежая проверка роли перед записью в панель менеджера: `team status --json` сейчас, а не последний опрос — разговор
    /// мог уйти в фоновую задачу между опросами. Вызов идёт только перед записью, в простое нагрузки нет (около 0,2 с на
    /// сообщение). status не прочитался — остаётся последний известный ответ. `true` — писать можно.
    public func confirmManagerRole() async -> Bool {
        if let cli {
            do {
                statusArrived(try await cli.status(cwd: repo))
            } catch {
                statusError = Self.describe(error)
            }
        }
        return !managerWriteHeld
    }

    /// Агенты, в чьих панелях не сессия роли: менеджер первым.
    public var notRoleAgents: [Agent] {
        (status?.agents ?? []).filter(\.notRole).sorted { ($0.kind == "manager" ? 0 : 1) < ($1.kind == "manager" ? 0 : 1) }
    }

    /// «Восстановить роль»: `team restart <агент>` возвращает разговор роли в панель. Итог — `roleRestore[агент]`:
    /// он виден на плашке, пока status не покажет панель с сессией роли.
    public func restoreRole(_ agent: String) async {
        roleRestore[agent] = nil
        let ok = await restart(agent, fresh: false)
        roleRestore[agent] = RoleRestore(ok: ok, message: lastActionMessage ?? (ok ? "team restart \(agent) выполнен" : "team restart \(agent) не удался"))
    }
    public func down(_ agent: String?) async { await act("down:" + (agent ?? "*"), ["down"] + (agent.map { [$0] } ?? [])) }
    /// Передача идёт через менеджера: владелец пишет только менеджеру, в строку агента приложение не вставляет.
    public static func handoffRequest(for agent: String) -> String {
        "Подготовь передачу агента \(agent): team handoff \(agent), затем restart --fresh, когда файл заполнен."
    }

    /// «Добавить в проект»: `team role new <роль> --extends <роль>` создаёт тонкую роль и вносит её в команду.
    /// Текст ошибки CLI показывается владельцу.
    @discardableResult
    public func addSharedRole(_ name: String) async -> Bool {
        guard let cli else { lastActionMessage = "Не найден инструмент team"; return false }
        let key = "add:" + name
        busyActions.insert(key)
        defer { busyActions.remove(key) }
        do {
            _ = try await cli.roleNew(name, extends: name, cwd: repo)
            lastActionMessage = "Роль \(name) добавлена в проект"
            forceStatus()
            schedule([.roles, .yaml], delay: 0)
            return true
        } catch {
            lastActionMessage = Self.describe(error)
            return false
        }
    }

    public func saveRole(_ role: String, title: String?, model: String?, description: String?, start: String?) async -> Bool {
        guard let cli else { return false }
        do {
            _ = try await cli.roleSet(role, title: title, model: model, description: description, start: start, cwd: repo)
            forceStatus()
            schedule([.roles, .yaml], delay: 0)
            return true
        } catch {
            lastActionMessage = Self.describe(error)
            return false
        }
    }

    // MARK: правки ролей

    /// Исходное состояние роли для формы: режим запуска — выбранный в списке ролей, пока team.yaml его не показал, затем
    /// из team.yaml, иначе из описания роли.
    public func roleBase(_ role: RoleInfo) -> RoleDraft {
        RoleDraft(role: role, startOverride: roleStarts.pending[role.role] ?? teamYAML.starts[role.role])
    }

    /// Владелец изменил форму роли.
    public func recordRoleEdit(_ role: String, form: RoleDraft, base: RoleDraft) {
        var e = roleEdits[role] ?? RoleEdits()
        e.record(form, base: base)
        roleEdits[role] = e.isEmpty ? nil : e
    }

    public func discardRoleEdits(_ role: String) { roleEdits[role] = nil }

    /// Сохраняет правку роли через `team role set`. Поля во время вызова открыты, поэтому после ответа стираются
    /// только поля, совпавшие с отправленными: допечатанное за это время остаётся правкой.
    public func saveRoleEdits(_ role: String, base: RoleDraft) async -> Bool {
        guard let sent = roleEdits[role], !savingRoles.contains(role) else { return false }
        let c = sent.changes(from: base)
        savingRoles.insert(role)
        defer { savingRoles.remove(role) }
        guard await saveRole(role, title: c.title, model: c.model, description: c.description, start: c.start) else { return false }
        if var e = roleEdits[role] {
            e.settle(sent: sent)
            roleEdits[role] = e.isEmpty ? nil : e
        }
        return true
    }

    // MARK: режим запуска в списке ролей

    /// Роли проекта со своим режимом запуска — строки переключателя в списке ролей. Без менеджера и общих ролей.
    public var roleStartRows: [RoleStartRow] { RoleStart.rows(roles: roles, starts: teamYAML.starts) }

    /// Режим в списке ролей — тот же, что в карточке роли: с её несохранённой правкой режима.
    public func roleStartShown(_ role: String) -> String? {
        guard let r = self.role(named: role) else { return nil }
        return (roleEdits[role] ?? RoleEdits()).applied(to: roleBase(r)).start
    }

    /// Режим выбран в списке ролей. В `team role set` уходит только `--start`: название, модель и описание, начатые
    /// в карточке, остаются черновиком. Правка режима в карточке снимается: список показывал её значение, и владелец
    /// выбрал поверх него. Сбой возвращает её и оставляет текст ошибки у строки списка. Выбор сохранённого режима
    /// только снимает правку карточки, team не вызывается. `false` — режим не сохранён.
    @discardableResult
    public func saveRoleStart(_ role: String, _ start: String) async -> Bool {
        guard let row = roleStartRows.first(where: { $0.role == role }), !savingRoles.contains(role),
              start != roleStartShown(role) else { return false }
        let drafted = removeRoleEdit(role, .start)
        guard roleStarts.begin(row, start: start) else { return false }
        savingRoles.insert(role)
        clearMessage()
        let ok = await saveRole(role, title: nil, model: nil, description: nil, start: start)
        savingRoles.remove(role)
        var error: String?
        if !ok {
            error = lastActionMessage ?? "Не найден инструмент team"
            clearMessage()
            if let drafted, roleEdits[role]?.values[.start] == nil {
                var e = roleEdits[role] ?? RoleEdits()
                e.restore(.start, drafted)
                roleEdits[role] = e
            }
        }
        roleStarts.finish(role, error: error)
        return ok
    }

    private func removeRoleEdit(_ role: String, _ field: RoleDraft.Field) -> String? {
        guard var e = roleEdits[role] else { return nil }
        let value = e.remove(field)
        roleEdits[role] = e.isEmpty ? nil : e
        return value
    }

    private func syncRoleStarts() { roleStarts.sync(roleStartRows) }

    public func newRole(_ role: String, title: String, model: String?, description: String?, start: String?) async -> Bool {
        guard let cli else { return false }
        do {
            _ = try await cli.roleNew(role, title: title, model: model, description: description, start: start, cwd: repo)
            forceStatus()
            schedule([.roles, .yaml], delay: 0)
            return true
        } catch {
            lastActionMessage = Self.describe(error)
            return false
        }
    }

    public func clearMessage() { lastActionMessage = nil }

    /// Итог действия, выполненного не через CLI (например, сообщения менеджеру).
    public func report(_ message: String) { lastActionMessage = message }

    // MARK: производные

    public func agents(ofRole role: String) -> [Agent] {
        (status?.agents ?? []).filter { $0.role == role && $0.alive }
    }

    /// Роли проекта: собственные и наследующие — в порядке team.yaml (так их отдаёт `team roles --json`).
    public var projectRoles: [RoleInfo] { roles.filter { !$0.isShared } }
    /// Общие роли, которые можно добавить в проект; подключённые (то же имя или `extends`) отдельной строкой не показываются.
    public var sharedRoles: [RoleInfo] { RoleGroups.addableShared(roles.filter(\.isShared), projectRoles: projectRoles) }
    /// Вся библиотека, в том числе уже подключённые роли: по ней строка роли проекта пишет «← общая …».
    public var libraryRoles: [RoleInfo] { roles.filter(\.isShared) }
    /// Общая роль, на которой стоит наследующая, — текст для блока «только чтение».
    public func parent(of role: RoleInfo) -> RoleInfo? {
        guard let name = role.extends else { return nil }
        return libraryRoles.first { $0.role == name }
    }
    public func role(named name: String) -> RoleInfo? { roles.first { $0.role == name && !$0.isShared } }

    public func agent(named name: String) -> Agent? { status?.agents.first { $0.name == name } }

    public var waitingHandoffs: Int { handoffs.filter(\.isWaiting).count }

    /// Отображаемое имя адресата SendMessage: адрес сокета → имя агента из status.
    public func displayName(forAddress addr: String) -> String {
        if let a = status?.agents.first(where: { $0.addr == addr }) { return Self.pretty(a.name) }
        return addr
    }

    /// «developer#1» → «developer #1».
    public static func pretty(_ name: String) -> String { name.replacingOccurrences(of: "#", with: " #") }
}

// MARK: сведения об агентах для экранов

public enum AgentState: Equatable, Sendable {
    case working
    case waiting(String)
    case quiet(minutes: Int)
    case stopped
    /// Транскрипт не найден и экран не показывает хода: утверждать «работает» или «простаивает» не на чем.
    case noData
}

/// Что показать о состоянии агента: состояние (цвет, фильтры), подпись и подсказка.
public struct AgentStatus: Equatable, Sendable {
    public var state: AgentState
    public var label: String
    public var tooltip: String
}

/// Решение, которое ждёт владельца.
public struct Decision: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case trust          // доверие к новой папке
        case permission     // право вне allow в панели агента
        case ask            // агент задал вопрос с вариантами (AskUserQuestion)
        case owner          // слияние или другое действие по слову владельца (событие waiting в журнале)
    }

    public var agent: String
    public var text: String
    public var kind: Kind
    public var task: String?
    public var id: String { "\(kind)-\(agent)-\(task ?? "")" }

    public init(agent: String, text: String, kind: Kind = .permission, task: String? = nil) {
        self.agent = agent
        self.text = text
        self.kind = kind
        self.task = task
    }
}

extension ProjectModel {
    /// Агенты на панелях «Команды»: все, кроме менеджера, у кого есть панель (живая или завершённая).
    /// Агенты на панелях «Команды». Список панелей tmux известен сразу, status приходит через полсекунды:
    /// панели рисуются по tmux (роль, номер, жив ли, каталог), поля status дорисовываются, когда он придёт.
    public var teamAgents: [Agent] {
        let fromStatus = (status?.agents ?? []).filter { $0.kind != "manager" && $0.paneID != nil }
        guard let panes = livePanes?(), !panes.isEmpty else { return fromStatus }
        let live = Set(panes.map(\.paneID))
        let known = fromStatus.filter { live.contains($0.paneID ?? "") }
        let knownIDs = Set(known.compactMap(\.paneID))
        let manager = managerRole
        let extra = panes.filter { p in
            !p.role.isEmpty && !knownIDs.contains(p.paneID) && Self.roleName(p.role) != manager
        }.map(Self.agent(fromPane:))
        return Self.uniqueKeys(known + extra)
    }

    /// Второй агент с уже встреченным именем получает ключ по своей панели. Записи status идут первыми, так что
    /// ключ-имя остаётся у них.
    nonisolated static func uniqueKeys(_ agents: [Agent]) -> [Agent] {
        var seen = Set<String>()
        return agents.map { a in
            var a = a
            if !seen.insert(a.name).inserted { a.keyOverride = "pane:" + (a.paneID ?? a.name) }
            return a
        }
    }

    nonisolated static func roleName(_ key: String) -> String { String(key.split(separator: "#").first ?? "") }

    nonisolated static func agent(fromPane p: PaneInfo) -> Agent {
        let role = roleName(p.role)
        let n = p.role.split(separator: "#").dropFirst().first.flatMap { Int($0) } ?? 1
        return Agent(name: "\(role)#\(n)", role: role, n: n, alive: !p.dead, paneID: p.paneID, cwd: p.path)
    }

    /// Задача агента — из последнего события журнала с задачей.
    /// Задача агента: поле task из status, у старого CLI — последнее событие журнала с задачей.
    public func task(of agent: String) -> String? {
        if let t = self.agent(named: agent)?.task, !t.isEmpty { return t }
        return events.first { $0.agent == agent && ($0.task?.isEmpty == false) }?.task
    }

    /// Задача агента для шапок: название с откатом на номер, время установки. Нет задачи — nil.
    public func taskLabel(of agent: String) -> TaskLabel? {
        if let a = self.agent(named: agent) {
            let l = TaskLabel(agent: a)
            if !l.isEmpty { return l }
        }
        return TaskLabel.fromEvents(events, agent: agent)
    }

    /// Название задачи для строки журнала: у события `task` — его собственное; иначе название этого же агента
    /// по номеру. Один номер у разных агентов может называться по-разному (у каждого своя часть работы).
    public func taskTitle(of event: TeamEvent) -> String? {
        TaskLabel.eventTitle(event, in: events)
            ?? event.task.flatMap { number in
                status?.agents.first { $0.name == event.agent && $0.task == number && ($0.taskTitle?.isEmpty == false) }?.taskTitle
            }
    }

    /// Репозиторий агента: worktree.repo роли или репозиторий проекта.
    public func repoName(of agent: Agent) -> String {
        let repo = role(named: agent.role)?.worktree?.repo ?? self.repo
        return (repo as NSString).lastPathComponent
    }

    /// `liveKnown` — у панели был захват (видимые панели захватываются по выводу, скрытые — по активности раз в 3 с):
    /// тогда признак «ждёт человека» из кеша team status не учитывается, он отстаёт до 15 с и держал бы решение после
    /// ответа владельца.
    ///
    /// «Работает» говорят только данные: строка хода на экране панели или идущий ход в транскрипте. Перерисовка
    /// панели (строка состояния, часы) и `idle_s` из team status работой не считаются: `idle_s` один на всю сессию tmux.
    /// Нет ни хода на экране, ни транскрипта — `.noData`.
    public func state(of agent: Agent, asksTrust: Bool, asksPermission: Bool = false, liveKnown: Bool = false,
                      screenTurn: TurnStatus? = nil, activity: AgentActivity? = nil, now: Date = Date()) -> AgentState {
        guard agent.alive else { return .stopped }
        if asksTrust { return .waiting("ждёт доверия") }
        // Форма AskUserQuestion на экране ловится теми же признаками, что запрос права; различает их открытый вопрос.
        let asks = Self.asksQuestion(agent, activity: activity)
        if asksPermission { return .waiting(asks ? "ждёт ответа" : "ждёт права") }
        if agent.waitingHuman || asks, !liveKnown { return .waiting("ждёт ответа") }
        if screenTurn != nil { return .working }
        guard let a = activity, let last = a.lastAction else { return .noData }
        if a.isWorking(now: now) { return .working }
        return .quiet(minutes: Int(now.timeIntervalSince(last)) / 60)
    }

    /// Ждёт ли агент человека — для плашки решений, фильтра «Ждут» и рамки панели. Тот же расчёт, что у статуса
    /// «ждёт…»: вопрос в хвосте панели; без захвата панели — признак `team status` или неотвеченный вопрос в транскрипте.
    /// `captured` — у панели был хотя бы один захват: тогда её хвост вернее кеша status.
    public func isWaiting(_ agent: Agent, pane: PaneOutput?, captured: Bool) -> Bool {
        guard agent.alive else { return false }
        if pane?.needsHuman == true { return true }
        return !captured && (agent.waitingHuman || Self.asksQuestion(agent, activity: activity[agent.name]))
    }

    /// Агент задал вопрос `AskUserQuestion` и ждёт ответа. Источники те же, что у карточки вопроса (`OpenQuestionSource`):
    /// - поле `question` из `team status`: хук `team` ловит вызов до ответа, в том числе одиночный;
    /// - неотвеченный вызов в транскрипте (`AgentActivity.pendingAsk`) — у роли, запущенной без хука. Одиночный вызов
    ///   Claude Code без хука пишет в транскрипт только вместе с ответом, так что этот путь ловит не всё.
    nonisolated static func asksQuestion(_ agent: Agent, activity: AgentActivity?) -> Bool {
        (agent.alive && agent.question != nil) || activity?.pendingAsk == true
    }

    /// Модель агента для строки состояния: из транскрипта (последний ответ или `/model`); поле model роли из
    /// `team status` — запасной путь, `inherit` в нём ничего не говорит.
    public func modelName(of agent: Agent) -> String? {
        activity[agent.name]?.model ?? agent.model.flatMap(ModelName.short)
    }

    /// Подсказка времени агента: запуск, последнее действие, текущий ход.
    public func timeTooltip(_ agent: Agent, screenTurn: TurnStatus? = nil, now: Date = Date()) -> String {
        AgentTime.tooltip(started: agent.started, activity: activity[agent.name], screenTurn: screenTurn, now: now)
    }

    /// Статус агента для показа — единственный расчёт: состояние, подпись и подсказка из экрана панели (если она
    /// захвачена) и транскрипта. `pane` — вывод панели, `liveKnown` — снимок панели свежий (панель на экране).
    public func agentStatus(_ agent: Agent, pane: PaneOutput? = nil, liveKnown: Bool = false, now: Date = Date()) -> AgentStatus {
        let act = activity[agent.name]
        // Строка хода на экране — прямое свидетельство работы, но только на свежем снимке и пока панель что-то выводит.
        let printing = pane?.lastOutput.map { now.timeIntervalSince($0) < 60 } ?? true
        let screenTurn = liveKnown && printing ? pane?.turn : nil
        let state = self.state(of: agent, asksTrust: pane?.asksTrust ?? false, asksPermission: pane?.asksPermission ?? false,
                               liveKnown: liveKnown, screenTurn: screenTurn, activity: act, now: now)
        let label = AgentTime.label(state, activity: act, screenTurn: screenTurn, now: now)
        return AgentStatus(state: state, label: label,
                           tooltip: label + "\n" + AgentTime.tooltip(started: agent.started, activity: act, screenTurn: screenTurn, now: now))
    }

    public func handoffs(of agent: String) -> [Handoff] { handoffs.filter { $0.agent == agent } }

    /// События waiting из журнала, после которых не было ни owner, ни report с той же задачей.
    /// Их пишет менеджер (`team log waiting …`), когда нужно слово владельца, например на слияние.
    public var ownerWaits: [TeamEvent] { Self.openWaits(events) }

    public nonisolated static func openWaits(_ newestFirst: [TeamEvent]) -> [TeamEvent] {
        var open: [String: TeamEvent] = [:]
        var order: [String] = []
        for e in newestFirst.sorted(by: { $0.ts < $1.ts }) {
            let key = e.task.flatMap { $0.isEmpty ? nil : "task:" + $0 } ?? "agent:" + e.agent
            switch e.type {
            case "waiting":
                if open[key] == nil { order.append(key) }
                open[key] = e
            case "owner", "report":
                open.removeValue(forKey: key)
            default:
                break
            }
        }
        return order.compactMap { open[$0] }.sorted { $0.ts > $1.ts }
    }

    /// Сообщение владельца в журнал (тип owner), чтобы фильтр «Вы» не был пуст. Старый CLI без team log — молча пропускаем.
    public func logOwnerMessage(_ text: String) {
        guard let cli, let manager = status?.manager?.name else { return }
        let short = String(text.replacingOccurrences(of: "\n", with: " ").prefix(120))
        let repo = self.repo
        // «--» перед текстом: сообщение вида «--help» не должно попасть в разбор аргументов.
        Task.detached { _ = await cli.run(["log", "owner", manager, "--", short], cwd: repo) }
    }
}

/// Итог `team restart` из плашки «в панели не сессия роли»: вывод или ошибка CLI.
public struct RoleRestore: Equatable, Sendable {
    public var ok: Bool
    public var message: String
}
