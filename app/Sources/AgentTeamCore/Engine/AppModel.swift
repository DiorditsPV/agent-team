import Foundation
import Observation

/// Проект в боковой панели: из сессии tmux `team-*` или подключённый вручную.
public struct ProjectEntry: Identifiable, Equatable, Sendable {
    public var session: String
    public var name: String
    public var repo: String?
    public var liveAgents: Int
    public var running: Bool
    public var id: String { session }
}

public enum AppSection: String, CaseIterable, Sendable {
    case team, roles, handoffs, journal, settings
}

public enum TeamMode: String, Sendable { case team, manager }

@MainActor
@Observable
public final class AppModel {
    public let hub: TmuxHub
    public private(set) var project: ProjectModel?
    public private(set) var selectedSession: String?
    public var section: AppSection = .team
    public var mode: TeamMode = .team
    public var openedAgent: String?
    /// Включена ли строка Claude Code вместо поля приложения (настройка живёт в приложении).
    @ObservationIgnored public var liveLineOn: () -> Bool = { false }
    /// Вкладка экрана агента при открытии (аргумент запуска `--tab` для снимков): `output`, `handoffs`, `instruction`, `permissions`.
    /// Экран агента применяет её один раз и сбрасывает.
    public var launchAgentTab: String?
    /// Картинка, раскрытая на всё окно (миниатюра в чате или в поле ввода).
    public var viewedImage: ViewedImage?
    public var roleTech = false
    /// Боковая панель скрыта (⌘\ или кнопка); состояние запоминается между запусками.
    public var sidebarCollapsed: Bool {
        didSet { defaults.set(sidebarCollapsed, forKey: Self.sidebarKey) }
    }
    public static let sidebarKey = "sidebarCollapsed"
    /// Роль, открытая на экране «Роли». Меняется только через `selectRole`.
    public private(set) var selectedRole: String?
    /// Выбрана роль общей библиотеки (имя может совпадать с ролью проекта).
    public private(set) var selectedRoleShared = false

    /// Выбор роли: имя и блок задаются вместе. По одному имени `RoleGroups.resolve` искал бы роль в блоке прежнего
    /// выбора: после общей роли созданная роль проекта не находилась, а одноимённая открывалась из библиотеки.
    public func selectRole(_ name: String?, shared: Bool = false) {
        selectedRole = name
        selectedRoleShared = shared
    }

    public private(set) var manualRepos: [String]
    /// Проекты из каталогов недавних сессий Claude Code (не сохраняются: находятся заново при старте).
    public private(set) var discoveredRepos: [String] = []
    public private(set) var discovering = false
    /// Найденные проекты, которые владелец убрал из списка.
    public private(set) var hiddenRepos: [String]
    /// Окружение login-шелла загружено, инструменты найдены заново.
    public private(set) var environmentReady = false
    /// Нет tmux или team: окно «Окружение» открывается само.
    public private(set) var missingEssentials = false
    public var toolPath: String {
        didSet {
            defaults.set(toolPath, forKey: "toolPath")
            cli = Self.makeCLI(toolPath: toolPath, socket: hub.socketName)
            for m in models.values { m.cli = cli }
            project?.refreshAll()
        }
    }
    @ObservationIgnored public private(set) var cli: TeamCLI?
    @ObservationIgnored private var sessionRepos: [String: String] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private let loadsLoginEnvironment: Bool

    /// `loginEnvironment: false` — без запуска шелла владельца (тесты).
    public init(defaults: UserDefaults = AppDefaults.store, socketName: String? = nil, loginEnvironment: Bool = true) {
        self.defaults = defaults
        self.loadsLoginEnvironment = loginEnvironment
        Task.detached(priority: .background) { Attachments.purge() }
        let tmux = ToolLocator.find("tmux") ?? "/opt/homebrew/bin/tmux"
        let socket = socketName ?? ProcessInfo.processInfo.environment["TEAM_TMUX_SOCKET"] ?? defaults.string(forKey: "tmuxSocket")
        hub = TmuxHub(tmuxPath: tmux, socketName: (socket?.isEmpty ?? true) ? nil : socket)
        sidebarCollapsed = defaults.bool(forKey: Self.sidebarKey)
        manualRepos = defaults.stringArray(forKey: "projects") ?? []
        hiddenRepos = defaults.stringArray(forKey: "hiddenProjects") ?? []
        let stored = defaults.string(forKey: "toolPath")
        toolPath = stored ?? TeamCLI.defaultToolRepo() ?? ""
        cli = Self.makeCLI(toolPath: toolPath, socket: hub.socketName)
        hub.onStructureChange = { [weak self] in self?.structureChanged() }
        // status перечитывается, когда у агента сменился признак «ждёт человека» (по захвату хвоста),
        // а не на каждую активность: работающий менеджер иначе запускал бы team status раз в 15 с.
        hub.onNeedsHumanChange = { [weak self] _ in
            guard let self, let p = self.project, p.session == self.hub.attachedSession else { return }
            p.paneActivity()
        }
    }

    /// CLI смотрит на тот же сервер tmux, что и приложение (`-L` → TEAM_TMUX_SOCKET).
    nonisolated static func makeCLI(toolPath: String, socket: String?) -> TeamCLI? {
        guard var c = TeamCLI.resolve(toolPath: toolPath) else { return nil }
        if let socket { c.environment["TEAM_TMUX_SOCKET"] = socket }
        return c
    }

    public func start(preferredProject: String? = nil) async {
        await loadEnvironment()
        startReapLoop()
        await discoverProjects()
        let want = preferredProject.map { $0.hasPrefix(TmuxListing.teamPrefix) ? $0 : TmuxListing.teamPrefix + $0 }
            ?? defaults.string(forKey: "selectedSession")
        await hub.connect(preferring: want)
        structureChanged()
        if let want, projects.contains(where: { $0.session == want }) {
            select(want)
        } else if let first = projects.first(where: \.running) ?? projects.first {
            select(first.session)
        }
    }

    /// Окружение login-шелла владельца — до первого вызова tmux и team: из Dock у процесса нет ни PATH
    /// с Homebrew, ни UTF-8 локали. После загрузки tmux и team ищутся заново.
    public func loadEnvironment() async {
        if loadsLoginEnvironment {
            ToolLocator.configure(login: await LoginEnvironment.capture())
        }
        if let tmux = ToolLocator.find("tmux") { hub.tmuxPath = tmux }
        cli = Self.makeCLI(toolPath: toolPath, socket: hub.socketName)
        for m in models.values { m.cli = cli }
        missingEssentials = EnvironmentCheck.missingEssentials(cli: cli)
        environmentReady = true
    }

    /// Проекты по каталогам недавних сессий Claude Code: разбор вне главного потока, при старте и по кнопке.
    public func discoverProjects(root: String = ProjectDiscovery.claudeProjects) async {
        guard !discovering else { return }
        discovering = true
        defer { discovering = false }
        discoveredRepos = await Task.detached(priority: .utility) { ProjectDiscovery.scan(root: root) }.value
        structureChanged()
    }

    public func hideProject(repo: String) {
        guard !hiddenRepos.contains(repo) else { return }
        hiddenRepos.append(repo)
        defaults.set(hiddenRepos, forKey: "hiddenProjects")
    }

    // MARK: лимиты подписки

    /// Лимиты подписки Claude для боковой панели; `nil` — данных нет.
    public private(set) var limits: UsageLimits?
    /// Когда лимиты читались: по этому времени строка решает, что окно уже сброшено.
    public private(set) var limitsReadAt = Date()

    /// Читает лимиты из `.team/statusline.json` известных проектов и кеша `/usage` в `~/.claude.json`, вне главного потока.
    public func refreshLimits(home: String = TranscriptParser.claudeHome) async {
        let repos = projects.compactMap(\.repo)
        let read = await Task.detached(priority: .utility) { UsageLimits.load(repos: repos, home: home) }.value
        limitsReadAt = Date()
        if read != limits { limits = read }
    }

    // MARK: проекты

    public var projects: [ProjectEntry] {
        var out: [ProjectEntry] = []
        var seen = Set<String>()
        for s in hub.sessions {
            seen.insert(s)
            out.append(ProjectEntry(session: s, name: String(s.dropFirst(TmuxListing.teamPrefix.count)),
                                    repo: sessionRepos[s], liveAgents: liveAgents(in: s), running: true))
        }
        for repo in knownRepos {
            let name = Self.projectName(repo: repo)
            let s = TmuxListing.teamPrefix + name
            guard !seen.contains(s) else { continue }
            seen.insert(s)
            out.append(ProjectEntry(session: s, name: name, repo: repo, liveAgents: 0, running: false))
        }
        return out
    }

    /// Подключённые вручную и найденные по сессиям Claude Code (кроме скрытых владельцем).
    private var knownRepos: [String] {
        manualRepos + discoveredRepos.filter { !manualRepos.contains($0) && !hiddenRepos.contains($0) }
    }

    /// Живые агенты сессии без менеджера — как на панелях «Команды».
    private func liveAgents(in session: String) -> Int {
        let manager = managerRole(session)
        return hub.panes.filter { p in
            p.session == session && !p.dead && !p.role.isEmpty && String(p.role.split(separator: "#").first ?? "") != manager
        }.count
    }

    @ObservationIgnored private var managerRoles: [String: String] = [:]

    private func managerRole(_ session: String) -> String {
        if let r = managerRoles[session] { return r }
        var role = "manager"
        if let repo = sessionRepos[session], let text = try? String(contentsOfFile: repo + "/agents/team.yaml", encoding: .utf8),
           let m = TeamYAMLSummary.parse(text).manager {
            role = m
        }
        if sessionRepos[session] != nil { managerRoles[session] = role }
        return role
    }

    /// Имя проекта: `project:` из agents/team.yaml, иначе имя каталога. Список проектов строится при каждой
    /// отрисовке боковой панели — имя читается из файла один раз на каталог.
    public nonisolated static func projectName(repo: String) -> String {
        if let n = nameCache.get(repo) { return n }
        let n = readProjectName(repo: repo)
        nameCache.set(repo, n)
        return n
    }

    private nonisolated static let nameCache = LockedCache()

    nonisolated static func readProjectName(repo: String) -> String {
        if let text = try? String(contentsOfFile: repo + "/agents/team.yaml", encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("project:") {
                let v = line.dropFirst(8).split(separator: "#").first?.trimmingCharacters(in: .whitespaces) ?? ""
                if !v.isEmpty { return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            }
        }
        return (repo as NSString).lastPathComponent
    }

    /// Репозиторий проекта по панелям его сессии: каталог с agents/team.yaml вверх от пути панели;
    /// сначала панель менеджера (у него нет отдельного worktree).
    nonisolated static func findRepo(panes: [PaneInfo]) -> String? {
        let ordered = panes.sorted { a, b in
            (a.role.contains("manager") ? 0 : 1, a.paneID) < (b.role.contains("manager") ? 0 : 1, b.paneID)
        }
        for p in ordered {
            var dir = p.path
            while dir.count > 1 {
                if FileManager.default.fileExists(atPath: dir + "/agents/team.yaml") { return dir }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    private func structureChanged() {
        for s in hub.sessions where sessionRepos[s] == nil {
            let panes = hub.panes.filter { $0.session == s }
            // Порядок: подключённый вручную → каталог из путей панелей сессии → найденный по сессиям Claude Code.
            // Найденный — последним: копия проекта с тем же project: не должна подменять каталог живой сессии.
            let named = { (repos: [String]) in repos.first { TmuxListing.teamPrefix + Self.projectName(repo: $0) == s } }
            if let manual = named(manualRepos) {
                sessionRepos[s] = manual
            } else if let r = Self.findRepo(panes: panes) {
                sessionRepos[s] = r
            } else if let found = named(knownRepos) {
                sessionRepos[s] = found
            }
        }
        if let s = selectedSession, s == hub.attachedSession { project?.tmuxStructureChanged() }
        attachLiveManager()
        if project == nil, let s = selectedSession { select(s) }
    }

    /// Старый CLI без --json: менеджер — по живой панели с @team_role, чтобы чат и ввод работали.
    private func attachLiveManager() {
        guard let p = project, p.status == nil, p.legacyCLI else { return }
        let role = p.managerRole
        if let pane = hub.panes.first(where: { $0.session == p.session && !$0.dead && $0.role.split(separator: "#").first.map(String.init) == role }) {
            p.useLiveManager(cwd: pane.path)
        }
    }

    @ObservationIgnored private var openedSessions: Set<String> = []
    /// Модели последних открытых проектов: возврат к проекту показывает его сразу. У невыбранных наблюдатели,
    /// хвосты файлов и загрузки приостановлены, данные сохранены.
    @ObservationIgnored private(set) var models: [String: ProjectModel] = [:]
    @ObservationIgnored private var recent: [String] = []
    public static let cachedProjects = 4

    /// Открытые модели в порядке открытия: экраны «Команды» этих проектов держатся готовыми.
    public private(set) var openModels: [ProjectModel] = []

    private func touch(_ session: String) {
        recent.removeAll { $0 == session }
        recent.append(session)
        // Модель с удержанными сообщениями менеджеру не вытесняется: её очередь пропала бы молча.
        while recent.count > Self.cachedProjects,
              let i = recent.dropLast().firstIndex(where: { (models[$0]?.heldCount ?? 0) == 0 }) {
            let old = recent.remove(at: i)
            models.removeValue(forKey: old)?.stop()
        }
        let list = models.values.sorted { $0.session < $1.session }
        if list.map(\.session) != openModels.map(\.session) || zip(list, openModels).contains(where: { $0 !== $1 }) {
            openModels = list
        }
    }

    /// Автоостановка: раз в минуту `team reap` для каждого проекта с живой сессией команды, открыт он в приложении или нет.
    /// Один цикл на приложение, фоном; вызов проекта не блокирует интерфейс (запрос идёт подпроцессом).
    public static let reapInterval: TimeInterval = 60
    @ObservationIgnored private var reapLoop: Task<Void, Never>?

    /// Один проход автоостановки. У открытого проекта — через его модель (очередь и черновик менеджера идут в `--keep`);
    /// у неоткрытого модель не создаётся: нужны только каталог и cli, очереди и черновика там нет.
    @discardableResult
    public func reapAll() async -> [String: [ReapEntry]] {
        var out: [String: [ReapEntry]] = [:]
        for t in Reap.targets(projects) {
            if let m = models[t.session] {
                out[t.session] = await m.reapTick()
            } else if let cli {
                out[t.session] = await Reap.run(cli: cli, repo: t.repo, session: t.session, keep: [])
            }
        }
        return out
    }

    private func startReapLoop() {
        guard reapLoop == nil else { return }
        reapLoop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.reapInterval * 1_000_000_000))
                guard let self else { return }
                await self.reapAll()
            }
        }
    }

    public func select(_ session: String) {
        startReapLoop()
        if session == selectedSession, project != nil { return }
        SwitchClock.shared.begin(session, label: openedSessions.contains(session) ? "повторно" : "впервые")
        openedSessions.insert(session)
        // Выбор агента и роли сбрасывается, только когда проект действительно сменился. Повторный select той же
        // сессии (каталог проекта стал известен позже, пришла структура tmux) выбор не трогает: иначе
        // `--screen agent --agent X` терялся, если проект находился уже после открытия экрана агента.
        let switched = session != selectedSession
        selectedSession = session
        defaults.set(session, forKey: "selectedSession")
        if switched {
            openedAgent = nil
            roleTech = false
            selectRole(nil)
        }
        project?.suspend()
        project = nil
        let entry = projects.first { $0.session == session }
        if let repo = entry?.repo ?? sessionRepos[session] {
            if let cached = models[session], cached.repo == repo {
                project = cached
                cached.resume()
            } else {
                models[session]?.stop()
                let p = ProjectModel(repo: repo, session: session, cli: cli, defaults: defaults)
                p.onLegacyCLI = { [weak self] in self?.attachLiveManager() }
                p.livePanes = { [weak self] in self?.hub.panes.filter { $0.session == session } ?? [] }
                p.outbox.writer = hub
                p.outbox.liveLineOn = { [weak self] in self?.liveLineOn() ?? false }
                p.appVisible = { [weak self] in self?.hub.isAppVisible ?? true }
                models[session] = p
                project = p
                p.start()
            }
            touch(session)
        }
        // Хаб запоминает выбор и прикрепится к сессии, как только она появится (team up после выбора).
        Task { await hub.connect(preferring: session) }
    }

    /// Удержанные сообщения менеджерам всех открытых проектов: при выходе они пропали бы.
    public var heldMessages: Int { models.values.reduce(0) { $0 + $1.heldCount } }

    /// Выход с непустой очередью, «Отправить и выйти»: удержанное каждого проекта уходит в панель его менеджера сейчас.
    /// `nil` — всё ушло; иначе почему не ушло (неотправленное осталось в очереди). `freshRole` — подтверждать роль
    /// менеджера свежим status (`ManagerOutbox.sendAllHeld`).
    public func sendAllHeld(freshRole: Bool = true) async -> String? {
        for m in models.values.sorted(by: { $0.session < $1.session }) where m.heldCount > 0 {
            guard await m.outbox.sendAllHeld(freshRole: freshRole) else { return m.outbox.error ?? "запись в панель менеджера не удалась" }
        }
        return nil
    }

    /// Выход по SIGTERM (перезапуск сборки без владельца): удержанные уходят менеджерам; что не ушло — в черновики
    /// проектов. Запись ждётся не дольше `deadline`: зависшая запись не должна держать процесс, которому велели выйти.
    /// Возвращает причину сбоя или `nil`.
    public func flushHeldForSignal(deadline: TimeInterval = 5) async -> String? {
        guard heldMessages > 0 else { return nil }
        final class Once { var done = false }
        let once = Once()
        let failure: String? = await withCheckedContinuation { c in
            Task { @MainActor in
                // Свежего status не ждём: его вызов съел бы срок выхода, а пришедший ответ двинул бы очередь в панель,
                // и к сроку в черновик было бы нечего вернуть. Роль — по последнему ответу; не подтверждена — в черновик.
                let r = await self.sendAllHeld(freshRole: false)
                if !once.done { once.done = true; c.resume(returning: r) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                if !once.done { once.done = true; c.resume(returning: "запись в панель не закончилась за \(Int(deadline)) с") }
            }
        }
        if failure != nil { models.values.forEach { $0.returnHeldToDraft() } }
        return failure
    }

    public func addProject(repo: String) -> Bool {
        guard FileManager.default.fileExists(atPath: repo + "/agents/team.yaml") else { return false }
        if !manualRepos.contains(repo) {
            manualRepos.append(repo)
            defaults.set(manualRepos, forKey: "projects")
        }
        select(TmuxListing.teamPrefix + Self.projectName(repo: repo))
        return true
    }

    /// «Поднять команду» у остановленного проекта: `team up` в его каталоге. team up не делает attach и не ждёт
    /// ввода; проект открывается, когда появится его сессия tmux.
    @discardableResult
    public func up(repo: String) async -> Bool {
        let session = TmuxListing.teamPrefix + Self.projectName(repo: repo)
        select(session)
        guard let p = project, p.repo == repo else { return false }
        let ok = await p.up()
        // Сервер без проектов проверяется раз в минуту — после team up хаб подключается сразу.
        if ok { await hub.connect(preferring: session) }
        return ok
    }

    public func removeProject(repo: String) {
        manualRepos.removeAll { $0 == repo }
        defaults.set(manualRepos, forKey: "projects")
    }

    public func openAgent(_ name: String) {
        section = .team
        openedAgent = name
    }

    /// Сессия ведётся вручную подключённым проектом — значит, у неё есть репозиторий.
    public func repo(for session: String) -> String? { sessionRepos[session] ?? projects.first { $0.session == session }?.repo }
}

/// Кэш имён проектов: читается из любого потока.
final class LockedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func get(_ k: String) -> String? { lock.withLock { values[k] } }
    func set(_ k: String, _ v: String) { lock.withLock { values[k] = v } }
}
