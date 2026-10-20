import AgentTeamCore
import AppKit
import SwiftUI

/// Шапка чата: менеджер, модель, контекст, состояние хода.
struct ChatHeader: View {
    @Bindable var project: ProjectModel

    var body: some View {
        HStack(spacing: 10) {
            Swatch(color: C.accent)
            Text(project.managerRole).font(C.mono(13, .semibold)).foregroundStyle(C.accent)
            Text(Self.metaText(project)).font(C.mono(11)).foregroundStyle(C.dim).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            pinsButton
            ManagerBadge(project: project)
        }
    }

    /// «К закреплённому · N»: одна запись — сразу к ней, несколько — список отрывков.
    @ViewBuilder private var pinsButton: some View {
        if let only = project.pins.first, project.pins.count == 1 {
            Button { project.requestJump(to: only.id) } label: { pinsLabel }
                .buttonStyle(.plain).help(only.excerpt)
        } else if !project.pins.isEmpty {
            Menu {
                ForEach(project.pins) { p in
                    Button((p.time.map { clock($0) + " · " } ?? "") + p.excerpt) { project.requestJump(to: p.id) }
                }
            } label: { pinsLabel }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private var pinsLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "pin.fill").font(.system(size: 10))
            Text("К закреплённому · \(project.pins.count)").font(C.text(12))
        }
        .foregroundStyle(C.accent)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(Rectangle().stroke(C.line, lineWidth: 1))
        .contentShape(Rectangle())
    }

    /// «ведущая сессия · Opus 5.5 · контекст 18%» — и для шапки чата, и для полосы режима «Менеджер».
    static func metaText(_ project: ProjectModel) -> String {
        var parts = ["ведущая сессия"]
        if let u = project.usage {
            parts.append(u.displayModel)
            parts.append("контекст \(u.contextPercent)%")
        }
        return parts.joined(separator: " · ")
    }

}

/// Состояние менеджера: «не запущен», «в работе», «свободен».
struct ManagerBadge: View {
    let project: ProjectModel

    var body: some View {
        if let m = project.status?.manager {
            if !m.alive {
                StatusBadge(text: "не запущен", color: C.dim)
            } else if project.managerBusy {
                StatusBadge(text: "в работе", color: C.accent)
            } else {
                // По транскрипту: ход закончен, менеджер ждёт следующего сообщения. Это не решение владельца.
                StatusBadge(text: "свободен", color: C.muted)
            }
        }
    }
}

struct ChatPanel: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    var wide = false
    @State var draft = ""
    /// Строка Claude Code вместо своего поля: живая нижняя часть панели менеджера (настройка «Поле ввода менеджеру»).
    private var live: Bool { DisplayModel.shared.liveInputOn }
    /// Запись в панель менеджера — через очередь проекта (`ManagerOutbox`).
    private var sending: Bool { project.outbox.sending }
    private var sendError: String? { project.outbox.error }
    /// Группировка ленты считается только при смене записей, набора показа или состава команды.
    @State private var feedCache = KeyedCache<[ManagerFeedItem]>()
    /// Группировка по отрезкам ленты: на новое в конце пересчитывается только последний отрезок.
    @State var managerFeed = ManagerFeedCache()
    /// Вся сессия менеджера страницами: открывается с конца, ранние страницы подгружаются при подходе к верху.
    /// Модель живёт в проекте и засыпает вместе с ним; вид её только показывает.
    var thread: AgentThreadModel { project.managerThread }
    /// Стенд пустот ленты (`ChatPanel+GapBench.swift`): подставной экран менеджера и признак, что стенд идёт в этой панели
    /// (панель чата одна на оба режима, но у каждого открытого проекта своя; стенд — в панели выбранного).
    @State var benchScreen: LiveReply?
    @State var gapBenchActive = false
    /// Прокрутка ленты: следование за концом, подгрузка начала с закреплением видимой строки — общая с «Диалогом».
    /// Хранится по проекту, а не в виде: чат, построенный заново после экрана агента или другого раздела, возвращается
    /// на прежнее место.
    var scroller: FeedScroller { FeedScroller.remembered(FeedScroller.chatKey(session: project.session)) }
    var follow: ThreadFollow {
        get { scroller.follow }
        nonmutating set { scroller.follow = newValue }
    }
    var viewH: CGFloat { scroller.viewH }
    var chatScroll: NSScrollView? { scroller.scroll }
    /// Владелец отправил сообщение из поля: лента встаёт на конец (`send()` вне `ScrollViewReader`, прокрутка — по счётчику).
    @State var ownSendJump = 0
    /// Чьё поле принимает не ушедшее сообщение (`returnFailed`).
    @State private var failureToken = UUID()
    @State private var composerHeight: CGFloat = 20
    @State private var subscribedPane: String?
    /// Черновик «пишет…» с экрана панели менеджера — от `ManagerScreenReader`. Его читает только хвост ленты
    /// (`ManagerFeedTail`): сам чат строки экрана не читает и на каждый захват панели не пересчитывается.
    @State private var liveDraft = LiveDraft()
    /// Подсказки поля ввода: команды по «/», файлы по «@»; история ввода по ↑.
    @State private var suggest = ComposerSuggest()
    @State private var history = InputHistory()
    @State private var cursorRequest: Int?
    @State private var chatSize = CGSize(width: 600, height: 900)

    /// В панели менеджера открыт экран встроенной команды Claude Code (`/mcp`, `/config`…), кто бы его ни открыл (поле
    /// приложения, терминал): признак с каждого захвата панели (`PaneOutput.commandScreen`).
    private var commandScreenOpen: Bool { managerPane.map { app.hub.output(for: $0).commandScreen } ?? false }

    var body: some View {
        // Строка Claude Code выключена, а экран команды открыт — он показывается сам на месте поля, клавиши идут в панель;
        // Esc закрывает экран, и поле возвращается.
        // В панели менеджера не сессия роли: строки Claude Code и экрана команды нет — клавиши ушли бы разговору без роли;
        // на их месте поле, отправка из него стоит (`ManagerOutbox`).
        let notRole = project.managerNotRole
        let command = !live && commandScreenOpen && !notRole
        VStack(spacing: 0) {
            feed
            if !live || notRole, !command, let pane = managerPane { ManagerWaitingStrip(hub: app.hub, session: project.session, pane: pane) }
            ForEach(project.notRoleAgents) { a in RoleAlertBanner(project: project, agent: a, colors: .chat) }
            if (live && !notRole) || command, let pane = managerPane {
                // Фокус — только если часть открыта действием владельца: строка Claude Code включена им или он только что
                // отправил команду из поля. Экран, открытый очередью или из терминала, набираемое не перехватывает.
                LiveInputPanel(hub: app.hub, pane: pane, available: chatSize, questions: project.managerQuestions,
                               onFallback: command ? nil : { DisplayModel.shared.settings.liveInput = false },
                               takesFocus: !command || project.outbox.fieldCommandWrittenAt.map { Date().timeIntervalSince($0) < 10 } == true)
            } else {
                // Список подсказок «/» открывается над всей группой (подсказка, полоса, поле), не закрывая кнопки.
                VStack(spacing: 0) {
                    if let cmd = ClaudeOwnMenus.command(in: draft), let pane = managerPane { ownMenuHint(cmd, pane: pane) }
                    composer
                }
                .overlay(alignment: .top) { suggestOverlay }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { chatSize = $0 }
        .background {
            if let pane = watchedPane {
                ManagerScreenReader(hub: app.hub, pane: pane, busy: project.managerBusy, draft: liveDraft)
            }
        }
        .onAppear {
            draft = project.draft
            returnFailed(register: true)
            reloadHistory()
            // Для снимка (`AGENT_TEAM_DRAFT="/co"`): черновик подставляется, список подсказок открывается.
            if let d = ProbeFlags.draft {
                draft = d
                suggest.configure(root: project.repo)
                suggest.update(text: d, cursor: (d as NSString).length)
            }
        }
        .task(id: project.status?.manager?.sessionID ?? "") {
            scroller.sessionChanged(to: project.status?.manager?.sessionID) { thread.follows(sessionID: $0) }
        }
        .task { await runChatBench() }
        .task { await runReadBench() }
        .task { await runHistoryBench() }
        .task { await runGapBench() }
        .task { await runStayBench() }
        .task {
            // Для проверки: через N секунд нажимается та же кнопка, что у владельца (`AGENT_TEAM_TOGGLE_LIVE_AFTER=3`).
            guard let n = ProbeFlags.toggleLiveAfter else { return }
            try? await Task.sleep(nanoseconds: UInt64(n * 1_000_000_000))
            DisplayModel.shared.settings.liveInput = true
        }
        .onChange(of: project.chat.count) { _, _ in reloadHistory() }
        // Конец хода и записи транскрипта двигают очередь сами (в проекте); возврат к полю приложения — здесь.
        .onChange(of: live) { _, on in if !on { project.outbox.flush() } }
        .onChange(of: project.outbox.sentTexts.count) { _, _ in reloadHistory() }
        .onChange(of: benchScreen) { _, new in if Self.gapBenchOn { liveDraft.screen = new } }
        .onChange(of: watchedPane, initial: true) { old, new in
            if let old, old == subscribedPane { app.hub.hide(old, detail: .grid); subscribedPane = nil }
            if let new, subscribedPane == nil { app.hub.show(new, detail: .grid); subscribedPane = new }
        }
        .onDisappear {
            if let p = subscribedPane { app.hub.hide(p, detail: .grid); subscribedPane = nil }
            returnFailed(register: false)
        }
    }

    /// Лента из страниц транскрипта менеджера; в замере с подменой чата — синтетическая, без подгрузки начала.
    private var useThread: Bool { !project.chatFrozen }

    /// Список подсказок: рамка нулевой высоты у верхнего края группы над полем, содержимое растёт вверх.
    @ViewBuilder private var suggestOverlay: some View {
        if suggest.isOpen {
            SuggestList(suggest: suggest) { index in
                suggest.selected = index
                acceptSuggestion()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: 0, alignment: .bottom)
            .offset(y: -6)
        }
    }

    /// Команда с собственным меню Claude Code: в поле приложения его нет, одна кнопка переключает на строку Claude Code
    /// и переносит набранную команду туда (Enter нажимает владелец).
    private func ownMenuHint(_ cmd: String, pane: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(C.accent)
            Text("Команда /\(cmd) работает в строке Claude Code: у неё там своё меню.")
                .font(C.text(13)).foregroundStyle(C.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Открыть в строке Claude Code") {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                DisplayModel.shared.settings.liveInput = true
                draft = ""
                project.draft = ""
                project.outbox.typeIntoLine(text)
            }
            .buttonStyle(AppButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.surface)
        .overlay(alignment: .top) { Rectangle().fill(C.accent).frame(height: 1) }
    }


    /// Панель менеджера подписана, пока он в ходе и проект на экране: в простое захваты не нужны.
    private var watchedPane: String? {
        guard project.active, let pane = managerPane else { return nil }
        return project.managerBusy || app.hub.output(for: pane).needsHuman ? pane : nil
    }

    /// Черновик, который лента показывает сейчас (стенды).
    var liveReply: LiveReply? { liveDraft.shown(feed: project.chat, key: "\(project.chatRevision)") }

    private var feed: some View {
        let vis = DisplayModel.shared.settings.feedManager
        // Тяжёлая группировка — по ключу; хвост (черновик «пишет…», очередь) — отдельной секцией после неё.
        let agentsKey = (project.status?.agents ?? []).map { ($0.addr ?? "") + $0.name }.joined(separator: ",") + "|" + (project.status?.manager?.role ?? "")
        let source = project.chatRevision
        let peers = FeedPeers(agents: project.status?.agents ?? [], managerRole: project.managerRole)
        let base = feedCache.value(key: "\(source)|\(vis.key)|\(agentsKey)") {
            FeedGrouping.visible(managerFeed.items(project.chatSegments, peers: peers), vis)
        }
        let items = base
        let _ = Diag.on ? (Diag.inc("body"), Diag.set("rows", Double(items.count))) : ((), ())
        return ScrollViewReader { proxy in
            ScrollView {
                // Ленивая лента: рисуются только видимые строки, сотни ходов не строятся при открытии.
                LazyVStack(alignment: .leading, spacing: ChatFont.gap(16)) {
                    // Верх ленты: «раньше…» при подгрузке или «начало сессии». Сам маркер — триггер подгрузки: он работает и тогда,
                    // когда лента короче окна и прокручивать нечего.
                    ZStack {
                        if useThread, thread.hasEarlier {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("раньше…").font(C.mono(11)).foregroundStyle(C.dim)
                            }
                        } else if useThread, !items.isEmpty {
                            Text("начало сессии").font(C.mono(11)).foregroundStyle(C.faint)
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .onGeometryChange(for: Bool.self) { $0.frame(in: .named("chat")).maxY > -FeedScroller.prefetchDistance } action: { _ in
                        scroller.startEarlier(model: useThread ? thread : nil, firstID: items.first?.id)
                    }
                    if items.isEmpty, project.pending.isEmpty, !liveDraft.active { emptyFeed }
                    ForEach(items) { item in
                        feedRow(item)
                    }
                    ManagerFeedTail(draft: liveDraft, entries: project.chat, feedKey: "\(source)", owners: FeedGrouping.owners(items),
                                    pending: project.pending, showsDraft: vis.draft, baseIDs: gapBenchActive ? items.map(\.id) : nil) { item in
                        feedRow(item)
                    }
                    // Строка хода — только в ходе менеджера: вне хода панель не подписана, и последний захват со строкой хода
                    // устарел бы.
                    if !live, vis.turnStatus, project.managerBusy, let pane = managerPane {
                        TurnStatusRow(hub: app.hub, pane: pane, colors: .chat, subscribes: false).modifier(BenchFrame(key: "~turn", on: gapBenchActive))
                    }
                    // Фоновые субагенты менеджера — в ленте под строкой хода: появляясь, полоса растит ленту, а не сжимает
                    // окно прокрутки (сжатие без ввода владельца сбивало бы следование за концом). У скрытого проекта опроса нет.
                    SubagentStrip(project: project, sessionID: project.active ? project.status?.manager?.sessionID ?? thread.sessionID : nil,
                                  cwd: project.status?.manager?.cwd, colors: .chat)
                    Color.clear.frame(height: 1).id("bottom").modifier(BenchFrame(key: "~bottom", on: gapBenchActive))
                        // Метка «лента нарисована» — фоном нижней строки: отдельная строка нулевой высоты добавляла бы лишний
                        // межзаписный интервал между хвостом ленты и строкой хода.
                        .background {
                            if !items.isEmpty { Color.clear.onAppear { SwitchClock.shared.mark("chat", project.session) } }
                        }
                }
                .coordinateSpace(name: "chatDoc")
                .padding(.horizontal, wide ? 20 : 20).padding(.vertical, wide ? 14 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollProbe(
                    onScroll: { d, previous in
                        DispatchQueue.main.async {
                            scroller.scrolled(distance: d, previous: previous, model: useThread ? thread : nil, firstID: items.first?.id)
                        }
                    },
                    onGrow: {
                        Diag.inc("grew")
                        DispatchQueue.main.async {
                            scroller.grew(proxy: proxy, bottomID: "bottom", model: useThread ? thread : nil, firstID: items.first?.id)
                        }
                    },
                    onGrowNow: { scroller.contentGrewNow(model: useThread ? thread : nil) },
                    onUserInput: { scroller.ownerInput() },
                    onLiveScroll: { scroller.liveScroll($0) },
                    onFound: { scroller.attached($0); scroller.endInset = wide ? 14 : 20 }))
            }
            .coordinateSpace(name: "chat")
            .background(GeometryReader { g in Color.clear.onAppear { scroller.viewH = g.size.height }.onChange(of: g.size.height) { _, h in scroller.viewH = h } })
            .onChange(of: thread.prependRevision) { _, _ in
                guard useThread else { return }
                scroller.pagePrepended(proxy: proxy, bottomID: "bottom", model: thread, ids: items.map(\.id))
            }
            .overlay(alignment: .top) {
                // Лента длиннее окна: у верхнего края затемнение.
                if scroller.scrolledFromTop {
                    LinearGradient(colors: [wide ? C.bg : C.side, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 72).allowsHitTesting(false)
                }
            }
            // Читавший выше конца возвращается на своё место; следовавший за концом и открывший впервые — на конец.
            .onAppear { scroller.appeared(proxy: proxy, ids: items.map(\.id), bottomID: "bottom", toEndOtherwise: true) }
            .onChange(of: project.chat.last?.id) { _, _ in
                // Новые записи внизу показываются сами, если владелец внизу; читающего выше не уводит, а копит под «Новые ↓».
                scroller.arrived(proxy: proxy, bottomID: "bottom", model: useThread ? thread : nil)
            }
            .onAppear {
                // Растущий черновик ответа тянет ленту за собой, пока владелец внизу и не листает сам. После кадра с новым
                // текстом: черновик растёт раньше, чем хвост ленты его покажет.
                liveDraft.onGrew = { DispatchQueue.main.async { Diag.inc("liveScroll"); scroller.draftGrew() } }
            }
            .onChange(of: project.pinJump) { _, jump in
                guard let jump else { return }
                project.pinJump = nil
                // Лента ленивая и содержит всё загруженное: запись есть среди элементов — прокрутка к ней сама реализует строки.
                // Записи нет в загруженной части (старше подгруженных страниц) — страницы подгружаются до неё.
                if items.contains(where: { $0.id == jump.id }) { scrollToPin(jump.id, proxy: proxy); return }
                guard useThread else {
                    project.report("Закреплённой записи нет в этой сессии")
                    return
                }
                // Следование снимается сразу: иначе страницы, встающие сверху, вернули бы ленту к концу.
                follow.scrolled(distanceFromBottom: 1_000_000)
                Task { @MainActor in
                    let ok = await thread.loadEarlier(until: jump.id)
                    if ok {
                        // Страница встала сверху и перестроила ленту: даём ей отрисоваться и прокручиваем к записи,
                        // затем ещё раз, когда возврат прокрутки после подгрузки уже отработал.
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        scrollToPin(jump.id, proxy: proxy)
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        scrollToPin(jump.id, proxy: proxy)
                    } else {
                        project.report("Закреплённой записи нет в этой сессии")
                    }
                }
            }
            .onChange(of: project.pending.count) { old, n in scroller.pendingChanged(from: old, to: n, proxy: proxy, bottomID: "bottom") }
            .onChange(of: ownSendJump) { _, _ in scroller.ownMessageSent(proxy: proxy, bottomID: "bottom") }
            .overlay(alignment: .bottom) {
                if follow.unseen {
                    Button {
                        scroller.jumpToEnd(proxy: proxy, bottomID: "bottom")
                    } label: {
                        Text("Новые ↓").font(C.text(13, .medium)).foregroundStyle(C.bg)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(C.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
        }
        // Смена интервала чата или показа элементов резко меняет высоты: ленивая лента пересоздаётся и заново встаёт на конец.
        .id("\(Int(ChatFont.spacing * 100))|\(vis.key)")
    }

    /// Строка ленты; в замере истории дополнительно сообщает своё положение в окне.
    @ViewBuilder private func feedRow(_ item: ManagerFeedItem) -> some View {
        row(item).id(item.id)
            .modifier(FeedRowPosition(id: item.id, scroller: scroller, space: "chat"))
            .modifier(BenchFrame(key: item.id, on: gapBenchActive))
    }

    private func scrollToPin(_ id: String, proxy: ScrollViewProxy) {
        // Переход — намерение читать: следование за концом снимается, события внизу не вернут ленту к концу.
        follow.scrolled(distanceFromBottom: 1_000_000)
        DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) } }
    }

    private var emptyFeed: some View {
        VStack(alignment: .leading, spacing: 6) {
            if project.status?.manager?.sessionID == nil {
                Text("Менеджер не запущен").font(C.text(14, .medium)).foregroundStyle(C.muted)
                Text("Чат появится, когда поднимется сессия менеджера (team up).").font(C.text(13)).foregroundStyle(C.dim)
            } else {
                Text("Диалог пока пуст").font(C.text(14, .medium)).foregroundStyle(C.muted)
                Text("Транскрипт сессии менеджера ещё не записан или не найден.").font(C.text(13)).foregroundStyle(C.dim)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ManagerFeedItem) -> some View {
        switch item {
        case let .owner(e, text):
            PinnableRow(project: project, entry: e, card: true) { pinned in
            VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
                Text("вы · \(clock(e.time))").font(C.mono(11)).foregroundStyle(C.dim)
                if !text.isEmpty {
                    Text(text).font(ChatFont.text(ChatFont.size)).foregroundStyle(C.ink).lineSpacing(ChatFont.spacing)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !e.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(e.images) { img in ImageThumb(key: img.id, base64: img.base64, app: app) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, ChatFont.gap(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pinned ? C.pin : C.surface)
            }
        case let .live(r):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(project.managerRole).font(C.mono(11)).foregroundStyle(C.accent)
                    Text("пишет…").font(C.mono(11)).foregroundStyle(C.amber)
                }
                Text((r.startCut ? "… " : "") + r.text).font(ChatFont.text(ChatFont.size)).foregroundStyle(C.ink)
                    .lineSpacing(ChatFont.spacing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        case let .queued(p):
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 10)) { ctx in
                    let lost = p.isUndelivered(now: ctx.date)
                    let asks = managerPane.map { app.hub.output(for: $0).asksPermission } ?? false
                    HStack(spacing: 8) {
                        Text("вы · \(clock(p.sentAt))").font(C.mono(11)).foregroundStyle(C.dim)
                        Text(lost ? "не дошло" : p.held ? (p.stopped ? "остановлено" : "в очереди" + (project.outbox.holdReason(p).map { " · " + $0 } ?? "")) : "отправлено")
                            .font(C.mono(11)).foregroundStyle(lost ? C.rose : p.held ? (p.stopped ? C.rose : C.amber) : C.dim)
                        Spacer(minLength: 8)
                        if p.held {
                            if !asks, !project.managerWriteHeld {
                                queueButton("↑ сейчас", help: "Прервать ход и отправить это сообщение", color: C.accent) { project.outbox.sendNow(p.id) }
                            }
                            queueButton("✎ изменить", help: "Вернуть в поле и убрать из очереди", color: C.muted) { edit(p) }
                            queueButton("× убрать", help: "Удалить из очереди", color: C.muted) { project.dropPending(p.id) }
                        } else if lost {
                            queueButton("Отправить ещё раз", help: "Повторить отправку", color: C.accent) { project.outbox.resend(p.id) }
                            queueButton("Убрать", help: "Убрать из ленты", color: C.muted) { project.dropPending(p.id) }
                        }
                    }
                }
                if !p.text.isEmpty {
                    Text(p.text).font(ChatFont.text(ChatFont.size)).foregroundStyle(C.ink).lineSpacing(ChatFont.spacing)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if !p.images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(p.images, id: \.self) { url in ImageThumb(key: url.lastPathComponent, url: url, app: app) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surface)
            .opacity(0.8)
        case let .actions(_, lines):
            VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
                ForEach(lines) { l in actionLine(l) }
            }
            .padding(.leading, 12).padding(.vertical, ChatFont.gap(2))
            .overlay(alignment: .leading) { Rectangle().fill(C.line).frame(width: 2) }
        case let .reply(e, text, showWho):
            PinnableRow(project: project, entry: e, card: false) { _ in
                VStack(alignment: .leading, spacing: ChatFont.gap(12)) {
                    if showWho { Text(project.managerRole).font(C.mono(11)).foregroundStyle(C.accent) }
                    MarkdownView(text: text, area: .chat)
                }
            }
        case let .incoming(e, from, to, text):
            PinnableRow(project: project, entry: e, card: true) { _ in
                IncomingCard(from: from, to: to, text: text, time: e.time)
            }
        case let .turnEnd(e, ms):
            Text("\(duration(ms: ms)) · \(clock(e.time))").font(C.mono(11)).foregroundStyle(C.faint)
        case let .compacted(e):
            CompactDivider(time: e.time)
        case let .command(e, name, text):
            // Вывод встроенной команды Claude Code (/context, /agents): как в терминале, моноширинно.
            VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
                Text("\(name) · \(clock(e.time))").font(C.mono(11)).foregroundStyle(C.dim)
                Text(text).font(C.mono(12)).foregroundStyle(C.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(.leading, 12).padding(.vertical, ChatFont.gap(2))
            .overlay(alignment: .leading) { Rectangle().fill(C.line).frame(width: 2) }
        case let .commandCall(e, line):
            // Вызов скилла или команды плагина: одна строка, ответ модели идёт следом.
            Text("\(line) · \(clock(e.time))").font(C.mono(12)).foregroundStyle(C.dim).lineLimit(2).textSelection(.enabled)
                .padding(.leading, 12).padding(.vertical, ChatFont.gap(2))
                .overlay(alignment: .leading) { Rectangle().fill(C.line).frame(width: 2) }
        }
    }

    private func actionLine(_ l: ManagerActionLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: l.kind == .send ? "paperplane" : l.kind == .tracker ? "checklist" : l.kind == .question ? "questionmark.circle" : "chevron.right.2")
                .font(.system(size: 11)).foregroundStyle(l.kind == .send ? C.cyan : C.dim)
            VStack(alignment: .leading, spacing: ChatFont.gap(3)) {
                Text(l.title).font(C.mono(12)).foregroundStyle(l.kind == .send ? C.cyan : C.muted).lineLimit(2)
                if let q = l.quote {
                    Text(q).font(C.text(13)).foregroundStyle(l.kind == .question ? C.muted : C.dim)
                        .lineLimit(l.kind == .question ? 8 : 2).lineSpacing(3)
                }
            }
        }
    }

    /// Панель менеджера по живому списку панелей tmux этой сессии, а не по кешу status.
    private var managerPane: String? { project.managerPaneID }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sendError {
                Text(sendError).font(C.mono(11)).foregroundStyle(C.rose)
            }
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    if !project.draftImages.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(project.draftImages, id: \.self) { url in
                                ImageThumb(key: url.lastPathComponent, url: url, side: 64, app: app) {
                                    project.draftImages.removeAll { $0 == url }
                                    try? FileManager.default.removeItem(at: url)
                                }
                            }
                        }
                        .padding(.top, 7)
                    }
                    ComposerField(text: $draft, height: $composerHeight,
                                  font: FontCatalog.nsFont(family: ChatFont.look.family, size: ChatFont.size, weight: .regular),
                                  lineHeight: ceil(ChatFont.size * 1.45), onSubmit: send,
                                  onEscape: stopOnEscape,
                                  onImages: { urls in project.draftImages.append(contentsOf: urls) },
                                  onEdit: { text, cursor in
                                      suggest.configure(root: project.repo)
                                      suggest.update(text: text, cursor: cursor)
                                  },
                                  onKey: handle,
                                  cursorRequest: $cursorRequest)
                        .frame(height: composerHeight)
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text(managerPane == nil ? "Менеджер не запущен"
                                     : project.managerNotRole ? "Отправка стоит: в панели менеджера не сессия роли"
                                     : project.draftImages.isEmpty ? "Сообщение менеджеру" : "Подпись к картинке")
                                    .font(ChatFont.text(ChatFont.size)).foregroundStyle(C.dim).allowsHitTesting(false)
                            }
                        }
                        .padding(.vertical, 7)
                }
                .onChange(of: draft) { _, v in project.draft = v }
                if let pane = managerPane {
                    // Значки рядом со стрелкой «Отправить»: «Стоп» (пока идёт ход) и переключатель на строку Claude Code.
                    if project.managerBusy { ComposerStopButton(hub: app.hub, pane: pane, outbox: project.outbox) }
                    if !project.managerNotRole {
                        ComposerIconButton(symbol: "terminal", help: "Строка Claude Code: меню «/» и «@», /rewind, диалоги, история по ↑") {
                            DisplayModel.shared.settings.liveInput = true
                        }
                    }
                }
                Button(action: send) {
                    Image(systemName: sending ? "ellipsis" : "arrow.up").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(C.onAccent).frame(width: 32, height: 32).background(canSend ? C.accent : C.faint)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 12)
            .background(C.surface)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url, Attachments.isImageFile(url), let saved = Attachments.add(file: url) else { return }
                        Task { @MainActor in project.draftImages.append(saved) }
                    }
                }
                return true
            }
        }
        .padding(.horizontal, wide ? 20 : 12).padding(.vertical, wide ? 10 : 8)
        .overlay(alignment: .top) { Rectangle().fill(C.line).frame(height: 1) }
    }

    /// Esc в пустом поле прерывает ход менеджера, как в терминале. Во время вопроса о праве или доверии Esc означал бы
    /// отказ, поэтому тогда он не отправляется: отвечает владелец.
    private func stopOnEscape() -> Bool {
        project.outbox.interrupt(requireTurn: true)
    }

    private func queueButton(_ title: String, help: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(C.text(12)).foregroundStyle(color) }
            .buttonStyle(.plain).help(help)
    }



    /// «✎ изменить»: сообщение возвращается в поле (перед тем, что уже набрано) и уходит из очереди.
    private func edit(_ p: PendingMessage) {
        guard let m = project.takeForEdit(p.id) else { return }
        draft = ProjectModel.draft(returning: m.text, before: draft)
        project.draftImages = m.images + project.draftImages
    }

    /// Не ушедшее сообщение возвращается в поле, пока поле на экране: перед набранным, как «✎ изменить». Обработчик
    /// задаёт поле на экране и снимает, уходя; без него очередь вернёт текст в сохранённый черновик проекта. Поле,
    /// построенное заново, может появиться раньше, чем уйдёт прежнее, поэтому снимает обработчик только тот, кто его задал.
    private func returnFailed(register on: Bool) {
        if on {
            Self.failureOwner[project.session] = failureToken
            project.outbox.onFailure = { text, images in
                draft = ProjectModel.draft(returning: text, before: draft)
                project.draftImages = images + project.draftImages
            }
        } else if Self.failureOwner[project.session] == failureToken {
            Self.failureOwner[project.session] = nil
            project.outbox.onFailure = nil
        }
    }
    private static var failureOwner: [String: UUID] = [:]

    private func acceptSuggestion() {
        guard let r = suggest.accept() else { return }
        draft = r.text
        cursorRequest = r.cursor
        suggest.update(text: r.text, cursor: r.cursor)
        history.reset()
    }

    /// Клавиши поля: список подсказок берёт ↑↓, Tab, Enter и Esc, пока открыт; иначе ↑↓ листают историю ввода.
    /// Esc в пустом поле не перехватывается.
    private func handle(_ key: ComposerKey) -> Bool {
        switch key {
        case .up:
            if suggest.isOpen { suggest.move(-1); return true }
            guard let t = history.up(current: draft) else { return false }
            draft = t
            cursorRequest = (t as NSString).length
            return true
        case .down:
            if suggest.isOpen { suggest.move(1); return true }
            guard let t = history.down(current: draft) else { return false }
            draft = t
            cursorRequest = (t as NSString).length
            return true
        case .tab:
            guard suggest.isOpen else { return false }
            acceptSuggestion()
            return true
        case .enter:
            // «/команда» набрана целиком — Enter отправляет её; иначе подставляется выбранное.
            guard suggest.isOpen, !suggest.typedExactCommand else { return false }
            acceptSuggestion()
            return true
        case .escape:
            guard suggest.isOpen else { return false }
            suggest.dismiss()
            return true
        }
    }

    private func reloadHistory() {
        let owners = project.chat.compactMap { e -> String? in
            if case let .owner(t) = e.kind { return t }
            return nil
        }
        // Множеством: проверка каждого отправленного по всем записям владельца шла бы по всему чату на каждое.
        let seen = Set(owners)
        let fresh = project.outbox.sentTexts.filter { !seen.contains($0) }
        history.reload(owners + fresh)
    }

    private var canSend: Bool {
        !sending && managerPane != nil && !project.managerNotRole
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !project.draftImages.isEmpty)
    }

    /// Сообщение владельца уходит через очередь проекта: сразу в ленте с отметкой, поле очищается. В ходе менеджера,
    /// пока прежнее не в транскрипте, или при строке Claude Code — ждёт своей очереди. Не ушло — текст возвращается в поле
    /// перед набранным (`returnFailed`).
    private func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = project.draftImages
        guard project.outbox.send(text: text, images: images, fromField: true) else { return }
        // Команда Claude Code может открыть свой экран: панель захватывается вскоре после отправки, не дожидаясь отметки
        // активности (она приходит не чаще раза в секунду, а захват по ней — не чаще раза в 3 с).
        if PendingMessage.looksLikeCommand(text, images: images), let pane = managerPane {
            for delay in [0.6, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { app.hub.captureNow(pane) } }
        }
        ownSendJump += 1
        draft = ""
        project.draft = ""
        project.draftImages = []
        history.reset()
        suggest.update(text: "", cursor: 0)
    }
}

/// Входящее сообщение агента: свёрнутая карточка с «развернуть».
struct IncomingCard: View {
    var from: String
    var to: String
    var text: String
    var time: Date?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left").font(.system(size: 11)).foregroundStyle(C.cyan)
                Text("\(from) → \(to)").font(C.mono(12)).foregroundStyle(C.cyan).lineLimit(1)
                Text(clock(time)).font(C.mono(11)).foregroundStyle(C.dim)
                Spacer()
                Button { expanded.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "свернуть" : "развернуть").font(C.text(12))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 10))
                    }
                    .foregroundStyle(C.muted)
                }
                .buttonStyle(.plain)
            }
            Text(text).font(C.text(13)).foregroundStyle(C.muted).lineSpacing(4)
                .lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 14).padding(.vertical, ChatFont.gap(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(C.line, lineWidth: 1))
    }
}

/// Список подсказок над полем ввода: имя и описание, выбранная строка подсвечена; клик подставляет.
struct SuggestList: View {
    var suggest: ComposerSuggest
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggest.items.enumerated()), id: \.element.id) { i, item in
                HStack(spacing: 10) {
                    Rectangle().fill(i == suggest.selected ? C.accent : Color.clear).frame(width: 2, height: 14)
                    Text(item.title).font(C.mono(12, .medium)).foregroundStyle(C.ink).lineLimit(1)
                    Text(item.detail).font(C.text(12)).foregroundStyle(C.dim).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(i == suggest.selected ? C.highlight : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { onPick(i) }
            }
        }
        .background(C.surface)
        .overlay(Rectangle().stroke(C.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 14)
    }
}

/// Запись чата с действием «Закрепить» при наведении. Закреплённая подсвечена подложкой темы чата и меткой слева; у карточек
/// (владельца, команды) подложку красит сама карточка, строка получает `pinned`.
struct PinnableRow<Content: View>: View {
    @Bindable var project: ProjectModel
    var entry: ChatEntry
    var card: Bool
    @ViewBuilder var content: (Bool) -> Content
    @State private var hover = false

    var body: some View {
        let pinned = project.isPinned(entry.id)
        // Значок живёт в своей колонке справа от записи, а не поверх неё: ни «развернуть», ни время, ни текст он не перекрывает.
        HStack(alignment: .top, spacing: 4) {
            content(pinned)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if pinned && !card { Rectangle().fill(C.pin).padding(.horizontal, -10).padding(.vertical, -6) }
                }
                .overlay(alignment: .leading) {
                    if pinned { Rectangle().fill(C.accent).frame(width: 3).padding(.leading, card ? 0 : -10).padding(.vertical, card ? 0 : -6) }
                }
            Button { project.togglePin(entry) } label: {
                Image(systemName: pinned ? "pin.slash.fill" : "pin").font(.system(size: 12))
                    .foregroundStyle(pinned ? C.accent : C.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hover || pinned ? 1 : 0)
            .help(pinned ? "Открепить: убрать из закреплённых" : "Закрепить запись: к ней можно вернуться из шапки чата")
            .accessibilityLabel(pinned ? "Открепить" : "Закрепить")
        }
        .onHover { hover = $0 }
    }
}


/// Квадратный значок в поле ввода: цвет — токен чата, рамка — линия чата; подсказка при наведении.
struct ComposerIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = C.muted
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .overlay(Rectangle().stroke(C.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// «Стоп» в поле ввода: виден, пока менеджер в ходе; шлёт Esc в панель. Во время вопроса о праве или доверии Esc означал бы
/// отказ, поэтому значка тогда нет: отвечает владелец. Панель в ходе подписывает чат (`watchedPane`), сам значок — нет.
struct ComposerStopButton: View {
    let hub: TmuxHub
    let pane: String
    let outbox: ManagerOutbox

    var body: some View {
        let out = hub.output(for: pane)
        Group {
            if out.turn != nil, !out.asksPermission, !out.asksTrust {
                ComposerIconButton(symbol: "stop.fill", help: "Прервать ход менеджера (Esc в панель)", tint: C.ink) {
                    outbox.interrupt(requireTurn: false)
                }
            }
        }
        .id(pane)
    }
}

/// Черновик «пишет…» с экрана панели менеджера. Отдельный невидимый вид: строки экрана читает он, и новый захват
/// пересчитывает только его, а не весь чат с лентой.
struct ManagerScreenReader: View {
    let hub: TmuxHub
    let pane: String
    let busy: Bool
    let draft: LiveDraft

    var body: some View {
        let reply = busy ? hub.output(for: pane).reply : nil
        Color.clear.frame(width: 0, height: 0)
            // В стенде пустот черновик подставляет стенд (`benchScreen`), экран панели его не перебивает.
            .onChange(of: reply, initial: true) { _, r in if !ChatPanel.gapBenchOn { draft.screen = r } }
            .onAppear { hub.readReply(pane, true) }
            .onDisappear { hub.readReply(pane, false); if !ChatPanel.gapBenchOn { draft.screen = nil } }
            .id(pane)
    }
}

/// Хвост ленты менеджера: черновик «пишет…» и отправленное, которого ещё нет среди показанных записей. Отдельный вид:
/// черновик растёт на каждом захвате панели, и пересчитывается только хвост — основная лента получает тот же вход.
/// Черновик сверяется с той же лентой, что на экране (`entries`): он и его блок сменяются в одном кадре.
struct ManagerFeedTail<Row: View>: View {
    let draft: LiveDraft
    let entries: [ChatEntry]
    let feedKey: String
    let owners: [ChatEntry]
    let pending: [PendingMessage]
    let showsDraft: Bool
    /// Стенд пустот: id основной ленты, чтобы сосчитать повторы id между лентой и хвостом.
    var baseIDs: [String]?
    @ViewBuilder let row: (ManagerFeedItem) -> Row

    var body: some View {
        let _ = Diag.inc("tail")
        let items = FeedGrouping.tail(owners: owners, pending: pending, live: showsDraft ? draft.shown(feed: entries, key: feedKey) : nil)
        let _ = baseIDs.map { ids in
            let all = ids + items.map(\.id)
            ChatPanel.benchDupIDs = max(ChatPanel.benchDupIDs, all.count - Set(all).count)
        }
        ForEach(items) { item in row(item) }
    }
}

/// Полоса над полем: менеджер ждёт ответа на вопрос в панели. Отвечает владелец в строке Claude Code или в терминале.
/// Строки экрана читает сама полоса, а не чат.
struct ManagerWaitingStrip: View {
    let hub: TmuxHub
    let session: String
    let pane: String

    var body: some View {
        let out = hub.output(for: pane)
        if let n = out.notice {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.bubble").font(.system(size: 12)).foregroundStyle(C.amber)
                Text(n.text).font(C.text(13)).foregroundStyle(C.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Включить строку Claude Code") { DisplayModel.shared.settings.liveInput = true }
                    .buttonStyle(.plain).font(C.text(12, .medium)).foregroundStyle(C.accent)
                Button("Открыть терминал") {
                    TerminalOpener.open(session: session, pane: pane, socket: hub.socketName, tmux: hub.tmuxPath)
                }
                .buttonStyle(.plain).font(C.text(12)).foregroundStyle(C.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surface)
            .overlay(alignment: .top) { Rectangle().fill(C.amber).frame(height: 1) }
        }
    }
}
