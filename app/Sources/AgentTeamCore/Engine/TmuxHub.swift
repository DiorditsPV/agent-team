import Foundation
import Observation

/// Вывод одной панели для показа. Отдельный объект на панель: обновление одной панели
/// не перерисовывает остальные.
@MainActor
@Observable
public final class PaneOutput {
    public let paneID: String
    public internal(set) var lines: [StyledLine] = []
    /// Время последнего вывода панели («тихо», последнее действие) — из уведомлений tmux, без опроса.
    public internal(set) var lastOutput: Date?
    /// В хвосте панели вопрос о доверии к каталогу.
    public internal(set) var asksTrust = false
    /// В хвосте панели запрос права (инструмент вне allow) или другой вопрос с выбором.
    public internal(set) var asksPermission = false
    /// Строка хода Claude Code на экране («✳ Shimmying… (2m 14s · ↓ 3.1k tokens)»): агент работает прямо сейчас.
    public internal(set) var turn: TurnStatus?
    /// Остальное из разбора экрана (`PaneScreen`): поля отдельные, чтобы вид, читающий одно, не пересчитывался от
    /// смены другого (черновик ответа меняется на каждом захвате, вопрос — редко).
    public internal(set) var askFormOpen = false
    public internal(set) var askQuestion: String?
    public internal(set) var inputTyped = false
    public internal(set) var notice: WaitingNotice?
    public internal(set) var reply: LiveReply?
    /// Открыт экран встроенной команды Claude Code (`PaneScreen.commandScreen`).
    public internal(set) var commandScreen = false
    /// Строка ввода Claude Code на экране (`PaneScreen.inputLine`).
    public internal(set) var inputLine = true
    /// Цвета, которыми в этой панели мигал кружок идущего инструмента.
    @ObservationIgnored var toolColors: Set<TermColor> = []
    /// Положение курсора панели (столбец, строка с нуля): только у панелей с детализацией `.live`.
    public internal(set) var cursor: (x: Int, y: Int)?
    /// Ширина панели в столбцах: у панелей с детализацией `.live`.
    public internal(set) var columns: Int?
    @ObservationIgnored var lastHash: Int = 0

    init(paneID: String) { self.paneID = paneID }

    /// Ждёт решения человека в своей панели.
    public var needsHuman: Bool { asksTrust || asksPermission }

    func apply(_ s: PaneScreen) {
        if turn != s.turn { turn = s.turn }
        if asksTrust != s.asksTrust { asksTrust = s.asksTrust }
        if asksPermission != s.asksPermission { asksPermission = s.asksPermission }
        if askFormOpen != s.askFormOpen { askFormOpen = s.askFormOpen }
        if askQuestion != s.askQuestion { askQuestion = s.askQuestion }
        if inputTyped != s.inputTyped { inputTyped = s.inputTyped }
        if notice != s.notice { notice = s.notice }
        if reply != s.reply { reply = s.reply }
        if commandScreen != s.commandScreen { commandScreen = s.commandScreen }
        if inputLine != s.inputLine { inputLine = s.inputLine }
    }
}

/// Как часто перерисовывать панель и сколько захватывать.
public enum PaneDetail: Int, Comparable, Sendable {
    case grid = 0     // сетка «Команды»: не чаще 4 Гц, видимый экран
    case focus = 1    // экран агента: не чаще 15 Гц, с историей
    case live = 2     // строка ввода менеджера в чате: до 60 Гц, видимый экран и курсор

    public static func < (a: PaneDetail, b: PaneDetail) -> Bool { a.rawValue < b.rawValue }

    var interval: TimeInterval { self == .grid ? 0.25 : self == .focus ? 1.0 / 15 : 0.016 }
    var history: Int { self == .focus ? 300 : 0 }
}

/// Одно соединение tmux control mode на всё приложение.
///
/// - Есть сессии team-* — клиент прикреплён к сессии выбранного проекта; смена проекта — switch-client.
/// - Сессий team-* нет, но сервер жив — соединения нет. К чужим сессиям клиент не прикрепляется: tmux без -t
///   бил бы в сессию с нашим клиентом, она становилась бы «последней» для tmux attach и выглядела attached.
///   Появление team-* проверяется `tmux -N list-sessions` раз в 60 с (только в этом состоянии) и сразу
///   по действию владельца.
/// - Сервера нет — соединения нет; появление сокета ловится kqueue на каталоге сокетов.
@MainActor
@Observable
public final class TmuxHub {
    public private(set) var connected = false
    /// Сессия, к которой прикреплён клиент (может быть не team-*, если таких нет).
    public private(set) var attachedSession: String?
    /// Сессии team-* и число живых агентов в каждой.
    public private(set) var sessions: [String] = []
    public private(set) var agentCounts: [String: Int] = [:]
    public private(set) var panes: [PaneInfo] = []
    /// Имена отдельных сессий из списка приложения; задаёт `AppModel`.
    public var soloNames: Set<String> = []
    /// Живые tmux-сессии из `soloNames`.
    public private(set) var soloLive: Set<String> = []

    /// Изменилась структура: панели появились или исчезли, сменились сессии.
    @ObservationIgnored public var onStructureChange: (() -> Void)?
    /// Панель прикреплённой сессии что-то вывела (в том числе на паузе).
    @ObservationIgnored public var onPaneActivity: ((String) -> Void)?
    /// У панели сменился признак «ждёт человека» (доверие или запрос права в хвосте).
    @ObservationIgnored public var onNeedsHumanChange: ((String) -> Void)?
    /// Сырые сигналы %output по панелям — для проверки, что скрытые панели действительно молчат.
    @ObservationIgnored var rawOutputCount: [String: Int] = [:]

    /// Путь к tmux: уточняется после загрузки окружения login-шелла.
    @ObservationIgnored public var tmuxPath: String
    @ObservationIgnored public let socketName: String?
    /// Окружение tmux; nil — общее окружение дочерних процессов. Тесты задают свой TMUX_TMPDIR.
    @ObservationIgnored public var environmentOverride: [String: String]?
    @ObservationIgnored private var client: ControlClient?
    @ObservationIgnored private var outputs: [String: PaneOutput] = [:]
    @ObservationIgnored private var interest: [String: [PaneDetail: Int]] = [:]
    /// Панели, чей черновик ответа сейчас показывают (`readReply`).
    @ObservationIgnored private var replyReaders: [String: Int] = [:]
    @ObservationIgnored private var streaming: Set<String> = []        // панели с включённым выводом
    @ObservationIgnored private var knownPaused: Set<String> = []      // pause уже отправлен этим клиентом
    @ObservationIgnored private var activitySeen: Set<String> = []
    @ObservationIgnored private var lastCapture: [String: Date] = [:]
    @ObservationIgnored private var lastProbe: [String: Date] = [:]
    /// Панели, хвост которых уже проверен хотя бы раз этим клиентом.
    @ObservationIgnored private var probedOnce: Set<String> = []
    @ObservationIgnored private var captureScheduled: Set<String> = []
    @ObservationIgnored private var captureInFlight: Set<String> = []
    @ObservationIgnored private var captureAgain: Set<String> = []
    /// Растёт при сбросе состояния клиента: захват, начатый до сброса, не трогает флаги захватов после него.
    @ObservationIgnored private var clientGeneration = 0
    @ObservationIgnored private var appVisible = true
    @ObservationIgnored private var listScheduled = false
    @ObservationIgnored private var fallbackTimer: Timer?
    @ObservationIgnored private var socketWatch: DirWatch?
    @ObservationIgnored private var wantedSession: String?
    @ObservationIgnored private var connecting = false
    /// Во время подключения пришёл новый запрос (team up, kqueue): повторить, когда текущее закончится, —
    /// текущее могло прочитать список сессий до появления новой.
    @ObservationIgnored private var connectAgain = false
    @ObservationIgnored private var probeScheduled: Set<String> = []
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var pollTimer: Timer?
    /// Как часто проверять появление team-* на живом сервере без проектов.
    @ObservationIgnored var pollInterval: TimeInterval = 60

    public init(tmuxPath: String, socketName: String?) {
        self.tmuxPath = tmuxPath
        self.socketName = socketName
    }

    /// Прикреплённая сессия — проект (team-*), а не чужая сессия для уведомлений.
    public var attachedTeamSession: String? {
        guard let s = attachedSession, s.hasPrefix(TmuxListing.teamPrefix) else { return nil }
        return s
    }

    /// Прикреплённая сессия — проект или отдельная одиночная сессия: для них идёт поток вывода панелей.
    public var attachedAppSession: String? {
        guard let s = attachedSession, s.hasPrefix(TmuxListing.teamPrefix) || soloNames.contains(s) else { return nil }
        return s
    }

    /// Каталог сокетов tmux: $TMUX_TMPDIR (или /tmp)/tmux-<uid>.
    public nonisolated static func socketDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return (base as NSString).appendingPathComponent("tmux-\(getuid())")
    }

    private var environment: [String: String] { environmentOverride ?? ToolLocator.environment }

    private var socketPath: String {
        (Self.socketDirectory(environment: environment) as NSString).appendingPathComponent(socketName ?? "default")
    }

    // MARK: подключение

    /// Подключиться и прикрепиться к сессии `session`, когда она есть.
    public func connect(preferring session: String?) async {
        stopped = false
        await connectIfNeeded(preferring: session)
    }

    private func connectIfNeeded(preferring session: String?) async {
        wantedSession = session
        guard !stopped else { return }
        // %exit и завершение процесса оба ведут сюда: второе соединение не поднимаем.
        guard !connecting else { connectAgain = true; return }
        connecting = true
        defer {
            connecting = false
            if connectAgain {
                connectAgain = false
                Task { await self.connectIfNeeded(preferring: self.wantedSession) }
            }
        }
        if let client, client.isConnected {
            await followWanted()
            return
        }
        // Нет файла сокета — нет сервера: подпроцесс не запускаем, ждём сокет по kqueue.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            markDisconnected()
            waitForServer()
            return
        }
        let all = await oneShotSessions()
        guard !stopped else { return }
        sessions = TmuxListing.teamSessions(all)
        soloLive = Set(all.filter { soloNames.contains($0) })
        let target = session.flatMap { sessions.contains($0) || soloLive.contains($0) ? $0 : nil }
            ?? sessions.first ?? soloLive.sorted().first
        guard let target else {
            markDisconnected()
            if all.isEmpty { waitForServer() } else { pollForProjects() }
            return
        }
        stopWaiting()
        stopPolling()
        let c = ControlClient(tmuxPath: tmuxPath, socketName: socketName, environment: environment)
        // Уведомления копятся и уходят на главный поток пачкой: вывод панелей приходит сотнями строк в секунду.
        let inbox = EventInbox()
        do {
            try c.start(session: target, onEvent: { [weak self] e in
                guard inbox.push(e) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        for ev in inbox.drain() { self?.handle(ev) }
                    }
                }
            }, onExit: { [weak self] in
                Task { @MainActor in self?.didDisconnect() }
            })
        } catch {
            markDisconnected()
            waitForServer()
            return
        }
        client = c
        connected = true
        resetClientState()
        attachedSession = target
        // Структура панелей прикреплённой сессии: смерть панели (remain-on-exit) видна только по pane_dead.
        c.fire("refresh-client -B " + TmuxQuote.word("agdead:%*:#{pane_dead}"))
        // Активность панелей на паузе: %output от них не приходит, а подписка на размер истории и строку курсора
        // присылает %subscription-changed не чаще раза в секунду (проверено на tmux 3.6b).
        c.fire("refresh-client -B " + TmuxQuote.word("agact:%*:#{history_size}:#{cursor_y}"))
        c.fire("refresh-client -f pause-after=5")
        await refreshListing()
        startFallbackTimer()
    }

    /// Полная остановка: соединение закрыто, переподключений нет.
    public func disconnect() {
        stopped = true
        client?.stop()
        client = nil
        markDisconnected()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        stopWaiting()
        stopPolling()
    }

    private func markDisconnected() {
        connected = false
        attachedSession = nil
        resetClientState()
    }

    /// У нового клиента и после смены сессии tmux ничего не знает о наших паузах: всё отправляется заново.
    private func resetClientState() {
        clientGeneration += 1
        streaming = []
        knownPaused = []
        activitySeen = []
        probedOnce = []
        captureInFlight = []
        captureAgain = []
        captureScheduled = []
    }

    /// Сервер жив, проектов нет: редкая проверка без соединения, только в этом состоянии.
    private func pollForProjects() {
        guard !stopped, pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.connected else { return }
                await self.connectIfNeeded(preferring: self.wantedSession)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Прикрепиться к выбранному проекту, если его сессия есть; к любой team-*, если сейчас прикреплены к чужой.
    private func followWanted() async {
        guard client?.isConnected == true else { return }
        var target: String?
        if let w = wantedSession, sessions.contains(w) || soloLive.contains(w) { target = w }
        else if attachedAppSession == nil { target = sessions.first ?? soloLive.sorted().first }
        if let t = target, t != attachedSession {
            await switchTo(t)
        } else if attachedAppSession == nil {
            leaveForeignSession()
        }
    }

    private func switchTo(_ session: String) async {
        guard let c = client else { return }
        do {
            _ = try await c.run("switch-client -t " + TmuxQuote.word(TmuxTarget.session(session)))
            sessionChanged(to: session)
            await refreshListing()
        } catch {}
    }

    private func sessionChanged(to session: String) {
        guard session != attachedSession else { return }
        attachedSession = session
        resetClientState()
        reconcileStreaming()
    }

    /// Закрыли сессию проекта, и tmux перевёл клиент в чужую сессию: уходим сразу. Есть другой проект —
    /// переключаемся на него, нет — закрываем соединение и ждём проекты.
    private func leaveForeignSession() {
        guard client != nil, attachedAppSession == nil else { return }
        client?.stop()
        client = nil
        markDisconnected()
        fallbackTimer?.invalidate()
        Task { await connectIfNeeded(preferring: wantedSession) }
    }

    private func didDisconnect() {
        client?.stop()
        client = nil
        markDisconnected()
        fallbackTimer?.invalidate()
        guard !stopped else { return }
        Task { await connectIfNeeded(preferring: wantedSession) }
    }

    // MARK: отдельные сессии

    public enum SoloError: Error, Equatable {
        case tmux(String), noClaude, missingDir
        /// Каталог, который tmux прочёл бы как разделитель команд (`;` в конце).
        case badDirectory(String)
        /// Нет id сессии Claude для `--session-id` или `--resume`.
        case noSessionID
        /// Сессия с таким именем принадлежит другой записи (другая сборка на том же сервере).
        case nameTaken(String)
    }

    /// Тесты: вызов, который должен упасть (проверка отката после ошибки посреди запуска).
    @ObservationIgnored var failTmux: (([String]) -> Bool)?

    private func tmuxOnce(_ args: [String], timeout: TimeInterval = 15) async -> ProcessResult {
        if let fail = failTmux, fail(args) { return ProcessResult(status: 1, stdout: Data(), stderr: "сбой для проверки") }
        return await Shell.run(tmuxPath, ["-u"] + (socketName.map { ["-L", $0] } ?? []) + args, environment: environment, timeout: timeout)
    }

    private struct SoloPane {
        var id: String
        var dead: Bool
        var soloID: String
        var startCommand: String
        /// Запущен `respawn-pane` нашей команды (`exec claude …`), а не оболочка по умолчанию от `new-session`.
        var launched: Bool { startCommand.contains("exec ") }
    }

    private func soloPanes(_ session: String) async -> [SoloPane]? {
        let fmt = "#{pane_id}\t#{pane_dead}\t#{@solo_id}\t#{pane_start_command}"
        let r = await tmuxOnce(["list-panes", "-s", "-t", TmuxTarget.session(session), "-F", fmt])
        guard r.status == 0 else { return nil }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map { line in
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            return SoloPane(id: f[0], dead: f.count > 1 && f[1] == "1", soloID: f.count > 2 ? f[2] : "",
                            startCommand: f.count > 3 ? f[3] : "")
        }
    }

    /// Имена живых `cc-*` на сервере: при выборе имени новой записи они считаются занятыми (сборка владельца и
    /// Dev-сборка работают на одном сервере tmux со своими списками).
    public func liveSoloSessionNames() async -> Set<String> {
        let r = await tmuxOnce(["-N", "list-sessions", "-F", TmuxListing.sessionFormat])
        guard r.status == 0 else { return [] }
        return Set(TmuxListing.soloSessions(String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)))
    }

    /// `-c` tmux раскрывает как формат: `#` надо удвоить, иначе `c#` или `a#Sb` молча дают домашний каталог.
    nonisolated static func tmuxPathArgument(_ cwd: String) -> String { cwd.replacingOccurrences(of: "#", with: "##") }

    /// Запускает claude в tmux-сессии записи (или продолжает: панель мертва — `respawn-pane`, сессии нет — создаётся).
    /// Одноразовые вызовы, не control-клиент: соединения может не быть, пока нет ни одной `team-*`.
    /// Порядок как у `team` (`tmuxctl.open_role`): панель с оболочкой, настройка, и только потом команда.
    /// Выбор сессии в приложении остаётся за вызывающим: хаб здесь только подключается, если соединения нет.
    @discardableResult
    public func startSolo(_ s: SoloSession, claude: String? = nil, resume: Bool) async throws -> String {
        guard let bin = claude ?? ProcessInfo.processInfo.environment["TEAM_CLAUDE_BIN"].flatMap({ $0.isEmpty ? nil : $0 })
                ?? ToolLocator.find("claude") else { throw SoloError.noClaude }
        let sid = resume ? (s.sessionID.isEmpty ? s.launchSessionID : s.sessionID) : s.launchSessionID
        guard !sid.isEmpty else { throw SoloError.noSessionID }
        // tmux при несуществующем -c молча берёт домашний каталог: сессия ушла бы не туда.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: s.cwd, isDirectory: &isDir), isDir.boolValue else { throw SoloError.missingDir }
        // Аргумент на «;» tmux читает как разделитель команд и падает на следующем флаге.
        guard !s.cwd.hasSuffix(";") else { throw SoloError.badDirectory(s.cwd) }
        let dir = Self.tmuxPathArgument(s.cwd)
        soloNames.insert(s.tmuxName)
        let id = s.id.uuidString
        var pane = ""
        var created = false
        if let existing = await soloPanes(s.tmuxName) {
            // Чужая метка — сессия другой записи с тем же именем: не трогаем.
            if let foreign = existing.first(where: { !$0.soloID.isEmpty && $0.soloID != id }) { throw SoloError.nameTaken(foreign.soloID) }
            guard let mine = existing.first(where: { $0.soloID == id }) ?? existing.first else { throw SoloError.tmux("в сессии нет панелей") }
            // Живую панель с нашим claude не перезапускаем: продолжение там, где ход идёт, оборвало бы его.
            // Живая оболочка без запуска — остаток прерванного старта: запускаем в ней.
            if !mine.dead, mine.launched { await syncAfterStart(); return mine.id }
            pane = mine.id
        } else {
            let r = await tmuxOnce(["new-session", "-d", "-P", "-F", "#{pane_id}", "-s", s.tmuxName, "-c", dir, "-x", "200", "-y", "50"])
            pane = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.status == 0, !pane.isEmpty else { throw SoloError.tmux(r.stderr) }
            created = true
        }
        do {
            for opt in [["set-option", "-p", "-t", pane, "@solo_id", id], ["set-option", "-w", "-t", pane, "remain-on-exit", "on"]] {
                let r = await tmuxOnce(opt)
                guard r.status == 0 else { throw SoloError.tmux(r.stderr) }
            }
            let r = await tmuxOnce(["respawn-pane", "-k", "-t", pane, "-c", dir]
                                   + SoloLaunch.command(claude: bin, sessionID: sid, resume: resume))
            guard r.status == 0 else { throw SoloError.tmux(r.stderr) }
        } catch {
            // Сессия, созданная этим вызовом, с голой оболочкой никому не нужна: «Продолжить» вернуло бы её навсегда.
            if created { _ = await tmuxOnce(["kill-session", "-t", TmuxTarget.session(s.tmuxName)]) }
            throw error
        }
        await syncAfterStart()
        return pane
    }

    private func syncAfterStart() async {
        if client?.isConnected == true { await refreshListing() } else { await connectIfNeeded(preferring: wantedSession) }
    }

    /// Убирает только свою tmux-сессию: по точному имени из записи и только если метка панели — этой записи
    /// (или пуста). Процессы по имени не трогаются.
    public func stopSolo(_ s: SoloSession) async {
        if let panes = await soloPanes(s.tmuxName),
           panes.contains(where: { !$0.soloID.isEmpty && $0.soloID != s.id.uuidString }) { return }
        _ = await tmuxOnce(["kill-session", "-t", TmuxTarget.session(s.tmuxName)])
        if client?.isConnected == true { await refreshListing() }
    }

    /// Все сессии сервера одним коротким вызовом — только при подключении, не по таймеру.
    private func oneShotSessions() async -> [String] {
        let r = await Shell.run(tmuxPath, ["-u"] + (socketName.map { ["-L", $0] } ?? []) + ["-N", "list-sessions", "-F", TmuxListing.sessionFormat],
                                environment: environment, timeout: 10)
        guard r.status == 0 else { return [] }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Сервера нет: kqueue на каталог сокетов. Срабатывает на любой файл каталога, но подпроцесс
    /// запускается, только когда появился наш сокет.
    private func waitForServer() {
        guard !stopped, socketWatch == nil else { return }
        let dir = Self.socketDirectory(environment: environment)
        let path = socketPath
        let dirExists = FileManager.default.fileExists(atPath: dir)
        // После загрузки каталога tmux-<uid> ещё нет: смотрим на родителя, а когда каталог появится —
        // переносим наблюдение в него (сокет создаётся внутри, родитель этого не увидит).
        socketWatch = DirWatch(path: dirExists ? dir : DirWatch.nearestExisting(dir)) { [weak self] in
            Task { @MainActor in
                guard let self, !self.connected else { return }
                if FileManager.default.fileExists(atPath: path) {
                    await self.connectIfNeeded(preferring: self.wantedSession)
                } else if !dirExists, FileManager.default.fileExists(atPath: dir) {
                    self.stopWaiting()
                    self.waitForServer()
                }
            }
        }
    }

    private func stopWaiting() {
        socketWatch?.stop()
        socketWatch = nil
    }

    /// Чужие сессии не присылают уведомлений о панелях (проверено на tmux 3.6b: split/kill-pane в неприкреплённой
    /// сессии дают максимум %window-pane-changed). Поэтому счётчики остальных проектов сверяются раз в минуту
    /// командой по тому же каналу (подпроцессов нет).
    private func startFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleListing() }
        }
    }

    // MARK: события

    private func handle(_ e: ControlEvent) {
        switch e {
        case let .output(pane):
            rawOutputCount[pane, default: 0] += 1
            guard attachedAppSession != nil else { return }
            let o = output(for: pane)
            // Отметка времени грубая (раз в секунду): иначе каждое уведомление перерисовывало бы подписи.
            let now = Date()
            if now.timeIntervalSince(o.lastOutput ?? .distantPast) >= 1 { o.lastOutput = now }
            if streaming.contains(pane) { scheduleCapture(pane) }
        case let .pause(pane):
            // Отстали от панели на 5 с. Видимую — продолжить, невидимая и так на паузе.
            if streaming.contains(pane) { client?.fire("refresh-client -A " + TmuxQuote.word(pane + ":continue")) }
        case .resumed:
            break
        case let .notification(name, args):
            switch name {
            case "subscription-changed":
                // %subscription-changed <имя> $s @w <idx> %pane : <значение>
                if args.first == "agact" {
                    if args.count > 4, attachedAppSession != nil { paneActivity(args[4]) }
                } else {
                    scheduleListing()
                }
            case "session-changed":
                // Сессию клиента закрыли — tmux сам переводит его на другую, возможно, чужую.
                if args.count > 1 { sessionChanged(to: args[1...].joined(separator: " ")) }
                if attachedAppSession == nil {
                    Task { await self.followWanted() }
                } else {
                    scheduleListing()
                }
            case "sessions-changed", "window-add", "window-close", "unlinked-window-add", "unlinked-window-close",
                 "layout-change", "window-pane-changed":
                scheduleListing()
            default:
                break
            }
        case .exit:
            didDisconnect()
        case .response:
            break
        }
    }

    /// Первое значение подписки приходит сразу при подписке — это не активность.
    private func paneActivity(_ pane: String) {
        guard activitySeen.contains(pane) else { activitySeen.insert(pane); return }
        let o = output(for: pane)
        let now = Date()
        if now.timeIntervalSince(o.lastOutput ?? .distantPast) >= 1 { o.lastOutput = now }
        if !streaming.contains(pane) { probe(pane) }
        onPaneActivity?(pane)
    }

    private func scheduleListing() {
        guard !listScheduled else { return }
        listScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            listScheduled = false
            await refreshListing()
        }
    }

    public func refreshListing() async {
        guard let c = client else { return }
        guard let sl = try? await c.run(TmuxListing.listSessionsCommand),
              let pl = try? await c.run(TmuxListing.listPanesCommand) else { return }
        let newSessions = TmuxListing.teamSessions(sl)
        let newPanes = TmuxListing.parsePanes(pl)
        let newSolo = Set(sl.map { $0.trimmingCharacters(in: .whitespaces) }.filter { soloNames.contains($0) })
        let changed = newSessions != sessions || newPanes != panes || newSolo != soloLive
        sessions = newSessions
        soloLive = newSolo
        panes = newPanes
        agentCounts = TmuxListing.liveAgentCounts(newPanes)
        forgetVanishedPanes()
        reconcileStreaming()
        probeNewPanes()
        if changed { onStructureChange?() }
        // Сессия выбранного проекта появилась (team up) или прикреплены к чужой сессии — переключиться.
        await followWanted()
    }

    /// При открытии проекта и при появлении панели — один захват хвоста каждой панели агента, даже скрытой:
    /// агент, который уже стоит на вопросе о доверии, молчит, и сигнала активности от него не будет.
    private func probeNewPanes() {
        guard let session = attachedAppSession else { return }
        let fresh = panes.filter { p in p.session == session && !p.dead && (!p.role.isEmpty || !p.soloID.isEmpty) && !probedOnce.contains(p.paneID) }
        // Сначала панели на экране: их хвост владелец видит сразу после переключения. Экран вернувшегося проекта
        // не появляется заново (держится готовым), поэтому show() их не захватывает — захват здесь.
        for p in fresh.sorted(by: { (detail(of: $0.paneID) != nil ? 0 : 1) < (detail(of: $1.paneID) != nil ? 0 : 1) }) {
            probedOnce.insert(p.paneID)
            lastProbe[p.paneID] = Date()
            captureNow(p.paneID)
            // Скрытой панели — ещё один захват в конце окна: вопрос, нарисованный до первого значения подписки
            // активности, активностью не считается (первое значение отбрасывается). Видимая получает вывод сама.
            if detail(of: p.paneID) == nil { probe(p.paneID) }
        }
    }

    /// Данные исчезнувших панелей не копятся.
    private func forgetVanishedPanes() {
        let alive = Set(panes.map(\.paneID))
        for id in outputs.keys where !alive.contains(id) && interest[id] == nil { outputs.removeValue(forKey: id) }
        for id in lastCapture.keys where !alive.contains(id) { lastCapture.removeValue(forKey: id) }
        for id in lastProbe.keys where !alive.contains(id) { lastProbe.removeValue(forKey: id) }
        knownPaused.formIntersection(alive)
        streaming.formIntersection(alive)
        activitySeen.formIntersection(alive)
        probedOnce.formIntersection(alive)
    }

    // MARK: подписка на вывод

    public func output(for pane: String) -> PaneOutput {
        if let o = outputs[pane] { return o }
        let o = PaneOutput(paneID: pane)
        outputs[pane] = o
        return o
    }

    /// Панель видна на экране с данной детализацией. Вывод включается только для видимых панелей.
    public func show(_ pane: String, detail: PaneDetail) {
        interest[pane, default: [:]][detail, default: 0] += 1
        reconcileStreaming()
        captureNow(pane)
    }

    /// Черновик ответа (`PaneOutput.reply`) нужен только чату менеджера, а его разбор — самая дорогая часть разбора
    /// экрана: он считается лишь у панелей, чей черновик сейчас показывают.
    public func readReply(_ pane: String, _ on: Bool) {
        replyReaders[pane, default: 0] += on ? 1 : -1
        if replyReaders[pane, default: 0] <= 0 { replyReaders[pane] = nil }
        // Сразу по последнему захвату: следующий может прийти не скоро.
        let o = output(for: pane)
        o.reply = replyReaders[pane] != nil && o.notice == nil && !o.commandScreen ? LiveReply.extract(o.lines, toolColors: o.toolColors) : nil
    }

    public func hide(_ pane: String, detail: PaneDetail) {
        guard var m = interest[pane] else { return }
        m[detail] = max(0, (m[detail] ?? 1) - 1)
        if m[detail] == 0 { m.removeValue(forKey: detail) }
        interest[pane] = m.isEmpty ? nil : m
        reconcileStreaming()
    }

    /// Окно приложения скрыто или свёрнуто — весь вывод на паузу.
    /// Окно приложения видно (не свёрнуто, не перекрыто, приложение не скрыто).
    public var isAppVisible: Bool { appVisible }

    public func setAppVisible(_ visible: Bool) {
        guard visible != appVisible else { return }
        appVisible = visible
        reconcileStreaming()
        if visible { for p in streaming { captureNow(p) } }
    }

    private func detail(of pane: String) -> PaneDetail? {
        interest[pane]?.keys.max()
    }

    /// Видимые панели прикреплённой сессии — `on` и `continue`, остальные — `pause`.
    /// `off` не используется: если наш клиент единственный, tmux по `off` перестаёт читать панель,
    /// и агент встаёт на записи в терминал (проверено на tmux 3.6b). `pause` вывод не блокирует.
    private func reconcileStreaming() {
        guard let c = client, let session = attachedAppSession else { return }
        let sessionPanes = panes.filter { $0.session == session && !$0.dead }.map(\.paneID)
        for p in sessionPanes {
            let want = appVisible && detail(of: p) != nil
            if want, !streaming.contains(p) {
                streaming.insert(p)
                knownPaused.remove(p)
                c.fire("refresh-client -A " + TmuxQuote.word(p + ":on") + " -A " + TmuxQuote.word(p + ":continue"))
            } else if !want, streaming.contains(p) || !knownPaused.contains(p) {
                streaming.remove(p)
                knownPaused.insert(p)
                c.fire("refresh-client -A " + TmuxQuote.word(p + ":pause"))
            }
        }
    }

    /// У панели есть захват (хоть раз): её признаки считает приложение по экрану, а не кеш team status, у которого
    /// «Esc to cancel» принимает за вопрос и меню, открытые самим владельцем (/rewind). Скрытые панели обновляются
    /// по их активности.
    public func hasCapture(_ pane: String) -> Bool { output(for: pane).lastHash != 0 }

    /// Один захват панели, у которой его ещё не было: кеш status сказал «ждёт человека», приложению нужно сверить с экраном.
    public func confirmWaiting(_ pane: String) {
        guard !hasCapture(pane) else { return }
        captureNow(pane)
    }

    /// Хвост панели захватывается сейчас (панель на экране и уже была захвачена): её признаки свежее кеша team status.
    public func hasLiveCapture(_ pane: String) -> Bool {
        streaming.contains(pane) && output(for: pane).lastHash != 0
    }

    public var streamingPanes: Set<String> { streaming }
    public var pausedPanes: Set<String> { knownPaused }

    // MARK: захват

    private func scheduleCapture(_ pane: String) {
        guard let d = detail(of: pane) else { return }
        if captureScheduled.contains(pane) { return }
        let wait = d.interval - Date().timeIntervalSince(lastCapture[pane] ?? .distantPast)
        if wait <= 0 {
            captureNow(pane)
        } else {
            captureScheduled.insert(pane)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                captureScheduled.remove(pane)
                captureNow(pane)
            }
        }
    }

    /// Скрытая панель что-то вывела: один захват экрана не чаще раза в 3 с, чтобы увидеть
    /// вопрос о доверии или запрос права у агента, которого нет на экране. Сигнал внутри окна не теряется,
    /// а переносится на его конец: новая сессия claude рисует вопрос о доверии через секунду после
    /// первого захвата и потом молчит.
    private func probe(_ pane: String) {
        let wait = 3 - Date().timeIntervalSince(lastProbe[pane] ?? .distantPast)
        if wait <= 0 {
            lastProbe[pane] = Date()
            captureNow(pane)
            return
        }
        guard !probeScheduled.contains(pane) else { return }
        probeScheduled.insert(pane)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            probeScheduled.remove(pane)
            guard panes.contains(where: { $0.paneID == pane && !$0.dead }) else { return }
            lastProbe[pane] = Date()
            captureNow(pane)
        }
    }

    /// Не больше одного захвата панели в работе; пришёл вывод во время захвата — повторить после.
    public func captureNow(_ pane: String) {
        guard let c = client, attachedAppSession != nil else { return }
        if captureInFlight.contains(pane) {
            captureAgain.insert(pane)
            return
        }
        let d = detail(of: pane) ?? .grid
        captureInFlight.insert(pane)
        lastCapture[pane] = Date()
        // Живая строка ввода рисуется строками экрана, и курсор tmux считает строки экрана: склейка переносов (-J)
        // сдвинула бы курсор. Claude Code переносит строки сам, так что на его экране -J обычно ничего не склеивает.
        var cmd = "capture-pane -p -e " + (d == .live ? "" : "-J ") + "-t " + TmuxQuote.word(pane)
        if d.history > 0 { cmd += " -S -\(d.history)" }
        let generation = clientGeneration
        Task { @MainActor in
            defer {
                // После сброса клиента флаги принадлежат новым захватам: старый их не снимает.
                if generation == clientGeneration {
                    captureInFlight.remove(pane)
                    if captureAgain.remove(pane) != nil { scheduleCapture(pane) }
                }
            }
            guard let lines = try? await c.run(cmd), generation == clientGeneration else { return }
            var cursor: (x: Int, y: Int)?
            var width: Int?
            if d == .live, let r = try? await c.run("display-message -p -t " + TmuxQuote.word(pane) + " '#{cursor_x} #{cursor_y} #{pane_width}'"),
               let first = r.first {
                let p = first.split(separator: " ").compactMap { Int($0) }
                if p.count == 3 { cursor = (p[0], p[1]); width = p[2] }
            }
            let o = output(for: pane)
            let previous = o.lastHash
            let cx = cursor?.x ?? -1, cy = cursor?.y ?? -1
            // Разбор SGR — вне главного потока; неизменный экран не трогает UI.
            // Экран разбирается здесь один раз (PaneScreen): виды читают готовые поля.
            let withReply = replyReaders[pane] != nil
            let known = o.toolColors
            let result = await Task.detached(priority: .utility) { () -> (Int, [StyledLine], PaneScreen, Set<TermColor>)? in
                let joined = lines.joined(separator: "\n")
                let h = (joined + "\u{0}\(cx),\(cy)").hashValue
                guard h != previous else { return nil }
                // Мигающий кружок идущего инструмента — в одной фазе: иначе разбор менялся бы на каждом захвате. Цвет
                // мигнувшего кружка запоминается: строка с кружком этого цвета — инструмент, а не черновик ответа.
                var colors = known
                let parsed = ScreenMarks.steadyBullets(SGRParser.parse(joined), blinked: &colors)
                return (h, parsed, PaneScreen.read(parsed, reply: withReply, toolColors: colors), colors)
            }.value
            guard let (h, parsed, screen, colors) = result else { return }
            if colors != o.toolColors { o.toolColors = colors }
            o.lastHash = h
            o.lines = parsed
            if d == .live { o.cursor = cursor; o.columns = width }
            let before = o.needsHuman
            o.apply(screen)
            // Чат начал или перестал читать черновик, пока шёл разбор: черновик — по новому правилу.
            if withReply != (replyReaders[pane] != nil) {
                o.reply = replyReaders[pane] != nil && o.notice == nil && !o.commandScreen ? LiveReply.extract(parsed, toolColors: o.toolColors) : nil
            }
            if o.needsHuman != before { onNeedsHumanChange?(pane) }
        }
    }

    // MARK: отправка

    /// Живая панель роли в сессии проекта — по списку панелей tmux, а не по кешу status.
    public func livePane(session: String, role: String) -> String? {
        panes.first { p in
            p.session == session && !p.dead && (p.role == role || p.role.split(separator: "#").first.map(String.init) == role)
        }?.paneID
    }

    /// Пауза между вставкой и Enter. Замер на живом claude (текст в строке ввода после `paste-buffer`, опрос 10 мс, 5 прогонов):
    /// строка 7–12 мс, вставка из 60 строк 7–8 мс, путь картинки до «[Image #1]» 25–35 мс. 120 мс — запас в 3–4 раза
    /// по самому медленному случаю; прежние 400 мс были осторожностью без замера.
    public static let enterDelay: TimeInterval = 0.12

    /// Сообщение с картинками: каждый путь вставляется отдельно (Claude Code превращает во вложение только
    /// вставку, целиком состоящую из пути), затем текст и Enter. `submit: false` оставляет всё в строке ввода.
    public func sendMessage(text: String, images: [URL], to pane: String, imageDelay: TimeInterval = 0.15,
                            enterDelay: TimeInterval = TmuxHub.enterDelay, submit: Bool = true) async throws {
        guard let c = client else { throw ControlError.notConnected }
        for url in images {
            try await paste(Self.sanitize(url.path), to: pane, via: c)
            try await Task.sleep(nanoseconds: UInt64(imageDelay * 1_000_000_000))
        }
        let clean = Self.sanitize(text)
        if !clean.isEmpty {
            if Self.canType(clean) {
                // Набор клавишами, а не вставка: Claude Code оборачивает вставленный многострочный текст в
                // `<pasted_content>`, и менеджер считает его чужим. Набранный текст — слова владельца.
                try await type(Self.typingPrefix(afterImages: !images.isEmpty) + clean, to: pane, via: c)
            } else {
                try await paste(images.isEmpty ? clean : " " + clean, to: pane, via: c)
            }
        }
        guard submit else { return }
        try await Task.sleep(nanoseconds: UInt64(enterDelay * 1_000_000_000))
        try await c.run("send-keys -t " + TmuxQuote.word(pane) + " Enter")
    }

    /// После вставленного пути картинки текст отделяется пробелом.
    nonisolated static func typingPrefix(afterImages: Bool) -> String { afterImages ? " " : "" }

    /// Набор клавишами невозможен, если первый символ — режим ввода Claude Code («!» — команда shell, «#» — память):
    /// такой текст уходит вставкой.
    nonisolated static func canType(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return true }
        return first != "!" && first != "#"
    }

    /// Строки набора и клавиши между ними: `send-keys -l` для текста, Meta-Enter для переноса без отправки.
    /// Табуляция в наборе открыла бы подсказку Claude Code, поэтому заменяется пробелами; длинные строки режутся
    /// на куски, чтобы команда tmux не разрасталась. Пробел в конце после «@слово» или «/слово» закрывает список
    /// подсказок: иначе Enter выбрал бы пункт списка, а не отправил сообщение.
    nonisolated static func typingSteps(_ text: String, chunk: Int = 1500) -> [TypingStep] {
        var steps: [TypingStep] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        for (i, line) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { steps.append(.newline) }
            var rest = Substring(line)
            while !rest.isEmpty {
                let part = rest.prefix(chunk)
                steps.append(.text(String(part)))
                rest = rest.dropFirst(part.count)
            }
        }
        if case let .text(last)? = steps.last, let token = last.split(separator: " ").last, last.last != " ",
           token.first == "@" || token.first == "/" {
            steps.append(.text(" "))
        }
        return steps
    }

    enum TypingStep: Equatable { case text(String), newline }

    private func type(_ text: String, to pane: String, via c: ControlClient) async throws {
        let target = TmuxQuote.word(pane)
        for step in Self.typingSteps(text) {
            switch step {
            case let .text(s): try await c.run("send-keys -t " + target + " -l -- " + TmuxQuote.word(s))
            case .newline: try await c.run("send-keys -t " + target + " M-Enter")
            }
        }
    }

    private func paste(_ text: String, to pane: String, via c: ControlClient) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let buf = "agentteam-" + UUID().uuidString.prefix(8)
        try await c.run("load-buffer -b " + TmuxQuote.word(String(buf)) + " " + TmuxQuote.word(url.path))
        try await c.run("paste-buffer -p -d -b " + TmuxQuote.word(String(buf)) + " -t " + TmuxQuote.word(pane))
    }

    /// Клавиши в панель как с клавиатуры, по именам tmux: `Escape`, `Enter`, `Down`, `1`. Приложение само ничего
    /// не нажимает: вызывается только по действию владельца.
    public func sendKeys(_ keys: [String], to pane: String) async throws {
        guard let c = client else { throw ControlError.notConnected }
        try await c.run("send-keys -t " + TmuxQuote.word(pane) + " " + keys.map { TmuxQuote.word($0) }.joined(separator: " "))
    }

    /// Текст в строку ввода панели как набор с клавиатуры (`send-keys -l`): без Enter и без вставки блоком.
    public func sendLiteral(_ text: String, to pane: String) async throws {
        guard let c = client, !text.isEmpty else { return }
        try await c.run("send-keys -t " + TmuxQuote.word(pane) + " -l -- " + TmuxQuote.word(Self.sanitize(text)))
    }

    /// Вставка блоком (bracketed paste) без Enter: ⌘V с текстом. Claude Code сворачивает длинную вставку сам.
    public func pasteText(_ text: String, to pane: String) async throws {
        guard let c = client, !text.isEmpty else { return }
        try await paste(Self.sanitize(text), to: pane, via: c)
    }

    /// Оставляет печатные символы, перевод строки и табуляцию.
    public nonisolated static func sanitize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { s in
            s == "\n" || s == "\t" || !(s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value))
        }))
    }

    /// Произвольная команда по каналу (для тестов и служебных нужд).
    public func run(_ command: String) async throws -> [String] {
        guard let c = client else { throw ControlError.notConnected }
        return try await c.run(command)
    }
}

/// Очередь уведомлений между потоком чтения и главным: `push` говорит, нужно ли запланировать разбор.
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ControlEvent] = []
    private var outputs: Set<String> = []
    private var scheduled = false

    func push(_ e: ControlEvent) -> Bool {
        lock.withLock {
            // Подряд идущие сигналы вывода одной панели схлопываются.
            if case let .output(p) = e {
                if outputs.contains(p) { return false }
                outputs.insert(p)
            }
            items.append(e)
            if scheduled { return false }
            scheduled = true
            return true
        }
    }

    func drain() -> [ControlEvent] {
        lock.withLock {
            let out = items
            items = []
            outputs = []
            scheduled = false
            return out
        }
    }
}

extension TmuxHub: ManagerPaneWriter {
    public func writeMessage(text: String, images: [URL], to pane: String) async throws {
        try await sendMessage(text: text, images: images, to: pane)
    }

    /// Захват снимается сейчас, мимо подписки и без записи в вывод панели — кроме признака экрана команды: по нему
    /// очередь решает, двигаться ли, и последний захват панели без подписки не должен держать её старым «открыт».
    public func freshPaneState(_ pane: String) async -> ManagerPaneState {
        guard let c = client, let lines = try? await c.run("capture-pane -p -e -t " + TmuxQuote.word(pane)) else { return paneState(pane) }
        let s = await Task.detached(priority: .userInitiated) { PaneScreen.read(SGRParser.parse(lines.joined(separator: "\n")), reply: false) }.value
        let o = output(for: pane)
        if o.commandScreen != s.commandScreen { o.commandScreen = s.commandScreen }
        return ManagerPaneState(turnRunning: s.turn != nil, asksPermission: s.asksPermission, asksTrust: s.asksTrust,
                                askFormOpen: s.askFormOpen, inputTyped: s.inputTyped, commandScreen: s.commandScreen,
                                inputLine: s.inputLine)
    }

    /// Ход, вопрос о праве и доверии — по последнему захвату панели.
    public func paneState(_ pane: String) -> ManagerPaneState {
        let out = output(for: pane)
        return ManagerPaneState(turnRunning: out.turn != nil, asksPermission: out.asksPermission, asksTrust: out.asksTrust,
                                askFormOpen: out.askFormOpen, inputTyped: out.inputTyped, commandScreen: out.commandScreen,
                                inputLine: out.inputLine)
    }
}
