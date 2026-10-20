import AgentTeamCore
import SwiftUI

/// Раздел «Журнал»: лента событий команды, новые сверху, по дням. Колонки одной ширины во всех строках;
/// фильтры по типу и агенту, поиск по задаче, коммиту и тексту, период.
struct JournalScreen: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    @State private var filter = JournalFilter()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                ScreenTitle(title: "Журнал", subtitle: "всё, что произошло в команде")
            } trailing: {
                search
                periodMenu
            }
            filters
            TimelineView(.everyMinute) { ctx in
                log(now: ctx.date)
            }
        }
    }

    // MARK: шапка и фильтры

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(T.dim)
            TextField("", text: $filter.query)
                .textFieldStyle(.plain).font(T.text(13)).foregroundStyle(T.ink)
                .rolesPlaceholder("Поиск: задача, коммит, текст", show: filter.query.isEmpty, font: T.text(13))
            if !filter.query.isEmpty {
                Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(T.dim)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 240, height: 34)
        .background(T.well, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }

    private var periodMenu: some View {
        Menu {
            ForEach(JournalPeriod.allCases, id: \.self) { p in
                Button { filter.period = p } label: {
                    if p == filter.period { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar").font(.system(size: 12))
                Text(filter.period.label).font(T.text(13, .medium))
            }
            .foregroundStyle(T.ink)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .overlay(Rectangle().stroke(T.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Text("ТИП").font(T.mono(11)).foregroundStyle(T.dim).padding(.trailing, 4)
            typeChip(nil)
            ForEach(JournalKind.filterable, id: \.self) { typeChip($0) }
            Spacer(minLength: 12)
            Text("АГЕНТ").font(T.mono(11)).foregroundStyle(T.dim)
            agentMenu
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    /// nil — «Все». Выбор нескольких типов сразу: щелчок добавляет или убирает тип.
    private func typeChip(_ kind: JournalKind?) -> some View {
        let on = kind.map { filter.kinds.contains($0) } ?? filter.kinds.isEmpty
        return Button {
            if let kind {
                if filter.kinds.contains(kind) { filter.kinds.remove(kind) } else { filter.kinds.insert(kind) }
            } else {
                filter.kinds = []
            }
        } label: {
            HStack(spacing: 6) {
                if let kind { Circle().fill(JournalStyle.color(kind)).frame(width: 6, height: 6) }
                Text(kind?.filterLabel ?? "Все").font(T.text(12)).foregroundStyle(on ? T.ink : T.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(on ? T.line : .clear, ignoresSafeAreaEdges: [])
            .overlay(Rectangle().stroke(on ? .clear : T.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var agents: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in (project.status?.agents.map(\.name) ?? []) + project.events.map(\.agent) where !a.isEmpty && seen.insert(a).inserted {
            out.append(a)
        }
        return out.sorted { JournalStyle.agentLabel($0) < JournalStyle.agentLabel($1) }
    }

    private var agentMenu: some View {
        Menu {
            Button("все агенты") { filter.agent = nil }
            Divider()
            ForEach(agents, id: \.self) { a in
                Button(JournalStyle.agentLabel(a)) { filter.agent = a }
            }
        } label: {
            HStack(spacing: 6) {
                Text(filter.agent.map(JournalStyle.agentLabel) ?? "все агенты").font(T.text(12))
                    .foregroundStyle(filter.agent == nil ? T.muted : T.ink)
                Image(systemName: "chevron.down").font(.system(size: 9))
                    .foregroundStyle(T.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Rectangle().stroke(T.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    // MARK: лента

    private enum Col {
        static let time: CGFloat = 64, type: CGFloat = 120, agent: CGFloat = 160, task: CGFloat = 200
    }

    private func log(now: Date) -> some View {
        let shown = filter.apply(project.events, now: now)
        let days = JournalDay.group(shown, now: now)
        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                head("Время").frame(width: Col.time, alignment: .leading)
                head("Тип").frame(width: Col.type, alignment: .leading)
                head("Агент").frame(width: Col.agent, alignment: .leading)
                head("Событие").frame(maxWidth: .infinity, alignment: .leading)
                head("Задача").frame(width: Col.task, alignment: .leading)
            }
            .frame(height: 39.5)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            if days.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.events.enumerated().map { ("\(day.start.timeIntervalSince1970)-\($0.offset)", $0.element) }, id: \.0) { row($0.1) }
                            } header: {
                                Text(day.title.uppercased()).font(T.mono(11)).kerning(1).foregroundStyle(T.muted)
                                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                    .background(T.bg, ignoresSafeAreaEdges: [])
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func head(_ s: String) -> some View {
        Text(s.uppercased()).font(T.mono(11)).kerning(0.5).foregroundStyle(T.dim)
    }

    private func row(_ e: TeamEvent) -> some View {
        let kind = JournalKind(type: e.type)
        let agentColor = JournalStyle.agentColor(e.agent, project: project)
        let task = e.task.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 16) {
            Text(JournalStyle.time(e.ts)).font(T.mono(12)).foregroundStyle(T.muted).frame(width: Col.time, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: JournalStyle.icon(e.type)).font(.system(size: 11)).frame(width: 13)
                    .foregroundStyle(JournalStyle.labelColor(kind))
                Text(JournalKind.rowLabel(type: e.type)).font(T.text(12)).foregroundStyle(JournalStyle.labelColor(kind)).lineLimit(1)
            }
            .frame(width: Col.type, alignment: .leading)
            HStack(spacing: 8) {
                Swatch(color: agentColor, size: 7)
                Text(JournalStyle.agentLabel(e.agent)).font(T.mono(12)).foregroundStyle(agentColor).lineLimit(1).truncationMode(.middle)
            }
            .frame(width: Col.agent, alignment: .leading)
            Text(e.text).font(T.text(13)).foregroundStyle(T.ink).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(e.text)
            // Название задачи (владельцу номер ни о чём не говорит); номер — в подсказке, а без названия — сам номер.
            let title = task == nil ? nil : project.taskTitle(of: e)
            Text(title ?? task ?? "—").font(title == nil ? T.mono(12) : T.text(13)).foregroundStyle(task == nil ? T.faint : T.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: Col.task, alignment: .leading)
                .help([title, task.map { "Задача " + $0 }].compactMap { $0 }.joined(separator: "\n"))
        }
        .frame(height: 43.5)
        .background(kind == .waiting ? T.surface : .clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
        .contentShape(Rectangle())
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var empty: some View {
        if project.events.isEmpty {
            EmptyState(title: "Событий пока нет",
                       detail: "Журнал пишет team: запуск и остановка агентов, передачи; задачи, отчёты и коммиты роли записывают командой team log.",
                       icon: "list.bullet.rectangle")
        } else {
            VStack(spacing: 14) {
                EmptyState(title: "Под фильтр ничего не попало",
                           detail: "Всего событий в журнале: \(project.events.count). Сбросьте фильтр или выберите период шире.",
                           icon: "line.3.horizontal.decrease.circle")
                    .frame(maxHeight: 180)
                Button("Показать всё") { filter = JournalFilter() }.buttonStyle(AppButtonStyle(kind: .normal))
                Spacer()
            }
            .padding(.top, 40)
        }
    }
}

/// Вид строк журнала: цвета, значки, подписи агентов.
@MainActor
enum JournalStyle {
    static func color(_ k: JournalKind) -> Color {
        switch k {
        case .task: return T.accent
        case .report: return T.cyan
        case .commit: return T.ink
        case .life: return T.muted
        case .handoff: return T.violet
        case .waiting: return T.amber
        case .owner: return T.ink
        case .other: return T.dim
        }
    }

    /// Подпись типа: задача, отчёт, передача и «ждёт вас» — цветом; коммит и «вы» — белым; запуск — приглушённо.
    static func labelColor(_ k: JournalKind) -> Color { color(k) }

    static func icon(_ type: String) -> String {
        switch type {
        case "task": return "arrow.right"
        case "report": return "arrow.left"
        case "commit": return "smallcircle.filled.circle"
        case "spawn", "restart": return "power"
        case "down": return "stop.circle"
        case "handoff": return "arrow.left.arrow.right"
        case "waiting": return "hand.raised"
        case "owner": return "text.bubble"
        default: return "circle"
        }
    }

    /// «owner» — «вы», «tester#1» — «tester #1».
    static func agentLabel(_ a: String) -> String { a == "owner" ? "вы" : ProjectModel.pretty(a) }

    @MainActor
    static func agentColor(_ a: String, project: ProjectModel) -> Color {
        if a == "owner" { return T.ink }
        return roleColor(String(a.split(separator: "#").first ?? ""), in: project)
    }

    static func time(_ ts: Int) -> String {
        DateFormats.string(Date(timeIntervalSince1970: TimeInterval(ts)), "HH:mm", locale: nil)
    }
}
