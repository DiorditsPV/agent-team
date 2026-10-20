import XCTest
import AppKit
@testable import AgentTeamCore

/// Подставная лента: строки с высотами в порядке документа, окно прокрутки с округлением до пикселя экрана. Каждый
/// сдвиг окна или раскладки сообщает места строк прокрутке, как ленивая лента (`rowMoved` / `rowGone`).
@MainActor
private final class FakeFeed: FeedRows, FeedClip, EarlierPages {
    var rows: [(id: String, h: CGFloat)]
    var origin: CGFloat = 0
    let viewH: CGFloat = 600
    var pixelSize: CGFloat = 0.5
    weak var scroller: FeedScroller?
    var scrolls: [(id: String, anchorY: CGFloat, animated: Bool)] = []
    // EarlierPages
    var hasEarlier = true
    var loadingEarlier = false
    var prependRevision = 0
    var lastLiveAppended = 1
    var loads = 0
    func loadEarlier() { loads += 1; loadingEarlier = true }

    init(count: Int, height: CGFloat = 100, prefix: String = "r") {
        rows = (0..<count).map { ("\(prefix)\($0)", height) } + [("bottom", 1)]
    }

    var docHeight: CGFloat { rows.reduce(0) { $0 + $1.h } }
    func docY(_ id: String) -> CGFloat? {
        var y: CGFloat = 0
        for r in rows { if r.id == id { return y }; y += r.h }
        return nil
    }
    func snap(_ y: CGFloat) -> CGFloat { (y / pixelSize).rounded() * pixelSize }
    func clamp(_ y: CGFloat) -> CGFloat { min(max(0, y), max(0, docHeight - viewH)) }

    /// Строки за краем окна (в полосе реализованных) о своём месте не сообщают — так ведёт себя ленивая лента
    /// SwiftUI: их запись остаётся от того места, где они были в окне.
    var quietOffscreen = false
    /// Строки, которые больше не сообщают места (ленивая лента перестала слать им геометрию).
    var muted: Set<String> = []
    /// Строка сообщит место ещё один раз и замолчит.
    var muteAfterReport: String?

    /// Места реализованных строк (окно и по 200 pt вокруг) — прокрутке; ушедшие из этой полосы — свёрнуты.
    func report() {
        guard let scroller else { return }
        var y: CGFloat = 0
        for r in rows {
            let inWindow = y - origin
            if muted.contains(r.id) { y += r.h; continue }
            if inWindow > -200, inWindow < viewH + 200 {
                if !muted.contains(r.id), !quietOffscreen || (inWindow >= 0 && inWindow < viewH) {
                    if r.id == muteAfterReport { muted.insert(r.id); muteAfterReport = nil }
                    scroller.rowMoved(r.id, y: inWindow)
                }
            } else { scroller.rowGone(r.id) }
            y += r.h
        }
    }
    var distanceFromBottom: CGFloat { docHeight - origin - viewH }

    // FeedRows
    func scrollTo(_ id: String, anchorY: CGFloat, animated: Bool) {
        scrolls.append((id, anchorY, animated))
        guard let d = docY(id), let h = rows.first(where: { $0.id == id })?.h else { return }
        origin = snap(clamp(d + anchorY * h - anchorY * viewH))
        report()
    }
    // FeedClip
    var originY: CGFloat { origin }
    /// Окно встаёт на целый пиксель; не сдвинулось — строки мест не сообщают (как у ленивой ленты).
    func setOriginY(_ y: CGFloat) {
        let new = snap(clamp(y))
        guard new != origin else { return }
        origin = new
        report()
    }
    var pixel: CGFloat { pixelSize }
    var width: CGFloat = 800
    var viewSize: CGSize { CGSize(width: width, height: viewH) }
    var visible = true
    var isVisible: Bool { visible }
    var distanceFromEnd: CGFloat? { docHeight - origin - viewH }
    var endJumps = 0
    func scrollToEnd(inset: CGFloat) { endJumps += 1; setOriginY(docHeight - viewH - inset) }

    /// Страница встала сверху: строки выше окна сдвигают всё ниже, окно прокрутки остаётся на прежнем смещении.
    /// Как в приложении, сначала приходит событие подгрузки (`pagePrepended` по `prependRevision`), а места строк
    /// после раскладки — следом (`layout()`).
    func prepend(_ count: Int, height: CGFloat = 100) {
        rows.insert(contentsOf: (0..<count).map { ("p\(prependRevision)-\($0)", height) }, at: 0)
        prependRevision += 1
        loadingEarlier = false
    }
    func layout() { report() }
    func ids() -> [String] { rows.map(\.id).filter { $0 != "bottom" } }

    /// В конец ленты пришли строки (раскладка ещё не сдвинула окно).
    func append(_ count: Int, height: CGFloat = 100) {
        let n = rows.count
        rows.insert(contentsOf: (0..<count).map { ("n\(n)-\($0)", height) }, at: rows.count - 1)
    }
}

@MainActor
final class FeedScrollerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var userInputAgo: TimeInterval = 100
    /// Отложенные вызовы прокрутки (`after`): тест выполняет их сам, когда «прошло время».
    private var delayed: [() -> Void] = []
    private func runDelayed() { let d = delayed; delayed = []; d.forEach { $0() } }

    private func make(_ feed: FakeFeed) -> FeedScroller {
        let s = FeedScroller()
        s.clipOverride = feed
        s.viewH = feed.viewH
        s.now = { [weak self] in self?.clock ?? Date() }
        s.sinceUserInput = { [weak self] in self?.userInputAgo ?? 100 }
        s.pinTick = { [weak self] in self?.clock += 0.1; await Task.yield() }
        s.later = { work in work() }
        s.after = { [weak self] _, work in self?.delayed.append(work) }
        feed.scroller = s
        return s
    }

    /// Окно у конца; лента сообщила места строк.
    private func atEnd(_ feed: FakeFeed, _ s: FeedScroller) {
        feed.origin = feed.clamp(feed.docHeight)
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: nil, model: nil, firstID: nil)
    }

    /// Владелец листает выше конца.
    private func readAbove(_ feed: FakeFeed, _ s: FeedScroller, to origin: CGFloat) {
        let before = feed.distanceFromBottom
        feed.origin = origin
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: before, model: nil, firstID: nil)
    }

    private func waitPinReleased(_ s: FeedScroller, ticks: Int = 5_000) async {
        for _ in 0..<ticks where s.tracker.pinID != nil { await Task.yield() }
    }

    // MARK: следование и «Новые ↓»

    func testFollowsAtEndAndCollectsBelowWhileReading() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        XCTAssertTrue(s.follow.follows)
        feed.append(1)
        s.arrived(rows: feed, bottomID: "bottom")
        runDelayed()
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5, "у конца лента идёт за новым")
        readAbove(feed, s, to: 500)
        let before = feed.scrolls.count
        s.arrived(rows: feed, bottomID: "bottom")
        s.arrived(rows: feed, bottomID: "bottom")
        XCTAssertEqual(feed.scrolls.count, before, "читающего выше новое не уводит")
        XCTAssertTrue(s.follow.unseen, "новое копится под «Новые ↓»")
        s.jumpToEnd(rows: feed, bottomID: "bottom")
        XCTAssertTrue(s.follow.follows)
        XCTAssertFalse(s.follow.unseen)
    }

    // MARK: подгрузка начала

    func testEarlierPagesOnlyAfterFirstPositioning() {
        let feed = FakeFeed(count: 3)                       // лента короче окна: верх рядом с самого начала
        let s = make(feed)
        s.syncTop(model: feed, firstID: "r0")
        XCTAssertEqual(feed.loads, 0, "до первой постановки на конец начало не грузится")
        atEnd(feed, s)
        s.syncTop(model: feed, firstID: "r0")
        XCTAssertEqual(feed.loads, 1)
        s.syncTop(model: feed, firstID: "r0")
        XCTAssertEqual(feed.loads, 1, "пока страница грузится, вторая не просится")
    }

    // MARK: закрепление при подгрузке сверху

    func testPrependKeepsReadRowInPlace() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        let anchor = s.tracker.rows.filter { $0.value >= 0 && $0.value < feed.viewH }.min { $0.value < $1.value }!
        feed.prepend(5, height: 137.3)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s)
        XCTAssertNil(s.tracker.pinID)
        let y = feed.docY(anchor.key)! - feed.origin
        XCTAssertEqual(y, anchor.value, accuracy: 0.25, "строка, которую читали, на прежнем месте окна")
    }

    /// Цепочка подгрузок подряд (страница за страницей, пока верх рядом): остаток закреплений не копится.
    func testChainOfPrependsDoesNotAccumulate() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        let first = s.tracker.rows.filter { $0.value >= 0 && $0.value < feed.viewH }.min { $0.value < $1.value }!
        for k in 0..<6 {
            feed.prepend(3, height: 91.7 + CGFloat(k) * 13.1)
            s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
            await waitPinReleased(s)
        }
        XCTAssertEqual(feed.docY(first.key)! - feed.origin, first.value, accuracy: 0.5)
    }

    /// Строка ушла за верхний край окна, не сообщив об этом: её запись осталась в окне. Якорем она не берётся — иначе
    /// закрепление ставит её на устаревшее место и сдвигает читаемый текст на величину прокрутки.
    func testAnchorIgnoresRowThatLeftWindowSilently() async {
        let feed = FakeFeed(count: 40)
        feed.quietOffscreen = true
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_200)                       // r12 сообщила место 0
        readAbove(feed, s, to: 1_260)                       // r12 ушла на −60 молча, r13 на 40
        XCTAssertEqual(s.tracker.rows["r12"], 0, "запись r12 устарела")
        feed.prepend(5)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s)
        XCTAssertEqual(feed.docY("r13")! - feed.origin, 40, accuracy: 0.5, "читаемая строка на месте")
    }

    /// Закреплённая строка перестала сообщать место: закрепление поправляет по месту с учётом своей прокрутки, а не
    /// повторяет одну и ту же поправку каждый шаг, уводя окно.
    func testPinDoesNotRunAwayWhenRowStopsReporting() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_260)
        feed.prepend(5)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        clock += 0.05
        feed.rows[0].h += 50                                // строка выше уточнила высоту: r13 сдвинулась на 50
        feed.muteAfterReport = "r13"                        // r13 сообщает этот сдвиг и замолкает
        feed.layout()
        await waitPinReleased(s)
        XCTAssertEqual(feed.docY("r13")! - feed.origin, 40, accuracy: 0.5, "окно не ушло дальше одной поправки")
    }

    /// Цепочка подгрузок: строка новой страницы, созданная во время прокрутки закрепления, сообщила место в окне, хотя
    /// стоит выше него (ленивая лента посчитала её геометрию до прокрутки). Следующая подгрузка цепочки держит строку,
    /// которую закрепление только что проверило, а не эту.
    func testChainKeepsVerifiedAnchorOverPhantomRow() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_260)                       // r13 на 40
        feed.prepend(3)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s)
        XCTAssertEqual(feed.docY("r13")! - feed.origin, 40, accuracy: 0.5)
        s.rowMoved("p0-2", y: 0)                            // на деле p0-2 стоит на −60
        feed.prepend(3)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s)
        XCTAssertEqual(feed.docY("r13")! - feed.origin, 40, accuracy: 0.5, "читаемая строка на месте")
    }

    /// Строка, созданная во время прокрутки закрепления, сообщила место, посчитанное до прокрутки, и замолчала. После
    /// того как владелец пролистал дальше, поправка на прокрутку приводит её запись в окно. Первая подгрузка новой
    /// цепочки (строка прежнего закрепления уже не в окне) её якорем не берёт.
    func testNewChainSkipsRowCreatedDuringPin() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_260)
        feed.prepend(3)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.muted = ["p0-0"]
        s.rowMoved("p0-0", y: 1_010)                        // на деле p0-0 — в самом верху документа
        feed.layout()
        await waitPinReleased(s)
        readAbove(feed, s, to: feed.origin + 1_000)         // r13 ушла вверх за окно, запись p0-0 «встала» на 10
        let top = feed.rows.map(\.id).first { id in
            guard id != "p0-0", let d = feed.docY(id) else { return false }
            return d - feed.origin >= 0 && d - feed.origin < feed.viewH
        }!
        let before = feed.docY(top)! - feed.origin
        feed.prepend(3)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s)
        XCTAssertEqual(feed.docY(top)! - feed.origin, before, accuracy: 0.5, "верхняя видимая строка на месте")
    }

    /// Экран 1×: сдвиг меньше пикселя не выполняется — закрепление не держится впустую и отпускает подгрузку.
    func testPinReleasesOnOnePointScreen() async {
        let feed = FakeFeed(count: 40)
        feed.pixelSize = 1
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        feed.prepend(5, height: 100.08)                     // сдвиг 500,4 pt: после поправки остаётся 0,4 pt — меньше пикселя
        let start = clock
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s)
        XCTAssertNil(s.tracker.pinID)
        XCTAssertLessThan(clock.timeIntervalSince(start), 1.5, "закрепление отпущено, а не держится до предела в 4 с")
    }

    /// Владелец листает сам — закрепление ему не мешает.
    func testOwnerInputBreaksPin() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        feed.prepend(5)
        userInputAgo = 0.1
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        feed.layout()
        await waitPinReleased(s, ticks: 20)
        XCTAssertNil(s.tracker.pinID)
    }

    // MARK: возврат к месту чтения

    /// Вид построен заново (экран агента, «Журнал» и назад): читавший выше конца возвращается к той же строке (RETURN).
    func testRestoreAfterRebuild() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        let read = s.tracker.rows.filter { $0.value >= 0 && $0.value < feed.viewH }.min { $0.value < $1.value }!
        // Новый вид: окно с начала, строки ещё не сообщили мест.
        feed.origin = 0
        s.tracker.rows = [:]
        s.appeared(rows: feed, ids: feed.ids(), bottomID: "bottom", toEndOtherwise: true)
        await waitPinReleased(s)
        XCTAssertEqual(feed.docY(read.key)! - feed.origin, read.value, accuracy: 0.5)
    }

    func testAppearWithoutReadingGoesToEnd() {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        s.appeared(rows: feed, ids: feed.ids(), bottomID: "bottom", toEndOtherwise: true)
        XCTAssertEqual(feed.scrolls.last?.id, "bottom")
        let feed2 = FakeFeed(count: 40)
        let s2 = make(feed2)
        s2.appeared(rows: feed2, ids: feed2.ids(), bottomID: "bottom", toEndOtherwise: false)
        XCTAssertTrue(feed2.scrolls.isEmpty, "«Диалог» без места чтения встаёт на конец сам")
    }

    /// Строка старого вида с тем же id, уходя, не стирает место строки нового.
    func testRowGoneFromOtherInstanceKeepsRow() {
        let s = FeedScroller()
        let old = UUID(), new = UUID()
        s.rowMoved("a", y: 10, view: old)
        s.rowMoved("a", y: 20, view: new)
        s.rowGone("a", view: old)
        XCTAssertEqual(s.tracker.rows["a"], 20)
        s.rowGone("a", view: new)
        XCTAssertNil(s.tracker.rows["a"])
    }

    // MARK: очередь чата (STAY)

    func testPendingCountWhileReadingDoesNotMove() {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        let n = feed.scrolls.count
        s.pendingChanged(from: 2, to: 1, rows: feed, bottomID: "bottom")
        s.pendingChanged(from: 1, to: 0, rows: feed, bottomID: "bottom")
        XCTAssertEqual(feed.scrolls.count, n, "дошедшее или убранное ленту не двигает")
        XCTAssertFalse(s.follow.unseen)
        s.pendingChanged(from: 0, to: 1, rows: feed, bottomID: "bottom")
        XCTAssertEqual(feed.scrolls.count, n, "новое ожидающее читающего выше не уводит")
        XCTAssertTrue(s.follow.unseen)
    }

    func testPendingAtEndFollowsAndOwnSendJumps() {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        atEnd(feed, s)
        feed.append(1)
        s.pendingChanged(from: 0, to: 1, rows: feed, bottomID: "bottom")
        runDelayed()
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
        readAbove(feed, s, to: 1_250)
        s.ownMessageSent(rows: feed, bottomID: "bottom")
        XCTAssertEqual(feed.scrolls.last?.id, "bottom")
        XCTAssertTrue(s.follow.follows, "после своей отправки лента снова следует за концом")
    }

    // MARK: смена сессии

    func testContinuedSessionKeepsPlaceNewSessionResets() async {
        let feed = FakeFeed(count: 40)
        let s = make(feed)
        s.sessionChanged(to: "s1") { _ in false }
        atEnd(feed, s)
        readAbove(feed, s, to: 1_250)
        s.sessionChanged(to: "s2") { $0 == "s2" }           // continued-in: та же цепочка
        feed.origin = 0
        XCTAssertTrue(s.restore(rows: feed, ids: feed.ids()), "место чтения сохранилось")
        await waitPinReleased(s)
        s.sessionChanged(to: "s9") { _ in false }           // новая сессия
        XCTAssertFalse(s.restore(rows: feed, ids: feed.ids()), "место прежней сессии не переносится")
        XCTAssertFalse(s.positioned)
    }

    // MARK: возврат в приложение

    /// Одна новая запись на видимом окне — обычное следование, как раньше: прокрутка к концу с анимацией.
    func testSingleNewRowFollowsAsBefore() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        feed.append(1, height: 60)
        feed.lastLiveAppended = 1
        s.contentGrewNow(model: feed)
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        XCTAssertEqual(feed.endJumps, 0, "сразу в конец не ставится")
        XCTAssertEqual(feed.scrolls.last?.id, "bottom")
        XCTAssertEqual(feed.scrolls.last?.animated, true)
    }

    /// Пачка записей (накопилось, пока приложение было в фоне) — в конец сразу, на каждом росте, без анимации.
    func testBatchSnapsOnEveryGrowth() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        let scrolls = feed.scrolls.count
        feed.append(12)
        feed.lastLiveAppended = 12
        s.contentGrewNow(model: feed)                       // рост приходит раньше события о новых записях
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        feed.rows[feed.rows.count - 2].h += 340             // ленивая лента уточнила высоту
        s.contentGrewNow(model: feed)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
        feed.origin += 300                                  // оценка уточнилась вниз: окно за концом
        s.contentGrewNow(model: feed)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
        XCTAssertEqual(feed.scrolls.count, scrolls, "ни одной прокрутки с анимацией")
    }

    /// Окно не видно — в конец сразу и одну запись; читавший выше остаётся на месте и копит «Новые ↓».
    func testInvisibleSnapsReaderStays() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        feed.visible = false
        feed.append(1)
        feed.lastLiveAppended = 1
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        XCTAssertEqual(feed.endJumps, 1)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
        feed.visible = true
        readAbove(feed, s, to: 500)
        let n = feed.scrolls.count, jumps = feed.endJumps
        feed.append(5)
        feed.lastLiveAppended = 5
        s.contentGrewNow(model: feed)
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        XCTAssertEqual(feed.scrolls.count, n, "читающего выше пачка не уводит")
        XCTAssertEqual(feed.endJumps, jumps)
        XCTAssertTrue(s.follow.unseen)
    }

    // MARK: петля следования

    /// Свёрнутая строка не оставляет за собой записей: за долгую сессию ленивая лента сворачивает тысячи строк.
    func testRowGoneForgetsStamp() {
        let s = FeedScroller()
        s.rowMoved("a", y: 10)
        s.rowGone("a")
        XCTAssertNil(s.tracker.rows["a"])
        XCTAssertNil(s.tracker.stamps["a"])
    }

    /// Рост содержимого так, как его сообщает проба: сразу, следующим проходом и после успокоения.
    private func grow(_ feed: FakeFeed, _ s: FeedScroller, by h: CGFloat) {
        feed.rows[feed.rows.count - 2].h += h
        s.contentGrewNow(model: feed)
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        let d = feed.distanceFromBottom
        s.scrolled(distance: d, previous: d, model: feed, firstID: nil)
    }

    /// Рост документа без новых данных (ленивая лента уточняет оценки высот) прокрутки с анимацией не запускает: окно
    /// встаёт в конец сразу, и только если оно не там. Анимированная прокрутка на каждый рост реализовала бы строки по
    /// пути, оценки менялись бы, документ снова рос — петля без данных.
    func testGrowthWithoutDataNeverAnimates() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        let scrolls = feed.scrolls.count
        for k in 0..<20 { grow(feed, s, by: k % 2 == 0 ? 40 : -25) }
        XCTAssertEqual(feed.scrolls.count, scrolls, "ни одной прокрутки к строке от роста")
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5, "окно в конце")
        let jumps = feed.endJumps
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        XCTAssertEqual(feed.endJumps, jumps, "окно уже в конце — постановки нет")
    }

    /// Петля раскладки: каждая постановка в конец снова меняет высоту выше окна. Без нового события данных постановок
    /// не больше предела, затем рост ленту не двигает; новое событие данных счёт обнуляет.
    func testLayoutLoopWithoutDataIsBounded() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        let jumps = feed.endJumps, scrolls = feed.scrolls.count
        for k in 0..<500 {
            feed.rows[5].h += k % 2 == 0 ? 37 : -21          // оценка строки выше окна скачет после каждой постановки
            s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        }
        XCTAssertEqual(feed.endJumps - jumps, FeedScroller.growthSnapLimit, "постановок от роста — не больше предела")
        XCTAssertEqual(feed.scrolls.count, scrolls, "прокруток к строке от роста без данных нет")
        XCTAssertTrue(s.follow.follows, "следование не снято: снимает его только владелец")
        feed.append(1)
        feed.lastLiveAppended = 1
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        clock += 1
        feed.rows[5].h += 10
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5, "после события данных лента снова у конца")
    }

    /// Разделитель или край окна тянут: каждая смена ширины переносит строки и растит документ без новых данных. Предел
    /// постановок этим не исчерпывается — после затишья окно в конце; при неизменной ширине предел по-прежнему держит.
    func testWidthChangeGrowthThenQuietEndsAtEnd() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        for k in 0..<(FeedScroller.growthSnapLimit * 3) {
            feed.width -= 1                                  // разделитель на 1 pt за кадр
            feed.rows[k % 20].h += 3                         // строки перенеслись заново
            s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        }
        feed.rows[feed.rows.count - 2].h += 40               // последняя смена перед затишьем
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5, "после перетаскивания окно в конце")
        XCTAssertTrue(s.follow.follows)
    }

    /// Ранняя страница у ленты, которая следует за концом, — новые данные: исчерпанный ростом предел постановок
    /// обнуляется, и лента снова держится у конца.
    func testPrependedPageResetsGrowthLimit() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        for k in 0..<(FeedScroller.growthSnapLimit + 5) {
            feed.rows[5].h += k % 2 == 0 ? 37 : -21
            s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        }
        XCTAssertEqual(s.growthSnaps, FeedScroller.growthSnapLimit)
        feed.prepend(3)
        s.pagePrepended(rows: feed, bottomID: "bottom", model: feed, ids: feed.ids())
        XCTAssertEqual(s.growthSnaps, 0)
        feed.rows[5].h += 50
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
    }

    /// Одна запись на видимом окне — одна прокрутка с анимацией; рост во время неё её не обрывает, окно встаёт
    /// в конец одной доводкой после неё.
    func testGrowthDuringAnimatedFollowSettlesOnce() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        feed.append(1, height: 60)
        feed.lastLiveAppended = 1
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        XCTAssertEqual(feed.scrolls.last?.animated, true)
        let jumps = feed.endJumps
        feed.rows[feed.rows.count - 2].h += 80              // строка реализовалась выше оценки
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        XCTAssertEqual(feed.endJumps, jumps, "посреди анимации окно не дёргается")
        XCTAssertEqual(delayed.count, 1, "доводка одна")
        clock += 0.2
        runDelayed()
        XCTAssertEqual(feed.endJumps, jumps + 1)
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
    }

    /// Растущий черновик ответа — событие данных: у конца лента идёт за ним сразу, у читающего выше — стоит.
    func testDraftGrowthFollowsOnlyAtEnd() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        atEnd(feed, s)
        feed.rows[feed.rows.count - 2].h += 120
        s.draftGrew()
        XCTAssertEqual(feed.distanceFromBottom, 0, accuracy: 0.5)
        readAbove(feed, s, to: 1000)
        let origin = feed.origin
        feed.rows[feed.rows.count - 2].h += 120
        s.draftGrew()
        XCTAssertEqual(feed.origin, origin, "читающего выше черновик не уводит")
    }

}

// MARK: листание вверх во время хода

@MainActor
final class OwnerScrollDuringTurnTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    /// Отложенные вызовы (`after`): тест выполняет их сам, когда «прошло время».
    private var delayed: [() -> Void] = []
    private func runDelayed() { let d = delayed; delayed = []; d.forEach { $0() } }

    private func make(_ feed: FakeFeed) -> FeedScroller {
        let s = FeedScroller()
        s.clipOverride = feed
        s.viewH = feed.viewH
        s.now = { [weak self] in self?.clock ?? Date() }
        s.sinceUserInput = { 100 }
        s.later = { work in work() }
        s.after = { [weak self] _, work in self?.delayed.append(work) }
        s.endInset = 20
        feed.scroller = s
        return s
    }

    /// Ход идёт: записи приходят парами (вызов инструмента и результат), лента ставится в конец на каждом росте.
    private func turnAtEnd(_ feed: FakeFeed, _ s: FeedScroller) {
        feed.origin = feed.clamp(feed.docHeight)
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: nil, model: feed, firstID: nil)
        feed.append(2)
        feed.lastLiveAppended = 2
        s.contentGrewNow(model: feed)
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
    }

    /// Рост содержимого так, как его сообщает проба: сразу (`contentGrewNow`), следующим проходом (`grew`) и после
    /// успокоения — оценка положения без сравнения с прежним.
    private func grow(_ feed: FakeFeed, _ s: FeedScroller, by h: CGFloat) {
        feed.rows[feed.rows.count - 2].h += h
        s.contentGrewNow(model: feed)
        s.grew(rows: feed, bottomID: "bottom", model: feed, firstID: nil)
        let d = feed.distanceFromBottom
        s.scrolled(distance: d, previous: d, model: feed, firstID: nil)
    }

    /// Шаг колеса или трекпада владельца вверх. `mark: false` — сдвиг без события у монитора (ползунок в руке: AppKit
    /// ведёт его своим циклом событий).
    private func ownerStepUp(_ feed: FakeFeed, _ s: FeedScroller, by step: CGFloat, mark: Bool = true) {
        if mark { s.ownerInput() }
        let before = feed.distanceFromBottom
        feed.origin -= step
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: before, model: feed, firstID: nil)
    }

    /// Медленный трекпад: 3 pt за событие, между событиями лента растёт. Следование снимается первым же шагом вверх,
    /// лента в конец не возвращается ни на одном росте, новое копится под «Новые ↓».
    func testSlowScrollUpDuringTurnLeavesEnd() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        XCTAssertEqual(feed.distanceFromBottom, 20, accuracy: 0.5, "в конце — с нижним отступом ленты")
        let jumps = feed.endJumps, scrolls = feed.scrolls.count
        var expected = feed.distanceFromBottom
        for i in 0..<20 {
            ownerStepUp(feed, s, by: 3)
            XCTAssertFalse(s.follow.follows, "шаг \(i): движение владельца вверх снимает следование сразу")
            grow(feed, s, by: 5)
            expected += 8
            XCTAssertEqual(feed.distanceFromBottom, expected, accuracy: 0.5, "шаг \(i): рост не возвращает ленту вниз")
        }
        XCTAssertEqual(feed.endJumps, jumps, "ни одной постановки в конец после начала жеста")
        XCTAssertEqual(feed.scrolls.count, scrolls, "ни одной прокрутки к концу")
        clock += 5                                          // жест кончился
        feed.append(2)
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        grow(feed, s, by: 40)
        XCTAssertFalse(s.follow.follows)
        XCTAssertTrue(s.follow.unseen, "новое — под «Новые ↓»")
        XCTAssertEqual(feed.endJumps, jumps)
    }

    /// Один шаг в 3 pt — меньше допуска «у конца»: после жеста ни успокоение раскладки, ни новый рост не возвращают ленту.
    func testSmallNudgeUpStaysAfterGesture() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        ownerStepUp(feed, s, by: 3)
        clock += 5
        let d = feed.distanceFromBottom
        grow(feed, s, by: 30)
        XCTAssertFalse(s.follow.follows)
        XCTAssertEqual(feed.distanceFromBottom, d + 30, accuracy: 0.5)
    }

    /// Владелец листает вниз к концу: в допуске следование возвращается, следующий рост ставит ленту в конец.
    func testScrollDownToEndResumesFollowing() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        for _ in 0..<10 { ownerStepUp(feed, s, by: 20) }
        XCTAssertFalse(s.follow.follows)
        for step: CGFloat in [20, 20, 20, 20, 20, 20, 20, 20, 20] {
            s.ownerInput()
            let before = feed.distanceFromBottom
            feed.origin += step
            feed.report()
            s.scrolled(distance: feed.distanceFromBottom, previous: before, model: feed, firstID: nil)
        }
        XCTAssertFalse(s.follow.follows, "в 40 pt от конца — выше допуска")
        s.ownerInput()
        let before = feed.distanceFromBottom
        feed.origin += 15
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: before, model: feed, firstID: nil)
        XCTAssertTrue(s.follow.follows, "в 25 pt от конца с движением к нему — снова следует")
        clock += 5
        grow(feed, s, by: 30)
        XCTAssertEqual(feed.distanceFromBottom, 20, accuracy: 0.5, "рост после жеста — снова в конец")
    }

    /// Владелец у конца (отскок трекпада), следование осталось; новое пришло посреди жеста, и больше ничего не растёт.
    /// После жеста лента доводится к концу сама, а не стоит над последней записью до следующего роста.
    func testPullDeferredUntilGestureEnds() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        s.ownerInput()
        let before = feed.distanceFromBottom
        feed.origin += 10                                   // за конец и обратно — отскок
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: before, model: feed, firstID: nil)
        feed.origin -= 10
        feed.report()
        s.scrolled(distance: feed.distanceFromBottom, previous: before - 10, model: feed, firstID: nil)
        XCTAssertTrue(s.follow.follows)
        feed.append(1, height: 80)
        feed.lastLiveAppended = 1
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        grow(feed, s, by: 0)
        XCTAssertEqual(feed.distanceFromBottom, 100, accuracy: 0.5, "посреди жеста лента стоит")
        clock += 0.2
        runDelayed()                                        // окно ввода ещё не кончилось — доводка ждёт дальше
        XCTAssertEqual(feed.distanceFromBottom, 100, accuracy: 0.5)
        clock += 1
        runDelayed()
        XCTAssertEqual(feed.scrolls.last?.id, "bottom", "после жеста — к концу")
        XCTAssertLessThan(feed.distanceFromBottom, 1)
        runDelayed()
        XCTAssertTrue(delayed.isEmpty, "доводка одна, не цепочка")
    }

    /// Один пиксель за событие — самый медленный трекпад, на Retina (0,5 pt) и на экране 1× (1 pt): первый же шаг
    /// снимает следование, и доводка после жеста ленту не возвращает.
    func testOnePixelStepLeavesEndOnBothScreens() {
        for pixel: CGFloat in [0.5, 1] {
            let feed = FakeFeed(count: 30)
            feed.pixelSize = pixel
            let s = make(feed)
            turnAtEnd(feed, s)
            ownerStepUp(feed, s, by: pixel)
            XCTAssertFalse(s.follow.follows, "пиксель \(pixel): шаг вверх снимает следование")
            let d = feed.distanceFromBottom
            feed.append(1)
            s.arrived(rows: feed, bottomID: "bottom", model: feed)
            grow(feed, s, by: 0)
            clock += 1
            runDelayed()
            XCTAssertEqual(feed.distanceFromBottom, d + 100, accuracy: 0.5, "пиксель \(pixel): лента осталась на месте")
            XCTAssertTrue(s.follow.unseen)
        }
    }

    /// Ползунок в руке дольше окна ввода: монитор видел только нажатие, но живая прокрутка AppKit идёт — владелец
    /// всё ещё листает. Медленный сдвиг вверх снимает следование, рост ленту не возвращает.
    func testLiveScrollKeepsOwnerScrollingPastInputWindow() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        s.ownerInput()                                      // нажатие на ползунок
        s.liveScroll(true)
        clock += 2
        XCTAssertTrue(s.ownerScrolling, "живая прокрутка идёт — владелец листает")
        let jumps = feed.endJumps
        ownerStepUp(feed, s, by: 0.5, mark: false)
        XCTAssertFalse(s.follow.follows)
        grow(feed, s, by: 30)
        XCTAssertEqual(feed.endJumps, jumps)
        s.liveScroll(false)
        XCTAssertTrue(s.ownerScrolling, "окно ввода — от конца живой прокрутки (инерция уже кончилась)")
        clock += 1
        XCTAssertFalse(s.ownerScrolling)
    }

    /// Доводка, отложенная во время живой прокрутки, ждёт её конца, а не окна ввода.
    func testDeferredPullWaitsForLiveScrollEnd() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        s.liveScroll(true)
        feed.append(1, height: 80)
        feed.lastLiveAppended = 1
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        let scrolls = feed.scrolls.count
        clock += 2
        runDelayed()
        XCTAssertEqual(feed.scrolls.count, scrolls, "живая прокрутка идёт — доводки нет")
        XCTAssertEqual(delayed.count, 1, "доводка ждёт дальше")
        s.liveScroll(false)
        clock += 1
        runDelayed()
        XCTAssertEqual(feed.scrolls.last?.id, "bottom")
    }

    /// Живая прокрутка, которая давно не двигала ленту (конец её от AppKit не пришёл), считается законченной: лента
    /// не остаётся «листаемой» навсегда. Пока она двигает ленту — идёт, сколько бы ни длилась.
    func testStaleLiveScrollEnds() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        s.liveScroll(true)
        for _ in 0..<5 {
            clock += 2
            ownerStepUp(feed, s, by: 0.5, mark: false)
            XCTAssertTrue(s.ownerScrolling, "ползунок в руке двигает ленту")
        }
        clock += ThreadFollow.liveScrollStale + 0.1
        XCTAssertFalse(s.ownerScrolling, "без сдвигов дольше предела — живая прокрутка кончилась")
        s.liveScroll(false)
        XCTAssertTrue(s.ownerScrolling, "конец, пришедший позже, — обычное окно ввода")
    }

    /// Пока идёт живая прокрутка любой ленты, общие часы ввода говорят «владелец листает сейчас»: закрепление строки
    /// при подгрузке сверху не спорит с ползунком в руке. Живая прокрутка без сдвигов дольше предела не считается.
    func testInputClockDuringLiveScroll() {
        let before = (UserInputClock.last, UserInputClock.liveScrolls, UserInputClock.liveMoved)
        defer { (UserInputClock.last, UserInputClock.liveScrolls, UserInputClock.liveMoved) = before }
        UserInputClock.last = Date(timeIntervalSinceNow: -10)
        UserInputClock.liveScrolls = 1
        UserInputClock.liveMoved = Date()
        XCTAssertEqual(UserInputClock.sinceLast(), 0)
        UserInputClock.liveMoved = Date(timeIntervalSinceNow: -(ThreadFollow.liveScrollStale + 1))
        XCTAssertGreaterThan(UserInputClock.sinceLast(), 9)
        UserInputClock.liveScrolls = 0
        UserInputClock.liveMoved = Date()
        XCTAssertGreaterThan(UserInputClock.sinceLast(), 9)
    }

    /// Сессия сменилась, пока доводка ждала конца жеста: прежняя доводка новую ленту не трогает, новая — ставится.
    func testDeferredPullDroppedOnSessionReset() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        s.ownerInput()
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        XCTAssertEqual(delayed.count, 1)
        s.reset()
        clock += 1
        let scrolls = feed.scrolls.count, jumps = feed.endJumps
        runDelayed()
        XCTAssertEqual(feed.scrolls.count, scrolls, "доводка прежней сессии не идёт")
        XCTAssertEqual(feed.endJumps, jumps)
        s.ownerInput()
        s.arrived(rows: feed, bottomID: "bottom", model: feed)
        XCTAssertEqual(delayed.count, 1, "после смены сессии доводка снова ставится")
    }

    /// Ввод, который ленту листает: колесо и трекпад, перетаскивание, клавиши. Щелчок — нет, и на полосе прокрутки тоже:
    /// ползунок покрыт живой прокруткой AppKit, а щелчок в ленте (выделить текст, раскрыть блок) не должен откладывать
    /// следование и пачку при возврате в приложение.
    func testOnlyScrollingInputCountsAsOwnerScrolling() {
        XCTAssertTrue(UserInputMonitor.scrolls(.scrollWheel))
        XCTAssertTrue(UserInputMonitor.scrolls(.leftMouseDragged))
        XCTAssertTrue(UserInputMonitor.scrolls(.keyDown))
        XCTAssertFalse(UserInputMonitor.scrolls(.leftMouseDown))
    }

    /// Пока владелец листает, лента, которая следует за концом, сама к концу не едет: рост посреди жеста его не перебивает.
    func testNoPullToEndWhileOwnerScrolls() {
        let feed = FakeFeed(count: 30)
        let s = make(feed)
        turnAtEnd(feed, s)
        let jumps = feed.endJumps, scrolls = feed.scrolls.count
        s.ownerInput()                                      // ввод отмечен, событие прокрутки ещё не дошло
        grow(feed, s, by: 30)
        XCTAssertEqual(feed.endJumps, jumps)
        XCTAssertEqual(feed.scrolls.count, scrolls)
    }

}
