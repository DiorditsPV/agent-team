import AgentTeamCore
import SwiftUI

struct TeamScreen: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    @State private var filter: AgentFilter = .all
    /// Свёрнутые агенты — по уникальному ключу (`Agent.key`), а не по роли: два агента одной роли независимы.
    @State var collapsed: Set<String> = []
    /// Группа каждого агента по статусу (`AgentGroupsReader`): порядок колонки и фильтр.
    @State private var groups: [String: AgentGroup] = [:]
    /// Переезды панелей анимируются после того, как первый ответ читателя групп уже нарисован.
    @State private var animateMoves = false
    @State private var showPicker = false
    @State private var confirmStop = false
    /// Ширина колонки агентов и число столбцов панелей — общие для проектов, хранятся в UserDefaults.
    @AppStorage(TeamLayout.widthKey, store: AppDefaults.store) private var agentsWidth: Double = TeamLayout.defaultAgentsWidth
    @AppStorage(TeamLayout.columnsKey, store: AppDefaults.store) private var columns: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let width = TeamLayout.agentsWidth(stored: agentsWidth, total: geo.size.width)
                HStack(spacing: 0) {
                    // Слева направо: чат менеджера — основная область, граница, колонка агентов. Чат стоит в одном месте
                    // в обоих режимах: «Менеджер» убирает только колонку агентов, лента и поле ввода не пересоздаются.
                    VStack(spacing: 0) {
                        if app.mode == .manager {
                            managerStrip
                        } else {
                            ChatHeader(project: project)
                                .padding(.horizontal, 20).frame(height: TeamLayout.stripHeight)
                                .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
                        }
                        ChatPanel(app: app, project: project, wide: true)
                    }
                    .frame(maxWidth: .infinity)
                    .background(C.bg)
                    if app.mode != .manager {
                        PaneDivider(width: $agentsWidth, total: geo.size.width)
                        agentsArea
                            .frame(width: width)
                    }
                }
            }
        }
        .background {
            AgentGroupsReader(hub: app.hub, project: project, agents: agents) { g in
                groups = g
                if !animateMoves { DispatchQueue.main.async { animateMoves = true } }
            }
        }
        .task { await runToggleBench() }
        .onAppear {
            // --screen collapsed: все панели свёрнуты (для снимка экрана); --collapse a,b — только перечисленные;
            // --filter working|waiting — фильтр колонки.
            let o = LaunchOptions.current
            if o.screen == "collapsed" { collapsed = Set(agents.map(\.key)) }
            if !o.collapse.isEmpty { collapsed = Set(o.collapse) }
            if o.filter == "working" { filter = .working } else if o.filter == "waiting" { filter = .waiting }
        }
        // Кеш status сказал «ждёт человека», а захвата панели нет: один захват проверяет, правда ли это.
        .task(id: waitingPaneIDs) { for p in waitingPaneIDs { app.hub.confirmWaiting(p) } }
        .onChange(of: agents.map(\.name)) { _, names in
            if LaunchOptions.current.screen == "collapsed" { collapsed = Set(agents.map(\.key)) }
            // Прокрутка ушедших агентов не держится.
            FeedScroller.forgetAgents(session: project.session, keeping: names)
        }
        .confirmationDialog("Остановить всю команду \(project.name)?", isPresented: $confirmStop) {
            Button("Остановить команду", role: .destructive) { Task { await project.down(nil) } }
        } message: {
            Text("team down закроет tmux-сессию \(project.session) со всеми агентами, включая менеджера. Работа в git и трекере сохранится.")
        }
    }

    // MARK: шапка

    /// Верхняя полоса: проект, переключатель режима и редкие действия. Тонкая — высота отдана лентам.
    private var header: some View {
        HStack(spacing: 12) {
            SidebarReveal(app: app)
            Text(project.name).font(T.title(15)).kerning(-0.2).foregroundStyle(T.ink).lineLimit(1)
            Segmented(items: [(TeamMode.team, "Команда", "square.grid.2x2"), (TeamMode.manager, "Менеджер", "arrow.up.left.and.arrow.down.right")],
                      selection: $app.mode)
                .fixedSize()
            Spacer(minLength: 12)
            Button { showPicker.toggle() } label: {
                Label("Новый агент", systemImage: "plus")
                    .font(T.text(12, .medium)).foregroundStyle(app.mode == .team ? T.onAccent : T.ink)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(app.mode == .team ? T.accent : .clear, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(app.mode == .team ? .clear : T.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                NewAgentPicker(project: project) { role in
                    showPicker = false
                    Task { await project.spawn(role: role) }
                }
            }
            Menu {
                Button("Обновить") { project.refreshAll() }
                Divider()
                Button("Остановить команду…", role: .destructive) { confirmStop = true }
                    .disabled(project.status?.sessionAlive != true)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).foregroundStyle(T.ink)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 26, height: 26).overlay(Rectangle().stroke(T.line, lineWidth: 1))
        }
        .padding(.horizontal, 20)
        .frame(height: TeamLayout.topBarHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    // MARK: агенты

    var agents: [Agent] { project.teamAgents }

    /// Сессии проекта нет на сервере tmux — по списку сессий хаба, а не по кешу status.
    private var stopped: Bool {
        !app.hub.sessions.contains(project.session) && project.status?.sessionAlive != true
    }

    /// Решение владельца висит, пока панель просит его. У панели на экране верен свежий захват: кеш team status
    /// отстаёт до 15 с и оставлял бы плашку после отказа или согласия; у скрытой панели — кеш и последняя проверка.
    /// Скрытая панель с признаком ожидания или открытым вопросом из status проверяется захватом.
    private var waitingPaneIDs: [String] {
        (agents + [project.status?.manager].compactMap { $0 }).filter { $0.alive && ($0.waitingHuman || $0.question != nil) }.compactMap(\.paneID)
    }

    private func isWaiting(_ a: Agent) -> Bool {
        project.isWaiting(a, pane: a.paneID.map { app.hub.output(for: $0) }, captured: a.paneID.map { app.hub.hasCapture($0) } ?? false)
    }

    /// Группа агента по статусу плашки. Пока читатель групп не ответил — по транскрипту и кешу status, без экрана.
    private func group(_ a: Agent) -> AgentGroup {
        groups[a.key] ?? AgentGroup(project.agentStatus(a).state)
    }

    /// Элементы колонки: порядок по статусу (работают, ждут, простаивают), фильтр по той же группе, свёрнутость по ключу.
    /// Для снимка (`AGENT_TEAM_PANE_LIMIT=5`) развёрнутых не больше лимита.
    private var columnItems: [ColumnItem] {
        AgentOrder.items(agents, filter: filter, collapsed: collapsed, paneLimit: ProbeFlags.paneLimit, group: group)
    }

    /// Решения владельца: доверие к папке и запрос права — по хвосту панели агента (и waiting_human из CLI);
    /// слово владельца (например, на слияние) — по событиям waiting журнала без последующего ответа.
    /// Менеджер в сетке не показан, но его вопрос тоже здесь: после «Поднять команду» он первым спрашивает
    /// о доверии к папке проекта.
    private var decisions: [Decision] {
        var out: [Decision] = []
        if let m = waitingManager {
            let q = question(of: m, name: "Менеджер")
            out.append(Decision(agent: m.name, text: q.text, kind: q.kind))
        }
        out += agents.filter(isWaiting).map { a in
            let q = question(of: a, name: ProjectModel.pretty(a.name))
            return Decision(agent: a.name, text: q.text, kind: q.kind)
        }
        out += project.ownerWaits.map { e in
            Decision(agent: e.agent, text: [e.task, e.text].compactMap { $0 }.joined(separator: " — "), kind: .owner, task: e.task)
        }
        return out
    }

    private func question(of a: Agent, name: String) -> (kind: Decision.Kind, text: String) {
        let out = a.paneID.map { app.hub.output(for: $0) }
        return DecisionText.question(name: name, asksTrust: out?.asksTrust ?? false, askFormOpen: out?.askFormOpen ?? false,
                                     askQuestion: out?.askQuestion, dir: (a.cwd as NSString?)?.lastPathComponent ?? "")
    }

    /// Менеджер ждёт ответа в своей панели. Его ответ даётся в терминале: в чате вопроса панели не видно.
    private var waitingManager: Agent? {
        guard let m = project.status?.manager, m.alive, m.paneID != nil else { return nil }
        return isWaiting(m) ? m : nil
    }

    private var managerAsksTrust: Bool {
        waitingManager?.paneID.map { app.hub.output(for: $0).asksTrust } ?? false
    }

    private var agentsArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            agentsHead
            VStack(alignment: .leading, spacing: 8) {
            if let err = project.statusError {
                Note(text: err, icon: "exclamationmark.triangle", color: T.amber, fill: T.amberBg)
            }
            // Решения считаются один раз за проход: расчёт сверяет хвосты панелей и события журнала.
            let decisions = self.decisions
            if !decisions.isEmpty { decisionsBar(decisions) }
            if agents.isEmpty {
                if stopped {
                    EmptyState(title: "Команда остановлена",
                               detail: "tmux-сессии \(project.session) нет. «Поднять команду» запускает team up в каталоге проекта: менеджер и роли со start: always.",
                               icon: "person.2.slash",
                               action: .init(title: "Поднять команду", icon: "play.fill", busy: project.busyActions.contains("up")) {
                                   Task { await app.up(repo: project.repo) }
                               })
                } else {
                    EmptyState(title: "Агентов нет",
                               detail: "Агента поднимает менеджер под задачу или вы — кнопкой «Новый агент».",
                               icon: "person.2.slash")
                }
            } else {
                GeometryReader { geo in
                    let items = columnItems
                    let flags = items.map(\.collapsed)
                    let cols = columns == 2 ? 2 : 1
                    let paneHeight = TeamLayout.paneHeight(available: geo.size.height - 12, collapsedRows: flags.filter { $0 }.count,
                                                           paneRows: AgentColumnLayout.paneRows(collapsed: flags, columns: cols))
                    ScrollView {
                        VStack(spacing: TeamLayout.gap) {
                            // Один список: агент сворачивается и разворачивается на своём месте, порядок задаёт только
                            // статус. При смене статуса панель переезжает, не пересоздаваясь (identity — ключ агента).
                            AgentColumnGrid(columns: cols, gap: TeamLayout.gap, paneHeight: paneHeight, rowHeight: PaneBand.height) {
                                ForEach(items, id: \.agent.key) { item in
                                    let a = item.agent
                                    Group {
                                        if item.collapsed {
                                            AgentRow(app: app, project: project, agent: a) { collapsed.remove(a.key) }
                                        } else {
                                            AgentPaneCard(app: app, project: project, agent: a, height: paneHeight) { collapsed.insert(a.key) }
                                        }
                                    }
                                    .layoutValue(key: CollapsedRowKey.self, value: item.collapsed)
                                }
                            }
                            // Переезд анимируется только после первого ответа читателя групп: до него порядок — по транскрипту,
                            // и поправка при открытии экрана не должна выглядеть движением.
                            .animation(animateMoves ? .easeInOut(duration: 0.25) : nil, value: items.map(\.agent.key))
                            .onAppear { SwitchClock.shared.mark("panels", project.session) }
                            if items.isEmpty {
                                EmptyState(title: filter == .waiting ? "Никто не ждёт ответа" : "Никто не работает",
                                           detail: filter == .waiting
                                               ? "Агенты, которые ждут вашего решения или ответа, появятся здесь."
                                               : "Здесь агенты, у которых идёт ход.",
                                           icon: filter == .waiting ? "hand.raised" : "moon.zzz",
                                           action: .init(title: "Показать всех", icon: "person.2") { filter = .all })
                                    .padding(.top, 20)
                            }
                        }
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.visible)
                }
            }
            }
            .padding(.horizontal, TeamLayout.gap * 2).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func decisionsBar(_ decisions: [Decision]) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "hand.raised").font(.system(size: 17)).foregroundStyle(T.amber)
            VStack(alignment: .leading, spacing: 3) {
                Text(plural(decisions.count, "решение ждёт", "решения ждут", "решений ждут") + " вас")
                    .font(T.text(14, .semibold)).foregroundStyle(T.amber)
                Text(decisions.map(\.text).joined(separator: ". ") + ".")
                    .font(T.text(13)).foregroundStyle(T.muted).lineLimit(2)
            }
            Spacer(minLength: 12)
            // Вопрос в панели менеджера отвечается в терминале; остальные решения — в разговоре с менеджером:
            // «Разобрать» открывает чат на всю ширину.
            if let m = waitingManager {
                Button("Ответить менеджеру") {
                    TerminalOpener.open(session: project.session, pane: m.paneID, socket: app.hub.socketName, tmux: app.hub.tmuxPath)
                }
                .buttonStyle(AppButtonStyle(kind: .warn))
            }
            if decisions.contains(where: { $0.agent != waitingManager?.name }) {
                Button("Разобрать") { app.mode = .manager }
                .buttonStyle(AppButtonStyle(kind: .warn))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(T.amberBg)
        .overlay(Rectangle().stroke(T.amber.opacity(0.35), lineWidth: 1))
    }

    /// Полоса над колонкой агентов: число, фильтр, «свернуть все» и раскладка 1/2 — в одну строку.
    private var agentsHead: some View {
        HStack(spacing: 8) {
            Text("Агенты").font(T.text(14, .semibold)).foregroundStyle(T.ink).lineLimit(1).fixedSize()
            Text(headCaption).font(T.mono(11)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.tail)
                .help(headHelp)
            Spacer(minLength: 4)
            filterMenu
            if !agents.isEmpty {
                let allCollapsed = agents.allSatisfy { collapsed.contains($0.key) }
                Button {
                    collapsed = allCollapsed ? [] : Set(agents.map(\.key))
                } label: {
                    Image(systemName: allCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.system(size: 11)).foregroundStyle(T.ink)
                        .frame(width: 26, height: 26)
                        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
                }
                .buttonStyle(PressFeedbackStyle(highlight: T.line))
                .help(allCollapsed ? "Развернуть все" : "Свернуть все")
            }
            Segmented(items: [(1, "1", "rectangle.grid.1x2"), (2, "2", "rectangle.grid.2x2")], selection: $columns)
                .fixedSize()
                .help("Панели агентов: один столбец или два")
        }
        .padding(.horizontal, 12)
        .frame(height: TeamLayout.stripHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    /// Фильтр «Все / Работают / Ждут» — меню: редко нужный выбор не занимает отдельную строку.
    private var filterMenu: some View {
        Menu {
            Picker("Показывать", selection: $filter) {
                Text("Все").tag(AgentFilter.all)
                Text("Работают").tag(AgentFilter.working)
                Text("Ждут").tag(AgentFilter.waiting)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                if filter != .all { Circle().fill(T.accent).frame(width: 6, height: 6) }
                Text(filter == .all ? "Все" : filter == .working ? "Работают" : "Ждут").font(T.text(12)).foregroundStyle(T.ink)
                Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(T.muted)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .overlay(Rectangle().stroke(filter == .all ? T.line : T.accent.opacity(0.6), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize()
        .help("Какие агенты показывать")
    }

    /// Коротко для полосы: «5 · 3 роли»; полностью — в подсказке.
    private var headCaption: String {
        let roles = Set(agents.map(\.role)).count
        return "\(agents.count) · " + plural(roles, "роль", "роли", "ролей")
    }

    private var headHelp: String {
        let roles = Set(agents.map(\.role)).count
        var parts = [plural(agents.count, "агент", "агента", "агентов"), plural(roles, "роль", "роли", "ролей")]
        let c = agents.filter { collapsed.contains($0.key) }.count
        if c > 0 { parts.append("\(c) свёрнуто") }
        return parts.joined(separator: " · ")
    }

    // MARK: режим «Менеджер»

    /// Полоса над чатом в режиме «Менеджер»: состояние менеджера, сколько агентов работает, решения, возврат к агентам.
    private var managerStrip: some View {
        HStack(spacing: 10) {
                Swatch(color: C.accent)
                Text(project.managerRole).font(C.mono(13, .semibold)).foregroundStyle(C.accent)
                Text(ChatHeader.metaText(project)).font(C.mono(11)).foregroundStyle(C.dim)
                Spacer()
                ManagerBadge(project: project)
                Text(plural(agents.filter(\.alive).count, "агент работает", "агента работают", "агентов работают"))
                    .font(C.mono(12)).foregroundStyle(C.muted)
                let waiting = decisions.count
                if waiting > 0 {
                    StatusBadge(text: plural(waiting, "решение ждёт", "решения ждут", "решений ждут") + " вас", color: C.amber)
                }
                Button { app.mode = .team } label: { Label("Показать агентов", systemImage: "square.grid.2x2") }
                    .buttonStyle(AppButtonStyle())
        }
        .padding(.horizontal, 20).frame(height: TeamLayout.stripHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
    }
}

/// Выбор роли для нового агента: роли из agents/roles с числом работающих агентов.
struct NewAgentPicker: View {
    let project: ProjectModel
    var onPick: (String) -> Void
    @State private var hover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(text: "Роль для нового агента")
                Spacer()
                Text("agents/roles").font(T.mono(11)).foregroundStyle(T.dim)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            let roles = project.projectRoles.filter { $0.kind != "manager" && $0.error == nil }
            if roles.isEmpty {
                Text(project.rolesError ?? "Ролей нет").font(T.text(12)).foregroundStyle(T.dim).padding(10)
            }
            ForEach(roles) { r in
                Button { onPick(r.role) } label: {
                    HStack(spacing: 10) {
                        Swatch(color: roleColor(r.role, in: project))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 8) {
                                Text(r.role).font(T.mono(13, .semibold)).foregroundStyle(roleColor(r.role, in: project))
                                Text(r.title ?? "").font(T.text(12)).foregroundStyle(T.muted)
                            }
                            if let d = r.description, !d.isEmpty {
                                Text(d).font(T.text(12)).foregroundStyle(T.dim).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 10)
                        Text("\(r.running) в работе").font(T.mono(11)).foregroundStyle(T.muted)
                    }
                    .padding(10)
                    .background(hover == r.role ? T.line : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 ? r.role : (hover == r.role ? nil : hover) }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(T.muted)
                Text("Каждый агент — своя сессия и свой worktree от ветки роли. Агентов одной роли сколько угодно.")
                    .font(T.text(12)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
        }
        .padding(6)
        .frame(width: 380)
        .background(T.surface)
    }
}

/// Размеры раскладки «Команды»: чат менеджера слева, граница, колонка агентов справа.
enum TeamLayout {
    static let widthKey = "teamAgentsWidth"
    static let columnsKey = "teamAgentColumns"
    static let defaultAgentsWidth = SplitLayout.defaultAgents
    /// Промежутки между панелями и отступы колонки: панели стоят плотно.
    static let gap: CGFloat = 4
    static func paneHeight(available: CGFloat, collapsedRows: Int, paneRows: Int) -> CGFloat {
        CGFloat(SplitLayout.paneHeight(available: Double(available), collapsedRows: collapsedRows, paneRows: paneRows, gap: Double(gap)))
    }
    /// Верхняя полоса экрана и полосы над колонками: тонкие, высота отдана лентам.
    static let topBarHeight: CGFloat = 38
    static let stripHeight: CGFloat = 34

    static func agentsWidth(stored: Double, total: CGFloat) -> CGFloat {
        CGFloat(SplitLayout.agentsWidth(stored: stored, total: Double(total)))
    }
}

/// Подвижная граница между чатом и агентами: курсор изменения размера, двойной щелчок — ширина по умолчанию.
/// Положение считается от начала перетаскивания в координатах окна: граница сама движется под курсором,
/// и перемещение в её собственных координатах дрожало бы.
struct PaneDivider: View {
    @Binding var width: Double
    var total: CGFloat
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle().fill(hovering || startWidth != nil ? T.accent.opacity(0.6) : T.line)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .background(Color.clear.contentShape(Rectangle()))
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { g in
                        if startWidth == nil { startWidth = Double(TeamLayout.agentsWidth(stored: width, total: total)) }
                        let next = (startWidth ?? width) - Double(g.translation.width)
                        width = Double(TeamLayout.agentsWidth(stored: next, total: total))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .onTapGesture(count: 2) { width = TeamLayout.defaultAgentsWidth }
    }
}
