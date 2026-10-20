import AgentTeamCore
import AppKit
import SwiftUI

/// Параметры запуска для скриншотов и проверки: `--project <имя> --screen <экран> --agent <агент> --role <роль> --socket <tmux -L>`.
struct LaunchOptions {
    var project: String?
    var screen: String?
    var agent: String?
    var role: String?
    var socket: String?
    var snapshot: String?
    /// Размер окна в точках для снимка: переменная `AGENT_TEAM_WINDOW_SIZE=1600x1000`. Аргументом запуска нельзя:
    /// AppKit принимает значение `--ключ=значение` за документ, и окно не открывается.
    var windowSize: CGSize? {
        guard AppDefaults.isProbeRun(CommandLine.arguments),
              let v = ProcessInfo.processInfo.environment["AGENT_TEAM_WINDOW_SIZE"] else { return nil }
        let p = v.split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }
    var snapshotDelay: Double = 6
    var quitAfterSnapshot = false
    /// Замер переключения: файл для меток и проекты для автоматического обхода.
    var timing: String?
    var bench: [String] = []
    var benchRounds = 2
    /// После обхода остаться открытым (замер нагрузки в простое с готовыми экранами в кэше).
    var benchStay = false
    /// Раскладка «Команды» для снимка: пишется во временный набор настроек, а не владельцу.
    var columns: Int?
    /// Роли из файла вместо `team roles --json` (снимок экрана «Роли» до готовности контракта).
    var rolesJSON: String?
    /// Боковая панель для снимка: «hidden» скрывает её (пишется во временный набор настроек).
    var sidebar: String?
    /// Проверочный запуск: инструмент team и подключаемый проект (во временном наборе настроек).
    var tool: String?
    /// Проверочный запуск: нажать «Добавить в проект» для общей роли до снимка.
    var addRole: String?
    /// Снимок: блок «Общая роль» раскрыт.
    var expandParent = false
    var repo: String?
    var roleShared = false
    /// Текст в ячейке автоостановки при запуске (снимок режима правки).
    var idleDraft: String?
    var agentsWidth: Double?
    /// Интервал чата для снимка (пишется во временный набор настроек) и значение, на которое он меняется в открытом окне
    /// посередине задержки: до смены и после снимаются два кадра.
    var chatSpacing: Double?
    var chatSpacingThen: Double?
    /// Скрытые элементы ленты для снимка (`bash,files,tools,team,tracker,compacted,duration,status,draft`) и список,
    /// который скрывается в открытом окне посередине задержки; применяется к чату менеджера и к лентам агентов.
    /// Вкладка экрана агента для снимка: `output`, `handoffs`, `instruction`, `permissions`.
    var tab: String?
    var feedHide: String?
    var feedHideThen: String?
    /// Для снимков: картинки в поле ввода и раскрытая первая картинка ленты.
    var draftImages: [String] = []
    var viewImage = false
    /// Для снимков: сообщение «в очереди», как после «Отправить» при занятом менеджере.
    var pending: String?
    /// Для снимков: ожидающее сообщение уже старше срока («не дошло»).
    var pendingLost = false
    /// Для снимков: закрепить столько последних записей (ответы менеджера и сообщения владельца), когда лента загрузится.
    var pinCount = 0
    /// Для снимков: закрепить запись с этим id и сразу перейти к ней (запись может быть старше загруженной части).
    var pinJumpID: String?
    /// Для снимков: сообщение удержано очередью приложения; со `--pending-stopped` — после «Стоп».
    var pendingHeld = false
    var pendingStopped = false
    /// Для снимков «Команды»: свернуть перечисленных агентов (`--collapse developer#2,tester#1`) и фильтр колонки
    /// (`--filter working|waiting`).
    var collapse: [String] = []
    var filter: String?

    /// Скрывает элементы ленты по списку из аргумента запуска, для чата менеджера и для агентов.
    @MainActor static func hideFeed(_ list: String) {
        for name in list.split(separator: ",").map(String.init) {
            for path in [\DisplaySettings.feedManager, \DisplaySettings.feedAgents] {
                switch name {
                case "bash": DisplayModel.shared.settings[keyPath: path].bash = false
                case "files": DisplayModel.shared.settings[keyPath: path].files = false
                case "tools": DisplayModel.shared.settings[keyPath: path].otherTools = false
                case "team": DisplayModel.shared.settings[keyPath: path].teamMessages = false
                case "tracker": DisplayModel.shared.settings[keyPath: path].tracker = false
                case "compacted": DisplayModel.shared.settings[keyPath: path].compacted = false
                case "duration": DisplayModel.shared.settings[keyPath: path].turnDuration = false
                case "status": DisplayModel.shared.settings[keyPath: path].turnStatus = false
                case "draft": DisplayModel.shared.settings[keyPath: path].draft = false
                default: break
                }
            }
        }
    }

    /// Аргументы этого запуска, разобранные один раз: виды читают их отсюда, а не разбирают в `body`.
    static let current = parse()

    static func parse(_ args: [String] = CommandLine.arguments) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 1
        while i < args.count {
            let v = i + 1 < args.count ? args[i + 1] : nil
            // Путь к существующему файлу отдельным аргументом AppKit принимает за документ и не открывает окно:
            // для картинок параметр пишется слитно, `--draft-image=<файл>`.
            if args[i].hasPrefix("--draft-image=") {
                o.draftImages.append(String(args[i].dropFirst("--draft-image=".count)))
                i += 1
                continue
            }
            switch args[i] {
            case "--project": o.project = v; i += 1
            case "--screen": o.screen = v; i += 1
            case "--agent": o.agent = v; i += 1
            case "--role": o.role = v; i += 1
            case "--socket": o.socket = v; i += 1
            case "--snapshot": o.snapshot = v; i += 1
            case "--snapshot-delay": o.snapshotDelay = Double(v ?? "") ?? 6; i += 1
            case "--quit": o.quitAfterSnapshot = true
            case "--timing": o.timing = v; i += 1
            case "--bench": o.bench = (v ?? "").split(separator: ",").map(String.init); i += 1
            case "--bench-rounds": o.benchRounds = Int(v ?? "") ?? 2; i += 1
            case "--bench-stay": o.benchStay = true
            case "--roles-json": o.rolesJSON = v; i += 1
            case "--role-shared": o.roleShared = true
            case "--idle-draft": o.idleDraft = v; i += 1
            case "--parent": o.expandParent = v == "expand"; i += 1
            case "--expand-parent": o.expandParent = true
            case "--add-role": o.addRole = v; i += 1
            case "--tool": o.tool = v; i += 1
            case "--repo": o.repo = v; i += 1
            case "--sidebar": o.sidebar = v; i += 1
            case "--columns": o.columns = Int(v ?? ""); i += 1
            case "--agents-width": o.agentsWidth = Double(v ?? ""); i += 1
            case "--chat-spacing": o.chatSpacing = Double(v ?? ""); i += 1
            case "--chat-spacing-then": o.chatSpacingThen = Double(v ?? ""); i += 1
            case "--tab": o.tab = v; i += 1
            case "--feed-hide": o.feedHide = v; i += 1
            case "--feed-hide-then": o.feedHideThen = v; i += 1
            case "--view-image": o.viewImage = true
            case "--pending": o.pending = v; i += 1
            case "--pending-lost": o.pendingLost = true
            case "--pin-jump": o.pinJumpID = v; i += 1
            case "--pin": o.pinCount = Int(v ?? "") ?? 1; i += 1
            case "--pending-state": o.pendingHeld = true; o.pendingStopped = v == "stopped"; i += 1
            case "--pending-held": o.pendingHeld = true
            case "--collapse": o.collapse = (v ?? "").split(separator: ",").map(String.init); i += 1
            case "--filter": o.filter = v; i += 1
            case "--pending-stopped": o.pendingHeld = true; o.pendingStopped = true
            default: break
            }
            i += 1
        }
        return o
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private static var checkRun = false

    /// Окно проверочного запуска — на неосновной экран, если он есть. Рамка, которая уже годится, не меняется:
    /// иначе перенос по уведомлению о смене экрана зацикливался бы.
    @MainActor private static func placeOnCheckScreen(_ w: NSWindow) {
        guard checkRun else { return }
        let screens = NSScreen.screens.map { CheckPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let target = CheckPlacement.place(window: w.frame, screens: screens), target.frame != w.frame else { return }
        w.setFrame(target.frame, display: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let environment = ProcessInfo.processInfo.environment
        let activates = AppDefaults.activatesOnLaunch(CommandLine.arguments, environment: environment)
        if AppDefaults.isCheckRun(CommandLine.arguments, environment: environment) {
            // Проверочный запуск (стенд, снимок): окна — на неосновной экран (`CheckPlacement`), основной — рабочий стол
            // владельца. Окна, открытые позже (второе окно, снимок), переносятся по уведомлениям о смене экрана и о выходе
            // окна на передний план. SwiftUI ставит окна после запуска, поэтому перенос — через полсекунды и ещё раз через две.
            Self.checkRun = true
            for delay in [0.5, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for w in NSApp.windows where w.isVisible && !(w is NSPanel) {
                        AppDelegate.placeOnCheckScreen(w)
                        // Без активации окно выводится вперёд без фокуса: стол у владельца общий, и активированное приложение
                        // забрало бы его ввод. Перекрытое окно ленты ведёт себя иначе (постановка в конец сразу, реже опрос),
                        // и замеры были бы не те, поэтому на задний план окно не уходит.
                        if !activates { w.orderFrontRegardless() }
                    }
                }
            }
            for name in [NSWindow.didChangeScreenNotification, NSWindow.didBecomeMainNotification, NSWindow.didExposeNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        for w in NSApp.windows where w.isVisible && !(w is NSPanel) { AppDelegate.placeOnCheckScreen(w) }
                    }
                }
            }
        }
        if activates { NSApp.activate(ignoringOtherApps: true) }
        handleTermSignal()
        Diag.start()
        if Diag.on {
            // Замер стенда засчитывается только при видимом окне: перекрытое чужим окном выводится вперёд снова, без фокуса.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    for w in NSApp.windows where w.isVisible && !(w is NSPanel) && !w.occlusionState.contains(.visible) { AppDelegate.placeOnCheckScreen(w); w.orderFrontRegardless() }
                }
            }
        }
    }

    /// Выход по сигналу: без вопроса владельцу.
    @MainActor private static var terminatingBySignal = false
    private var termSource: DispatchSourceSignal?

    /// SIGTERM (перезапуск сборки, выход системы) обходил applicationShouldTerminate, и очередь менеджерам пропадала.
    /// Владельца у машины может не быть, поэтому вопроса нет: удержанные уходят менеджерам, как при «Отправить и выйти»;
    /// что не ушло — в черновик проекта (владелец увидит его в поле после запуска) и в системный журнал.
    private func handleTermSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Task { @MainActor in
                if let model = Self.model, let failure = await model.flushHeldForSignal() {
                    NSLog("agent-team: очередь менеджеру не отправлена при выходе по SIGTERM (%@), текст сохранён в черновике проекта", failure)
                }
                // Запись в журнал команды (team log owner) идёт отдельным процессом: даём ему запуститься.
                try? await Task.sleep(nanoseconds: 500_000_000)
                Self.terminatingBySignal = true
                NSApp.terminate(nil)
            }
        }
        source.resume()
        termSource = source
    }

    func applicationWillTerminate(_ notification: Notification) { AppDefaults.cleanup() }

    /// Модель приложения: при выходе проверяется очередь сообщений менеджерам.
    @MainActor static weak var model: AppModel?

    /// Очередь менеджерам живёт только в памяти: выход с удержанными сообщениями спрашивает, отправить их или потерять.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Снимки и стенды выходят сами, их очередь — заготовка.
        guard !Self.terminatingBySignal, !AppDefaults.isProbeRun(CommandLine.arguments),
              let model = Self.model, model.heldMessages > 0 else { return .terminateNow }
        let n = model.heldMessages
        let alert = NSAlert()
        alert.messageText = "Менеджеру не отправлено: " + plural(n, "сообщение", "сообщения", "сообщений")
        alert.informativeText = "Они ждут в очереди приложения: конца хода менеджера или возврата к полю ввода. "
            + "Очередь хранится только в памяти, после выхода её не будет. «Отправить и выйти» отправит их сейчас: "
            + "если менеджер в ходе, Claude Code поставит их в свою очередь."
        alert.addButton(withTitle: "Отправить и выйти")
        alert.addButton(withTitle: "Выйти, потеряв \(n)")
        alert.addButton(withTitle: "Отмена")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                let failure = await model.sendAllHeld()
                if let failure {
                    let failed = NSAlert()
                    failed.messageText = "Очередь не отправлена, приложение не закрыто"
                    failed.informativeText = failure
                    failed.runModal()
                }
                sender.reply(toApplicationShouldTerminate: failure == nil)
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AgentTeamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app: AppModel
    private let options: LaunchOptions

    init() {
        T.registerFontsIfNeeded()
        // Тема окна публикуется при создании модели вида: без этого экран, не читающий настройки, остался бы в оформлении по умолчанию.
        _ = DisplayModel.shared
        let o = LaunchOptions.current
        options = o
        if AppDefaults.isProbeRun(CommandLine.arguments) {
            if let c = o.columns { AppDefaults.store.set(c, forKey: TeamLayout.columnsKey) }
            if let t = o.tool { AppDefaults.store.set(t, forKey: "toolPath") }
            if let r = o.repo { AppDefaults.store.set((AppDefaults.store.stringArray(forKey: "projects") ?? []) + [r], forKey: "projects") }
            if let sb = o.sidebar { AppDefaults.store.set(sb == "hidden", forKey: AppModel.sidebarKey) }
            if let w = o.agentsWidth { AppDefaults.store.set(w, forKey: TeamLayout.widthKey) }
            if let sp = o.chatSpacing { DisplayModel.shared.settings.chat.spacing = sp }
            if let h = o.feedHide { LaunchOptions.hideFeed(h) }
        }
        let model = AppModel(socketName: o.socket)
        // Очередь сообщений менеджеру знает, включена ли строка Claude Code: пока включена, сама в панель не пишет.
        model.liveLineOn = { DisplayModel.shared.liveInputOn }
        AppDelegate.model = model
        FeedScroller.installBenchHook()
        _app = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup("agent-team") {
            RootView(app: app, options: options)
                .frame(minWidth: 1100, minHeight: 700)
                .windowAppearance()
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appSettings) { EnvironmentMenuButton() }
            CommandGroup(after: .sidebar) {
                Button(app.sidebarCollapsed ? "Показать боковую панель" : "Скрыть боковую панель") { app.sidebarCollapsed.toggle() }
                    .keyboardShortcut("\\", modifiers: .command)
            }
        }

        Window(EnvironmentView.title, id: EnvironmentView.windowID) {
            EnvironmentView(app: app)
                .windowAppearance()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(app: app)
                .windowAppearance()
        }
    }
}

struct RootView: View {
    @Bindable var app: AppModel
    var options: LaunchOptions
    @State private var started = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            if !app.sidebarCollapsed { Sidebar(app: app) }
            Group {
                if let project = app.project {
                    if app.section == .team, app.openedAgent == nil {
                        teamScreens(selected: project)
                    } else {
                        content(project)
                            .overlay(alignment: .bottomTrailing) { ActionToast(project: project) }
                            // Состояние экранов (черновик, свёрнутые панели, фильтры) — своё у каждого проекта.
                            .id(project.session)
                    }
                } else if app.section == .settings {
                    SettingsScreen(app: app)       // нужен и без проекта: там путь к team
                } else {
                    noProject
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .environment(app)
        // Прокрутка лент держится только у проектов в кеше открытых: вытесненный проект откроется заново, с конца.
        .onChange(of: app.openModels.map(\.session)) { _, sessions in FeedScroller.keep(sessions: Set(sessions)) }
        .background(T.bg)
        .foregroundStyle(T.ink)
        .ignoresSafeArea()
        .overlay {
            if let item = app.viewedImage {
                ImageViewer(item: item) { app.viewedImage = nil }.transition(.opacity)
            }
        }
        .task {
            guard !started else { return }
            started = true
            if let t = options.timing { SwitchClock.shared.enable(logTo: (t as NSString).expandingTildeInPath) }
            await app.start(preferredProject: options.project)
            apply(options)
            for path in options.draftImages {
                if let u = Attachments.add(file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) { app.project?.draftImages.append(u) }
            }
            if let p = options.pending {
                app.project?.addPending(text: p, images: app.project?.draftImages ?? [], held: options.pendingHeld)
                if options.pendingStopped { app.project?.stopQueue() }
                if options.pendingLost { app.project?.backdatePending(PendingMessage.deliveryTimeout + 30) }
            }
            if options.pinCount > 0 { await pinLastEntries(options.pinCount) }
            if let id = options.pinJumpID { await pinAndJump(id) }
            if options.viewImage { await openFirstChatImage() }
            if AppDefaults.isProbeRun(CommandLine.arguments), let r = options.addRole {
                await app.project?.addSharedRole(r)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            if !options.bench.isEmpty { await runBench(options) }
            await runModeBench()
            await runReturnBench()
            await runResumeBench()
            await ScrollUpBench.run()
            await runFramesBench()
            // Нет tmux или team — окно «Окружение» открывается само и говорит, что сделать.
            let showEnvironment = app.missingEssentials || options.screen == "environment"
            if showEnvironment { openWindow(id: EnvironmentView.windowID) }
            if let path = options.snapshot {
                if options.chatSpacingThen != nil || options.feedHideThen != nil {
                    // Смена интервала в открытом окне: кадр до и кадр после в одном запуске.
                    try? await Task.sleep(nanoseconds: UInt64(options.snapshotDelay / 2 * 1_000_000_000))
                    WindowSnapshot.save(to: path.replacingOccurrences(of: ".png", with: "-before.png"), title: "agent-team")
                    if let then = options.chatSpacingThen { DisplayModel.shared.settings.chat.spacing = then }
                    if let hide = options.feedHideThen { LaunchOptions.hideFeed(hide) }
                    try? await Task.sleep(nanoseconds: UInt64(options.snapshotDelay / 2 * 1_000_000_000))
                } else {
                    try? await Task.sleep(nanoseconds: UInt64(options.snapshotDelay * 1_000_000_000))
                }
                WindowSnapshot.save(to: path, title: options.screen == "environment" ? EnvironmentView.title : "agent-team")
                if options.quitAfterSnapshot { NSApp.terminate(nil) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { n in
            // Окно перекрыто или свёрнуто — весь вывод панелей на паузу.
            guard let w = n.object as? NSWindow, w.title == "agent-team" else { return }
            app.hub.setAppVisible(w.occlusionState.contains(.visible))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in app.hub.setAppVisible(false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in app.hub.setAppVisible(true) }
    }

    /// «Команда» недавно открытых проектов держится построенной: возврат к проекту — смена видимости,
    /// без новой раскладки ленты и панелей (она стоила 100–200 мс). Невидимые экраны не меняются: их модели
    /// приостановлены, панели чужих сессий не получают вывода.
    private func teamScreens(selected: ProjectModel) -> some View {
        ZStack {
            ForEach(app.openModels, id: \.session) { m in
                let visible = m === selected
                TeamScreen(app: app, project: m)
                    .overlay(alignment: .bottomTrailing) { ActionToast(project: m) }
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
                    .zIndex(visible ? 1 : 0)
                    .onChange(of: visible) { _, now in
                        guard now else { return }
                        if !m.teamAgents.isEmpty { SwitchClock.shared.mark("panels", m.session) }
                        if !m.chat.isEmpty { SwitchClock.shared.mark("chat", m.session) }
                    }
            }
        }
    }

    @ViewBuilder
    private func content(_ project: ProjectModel) -> some View {
        switch app.section {
        case .team:
            if let name = app.openedAgent {
                AgentScreen(app: app, project: project, agentName: name)
            } else {
                TeamScreen(app: app, project: project)
            }
        case .roles: RolesScreen(app: app, project: project)
        case .handoffs: HandoffsScreen(app: app, project: project)
        case .journal: JournalScreen(app: app, project: project)
        case .settings: SettingsScreen(app: app)
        }
    }

    private var noProject: some View {
        EmptyState(title: !app.environmentReady ? "Загрузка окружения" : app.projects.isEmpty ? "Нет проектов" : "Проект не найден",
                   detail: !app.environmentReady
                       ? "PATH и локаль берутся из login-шелла."
                       : app.projects.isEmpty
                       ? "Проекты появляются из сессий tmux team-* и из каталогов недавних сессий Claude Code с agents/team.yaml. Подключите каталог проекта вручную или нажмите «Найти проекты»."
                       : "Не удалось найти каталог проекта для этой сессии tmux. Подключите его вручную.",
                   icon: "square.stack.3d.up")
    }

    private func apply(_ o: LaunchOptions) {
        // Размер окна для снимка: после того как окно построено, а не через defaultSize (с ним окно не открывалось).
        if let size = o.windowSize, let w = NSApp.windows.first(where: { $0.title == "agent-team" && $0.isVisible }) {
            w.setContentSize(size)
            w.center()
        }
        if AppDefaults.isProbeRun(CommandLine.arguments), let f = o.rolesJSON,
           let data = FileManager.default.contents(atPath: (f as NSString).expandingTildeInPath),
           let roles = try? JSONDecoder().decode([RoleInfo].self, from: data) {
            app.project?.rolesOverride = roles
            app.project?.refreshAll()
        }
        switch o.screen {
        case "manager": app.section = .team; app.mode = .manager
        case "agent":
            app.section = .team
            app.launchAgentTab = o.tab
            if let a = o.agent ?? app.project?.status?.agents.first(where: { $0.alive && $0.kind != "manager" })?.name {
                app.openedAgent = a
            }
        case "roles": app.section = .roles; app.selectRole(o.role, shared: o.roleShared)
        case "roletech": app.section = .roles; app.selectRole(o.role, shared: o.roleShared); app.roleTech = true
        case "handoffs": app.section = .handoffs
        case "composition": app.section = .roles; app.selectRole(o.role)
        case "journal": app.section = .journal
        case "settings": app.section = .settings
        default: break
        }
    }
}

struct SettingsView: View {
    @Bindable var app: AppModel
    @State private var path = ""

    var body: some View {
        Form {
            Section {
                TextField("Репозиторий инструмента team", text: $path, prompt: Text("путь к клону agent-team"))
                    .onSubmit { app.toolPath = path }
                HStack {
                    Button("Выбрать…") { choose() }
                    Button("Применить") { app.toolPath = path }
                    Spacer()
                }
                Text(app.cli.map { "Вызов: " + ([$0.executable] + $0.prefixArgs).joined(separator: " ") } ?? "team не найден")
                    .font(T.mono(11)).foregroundStyle(T.muted)
                Text("Каталог репозитория agent-team: приложение вызывает <каталог>/.venv/bin/team или uv run --project <каталог> team. По умолчанию — найденный в PATH team.")
                    .font(T.text(12)).foregroundStyle(T.dim)
            }
            Section {
                Text("Сервер tmux: \(app.hub.socketName.map { "-L \($0)" } ?? "по умолчанию")").font(T.mono(11)).foregroundStyle(T.muted)
                EnvironmentMenuButton()
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 300)
        .onAppear { path = app.toolPath }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        app.toolPath = path
    }
}

/// Открыть панель агента в Терминале: `tmux attach` к сессии с выбором панели.
enum TerminalOpener {
    @MainActor
    static func open(session: String, pane: String?, socket: String?, tmux: String) {
        var cmd = "exec " + shq(tmux) + " -u"
        if let socket { cmd += " -L " + shq(socket) }
        cmd += " attach-session -t " + shq(TmuxTarget.session(session))
        if let pane { cmd += " \\; select-window -t " + shq(pane) + " \\; select-pane -t " + shq(pane) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-attach-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/sh\nunset TMUX\nrm -f \"$0\"\n\(cmd)\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {}
    }

    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Снимок главного окна самим приложением: screencapture требует разрешения на запись экрана,
/// а отрисовка своего окна — нет.
enum WindowSnapshot {
    @MainActor
    static func save(to path: String, title: String = "agent-team") {
        guard let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) ?? NSApp.mainWindow,
              let view = w.contentView?.superview ?? w.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }
}
