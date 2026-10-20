import AppKit
import Foundation
import Observation

/// Прокрутка ленты транскрипта — одна для чата менеджера, вкладки «Диалог» и панелей агентов.
///
/// - Следование за концом решается положением прокрутки (`ThreadFollow`): у конца лента идёт за новым, выше — новое
///   копится под «Новые ↓».
/// - К концу из кода лента едет по событиям данных (новая запись, своя отправка, «Новые ↓»): одна прокрутка на событие.
///   Рост высоты документа сам прокрутку с анимацией не запускает — только мгновенную постановку окна в конец, и только
///   если окно не в конце. Анимированная прокрутка ленивой ленты реализует строки по пути и меняет оценки высот, документ
///   снова растёт, и рост, который снова прокручивал бы с анимацией, крутился бы без новых данных (разбор зависания
///   v0.1.0). Сверх того число постановок в конец от роста между событиями данных ограничено (`growthSnapLimit`).
/// - Ранние страницы подгружаются, когда верх ленты ближе `prefetchDistance` к окну, и только после того, как лента
///   первый раз встала на конец: иначе открытие, которое начинается сверху, грузило бы страницы зря.
/// - Подгрузка сверху не сдвигает видимый текст: видимая в окне строка закрепляется на своём месте, и каждый её сдвиг
///   при раскладке (ленивая лента уточняет высоты выше окна) тут же компенсируется прокруткой, пока она не встанет.
///   Владелец, листающий сам, главнее закрепления.
@MainActor
@Observable
public final class FeedScroller {
    /// Следование за концом и кнопка «Новые ↓».
    public var follow = ThreadFollow()
    /// Лента прокручена от верха: у верхнего края затемнение.
    public private(set) var scrolledFromTop = false

    /// Положения строк в окне и закрепление после подгрузки.
    @ObservationIgnored public let tracker = RowTracker()
    /// Подгрузка сверху запрошена и страница ещё не встала.
    @ObservationIgnored private var earlierRequested = false
    /// Строка последнего закрепления: её место закрепление проверило по свежим сообщениям.
    @ObservationIgnored private var lastPinned: String?
    /// Когда лента в последний раз прокручивалась к строке из кода (`FeedRows.scrollTo`).
    @ObservationIgnored private var programmaticScrollAt = Date.distantPast
    /// Верх ленты относительно окна: 0 — у верхнего края, отрицательное — прокручена вниз.
    @ObservationIgnored private var contentTop: CGFloat = 0
    @ObservationIgnored public var viewH: CGFloat = 0
    /// Окно прокрутки AppKit: верх ленты и поправки закрепления идут через него (`clip`), стенды читают его сами.
    @ObservationIgnored public weak var scroll: NSScrollView?
    /// Подмена окна прокрутки в тестах; без неё — `scroll`.
    @ObservationIgnored public var clipOverride: FeedClip?
    var clip: FeedClip? { clipOverride ?? scroll.map(ScrollViewClip.init) }

    // MARK: подставляемое (тесты)

    /// Сколько секунд назад владелец сам листал ленту.
    @ObservationIgnored public var sinceUserInput: () -> TimeInterval = { UserInputClock.sinceLast() }
    @ObservationIgnored public var now: () -> Date = Date.init
    /// Шаг закрепления (100 мс).
    @ObservationIgnored public var pinTick: () async -> Void = { try? await Task.sleep(nanoseconds: 100_000_000) }
    /// Отложить на следующий проход цикла (`DispatchQueue.main.async`).
    @ObservationIgnored public var later: (@escaping @MainActor () -> Void) -> Void = { work in DispatchQueue.main.async { work() } }
    /// Отложить на `delay` секунд.
    @ObservationIgnored public var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
    }
    /// Замер стенда (`AGENT_TEAM_*_BENCH`): ставит приложение, в обычной работе пуст.
    public static var benchHook: FeedScrollerBenchHook?

    public init() {}
    /// Лента после открытия встала на конец: с этого момента верх догружает начало.
    @ObservationIgnored public private(set) var positioned = false
    /// Нижний отступ ленты под последней строкой: «в конец» — так, чтобы он остался, как у прокрутки к нижней метке.
    @ObservationIgnored public var endInset: CGFloat = 0
    /// Последний ввод владельца в эту ленту (из `ScrollProbe`): колесо и тачпад с инерцией, ползунок, клавиши.
    @ObservationIgnored private var lastOwnerInput = Date.distantPast
    /// Идёт живая прокрутка AppKit (`NSScrollView.willStartLiveScroll` … `didEndLiveScroll`): жест трекпада с инерцией,
    /// ползунок в руке.
    @ObservationIgnored private var liveScrolling = false
    /// Когда живая прокрутка последний раз двигала ленту (`ThreadFollow.liveScrollStale`).
    @ObservationIgnored private var liveMoved = Date.distantPast
    /// Доводка к концу ждёт конца жеста владельца (`pullAfterGesture`).
    @ObservationIgnored private var pullPending = false
    /// Постановок в конец от роста документа с последнего события данных (`growthSnapLimit`).
    @ObservationIgnored public private(set) var growthSnaps = 0
    /// До какого времени идёт прокрутка к концу с анимацией, начатая событием данных: рост в это время её не обрывает,
    /// окно встаёт в конец одной доводкой после неё.
    @ObservationIgnored private var animatingUntil = Date.distantPast
    @ObservationIgnored private var settlePending = false
    /// Предел постановок в конец от роста между событиями данных: при открытии ленивая лента реализует строки и растёт
    /// десятки раз, а высота, которая без новых данных меняется дольше, — уже петля раскладки, а не новое внизу.
    /// Счёт обнуляют события данных и смена размера окна ленты (`viewSize`): ширина и высота меняются по действию
    /// человека (разделитель, размер окна), а не от собственной постановки, и строки, перенесённые заново, — не петля.
    /// Растущий черновик (`draftGrew`) обнуляет счёт на каждом захвате, где текст вырос: блок в 4500 знаков стоит на
    /// экране около 13 с, и без этого лента за длинным черновиком не пошла бы. Поэтому, пока менеджер пишет, предел почти
    /// не действует; от петли тогда защищает главное — рост не запускает прокрутку с анимацией.
    public static let growthSnapLimit = 60
    /// Размер окна ленты при последней постановке от роста: сменился — счёт постановок заново.
    @ObservationIgnored private var growthViewSize: CGSize?
    /// Поколение ленты: растёт при смене сессии (`reset`). Доводка, отложенная до смены, по нему видит, что лента уже
    /// другая, и не идёт: она держит прокси и модель прежней ленты.
    @ObservationIgnored private var generation = 0

    public static let prefetchDistance: CGFloat = 400

    /// Сессия, для которой лента открыта: сменилась — прокрутка начинается заново.
    @ObservationIgnored public var sessionID: String?
    /// Верхняя видимая строка и её место в окне, пока владелец читает выше конца: лента, построенная заново (возврат
    /// с экрана агента), ставит эту строку на то же место. По расстоянию до конца так нельзя: пока экран агента открыт,
    /// внизу ленты прибавляется новое.
    @ObservationIgnored private var reading: (id: String, y: CGFloat)?

    /// Прокрутка лент по ключу: чат менеджера проекта (`chatKey`) и ленты агентов (`agentKey`: проект, агент, панель
    /// или «Диалог»). Вид, построенный заново (возврат с экрана агента или из другого раздела), берёт ту же и встаёт
    /// на прежнее место. Ленты агентов, которых больше нет, не держатся (`forgetAgents`).
    private static var store: [String: FeedScroller] = [:]
    public static func chatKey(session: String) -> String { session + "|~chat" }
    public static func agentKey(session: String, agent: String, dense: Bool) -> String { session + "|" + agent + (dense ? "|pane" : "|dialog") }
    public static func remembered(_ key: String) -> FeedScroller {
        if let s = store[key] { return s }
        let s = FeedScroller()
        store[key] = s
        return s
    }
    /// Все запомненные прокрутки по ключу (стенды).
    public static var rememberedByKey: [String: FeedScroller] { store }
    /// Прокрутка проектов, вытесненных из кеша открытых (`AppModel.openModels`), не держится.
    public static func keep(sessions: Set<String>) {
        for k in store.keys where !sessions.contains(where: { k.hasPrefix($0 + "|") }) { store.removeValue(forKey: k) }
    }
    /// Прокрутка ушедших агентов проекта не держится; чат менеджера проекта остаётся.
    public static func forgetAgents(session: String, keeping names: [String]) {
        let prefix = session + "|"
        let chat = chatKey(session: session)
        for k in store.keys where k.hasPrefix(prefix) && k != chat {
            if !names.contains(String(k.dropFirst(prefix.count).split(separator: "|").first ?? "")) { store.removeValue(forKey: k) }
        }
    }

    /// Окно прокрутки найдено (впервые или после того, как вид построен заново).
    public func attached(_ scroll: NSScrollView) {
        self.scroll = scroll
    }

    /// Лента построена заново: читавший выше конца возвращается к той же строке на том же месте окна; следующая за
    /// концом встанет на конец сама. `false` — возвращать некуда (лента следовала за концом или открыта впервые).
    @discardableResult
    public func restore(rows: FeedRows, ids: [String]) -> Bool {
        guard positioned, !follow.follows, let r = reading, ids.contains(r.id) else { return false }
        pin(r.id, at: r.y, rows: rows, then: {})
        return true
    }

    /// Сессия сменилась: лента открывается заново, с конца.
    public func reset() {
        generation += 1
        pullPending = false
        settlePending = false
        growthSnaps = 0
        follow = ThreadFollow()
        positioned = false
        earlierRequested = false
        lastPinned = nil
        reading = nil
        tracker.pinID = nil
        tracker.target = nil
    }

    // MARK: события прокрутки

    /// Владелец листает эту ленту: событие ввода пришло раньше сдвига, который оно вызовет.
    public func ownerInput() { lastOwnerInput = now() }

    /// Живая прокрутка AppKit началась или кончилась (из `ScrollProbe`). Ползунок AppKit ведёт своим циклом событий,
    /// и монитор ввода видит только нажатие: без этого окно ввода гасло бы, пока ползунок ещё в руке. Окно ввода
    /// после конца — от конца живой прокрутки.
    public func liveScroll(_ active: Bool) {
        liveScrolling = active
        if active { liveMoved = now() } else { lastOwnerInput = now() }
    }

    /// Живая прокрутка идёт и двигала ленту недавно: без сдвигов дольше `ThreadFollow.liveScrollStale` она считается
    /// законченной, даже если её конец не пришёл.
    private var liveActive: Bool { liveScrolling && now().timeIntervalSince(liveMoved) < ThreadFollow.liveScrollStale }

    /// Владелец листает ленту: идёт живая прокрутка AppKit или ввод был только что (окно `ThreadFollow.userInputWindow`
    /// — для колеса мыши, у которого живой прокрутки нет). Пока он листает, лента сама к концу не едет: доводка к концу
    /// посреди жеста возвращала бы его шаг.
    public var ownerScrolling: Bool { liveActive || now().timeIntervalSince(lastOwnerInput) < ThreadFollow.userInputWindow }

    /// Следует ли лента за концом прямо сейчас: следует и владелец её не листает.
    public var pullsToEnd: Bool { follow.shouldStickToEnd && !ownerScrolling }

    /// Положение прокрутки изменилось (из `ScrollProbe`).
    public func scrolled(distance d: CGFloat, previous: CGFloat?, model: EarlierPages?, firstID: String?) {
        if let previous {
            if liveScrolling, abs(d - previous) > 0.1 { liveMoved = now() }
            // В конце лента стоит на нижнем отступе с точностью до полпикселя: окно прокрутки встаёт на целый пиксель.
            follow.scrolled(distanceFromBottom: d, from: previous, byOwner: ownerScrolling, end: endInset + (clip?.pixel ?? 0.5) / 2)
        } else {
            follow.scrolled(distanceFromBottom: d)
        }
        if follow.follows { positioned = true; reading = nil } else { rememberReading() }
        syncTop(model: model, firstID: firstID)
    }

    /// Содержимое выросло (из `ScrollProbe`): у конца — окно в конец, сразу и без анимации (`snapForGrowth`). Владелец
    /// листает — одной доводкой после жеста.
    public func grew(rows: FeedRows, bottomID: String, model: EarlierPages?, firstID: String?) {
        if follow.shouldStickToEnd {
            if ownerScrolling { pullAfterGesture(rows: rows, bottomID: bottomID, model: model) } else { snapForGrowth() }
        }
        syncTop(model: model, firstID: firstID)
    }

    /// Рост документа у ленты, которая следует за концом: окно встаёт в конец, если оно не там. Прокрутка с анимацией,
    /// начатая событием данных, ещё идёт — доводка одна, после неё. Сверх `growthSnapLimit` без нового события данных —
    /// ничего: высота, которая меняется без данных, — петля раскладки.
    private func snapForGrowth() {
        let wait = animatingUntil.timeIntervalSince(now())
        if wait > 0 {
            guard !settlePending else { return }
            settlePending = true
            let generation = self.generation
            after(wait + 0.02) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.settlePending = false
                if self.pullsToEnd { self.snapForGrowth() }
            }
            return
        }
        guard let clip else { return }
        let size = clip.viewSize
        if size != growthViewSize { growthViewSize = size; growthSnaps = 0 }
        guard let d = clip.distanceFromEnd, abs(d - endInset) > clip.pixel / 2 else { return }
        guard growthSnaps < Self.growthSnapLimit else { Diag.inc("snap.limit"); return }
        growthSnaps += 1
        Diag.inc("grow.snap")
        clip.scrollToEnd(inset: endInset)
    }

    /// Событие данных (новая запись, очередь, своя отправка, «Новые ↓», открытие): счёт постановок от роста — заново.
    private func dataEvent() { growthSnaps = 0 }

    /// Растущий черновик ответа менеджера (событие данных): лента у конца идёт за ним, сразу.
    public func draftGrew() {
        dataEvent()
        if pullsToEnd { snapForGrowth() }
    }

    /// В конец ленты пришло новое: у конца лента идёт за ним, выше — копится под «Новые ↓». `model` — лента
    /// транскрипта: по ней видно, сколько записей пришло.
    public func arrived(rows: FeedRows, bottomID: String, model: EarlierPages? = nil) {
        dataEvent()
        if follow.shouldStickToEnd {
            if ownerScrolling { pullAfterGesture(rows: rows, bottomID: bottomID, model: model) } else { pullToEnd(rows: rows, bottomID: bottomID, model: model) }
        } else if positioned {
            follow.arrived()
        }
    }

    /// Содержимое выросло — вызов прямо из уведомления о новом размере документа, в том же проходе раскладки. После
    /// пачки записей или на невидимом окне лента, которая следует за концом, встаёт в конец до показа кадра: отложенная
    /// доводка с анимацией догоняла бы растущую высоту, и следящие ленты пролистывали бы новое на глазах.
    public func contentGrewNow(model: EarlierPages?) {
        guard pullsToEnd, positioned, snapsToEnd(model), let clip else { return }
        Diag.inc("growNow.snap")
        clip.scrollToEnd(inset: endInset)
    }

    /// К концу: после пачки или на невидимом окне — сразу, иначе прокруткой с анимацией.
    private func pullToEnd(rows: FeedRows, bottomID: String, model: EarlierPages?) {
        if snapsToEnd(model), let clip { Diag.inc("pull.snap"); clip.scrollToEnd(inset: endInset) } else { animatedToEnd(rows: rows, bottomID: bottomID) }
    }

    /// Владелец листает ленту, которая следует за концом (довёл её вниз, отскок трекпада у конца): к концу — одной
    /// доводкой после окна ввода. Иначе новое, пришедшее посреди жеста, стояло бы под окном до следующего роста.
    /// Жест увёл ленту выше — доводки нет: следование уже снято.
    private func pullAfterGesture(rows: FeedRows, bottomID: String, model: EarlierPages?) {
        guard !pullPending else { return }
        pullPending = true
        // Живая прокрутка идёт — конец её неизвестен, проверка через окно ввода.
        let wait = liveActive ? ThreadFollow.userInputWindow
            : max(0.05, ThreadFollow.userInputWindow - now().timeIntervalSince(lastOwnerInput) + 0.05)
        let generation = self.generation
        after(wait) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.pullPending = false
            guard self.follow.shouldStickToEnd else { return }
            if self.ownerScrolling { self.pullAfterGesture(rows: rows, bottomID: bottomID, model: model) } else { self.pullToEnd(rows: rows, bottomID: bottomID, model: model) }
        }
    }

    /// Доводка до конца — сразу, без анимации: последнее обновление ленты принесло больше одной записи (пачка,
    /// накопившаяся в фоне) или окно не видно. Одна запись на видимом окне — обычное следование с анимацией.
    func snapsToEnd(_ model: EarlierPages?) -> Bool {
        guard let clip else { return false }
        return !clip.isVisible || (model?.lastLiveAppended ?? 1) > 1
    }

    /// «Новые ↓».
    public func jumpToEnd(rows: FeedRows, bottomID: String) {
        dataEvent()
        follow.jumpedToEnd()
        animatedToEnd(rows: rows, bottomID: bottomID)
    }

    /// Прокрутка к концу с анимацией — одна на событие данных; рост во время неё доводится после (`snapForGrowth`).
    private func animatedToEnd(rows: FeedRows, bottomID: String) {
        Diag.inc("pull.anim")
        animatingUntil = now().addingTimeInterval(Self.animationTime)
        scrollRows(rows, bottomID, anchorY: 1, animated: true)
    }

    /// Длительность прокрутки к концу с анимацией (`ProxyRows`).
    public static let animationTime: TimeInterval = 0.15

    /// Строка ленты сообщила своё место в окне; закреплённая — компенсирует сдвиг.
    /// `view` — какой экземпляр строки сообщил: у старого и нового вида ленты (вид построен заново, ленивая лента
    /// пересоздана) строки носят одни id, и уход старой строки не должен стирать запись новой.
    public func rowMoved(_ id: String, y: CGFloat, view: UUID? = nil) {
        // Строка, которую ленивая лента создала во время прокрутки к строке из кода, сообщает место, посчитанное до
        // прокрутки (на её величину ниже настоящего), и, уйдя за край, его не поправляет. Такое место не подтверждено,
        // пока строка не сообщит его ещё раз.
        if tracker.rows[id] == nil, tracker.pinID != nil || now().timeIntervalSince(programmaticScrollAt) < 0.5 {
            tracker.unconfirmed.insert(id)
        } else {
            tracker.unconfirmed.remove(id)
        }
        tracker.rows[id] = y
        tracker.origins[id] = originY
        tracker.stamps[id] = now()
        if let view { tracker.owners[id] = view }
        if id == tracker.pinID { pinIfNeeded(y) }
        Self.benchHook?.rowMoved(id, y: y)
    }

    public func rowGone(_ id: String, view: UUID? = nil) {
        if let view, let owner = tracker.owners[id], owner != view { return }
        tracker.rows[id] = nil
        tracker.origins[id] = nil
        tracker.unconfirmed.remove(id)
        tracker.stamps[id] = nil
        tracker.owners[id] = nil
    }

    /// Положение окна прокрутки сейчас (без окна — 0).
    var originY: CGFloat { clip?.originY ?? 0 }

    /// Прокрутка к строке из кода; время запоминается (`rowMoved`: места строк, созданных во время неё, не подтверждены).
    private func scrollRows(_ rows: FeedRows, _ id: String, anchorY: CGFloat, animated: Bool) {
        programmaticScrollAt = now()
        rows.scrollTo(id, anchorY: anchorY, animated: animated)
    }

    private func rememberReading() {
        var top: (id: String, y: CGFloat)?
        for (id, y) in tracker.places(origin: originY) where y >= 0 && y < viewH {
            if top == nil || y < top!.y { top = (id, y) }
        }
        if let top { reading = top }
    }

    // MARK: подгрузка начала

    /// Верх ленты относительно окна — из прокрутки AppKit (предпочтения геометрии ленивая лента не доставляет): затемнение
    /// у верхнего края и подгрузка ранних страниц при подходе к верху.
    public func syncTop(model: EarlierPages?, firstID: String?) {
        guard let origin = clip?.originY else { return }
        contentTop = -origin
        let fromTop = origin > 4
        if scrolledFromTop != fromTop { scrolledFromTop = fromTop }
        if contentTop > -Self.prefetchDistance { startEarlier(model: model, firstID: firstID) }
    }

    /// Подгружает раннюю страницу, если верх ленты рядом с окном и лента уже вставала на конец.
    public func startEarlier(model: EarlierPages?, firstID: String?) {
        guard let model, positioned, contentTop > -Self.prefetchDistance, model.hasEarlier, !model.loadingEarlier,
              !earlierRequested, tracker.pinID == nil, viewH > 0, firstID != nil else { return }
        earlierRequested = true
        Self.benchHook?.pageRequested()
        model.loadEarlier()
    }

    /// Страница встала сверху (`prependRevision` модели вырос).
    public func pagePrepended(rows: FeedRows, bottomID: String, model: EarlierPages, ids: [String]) {
        // Верх всё ещё виден (страница не заполнила окно) — следующая страница.
        after(0.25) { [weak self] in self?.startEarlier(model: model, firstID: ids.first) }
        earlierRequested = false
        guard !ids.isEmpty else { return }
        // Страница — тоже новые данные: цепочка подгрузок у короткой ленты не должна исчерпать предел постановок от роста.
        dataEvent()
        if follow.shouldStickToEnd {
            // Лента короче окна или владелец у конца: ранняя страница лента не двигает, она остаётся у конца.
            later { [weak self] in self?.scrollRows(rows, bottomID, anchorY: 1, animated: false) }
            return
        }
        // Якорь — видимая в окне строка; подгрузка показанные строки не меняет (`ThreadFeed.prepend`), так что годится
        // любая, если её место верно. Место — с поправкой на прокрутку после её сообщения (`RowTracker.places`): строка
        // за краем окна о сдвиге прокрутки не сообщает, и по записанному месту она «стояла бы» в окне. Но и поправка не
        // спасает строки, которые ленивая лента создала во время прокрутки закрепления: их место посчитано до прокрутки,
        // и они «стоят» в окне, будучи выше него. Поэтому подгрузка цепочки держит строку прежнего закрепления, пока та в
        // окне: её место закрепление только что проверило. Вне цепочки такие строки
        // (`RowTracker.unconfirmed`) якорем берутся, только если в окне нет других. Строка возвращается на то место окна, где стояла в момент
        // прихода страницы: scrollTo приводит её в окно (иначе ленивая лента её не реализует), а закрепление компенсирует
        // каждый её сдвиг.
        let known = Set(ids)
        let places = tracker.places(origin: originY)
        var anchor: (key: String, value: CGFloat)?
        if let id = lastPinned, let y = places[id], y >= 0, y < viewH, known.contains(id) {
            anchor = (id, y)
        } else {
            // Строка с неподтверждённым местом — только если в окне нет других.
            for confirmedOnly in [true, false] where anchor == nil {
                for (id, y) in places where y >= 0 && y < viewH && known.contains(id) && (!confirmedOnly || !tracker.unconfirmed.contains(id)) {
                    if anchor == nil || y < anchor!.value { anchor = (id, y) }
                }
            }
        }
        guard let anchor else { return }
        Self.benchHook?.note(String(format: "якорь %@: место %.1f, записано %.1f", anchor.key, Double(anchor.value),
                                    Double(tracker.rows[anchor.key] ?? .nan)))
        Self.benchHook?.anchorChosen(anchor.key, y: anchor.value)
        pin(anchor.key, at: anchor.value, rows: rows) { [weak self] in
            self?.startEarlier(model: model, firstID: ids.first)         // верх всё ещё рядом — следующая страница
        }
        Self.benchHook?.prepended(ids: ids, revision: { model.prependRevision })
    }

    /// Строка ставится на место `y` окна и держится там, пока раскладка не успокоится: scrollTo приводит её в окно
    /// (иначе ленивая лента её не реализует), каждый её сдвиг компенсируется прокруткой (`pinIfNeeded`).
    private func pin(_ id: String, at y: CGFloat, rows: FeedRows, then: @escaping () -> Void) {
        tracker.pinID = id
        tracker.target = y
        let start = now()
        tracker.lastCorrection = start
        let unit = viewH > 0 ? min(max(y / viewH, 0), 1) : 0
        later { [weak self] in self?.scrollRows(rows, id, anchorY: unit, animated: false) }
        Task { @MainActor [weak self] in
            for tick in 0..<40 {
                guard let wait = self?.pinTick else { break }
                await wait()
                guard let self, self.tracker.pinID == id else { break }
                if self.sinceUserInput() < 0.25 { break }
                // Пока строка не сообщила положение после закрепления, она не реализована (или запись устарела):
                // подводим её в окно ещё раз.
                guard (self.tracker.stamps[id] ?? .distantPast) > start else {
                    scrollRows(rows, id, anchorY: unit, animated: false)
                    continue
                }
                // Раскладка выше окна сдвинула строку так, что ленивая лента её свернула, — подводим снова. Строка
                // в ленте, но не на месте (сдвиг пришёл, пока окно прокрутки было ещё от прежнего вида) — поправка
                // через текущее окно. Место — с поправкой на прокрутку после её сообщения: строка, ушедшая за край окна,
                // о новых сдвигах не сообщает, и поправка по записанному месту повторялась бы каждый шаг.
                guard let y = self.tracker.place(id, origin: self.originY) else {
                    scrollRows(rows, id, anchorY: unit, animated: false)
                    self.tracker.lastCorrection = self.now()
                    continue
                }
                self.pinIfNeeded(y)
                if tick >= 3, self.now().timeIntervalSince(self.tracker.lastCorrection) > 0.6 { break }
            }
            guard let self else { return }
            Self.benchHook?.note(String(format: "закрепление %@ кончилось: %@, место %.1f при цели %.1f", id,
                                        self.tracker.pinID != id ? "сменилось" : self.sinceUserInput() < 0.25 ? "ввод" : "успокоилось",
                                        Double(self.tracker.place(id, origin: self.originY) ?? .nan), Double(y)))
            if self.tracker.pinID == id { self.tracker.pinID = nil; self.tracker.target = nil }
            self.lastPinned = id
            then()
        }
    }

    /// Каждый сдвиг закреплённой строки при раскладке тут же компенсируется прокруткой. Владелец, листающий сам, главнее.
    private func pinIfNeeded(_ y: CGFloat) {
        guard let target = tracker.target, sinceUserInput() > 0.25, let clip else { return }
        let delta = y - target
        // Допуск — четверть пункта: подгрузки идут цепочкой (страница за страницей, пока верх рядом), и остаток каждого
        // закрепления складывался — при допуске в полпункта к концу цепочки строка уезжала на 2–4 pt. Но не меньше
        // полпикселя экрана: прокрутка встаёт на целый пиксель, и на экране 1× сдвиг в четверть пункта не выполнился бы,
        // а закрепление «поправляло» бы впустую до своего предела в 4 с и столько же держало подгрузку следующей страницы.
        let pixel = clip.pixel
        guard abs(delta) > max(0.25, pixel / 2) else { return }
        clip.setOriginY(max(0, clip.originY + delta))
        tracker.lastCorrection = now()
    }
}

// MARK: правила видов

extension FeedScroller {
    /// Вид ленты появился (построен заново): читавший выше конца возвращается к той же строке; иначе, если
    /// `toEndOtherwise`, лента встаёт на конец.
    public func appeared(rows: FeedRows, ids: [String], bottomID: String, toEndOtherwise: Bool) {
        dataEvent()
        if !restore(rows: rows, ids: ids), toEndOtherwise { scrollRows(rows, bottomID, anchorY: 1, animated: false) }
    }

    /// Число ожидающих сообщений в чате изменилось. Прибавилось — как любое новое внизу: у конца лента идёт за ним,
    /// выше копится под «Новые ↓». Ушедшее в транскрипт или убранное ленту не двигает: читающего выше оно не касается.
    public func pendingChanged(from old: Int, to new: Int, rows: FeedRows, bottomID: String) {
        if new > old { arrived(rows: rows, bottomID: bottomID) }
    }

    /// Своё сообщение из поля видно сразу: лента встаёт на конец и снова следует за ним, даже если была выше.
    public func ownMessageSent(rows: FeedRows, bottomID: String) {
        jumpToEnd(rows: rows, bottomID: bottomID)
    }

    /// Сессия ленты по team status. Другая сессия (перезапуск, handoff) — место чтения прежней не переносится, лента
    /// с конца. Продолжение той же в новом файле (`continues`, continued-in) лента не перезапускает — место остаётся.
    public func sessionChanged(to sid: String?, continues: (String) -> Bool) {
        guard let sid, sessionID != sid else { return }
        if sessionID != nil, !continues(sid) { reset() }
        sessionID = sid
    }
}

// MARK: швы

/// Прокрутка к строке ленты (в приложении — `ScrollViewProxy`). `anchorY` — место строки в окне: 0 — верх, 1 — низ.
@MainActor
public protocol FeedRows {
    func scrollTo(_ id: String, anchorY: CGFloat, animated: Bool)
}

/// Положение прокрутки: верх окна в документе. В приложении — `NSClipView`, который встаёт на целый пиксель.
@MainActor
public protocol FeedClip {
    var originY: CGFloat { get }
    func setOriginY(_ y: CGFloat)
    /// Окно видно владельцу (не скрыто, не перекрыто целиком).
    var isVisible: Bool { get }
    /// Расстояние от низа окна до конца ленты.
    var distanceFromEnd: CGFloat? { get }
    /// Окно — в конец ленты, сразу; под концом остаётся `inset`.
    func scrollToEnd(inset: CGFloat)
    /// Размер пикселя экрана в пунктах (0,5 на Retina, 1 на экране 1×).
    var pixel: CGFloat { get }
    /// Размер окна прокрутки: ширина и высота видимой части ленты.
    var viewSize: CGSize { get }
}

/// Ранние страницы ленты (в приложении — `AgentThreadModel`).
@MainActor
public protocol EarlierPages: AnyObject {
    var hasEarlier: Bool { get }
    var loadingEarlier: Bool { get }
    var prependRevision: Int { get }
    /// Сколько записей добавило последнее живое обновление.
    var lastLiveAppended: Int { get }
    func loadEarlier()
}

extension AgentThreadModel: EarlierPages {}

/// Окно прокрутки AppKit как `FeedClip`.
@MainActor
struct ScrollViewClip: FeedClip {
    let scroll: NSScrollView
    var originY: CGFloat { scroll.contentView.bounds.origin.y }
    func setOriginY(_ y: CGFloat) {
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }
    var pixel: CGFloat { 1 / max(scroll.window?.backingScaleFactor ?? 2, 1) }
    var viewSize: CGSize { scroll.contentView.bounds.size }
    var isVisible: Bool { scroll.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false }
    var distanceFromEnd: CGFloat? { scroll.documentView.map { $0.frame.height - scroll.contentView.bounds.maxY } }
    func scrollToEnd(inset: CGFloat) {
        guard let doc = scroll.documentView else { return }
        setOriginY(max(0, doc.frame.height - scroll.contentView.bounds.height - inset))
    }
}

/// Замер стенда: строка сообщила место, выбран якорь подгрузки, подгрузка пришла.
@MainActor
public protocol FeedScrollerBenchHook: AnyObject {
    func rowMoved(_ id: String, y: CGFloat)
    func anchorChosen(_ id: String, y: CGFloat)
    func prepended(ids: [String], revision: @escaping @MainActor () -> Int)
    /// Строка для трассы разбора.
    func note(_ text: String)
    /// Прокрутка просит раннюю страницу (лента ещё не изменилась).
    func pageRequested()
}

public extension FeedScrollerBenchHook {
    func note(_ text: String) {}
    func pageRequested() {}
}

/// Положение отслеживаемой строки в окне (не наблюдаемое: чтение не перерисовывает ленту).
public final class RowTracker {
    /// Положение в окне каждой реализованной сейчас строки (строка исчезает из словаря, когда ленивая лента её сворачивает)
    /// в момент её последнего сообщения.
    public var rows: [String: CGFloat] = [:]
    /// Положение окна прокрутки в момент сообщения строки. Строка за краем окна о сдвиге прокрутки не сообщает (ленивая
    /// лента не шлёт ей геометрию), и её запись в `rows` устаревает на этот сдвиг.
    public var origins: [String: CGFloat] = [:]
    /// Строки, чьё место не подтверждено: впервые сообщено во время прокрутки к строке из кода (`FeedScroller.rowMoved`).
    public var unconfirmed: Set<String> = []
    /// Когда строка в последний раз сообщила своё положение: по метке видно, что запись свежая, а не оставшаяся от свёрнутой строки.
    public var stamps: [String: Date] = [:]
    /// Какой экземпляр строки сообщил место последним (`FeedRowPosition`).
    public var owners: [String: UUID] = [:]
    /// Строка, закреплённая после подгрузки сверху, и место окна, где она должна стоять: любой её сдвиг при раскладке
    /// тут же компенсируется прокруткой.
    public var pinID: String?
    public var target: CGFloat?
    public var lastCorrection = Date.distantPast

    public init() {}

    /// Место строки в окне сейчас: записанное место минус сдвиг прокрутки после записи.
    public func place(_ id: String, origin: CGFloat) -> CGFloat? {
        rows[id].map { $0 - (origin - (origins[id] ?? origin)) }
    }

    /// Места всех реализованных строк сейчас (`place`).
    public func places(origin: CGFloat) -> [String: CGFloat] {
        rows.reduce(into: [:]) { out, row in out[row.key] = row.value - (origin - (origins[row.key] ?? origin)) }
    }
}
