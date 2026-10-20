import AgentTeamCore
import AppKit
import SwiftUI

/// Вкладка «Диалог» экрана агента и панель агента на «Команде»: тред агента из его транскрипта, до начала сессии.
/// Лента живёт в проекте (`ProjectModel.agentThread`): вид её только показывает, уход с экрана наблюдение не снимает.
struct AgentThreadView: View {
    @Bindable var project: ProjectModel
    var agent: Agent
    /// Для строки хода из панели агента; без узла строки нет.
    var hub: TmuxHub?
    /// Плотный вариант для панели на «Команде»: меньший кегль и отступы, сообщения короче.
    var dense = false
    /// Лента живёт в проекте: панель и вкладка «Диалог» показывают одну модель, она переживает сворачивание панели
    /// и уход с экрана и засыпает вместе с проектом.
    private var model: AgentThreadModel { project.agentThread(agent.name) }
    /// Прокрутка — общая с чатом менеджера (`FeedScroller`). Хранится по агенту, а не в виде: панель, построенная
    /// заново после экрана агента, возвращается на прежнее место.
    private var scroller: FeedScroller { FeedScroller.remembered(FeedScroller.agentKey(session: project.session, agent: agent.name, dense: dense)) }
    @State private var snapshotScrolled = false

    private static let bottomID = "thread-bottom"
    private nonisolated static let space = "thread"
    /// Для снимка (`AGENT_TEAM_THREAD_SCROLLED_UP=1`): после открытия лента прокручивается вверх от конца.
    private static let scrolledUpForSnapshot = ProcessInfo.processInfo.environment["AGENT_TEAM_THREAD_SCROLLED_UP"] == "1"

    var body: some View {
        Group {
            switch model.phase {
            case .noSession where dense:
                DenseNote(text: "Сессии нет: диалог появится, когда агент поднимется.")
            case .waiting where dense:
                DenseNote(text: "Транскрипта ещё нет: он появится здесь сам.")
            case .idle where dense:
                DenseNote(text: "")
            case .noSession:
                EmptyState(title: "Сессии нет", detail: "team status не знает session_id этого агента: диалог появится, когда агент поднимется.", icon: "text.bubble", agentArea: true)
            case .waiting:
                EmptyState(title: "Транскрипта ещё нет", detail: "Claude Code пишет транскрипт с первого сообщения сессии. Он появится здесь сам.", icon: "text.bubble", agentArea: true)
            case .idle, .ready:
                if model.phase == .ready, model.feed.count == 0, !model.hasEarlier {
                    if dense { DenseNote(text: "Диалог пока пуст.") } else { EmptyState(title: "Диалог пока пуст", detail: "В транскрипте нет сообщений: агент ждёт первой задачи.", icon: "text.bubble", agentArea: true) }
                } else {
                    feed
                }
            }
        }
        .background(A.bg)      // весь экран ленты, и пустые состояния тоже, — в теме терминала
        .task {
            // Стенд истории на вкладке «Диалог» (`AGENT_TEAM_DIALOG_BENCH=<файл>`, вместе с `--screen agent`): тот же замер,
            // что у чата менеджера, — прыжок видимой строки на каждой подгрузке начала.
            guard !dense, let path = ProcessInfo.processInfo.environment["AGENT_TEAM_DIALOG_BENCH"] else { return }
            try? await Task.sleep(nanoseconds: 16_000_000_000)
            await FeedScroller.runHistoryBench(path: path, scroller: scroller, model: model)
        }
        .task(id: agent.sessionID ?? "") {
            scroller.sessionChanged(to: agent.sessionID) { model.follows(sessionID: $0) }
            project.openAgentThread(agent)
        }
    }

    private var feed: some View {
        let peers = TeamPeers(project: project, agent: agent)
        let vis = DisplayModel.shared.settings.feedAgents
        let items = ThreadGrouping.visible(model.feed.items, vis)
        let scroller = self.scroller
        let model = self.model
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ChatFont.gap(dense ? 10 : 16)) {
                    top(firstID: items.first?.id)
                    ForEach(items) { item in
                        ThreadRow(item: item, peers: peers, dense: dense).id(item.id)
                            .modifier(FeedRowPosition(id: item.id, scroller: scroller, space: Self.space))
                    }
                    if vis.turnStatus, let hub, let pane = agent.paneID { TurnStatusRow(hub: hub, pane: pane, colors: .agent) }
                    // Фоновые субагенты на вкладке «Диалог» — в ленте под строкой хода; в панели «Команды» полоса стоит под лентой.
                    if !dense { SubagentStrip(project: project, sessionID: agent.sessionID, cwd: agent.cwd, colors: .agent) }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, dense ? 10 : 28).padding(.vertical, ChatFont.gap(dense ? 8 : 20))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollProbe(
                    onScroll: { d, previous in
                        DispatchQueue.main.async {
                            scroller.scrolled(distance: d, previous: previous, model: model, firstID: items.first?.id)
                            scrollUpForSnapshot()
                        }
                    },
                    onGrow: {
                        // Уведомление приходит посреди раскладки: прокрутка — на следующем проходе цикла.
                        DispatchQueue.main.async { scroller.grew(proxy: proxy, bottomID: Self.bottomID, model: model, firstID: items.first?.id) }
                    },
                    onGrowNow: { scroller.contentGrewNow(model: model) },
                    onUserInput: { scroller.ownerInput() },
                    onLiveScroll: { scroller.liveScroll($0) },
                    onFound: { scroller.attached($0); scroller.endInset = ChatFont.gap(dense ? 8 : 20) }))
            }
            .coordinateSpace(name: Self.space)
            .background(GeometryReader { g in Color.clear.onAppear { scroller.viewH = g.size.height }.onChange(of: g.size.height) { _, h in scroller.viewH = h } })
            .onAppear { scroller.appeared(proxy: proxy, ids: items.map(\.id), bottomID: Self.bottomID, toEndOtherwise: false) }
            .onChange(of: model.feed.items.count) { _, _ in scrollUpForSnapshot() }
            .onChange(of: model.liveRevision) { _, _ in scroller.arrived(proxy: proxy, bottomID: Self.bottomID, model: model) }
            .onChange(of: model.prependRevision) { _, _ in
                scroller.pagePrepended(proxy: proxy, bottomID: Self.bottomID, model: model, ids: items.map(\.id))
            }
            .overlay(alignment: .bottom) {
                if scroller.follow.unseen {
                    Button {
                        scroller.jumpToEnd(proxy: proxy, bottomID: Self.bottomID)
                    } label: {
                        Text("Новые ↓").font(A.text(13, .medium)).foregroundStyle(A.bg)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(A.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, dense ? 8 : 16)
                }
            }
        }
        // Смена интервала чата или показа элементов резко меняет высоты: ленивая лента пересоздаётся и заново встаёт на конец.
        .id("\(Int(ChatFont.spacing * 100))|\(vis.key)")
    }

    /// Верх ленты: догрузка начала или отметка «начало сессии». Сам маркер — триггер подгрузки: он работает и тогда,
    /// когда лента короче окна и прокручивать нечего.
    private func top(firstID: String?) -> some View {
        Group {
            if model.hasEarlier {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("раньше…").font(A.mono(11)).foregroundStyle(A.dim)
                }
            } else {
                Text("начало сессии").font(A.mono(11)).foregroundStyle(A.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .onGeometryChange(for: Bool.self) { $0.frame(in: .named(Self.space)).maxY > -FeedScroller.prefetchDistance } action: { _ in
            scroller.startEarlier(model: model, firstID: firstID)
        }
    }

    /// Для снимка: через несколько секунд после открытия, когда лента уже догрузилась, она уходит вверх от конца.
    private func scrollUpForSnapshot() {
        guard Self.scrolledUpForSnapshot, scroller.positioned, !snapshotScrolled else { return }
        snapshotScrolled = true
        Task { @MainActor in
            // Ждём, пока лента догрузится выше полутора экранов.
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let scroll = scroller.scroll, let doc = scroll.documentView, doc.frame.height > scroll.contentView.bounds.height * 1.5 { break }
            }
            guard let scroll = scroller.scroll else { return }
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - clip.bounds.height * 0.8)))
            scroll.reflectScrolledClipView(clip)
        }
    }
}

/// Положение прокрутки из AppKit: расстояние до конца при каждом сдвиге и рост содержимого. Положение одинаково
/// для колеса, ползунка, клавиш, тачпада и прокрутки из кода, поэтому следование не зависит от способа.
/// Рост содержимого сдвигом владельца не считается: пока высота меняется, положение не оценивается, а после
/// успокоения лента ещё раз просится к концу (оценки высот ленивых строк уточняются не сразу).
struct ScrollProbe: NSViewRepresentable {
    /// Расстояние до конца и прежнее расстояние при неизменной высоте (`nil` — оценка без сравнения).
    var onScroll: (CGFloat, CGFloat?) -> Void
    var onGrow: () -> Void
    /// Рост содержимого — синхронно, из самого уведомления (в отличие от `onGrow`, которое виды откладывают).
    var onGrowNow: () -> Void = {}
    /// Ввод владельца, который ленту листает (колесо, трекпад, перетаскивание, клавиши; не щелчок), — синхронно, из
    /// монитора событий, раньше сдвига, который он вызовет.
    var onUserInput: () -> Void = {}
    /// Живая прокрутка AppKit началась (`true`) или кончилась: трекпад с инерцией, ползунок в руке.
    var onLiveScroll: (Bool) -> Void = { _ in }
    var onFound: (NSScrollView) -> Void

    @MainActor final class Coordinator: UserInputTarget {
        var observers: [NSObjectProtocol] = []
        var onScroll: (CGFloat, CGFloat?) -> Void = { _, _ in }
        var onGrow: () -> Void = {}
        var onGrowNow: () -> Void = {}
        var onUserInput: () -> Void = {}
        var onLiveScroll: (Bool) -> Void = { _ in }
        var onFound: (NSScrollView) -> Void = { _ in }
        /// Живая прокрутка идёт: снятое наблюдение её завершает, иначе лента считала бы, что владелец листает всегда.
        var live = false
        /// Когда живая прокрутка последний раз двигала ленту: без сдвигов дольше `ThreadFollow.liveScrollStale` она
        /// считается законченной, даже если её конец не пришёл.
        var liveMoved = Date.distantPast
        var liveActive: Bool { live && Date().timeIntervalSince(liveMoved) < ThreadFollow.liveScrollStale }
        weak var scroll: NSScrollView?
        weak var doc: NSView?
        var lastHeight: CGFloat = 0
        var lastDistance: CGFloat?
        var settle: DispatchWorkItem?
        var lastGrowth = Date.distantPast
        /// Последний ввод владельца в эту ленту: колесо и тачпад (с инерцией), перетаскивание ползунка, клавиши навигации.
        var lastUserInput = Date.distantPast

        /// Наблюдение за окном прокрутки и видом документа. Повторный вызов с теми же ничего не делает; с другими —
        /// снимает прежние наблюдатели и ставит новые, затем оценивает положение как после роста.
        func attach(_ scroll: NSScrollView?) {
            guard let scroll, let doc = scroll.documentView else { return }
            if scroll === self.scroll, doc === self.doc { return }
            stop()
            self.scroll = scroll
            self.doc = doc
            watchUserInput(scroll)
            onFound(scroll)
            scroll.contentView.postsBoundsChangedNotifications = true
            doc.postsFrameChangedNotifications = true
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bounds() }
            })
            observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.grew() }
            })
            observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveScroll(true) }
            })
            observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveScroll(false) }
            })
            // Стартовый замер положение не решает: лента ещё не встала на конец (якорь внизу применяется после
            // раскладки), расстояние в этот момент большое. Как рост: прижаться к концу и оценить после успокоения.
            grew()
        }

        func detach() {
            stop()
            scroll = nil
            doc = nil
        }

        func stop() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if live { liveScroll(false) }
            settle?.cancel()
            UserInputMonitor.shared.unregister(self)
        }

        /// Ввод владельца в эту ленту отмечается, чтобы сдвиг после него никогда не считался раскладкой. Монитор событий
        /// один на приложение (`UserInputMonitor`), ленты в нём регистрируются.
        @MainActor func watchUserInput(_ scroll: NSScrollView) {
            UserInputMonitor.shared.register(self)
        }

        func liveScroll(_ active: Bool) {
            if active != live { UserInputClock.liveScrolls += active ? 1 : -1 }
            live = active
            if active {
                lastUserInput = Date()
                liveMoved = Date()
                UserInputClock.last = Date()
                UserInputClock.liveMoved = Date()
            }
            onLiveScroll(active)
        }

        /// Любой ввод (и щелчок) отмечается для оценки сдвига (`isLayoutShift`); ленте — только листающий.
        func markUserInput(scrolling: Bool) {
            lastUserInput = Date()
            UserInputClock.last = Date()
            if scrolling { onUserInput() }
        }

        @MainActor func measure() -> (height: CGFloat, distance: CGFloat)? {
            guard let scroll, let doc = scroll.documentView else { return nil }
            if Diag.on {
                Diag.set("docH", doc.frame.height)
                Diag.set("dist", doc.frame.height - scroll.contentView.bounds.maxY)
                Diag.set("vis", scroll.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true ? 1 : 0)
            }
            return (doc.frame.height, doc.frame.height - scroll.contentView.bounds.maxY)
        }

        /// Сдвиг границ. Высота сменилась — это рост, положение не оценивается.
        @MainActor func bounds() {
            guard let m = measure() else { return }
            if live { liveMoved = Date(); UserInputClock.liveMoved = Date() }
            // Живая прокрутка — владелец листает, сколько бы она ни шла (ползунок в руке дольше окна ввода).
            let userMoved = liveActive || Date().timeIntervalSince(lastUserInput) < ThreadFollow.userInputWindow
            if m.height != lastHeight {
                // Ленивая лента уточняет высоту прямо во время прокрутки владельца: при недавнем вводе положение всё равно
                // оценивается, иначе жест вверх, совпавший с пересчётом высоты, не снял бы следование. Прежнее расстояние
                // пересчитывается на новую высоту: сравнивается только сдвиг владельца, а выросшее ниже окна за его шаг
                // вверх не считается.
                let grown = m.height - lastHeight
                lastHeight = m.height
                if !userMoved { lastDistance = m.distance; return }
                lastDistance = lastDistance.map { $0 + grown }
            }
            let previous = lastDistance
            lastDistance = m.distance
            // Сразу после роста SwiftUI сам переставляет границы (якорь, подгрузка сверху): сдвиг прочь от конца
            // в этот момент — раскладка, а не владелец. Лента потом снова просится к концу.
            let now = Date()
            if let previous, ThreadFollow.isLayoutShift(distance: m.distance, previous: previous,
                                                        sinceGrowth: now.timeIntervalSince(lastGrowth),
                                                        sinceUserInput: liveActive ? 0 : now.timeIntervalSince(lastUserInput)) { return }
            onScroll(m.distance, previous)
        }

        @MainActor func grew() {
            Diag.inc("probe.grew")
            guard let m = measure() else { return }
            lastHeight = m.height
            lastDistance = m.distance
            lastGrowth = Date()
            onGrowNow()
            onGrow()
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let m = self.measure() else { return }
                    self.lastHeight = m.height
                    self.lastDistance = m.distance
                    self.onScroll(m.distance, m.distance + 0)   // не дальше прежнего: следование не снимается
                    self.onGrow()
                }
            }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let c = context.coordinator
        c.onFound = onFound
        let v = ProbeView()
        // Привязка к окну прокрутки — когда вид встал в окно, а не один раз сразу после создания: ленивая лента
        // вставляет фон позже, и проба, не нашедшая окна прокрутки, оставалась бы без наблюдения навсегда (лента
        // после открытия не шла к концу). Сменившееся окно прокрутки или вид документа привязываются заново.
        v.onMove = { [weak v] in
            MainActor.assumeIsolated {
                // Вид ушёл из окна (экран разбирается): наблюдение снимается сразу, чтобы изменения размеров при разборке
                // не дошли до ленты как прокрутка и не вернули её к концу.
                if v?.window == nil { c.detach() } else { c.attach(v?.enclosingScrollView) }
            }
        }
        DispatchQueue.main.async { [weak v] in
            MainActor.assumeIsolated { c.attach(v?.enclosingScrollView) }
        }
        return v
    }

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.stop() }
    }

    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onGrow = onGrow
        context.coordinator.onGrowNow = onGrowNow
        context.coordinator.onUserInput = onUserInput
        context.coordinator.onLiveScroll = onLiveScroll
        context.coordinator.onFound = onFound
        context.coordinator.attach(v.enclosingScrollView)
    }
}

/// Фон ленты, который сообщает, что встал в окно или сменил родителя: по этим событиям проба находит окно прокрутки.
final class ProbeView: NSView {
    var onMove: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMove?()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onMove?()
    }
}

/// Кто есть кто в команде: адрес сессии → имя и цвет роли. Сообщения команды показываются именами и цветами ролей.
struct TeamPeers {
    var agentName: String
    var agentColor: Color
    private var byAddr: [String: (name: String, color: Color)] = [:]

    @MainActor
    init(project: ProjectModel, agent: Agent) {
        agentName = ProjectModel.pretty(agent.name)
        agentColor = roleColor(agent.role, in: project, agentArea: true)
        for a in project.status?.agents ?? [] {
            if let addr = a.addr { byAddr[addr] = (ProjectModel.pretty(a.name), roleColor(a.role, in: project, agentArea: true)) }
        }
    }

    func name(_ addr: String) -> String { byAddr[addr]?.name ?? addr }
    /// Неизвестный адрес (сессия вне команды) — нейтральный цвет сообщений.
    func color(_ addr: String) -> Color { byAddr[addr]?.color ?? A.cyan }
}

/// Элемент ленты агента.
struct ThreadRow: View {
    var item: ThreadItem
    var peers: TeamPeers
    var dense = false

    var body: some View {
        switch item {
        case let .input(e, text):
            TeamMessage(arrow: "arrow.left", title: "ввод в панель", time: e.time, text: text, color: A.muted, lines: dense ? 2 : 3, dense: dense)
        case let .incoming(e, from, addr, text):
            TeamMessage(arrow: "arrow.left", title: "\(from.isEmpty ? peers.name(addr) : from) → \(peers.agentName)", time: e.time,
                        text: text, color: peers.color(addr), lines: dense ? 3 : 6, dense: dense)
        case let .send(e, to, text):
            TeamMessage(arrow: "arrow.right", title: "\(peers.agentName) → \(peers.name(to))", time: e.time,
                        text: text, color: peers.color(to), lines: dense ? 2 : 3, dense: dense)
        case let .actions(_, lines):
            VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
                ForEach(lines) { l in actionLine(l) }
            }
            .padding(.leading, 12).padding(.vertical, ChatFont.gap(2))
            .overlay(alignment: .leading) { Rectangle().fill(A.line).frame(width: 2) }
        case let .reply(_, text, showWho):
            VStack(alignment: .leading, spacing: ChatFont.gap(12)) {
                if showWho { Text(peers.agentName).font(A.mono(11)).foregroundStyle(peers.agentColor) }
                MarkdownView(text: text, size: dense ? 12 : nil, area: .agent)
            }
        case let .turnEnd(e, ms):
            Text("\(duration(ms: ms)) · \(clock(e.time))").font(A.mono(11)).foregroundStyle(A.faint)
        case let .compacted(e):
            CompactDivider(time: e.time)
        case let .command(e, name, text):
            // Вывод встроенной команды Claude Code (/context, /agents): как в терминале, моноширинно.
            VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
                Text("\(name) · \(clock(e.time))").font(A.mono(11)).foregroundStyle(A.dim)
                Text(text).font(A.mono(dense ? 11 : 12)).foregroundStyle(A.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.leading, 12).padding(.vertical, ChatFont.gap(2))
            .overlay(alignment: .leading) { Rectangle().fill(A.line).frame(width: 2) }
        case let .commandCall(e, line):
            // Вызов скилла или команды плагина: одна строка, ответ модели идёт следом.
            Text("\(line) · \(clock(e.time))").font(A.mono(dense ? 11 : 12)).foregroundStyle(A.dim).lineLimit(2).textSelection(.enabled)
                .padding(.leading, 12).padding(.vertical, ChatFont.gap(2))
                .overlay(alignment: .leading) { Rectangle().fill(A.line).frame(width: 2) }
        }
    }

    private func actionLine(_ l: ThreadAction) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: l.kind == .tracker ? "checklist" : "chevron.right.2").font(.system(size: 11)).foregroundStyle(A.dim)
            Text(l.title).font(A.mono(12)).foregroundStyle(A.muted).lineLimit(2)
        }
    }
}

/// Сообщение команды: «← от кого» или «→ кому» в цвете роли собеседника, текст свёрнут до нескольких строк.
struct TeamMessage: View {
    var arrow: String
    var title: String
    var time: Date?
    var text: String
    var color: Color
    var lines: Int
    var dense = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
            HStack(spacing: 8) {
                Image(systemName: arrow).font(.system(size: 11)).foregroundStyle(color)
                Text(title).font(A.mono(12)).foregroundStyle(color).lineLimit(1)
                Text(clock(time)).font(A.mono(11)).foregroundStyle(A.dim)
                Spacer()
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "свернуть" : "развернуть").font(A.text(12))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                    }
                    .foregroundStyle(A.muted)
                }
                .buttonStyle(.plain)
            }
            Text(text).font(A.text(dense ? 12 : 13)).foregroundStyle(A.ink.opacity(0.85)).lineSpacing(dense ? 2 : 4)
                .lineLimit(expanded ? nil : lines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, dense ? 10 : 14).padding(.vertical, ChatFont.gap(dense ? 7 : 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
    }
}

/// Короткая заметка вместо пустого экрана в плотной ленте панели.
struct DenseNote: View {
    var text: String
    var body: some View {
        Text(text).font(A.mono(11)).foregroundStyle(A.dim)
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
