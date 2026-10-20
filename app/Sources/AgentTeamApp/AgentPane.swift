import AgentTeamCore
import AppKit
import SwiftUI

/// Вывод панели: подписывается на поток, пока виден на экране, и отписывается, когда пропадает.
struct PaneOutputView: View {
    let hub: TmuxHub
    let paneID: String
    var detail: PaneDetail = .grid
    var maxLines = 5
    /// Участники команды: подписи и цвета выделенных сообщений.
    var roster = TeamRoster()

    var body: some View {
        // Тело не читает строки вывода: их рисует AppKit-вид, SwiftUI при новом захвате не пересчитывается.
        // Настройки читаются здесь: смена шрифта и темы перерисовывает вид, не пересоздавая подписку на панель.
        let out = hub.output(for: paneID)
        let look = TerminalLook.current(grid: detail == .grid)
        Group {
            if detail == .grid {
                TerminalTail(output: out, maxLines: maxLines, look: look, roster: roster)
            } else {
                TerminalScroll(output: out, look: look, roster: roster)
            }
        }
        .background(look.background)
        .onAppear { hub.show(paneID, detail: detail) }
        .onDisappear { hub.hide(paneID, detail: detail) }
        // После restart у агента новая панель: вид пересоздаётся, подписка переходит на новый pane_id.
        .id(paneID)
    }
}

/// Цвет состояния агента.
func stateColor(_ s: AgentState, agentArea: Bool = false) -> Color {
    switch s {
    case .working: return agentArea ? A.accent : T.accent
    case .waiting: return agentArea ? A.amber : T.amber
    case .quiet: return agentArea ? A.muted : T.muted
    case .stopped: return agentArea ? A.dim : T.dim
    case .noData: return agentArea ? A.dim : T.dim
    }
}

struct AgentStatusView: View {
    let hub: TmuxHub
    let project: ProjectModel
    let agent: Agent
    /// Только цветная точка, полный текст — в подсказке (узкая шапка карточки).
    var compact = false
    var agentArea = false

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let st = project.shownStatus(agent, hub: hub, now: ctx.date)
            let state = st.state, text = st.label, tip = st.tooltip
            let color = stateColor(state, agentArea: agentArea)
            if compact {
                Circle().fill(color).frame(width: 9, height: 9).padding(.horizontal, 4).help(tip)
            } else {
                StatusBadge(text: text, color: color).help(tip)
            }
        }
    }
}

extension ProjectModel {
    /// Статус агента на экране — один расчёт для плашки, порядка колонки и фильтра: у панели на экране — по свежему
    /// захвату, у скрытой — по транскрипту.
    func shownStatus(_ agent: Agent, hub: TmuxHub, now: Date) -> AgentStatus {
        let live = agent.paneID.map { hub.hasCapture($0) } ?? false
        return agentStatus(agent, pane: agent.paneID.map { hub.output(for: $0) }, liveKnown: live, now: now)
    }
}

/// Группы агентов колонки по статусу. Отдельный вид: статус читает строку хода и время вывода панелей, они меняются
/// каждую секунду, а экран «Команды» перерисовывается только при смене группы (агент начал или закончил ход).
struct AgentGroupsReader: View {
    let hub: TmuxHub
    let project: ProjectModel
    let agents: [Agent]
    var report: ([String: AgentGroup]) -> Void

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let groups = Dictionary(agents.map { ($0.key, AgentGroup(project.shownStatus($0, hub: hub, now: ctx.date).state)) },
                                    uniquingKeysWith: { a, _ in a })
            Color.clear.onChange(of: groups, initial: true) { _, g in report(g) }
        }
    }
}

/// Имя агента: квадрат цвета роли, роль и номер.
struct AgentName: View {
    let project: ProjectModel
    let agent: Agent
    var size: CGFloat = 13
    var agentArea = false

    var body: some View {
        let color = roleColor(agent.role, in: project, agentArea: agentArea)
        HStack(spacing: 6) {
            Swatch(color: color)
            Text(agent.role).font(T.mono(size, .semibold)).foregroundStyle(color)
                .lineLimit(1).truncationMode(.tail)
            Text("#\(agent.n)").font(T.mono(11)).foregroundStyle(agentArea ? A.dim : T.dim).fixedSize()
        }
    }
}

/// Модель агента коротким именем («Opus 5.5»): из транскрипта, после `/model` — новая. Нет данных — ничего.
struct AgentModelLabel: View {
    let project: ProjectModel
    let agent: Agent
    var agentArea = false

    var body: some View {
        if let name = project.modelName(of: agent) {
            Text(name).font(T.mono(11)).foregroundStyle(agentArea ? A.muted : T.muted).lineLimit(1)
                .help("Модель агента")
        }
    }
}

/// Длительность сессии с явной подписью; запуск, последнее действие и ход — в подсказке.
struct Uptime: View {
    var started: Int?
    var tooltip: String = ""
    var agentArea = false
    var body: some View {
        let color = agentArea ? A.muted : T.muted
        TimelineView(.everyMinute) { ctx in
            Text(AgentTime.session(started: started, now: ctx.date)).font(T.mono(11)).foregroundStyle(color)
                .help(tooltip)
        }
    }
}

/// Развёрнутая панель агента в сетке «Команды».
struct AgentPaneCard: View {
    @Bindable var app: AppModel
    let project: ProjectModel
    let agent: Agent
    /// Высота карточки: сетка делит высоту колонки между рядами.
    var height: CGFloat = 220
    var onToggle: () -> Void

    var body: some View {
        let waiting = isWaiting
        VStack(spacing: 0) {
            // В узкой панели (два столбца) время работы уступает место имени и статусу.
            ViewThatFits(in: .horizontal) {
                header(showUptime: true, waiting: waiting)
                header(showUptime: false, waiting: waiting)
                header(showUptime: false, compactStatus: true, waiting: waiting)
            }
            .padding(.horizontal, PaneBand.inset).frame(height: PaneBand.height)
            .overlay(alignment: .bottom) { Rectangle().fill(A.line).frame(height: 1) }

            if agent.alive {
                AgentThreadView(project: project, agent: agent, hub: app.hub, dense: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Субагенты агента — полосой под лентой: лента прокручивается, а полоса видна всё время, пока они работают.
                SubagentStrip(project: project, sessionID: agent.sessionID, cwd: agent.cwd, colors: .agent, dense: true,
                              insets: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            } else {
                Text("Панель завершилась. Перезапуск — на экране агента.").font(A.mono(12)).foregroundStyle(A.dim)
                    .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: height)
        .background(A.bg)
        .overlay(Rectangle().stroke(agent.notRole ? A.rose : waiting ? A.amber.opacity(0.55) : A.line, lineWidth: 1))
    }

    /// Ждущему агенту — заметное «Ответить» в терминале (подпись, пока хватает места).
    @ViewBuilder
    private func replyControl(waiting: Bool, labeled: Bool) -> some View {
        if waiting {
            Button {
                TerminalOpener.open(session: project.session, pane: agent.paneID, socket: app.hub.socketName, tmux: app.hub.tmuxPath)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "apple.terminal").font(.system(size: 11))
                    if labeled { Text("Ответить").font(T.text(12)) }
                }
                .foregroundStyle(A.amber).padding(.horizontal, 7).frame(height: 22)
                .overlay(Rectangle().stroke(A.amber.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain).help("Ответить в панели")
            .fixedSize()   // не сжимается в «…»: не хватает места — шапка берёт вариант с одной иконкой
        }
    }

    /// Шапка в одну строку: переключатель слева (на том же месте, что у свёрнутой строки), имя, задача, время, статус,
    /// справа — отдельная иконка экрана агента. Клик по самой шапке ничего не делает: сворачивает только переключатель,
    /// экран агента открывает только иконка.
    private func header(showUptime: Bool, compactStatus: Bool = false, waiting: Bool) -> some View {
        HStack(spacing: 6) {
            PaneToggle(collapsed: false, agentArea: true, action: onToggle)
            AgentName(project: project, agent: agent, agentArea: true).layoutPriority(1).help("\(agent.role) #\(agent.n)")
            // Название задачи (при его отсутствии номер); полное название, номер и время установки — в подсказке.
            let label = project.taskLabel(of: agent.name)
            Text(label?.text ?? "").font(A.mono(11)).foregroundStyle(A.dim).lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, idealWidth: 90, maxWidth: .infinity, alignment: .leading).layoutPriority(0)
                // ideal 90: вариант шапки подходит, только если названию остаётся хоть сколько-то места; иначе берётся
                // следующий, без времени или с одной точкой статуса, а не название, сжатое до «…».
                .help(label?.tooltip() ?? "")
            AgentModelLabel(project: project, agent: agent, agentArea: true).fixedSize()
            if showUptime { Uptime(started: agent.started, tooltip: project.timeTooltip(agent), agentArea: true).fixedSize() }
            replyControl(waiting: waiting, labeled: !compactStatus && showUptime)
            RoleMark(agent: agent, compact: compactStatus).layoutPriority(2)
            AgentStatusView(hub: app.hub, project: project, agent: agent, compact: compactStatus, agentArea: true).fixedSize().layoutPriority(2)
            OpenAgentButton(agentArea: true) { app.openAgent(agent.name) }
        }
    }

    private var isWaiting: Bool {
        project.isWaiting(agent, pane: agent.paneID.map { app.hub.output(for: $0) }, captured: agent.paneID.map { app.hub.hasCapture($0) } ?? false)
    }
}

/// Свёрнутый агент — строка с выровненными колонками. Переключатель слева на том же месте, что в шапке панели;
/// экран агента открывает только иконка справа. Строка — свёрнутая шапка панели: те же токены области агента (тема
/// терминала), поэтому цвет роли и статуса не меняется при сворачивании.
struct AgentRow: View {
    @Bindable var app: AppModel
    let project: ProjectModel
    let agent: Agent
    var onToggle: () -> Void

    var body: some View {
        // Варианты, как у шапки развёрнутой панели: в узкой колонке сначала уходит время, потом подпись статуса
        // сжимается до точки (полный текст — в подсказке). Название задачи не сжимается до пары букв.
        ViewThatFits(in: .horizontal) {
            line(showUptime: true)
            line(showUptime: false)
            line(showUptime: false, compactStatus: true)
        }
        .padding(.horizontal, PaneBand.inset)
        .frame(height: PaneBand.height)
        .background(A.bg)
        .overlay(Rectangle().stroke(agent.notRole ? A.rose : A.line, lineWidth: 1))
    }

    /// Строка в одну линию. Имя — по своей ширине; название задачи занимает всё свободное место между именем и
    /// моделью, но не меньше 140 pt: иначе берётся следующий вариант; модель, время, статус и иконка прижаты вправо.
    private func line(showUptime: Bool, compactStatus: Bool = false) -> some View {
        HStack(spacing: 0) {
            PaneToggle(collapsed: true, agentArea: true, action: onToggle)
                .padding(.trailing, 14)
            AgentName(project: project, agent: agent, agentArea: true).fixedSize().layoutPriority(2)
            Text([project.taskLabel(of: agent.name)?.text, project.repoName(of: agent)].compactMap { $0 }.joined(separator: " · "))
                .font(A.mono(12)).foregroundStyle(A.muted).lineLimit(1).truncationMode(.tail)
                .help([project.taskLabel(of: agent.name)?.tooltip(), project.repoName(of: agent)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
                .frame(minWidth: 0, idealWidth: 140, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            AgentModelLabel(project: project, agent: agent, agentArea: true).fixedSize().layoutPriority(2)
            if showUptime {
                Uptime(started: agent.started, tooltip: project.timeTooltip(agent), agentArea: true).fixedSize().layoutPriority(2)
                    .padding(.leading, 10)
            }
            RoleMark(agent: agent, compact: compactStatus).padding(.leading, 10).layoutPriority(2)
            AgentStatusView(hub: app.hub, project: project, agent: agent, compact: compactStatus, agentArea: true).fixedSize()
                .padding(.leading, 10).layoutPriority(2)
            OpenAgentButton(agentArea: true) { app.openAgent(agent.name) }
                .padding(.leading, 8)
        }
    }
}

/// Размеры полосы агента: у шапки развёрнутой панели и у свёрнутой строки они одинаковы, поэтому переключатель
/// стоит в одной точке в обоих состояниях.
enum PaneBand {
    static let height: CGFloat = 44
    static let inset: CGFloat = 14
    /// Зона нажатия кнопок полосы: не меньше 28×28 pt, кнопки не пересекаются.
    static let hit: CGFloat = 28
}

/// Переключатель «свернуть / развернуть»: шеврон слева от имени. Вниз — развёрнуто, вправо — свёрнуто.
/// Нажатие подсвечивается сразу; зона нажатия — вся рамка 28×28.
struct PaneToggle: View {
    var collapsed: Bool
    var agentArea: Bool
    var action: () -> Void

    var body: some View {
        let line = agentArea ? A.line : T.line
        Button(action: action) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 11, weight: .semibold))
                .frame(width: PaneBand.hit, height: PaneBand.hit)
                .overlay(Rectangle().stroke(line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackStyle(highlight: line))
        .foregroundStyle(agentArea ? A.muted : T.muted)
        .help(collapsed ? "Развернуть вывод" : "Свернуть вывод")
    }
}

/// Иконка «Открыть экран агента»: отдельная, всегда видимая, справа в полосе. Единственное место, откуда открывается экран.
struct OpenAgentButton: View {
    var agentArea: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right.square").font(.system(size: 13))
                .frame(width: PaneBand.hit, height: PaneBand.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressFeedbackStyle(highlight: agentArea ? A.line : T.line))
        .foregroundStyle(agentArea ? A.muted : T.muted)
        .help("Открыть экран агента")
    }
}

extension ProjectModel {
    /// Участники команды для подписей сообщений: менеджер и агенты из status с цветом роли.
    var roster: TeamRoster {
        var all = status?.agents ?? []
        if let m = status?.manager, !all.contains(where: { $0.name == m.name }) { all.append(m) }
        return TeamRoster(all.map { a in
            TeamRoster.Entry(name: a.name, role: a.role, title: a.title, address: a.addr,
                             color: Self.termColor(roleColor(a.role, in: self)))
        })
    }

    static func termColor(_ c: Color) -> TermColor? {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return nil }
        func b(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        return .rgb(b(ns.redComponent), b(ns.greenComponent), b(ns.blueComponent))
    }
}

/// Кнопка с немедленной подсветкой при нажатии: отклик виден, пока панель ещё перестраивается.
struct PressFeedbackStyle: ButtonStyle {
    var highlight: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? highlight : Color.clear)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Свёрнут ли элемент колонки агентов (`AgentColumnGrid`).
struct CollapsedRowKey: LayoutValueKey {
    static let defaultValue = false
}

/// Колонка агентов одним списком: свёрнутый агент — строка на всю ширину на своём месте, развёрнутые — рядами по
/// `columns` (`AgentColumnLayout`). У каждого агента одна identity при любом числе свёрнутых и при смене порядка:
/// переезд панели не пересоздаёт её ленту.
struct AgentColumnGrid: Layout {
    var columns: Int
    var gap: CGFloat
    var paneHeight: CGFloat
    var rowHeight: CGFloat

    private func frames(width: CGFloat, subviews: Subviews) -> [ColumnFrame] {
        AgentColumnLayout.frames(collapsed: subviews.map { $0[CollapsedRowKey.self] }, width: Double(width), columns: columns,
                                 gap: Double(gap), paneHeight: Double(paneHeight), rowHeight: Double(rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: AgentColumnLayout.height(frames(width: width, subviews: subviews)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (sub, f) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            sub.place(at: CGPoint(x: bounds.minX + f.x, y: bounds.minY + f.y), anchor: .topLeading,
                      proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}
