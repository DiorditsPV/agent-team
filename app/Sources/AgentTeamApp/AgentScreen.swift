import AgentTeamCore
import SwiftUI

enum AgentTab: Hashable {
    case dialog, output, handoffs, instruction, allow

    /// Вкладка по имени из аргумента запуска `--tab`.
    init?(launchName: String) {
        switch launchName {
        case "dialog": self = .dialog
        case "output": self = .output
        case "handoffs": self = .handoffs
        case "instruction": self = .instruction
        case "permissions", "allow": self = .allow
        default: return nil
        }
    }
}

/// Экран агента: диалог из транскрипта, живой вывод, передачи, инструкция, права; инспектор справа.
struct AgentScreen: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    var agentName: String
    @State private var tab: AgentTab = .dialog
    @State private var uncommitted: Int?
    @State private var confirm: PendingAction?

    enum PendingAction: Identifiable {
        case handoff, resume, fresh, stop
        var id: Int { hashValue }
    }

    var body: some View {
        if let agent = project.agent(named: agentName) {
            content(agent)
                .onAppear {
                    if let name = app.launchAgentTab, let t = AgentTab(launchName: name) { tab = t }
                    app.launchAgentTab = nil
                }
        } else {
            VStack(spacing: 0) {
                ScreenHeader { crumb(nil) } trailing: { EmptyView() }
                EmptyState(title: "Агента \(ProjectModel.pretty(agentName)) нет", detail: "Он остановлен или ещё не поднят.", icon: "person.slash")
            }
        }
    }

    private func content(_ agent: Agent) -> some View {
        let role = project.role(named: agent.role)
        return VStack(spacing: 0) {
            ScreenHeader {
                crumb(agent)
            } trailing: {
                Button {
                    TerminalOpener.open(session: project.session, pane: agent.paneID, socket: app.hub.socketName, tmux: app.hub.tmuxPath)
                } label: { Label("Открыть панель", systemImage: "apple.terminal") }
                    .buttonStyle(AppButtonStyle())
                    .disabled(agent.paneID == nil)
                actionsMenu(agent)
            }
            tabs(agent)
            if agent.notRole { RoleAlertBanner(project: project, agent: agent, colors: .window) }
            HStack(spacing: 0) {
                Group {
                    switch tab {
                    case .dialog: AgentThreadView(project: project, agent: agent, hub: app.hub)
                    case .output: outputTab(agent)
                    case .handoffs: handoffsTab(agent)
                    case .instruction: instructionTab(role)
                    case .allow: allowTab(agent, role)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                inspector(agent, role)
            }
        }
        .task(id: agent.cwd) { await loadUncommitted(agent.cwd) }
        .onChange(of: project.status) { _, _ in Task { await loadUncommitted(agent.cwd) } }
        .confirmationDialog(confirmTitle(agent), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirmButton, role: confirm == .stop ? .destructive : nil) { run(confirm, agent) }
        } message: {
            Text(confirmMessage(agent))
        }
    }

    private func crumb(_ agent: Agent?) -> some View {
        HStack(spacing: 12) {
            Button { app.openedAgent = nil } label: {
                Text("Команда /").font(T.text(14)).foregroundStyle(T.muted)
            }
            .buttonStyle(.plain)
            if let agent {
                Swatch(color: roleColor(agent.role, in: project), size: 10)
                Text(ProjectModel.pretty(agent.name)).font(T.title(20)).kerning(-0.3).foregroundStyle(T.ink).lineLimit(1)
                if let t = agent.title { Text(t).font(T.text(14)).foregroundStyle(T.muted).lineLimit(1) }
                if let l = project.taskLabel(of: agent.name), let text = l.text {
                    Text(text).font(T.text(14)).foregroundStyle(T.ink).lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(T.surface, ignoresSafeAreaEdges: [])
                        .help(l.tooltip())
                }
                if let model = project.modelName(of: agent) {
                    Text(model).font(T.mono(13)).foregroundStyle(T.muted).lineLimit(1).help("Модель агента")
                }
                AgentStatusView(hub: app.hub, project: project, agent: agent)
            } else {
                Text(ProjectModel.pretty(agentName)).font(T.title(20)).foregroundStyle(T.ink)
            }
        }
    }

    private func actionsMenu(_ agent: Agent) -> some View {
        Menu {
            Button { confirm = .handoff } label: { Label("Передать — попросить менеджера подготовить передачу", systemImage: "arrow.left.arrow.right") }
                .disabled(!agent.alive)
            Button { confirm = .resume } label: { Label("Продолжить сессию — --resume, тот же контекст", systemImage: "arrow.counterclockwise") }
            Button { confirm = .fresh } label: { Label("Новая сессия — --fresh, с последней передачей", systemImage: "play") }
            Divider()
            Button(role: .destructive) { confirm = .stop } label: { Label("Остановить агента", systemImage: "stop") }
                .disabled(!agent.alive)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14)).foregroundStyle(T.ink)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 34, height: 34).background(T.surface, ignoresSafeAreaEdges: []).overlay(Rectangle().stroke(T.line, lineWidth: 1))
        .disabled(project.busyActions.contains { $0.hasSuffix(":" + agent.name) })
    }

    private func confirmTitle(_ a: Agent) -> String {
        let n = ProjectModel.pretty(a.name)
        switch confirm {
        case .handoff: return "Попросить менеджера подготовить передачу \(n)?"
        case .resume: return "Перезапустить \(n) с той же сессией?"
        case .fresh: return "Перезапустить \(n) с новой сессией?"
        case .stop: return "Остановить \(n)?"
        case nil: return ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .handoff: return "Передать"
        case .resume: return "Продолжить сессию"
        case .fresh: return "Новая сессия"
        case .stop: return "Остановить агента"
        case nil: return ""
        }
    }

    private func confirmMessage(_ a: Agent) -> String {
        switch confirm {
        case .handoff: return "Менеджеру уйдёт сообщение: «\(ProjectModel.handoffRequest(for: a.name))» Оно появится в ленте чата."
        case .resume: return "team restart \(a.name): панель закроется, Claude продолжит прежнюю сессию (--resume)."
        case .fresh: return "team restart \(a.name) --fresh: новая сессия Claude; контекст — из последней передачи."
        case .stop: return "team down \(a.name): панель агента закроется. Работа в git и трекере сохранится."
        case nil: return ""
        }
    }

    private func run(_ action: PendingAction?, _ a: Agent) {
        Task {
            switch action {
            case .handoff:
                // Как сообщение в чате и через ту же очередь: в ходе менеджера просьба ждёт конца хода с карточкой
                // «в очереди», а не уходит в очередь самого Claude Code мимо удержанных сообщений.
                if project.outbox.send(text: ProjectModel.handoffRequest(for: a.name), images: []) {
                    // Ждёт — так и сказано, чего: хода менеджера или набранного в строке Claude Code.
                    let reason = project.pending.last.flatMap { project.outbox.holdReason($0) }
                    project.report("Просьба о передаче \(ProjectModel.pretty(a.name)) — "
                                   + (reason.map { "в очереди: \($0)" } ?? "в ленте чата"))
                } else {
                    project.report("Менеджер не запущен — передачу некому поручить")
                }
            case .resume: await project.restart(a.name, fresh: false)
            case .fresh: await project.restart(a.name, fresh: true)
            case .stop: await project.down(a.name)
            case nil: break
            }
        }
    }

    // MARK: вкладки

    private func tabs(_ agent: Agent) -> some View {
        let hcount = project.handoffs(of: agent.name).count
        return HStack(spacing: 24) {
            tabButton(.dialog, "Диалог")
            tabButton(.output, "Вывод")
            tabButton(.handoffs, hcount > 0 ? "Передачи \(hcount)" : "Передачи")
            tabButton(.instruction, "Инструкция")
            tabButton(.allow, "Права")
            Spacer()
        }
        .padding(.horizontal, 28).frame(height: 41.5)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    private func tabButton(_ t: AgentTab, _ title: String) -> some View {
        Button { tab = t } label: {
            Text(title).font(T.text(14, tab == t ? .medium : .regular)).foregroundStyle(tab == t ? T.ink : T.muted)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(tab == t ? T.accent : .clear).frame(height: 2) }
        }
        .buttonStyle(.plain)
    }

    private func outputTab(_ agent: Agent) -> some View {
        VStack(spacing: 14) {
            // Claude Code рисует в альтернативном экране: у панели нет истории, только видимое.
            Text("История — во вкладке «Диалог»").font(A.text(13)).foregroundStyle(A.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                HStack {
                    Text([shortPath(agent.cwd), agent.branch].compactMap { $0 }.joined(separator: " · "))
                        .font(A.mono(11)).foregroundStyle(A.muted).lineLimit(1)
                    Spacer()
                    if agent.alive, agent.paneID != nil {
                        Text("● вживую · \(agent.paneID ?? "")").font(A.mono(11)).foregroundStyle(A.accent)
                    } else {
                        Text("панель завершилась").font(A.mono(11)).foregroundStyle(A.dim)
                    }
                }
                .padding(.horizontal, 14).frame(height: 34.5)
                .overlay(alignment: .bottom) { Rectangle().fill(A.line).frame(height: 1) }
                if let pane = agent.paneID {
                    PaneOutputView(hub: app.hub, paneID: pane, detail: .focus, roster: project.roster)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyState(title: "Панели нет", detail: "Агент не запущен.", icon: "terminal")
                }
            }
            .background(A.well)
            .overlay(Rectangle().stroke(A.line, lineWidth: 1))
            Text("Задачи роли даёт менеджер. Чтобы что-то поручить \(agent.role), напишите менеджеру — тогда роль увидит отправителя, а не чужой ввод.")
                .font(A.text(13)).foregroundStyle(A.muted).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .background(A.bg)      // «Вывод» целиком в теме терминала
    }

    private func handoffsTab(_ agent: Agent) -> some View {
        let list = project.handoffs(of: agent.name)
        return Group {
            if list.isEmpty {
                EmptyState(title: "Передач нет", detail: "Передача пишется перед сменой сессии: меню «…» → Передать.", icon: "arrow.left.arrow.right")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(list) { h in HandoffSummary(handoff: h) }
                    }
                    .padding(24)
                }
            }
        }
    }

    private func instructionTab(_ role: RoleInfo?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("инструкция · собрана из \(role.map { ($0.file as NSString?)?.lastPathComponent ?? $0.role } ?? "—") + \(role?.includes.count ?? 0) includes · только чтение")
                    .font(T.mono(11)).foregroundStyle(T.muted)
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            MarkdownDocument(text: role?.instruction ?? role?.body ?? (project.rolesError ?? "Инструкция недоступна"))
        }
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
        .padding(24)
    }

    private func allowTab(_ agent: Agent, _ role: RoleInfo?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionLabel(text: "Действующий список --allowedTools")
                FlowChips(items: role?.effectiveAllow ?? [], color: T.ink)
                if let role, role.allow.isEmpty {
                    Text("allow в роли не задан — действует набор team по умолчанию.").font(T.text(13)).foregroundStyle(T.muted)
                } else if let role {
                    SectionLabel(text: "allow роли")
                    FlowChips(items: role.allow, color: T.amber)
                }
                ForEach(permissionWarnings(role), id: \.self) { w in
                    Note(text: w, icon: "exclamationmark.triangle", color: T.amber, fill: T.amberBg)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: инспектор

    private func inspector(_ agent: Agent, _ role: RoleInfo?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                group("Сессия") {
                    KeyValueRow(key: "модель", value: agent.model ?? role?.model ?? "—")
                    KeyValueRow(key: "session-id", value: shortID(agent.sessionID))
                    KeyValueRow(key: "запущена", value: startedText(agent.started))
                    let hs = project.handoffs(of: agent.name)
                    KeyValueRow(key: "передачи", value: hs.isEmpty ? "нет" : "\(hs.count) · \(clock(Date(timeIntervalSince1970: TimeInterval(hs[0].ts))))")
                }
                group("Worktree") {
                    KeyValueRow(key: "каталог", value: shortPath(agent.cwd) ?? "—")
                    KeyValueRow(key: "ветка", value: agent.branch ?? "—")
                    KeyValueRow(key: "не в коммите", value: uncommittedText, valueColor: (uncommitted ?? 0) == 0 ? T.accent : T.amber)
                }
                group("Зона и права") {
                    KeyValueRow(key: "includes", value: role?.includes.map { ($0 as NSString).deletingPathExtension }.joined(separator: ", ") ?? "—")
                    if let zone = role?.zone, !zone.isEmpty {
                        FlowChips(items: zone, color: T.cyan, small: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if role?.allow.isEmpty ?? true {
                            Text("allow не задан — набор team:").font(T.mono(12)).foregroundStyle(T.dim)
                        }
                        Text((role?.effectiveAllow ?? []).joined(separator: ", ")).font(T.mono(12)).foregroundStyle(T.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(permissionWarnings(role), id: \.self) { w in
                            Text(w).font(T.mono(12)).foregroundStyle(T.amber).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(T.well)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
        }
        .frame(width: 360)
        .background(T.side)
        .overlay(alignment: .leading) { Rectangle().fill(T.line).frame(width: 1) }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
            content()
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    /// Замечания team check о правах этой роли: агент встанет на запросе права.
    private func permissionWarnings(_ role: RoleInfo?) -> [String] {
        guard let role, let check = project.check else { return [] }
        // Имя роли — целым словом: «developer» не должен совпадать с «app-developer».
        let names = project.projectRoles.map(\.role)
        func mentions(_ text: String, _ name: String) -> Bool {
            let pattern = "(^|[^A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: name) + "($|[^A-Za-z0-9_-])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        return check.problems.filter { issue in
            let text = issue.title + " " + issue.detail
            let lower = text.lowercased()
            // Только замечания о правах: черновик роли или пересечение зон — не повод для «встанет на запросе права».
            guard lower.contains("прав") || lower.contains("allow") || lower.contains("bash(") else { return false }
            if mentions(text, role.role) { return true }
            // Замечание о правах без имени роли касается всех ролей без своего allow.
            return !names.contains { mentions(text, $0) } && role.allow.isEmpty
        }
        .map { "\($0.title): \($0.detail) — агент встанет на запросе права" }
    }

    private var uncommittedText: String {
        guard let n = uncommitted else { return "—" }
        return n == 0 ? "нет" : plural(n, "файл", "файла", "файлов")
    }

    private func loadUncommitted(_ cwd: String?) async {
        // Новый CLI отдаёт незакоммиченные пути в status.dirty; git status — для старого.
        if let dirty = project.agent(named: agentName)?.dirty { uncommitted = dirty.count; return }
        guard let cwd, FileManager.default.fileExists(atPath: cwd) else { uncommitted = nil; return }
        let r = await Shell.run(ToolLocator.find("git") ?? "/usr/bin/git", ["--no-optional-locks", "-C", cwd, "status", "--porcelain"], environment: ToolLocator.environment, timeout: 10)
        guard r.status == 0 else { uncommitted = nil; return }
        uncommitted = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").count
    }

    private func shortPath(_ p: String?) -> String? {
        guard let p else { return nil }
        let home = NSHomeDirectory()
        let parent = (project.repo as NSString).deletingLastPathComponent
        if p.hasPrefix(parent + "/") { return String(p.dropFirst(parent.count + 1)) }
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func shortID(_ s: String?) -> String {
        guard let s, s.count > 16 else { return s ?? "—" }
        return s.prefix(8) + "…" + s.suffix(6)
    }

    private func startedText(_ ts: Int?) -> String {
        guard let ts else { return "—" }
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        return DateFormats.string(d, Calendar.current.isDateInToday(d) ? "'сегодня', HH:mm" : "d MMMM, HH:mm")
    }
}

/// Чипы с переносом по строкам.
struct FlowChips: View {
    var items: [String]
    var color: Color
    var small = false

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { s in
                Text(s).font(T.mono(small ? 11 : 12)).foregroundStyle(color)
                    .padding(.horizontal, small ? 7 : 10).padding(.vertical, small ? 3 : 5)
                    .background(T.surface)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            maxX = max(maxX, x)
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: min(width, maxX), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Краткая карточка передачи на экране агента.
struct HandoffSummary: View {
    var handoff: Handoff

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(clock(Date(timeIntervalSince1970: TimeInterval(handoff.ts)))).font(T.mono(11)).foregroundStyle(T.dim)
                Text([handoff.task, handoff.reason].compactMap { $0 }.joined(separator: " · ")).font(T.text(14)).foregroundStyle(T.ink)
                Spacer()
                StatusBadge(text: handoff.isWaiting ? "ждёт" : "использована" + (handoff.usedAt.map { " " + clock(Date(timeIntervalSince1970: TimeInterval($0))) } ?? ""),
                            color: handoff.isWaiting ? T.amber : T.muted)
            }
            ForEach([("Сделано", handoff.sections.done), ("Проверено", handoff.sections.verified),
                     ("В работе", handoff.sections.inProgress), ("Подводные камни", handoff.sections.pitfalls),
                     ("Дальше", handoff.sections.next)], id: \.0) { title, text in
                if !text.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: title)
                        MarkdownView(text: text, size: 13)
                    }
                }
            }
        }
        .padding(16)
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }
}
