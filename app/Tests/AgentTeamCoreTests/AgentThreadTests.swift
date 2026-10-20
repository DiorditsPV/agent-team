import XCTest
@testable import AgentTeamCore

/// События наблюдателя транскрипта, собранные под замком.
private final class FollowerLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TranscriptFollower.Event] = []
    func add(_ e: TranscriptFollower.Event) { lock.withLock { events.append(e) } }
    var all: [TranscriptFollower.Event] { lock.withLock { events } }
    var opened: [String] { all.flatMap { if case let .opened(l, _) = $0 { return l } else { return [] } } }
    var appended: [String] { all.flatMap { if case let .appended(l) = $0 { return l } else { return [] } } }
    var earlierPages: [([String], Bool)] { all.compactMap { if case let .earlier(l, h) = $0 { return (l, h) } else { return nil } } }
    var openedHasEarlier: Bool? { all.lazy.compactMap { if case let .opened(_, h) = $0 { return h } else { return nil } }.first }
    var waited: Bool { all.contains { if case .waiting = $0 { return true } else { return false } } }
}

final class TranscriptFollowerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-follow-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func append(_ url: URL, _ text: String) throws {
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(text.utf8))
        try fh.close()
    }

    private func wait(_ what: String, timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) {
        let e = expectation(description: what)
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if cond() { e.fulfill(); return }
            if Date() > deadline { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        poll()
        wait(for: [e], timeout: timeout + 1)
    }

    /// Первая страница — с конца файла; ранние страницы по запросу встают ровно перед ней, до начала файла,
    /// без повторов и пропусков; дописанные строки (в том числе дописанные кусками) приходят по kqueue.
    func testLastPageEarlierPagesAndAppends() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        let lines = (0..<60).map { #"{"n":\#($0),"pad":"\#(String(repeating: "x", count: $0 % 7))"}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let log = FollowerLog()
        let f = TranscriptFollower(url: url, pageBytes: 120)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { !log.opened.isEmpty }
        XCTAssertEqual(log.openedHasEarlier, true)
        XCTAssertEqual(log.opened, Array(lines.suffix(log.opened.count)))
        XCTAssertLessThan(log.opened.count, 10)

        var pages = 0
        while log.earlierPages.last?.1 ?? true {
            f.loadEarlier()
            pages += 1
            wait("страница \(pages)") { log.earlierPages.count == pages }
            XCTAssertLessThan(pages, 100)
        }
        let earlier = log.earlierPages.reversed().flatMap(\.0)
        XCTAssertEqual(earlier + log.opened, lines)

        try append(url, #"{"n":"new1"}"# + "\n" + #"{"n":"ne"#)
        wait("дописанная строка") { log.appended.count == 1 }
        try append(url, #"w2"}"# + "\n")
        wait("строка, дописанная кусками") { log.appended.count == 2 }
        XCTAssertEqual(log.appended, [#"{"n":"new1"}"#, #"{"n":"new2"}"#])
    }

    /// Файл заменили через временный файл и переименование, тем же текстом и дописанным: это продолжение — приходит
    /// только дописанное, ранние страницы по-прежнему подгружаются (М3). Другой текст — открытие заново.
    func testReplacedFileWithSamePrefixContinues() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        let lines = (0..<40).map { #"{"n":\#($0)}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url, pageBytes: 120)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { !log.opened.isEmpty }
        let openedCount = log.all.filter { if case .opened = $0 { return true } else { return false } }.count
        try ((lines + [#"{"n":"new"}"#]).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        wait("дописанное после замены") { log.appended == [#"{"n":"new"}"#] }
        XCTAssertEqual(log.all.filter { if case .opened = $0 { return true } else { return false } }.count, openedCount, "ленту не сбросили")
        XCTAssertFalse(log.waited)
        f.loadEarlier()
        wait("ранняя страница из нового файла") { log.earlierPages.count == 1 }
        XCTAssertEqual(log.earlierPages[0].0 + log.opened, Array(lines.suffix(log.earlierPages[0].0.count + log.opened.count)))

        try "другой файл\n".write(to: url, atomically: true, encoding: .utf8)
        wait("другой текст — открыт заново") { log.opened.last == "другой файл" }
    }

    /// Строка длиннее страницы: страница растёт, строка приходит целой.
    func testLongLineGrowsPage() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        let long = #"{"big":""# + String(repeating: "y", count: 1000) + #""}"#
        try ([#"{"a":1}"#, long, #"{"b":2}"#].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url, pageBytes: 16)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { !log.opened.isEmpty }
        XCTAssertEqual(log.opened, [#"{"b":2}"#])
        f.loadEarlier()
        wait("длинная строка") { log.earlierPages.count == 1 }
        // Выросшая страница дошла до начала файла: в ней и длинная строка целиком, и та, что перед ней.
        XCTAssertEqual(log.earlierPages[0].0, [#"{"a":1}"#, long])
        XCTAssertEqual(log.earlierPages[0].1, false)
    }

    /// Закрыли экран — наблюдение снято: дописанное после stop не приходит.
    func testStopRemovesWatch() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        try "{\"a\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url)
        f.start { log.add($0) }
        wait("первая страница") { !log.opened.isEmpty }
        try append(url, "{\"b\":2}\n")
        wait("дописанное до закрытия") { log.appended.count == 1 }
        f.stop()
        let before = log.all.count
        try append(url, "{\"c\":3}\n")
        f.loadEarlier()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(log.all.count, before)
        XCTAssertEqual(log.appended, [#"{"b":2}"#])
    }

    /// Транскрипта ещё нет: наблюдатель говорит об этом и открывает файл, когда он появится.
    func testWaitsForFile() throws {
        let url = dir.appendingPathComponent("later/s.jsonl")
        let log = FollowerLog()
        let f = TranscriptFollower(url: url)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("ожидание файла") { log.waited }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"a\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        wait("файл появился") { log.opened == [#"{"a":1}"#] }
        XCTAssertEqual(log.openedHasEarlier, false)
    }
}

final class AgentThreadTests: XCTestCase {
    private func fixtureEntries() throws -> [ChatEntry] {
        let text = String(decoding: try fixture("agent-transcript.jsonl"), as: UTF8.self)
        var p = TranscriptParser()
        p.feed(lines: text.split(separator: "\n"))
        return p.entries
    }

    /// Лента агента на обезличенном транскрипте: задача от менеджера, действия компактным блоком, ответ
    /// одним Markdown, конец хода. Записи субагента в ленту не попадают.
    func testGroupingOnFixture() throws {
        let entries = try fixtureEntries()
        let feed = ThreadFeed(entries)
        XCTAssertEqual(feed.segments.map(\.id), ["u1", "d1", "u7", "d2"])

        let items = ThreadGrouping.items(entries)
        guard items.count == 8 else { return XCTFail("элементов \(items.count): \(items)") }

        guard case let .incoming(_, from, addr, task) = items[0] else { return XCTFail("\(items[0])") }
        XCTAssertEqual(from, "Менеджер")
        XCTAssertEqual(addr, "uds:/tmp/socks/100.sock")
        XCTAssertEqual(task, "TASK-12 — кнопка экспорта в отчёте.\nЗона: src/report.")

        guard case let .actions(_, actions) = items[1] else { return XCTFail("\(items[1])") }
        XCTAssertEqual(actions.map(\.title), [
            "Read ×2 · /repo/src/report/export.py",
            "Bash · Run tests",
            "трекер · save_comment · TASK-12",
        ])
        XCTAssertEqual(actions.map(\.kind), [.tool, .tool, .tracker])

        // Сообщение команде — отдельный элемент с адресатом, а не строка в блоке инструментов.
        guard case let .send(_, to, report) = items[2] else { return XCTFail("\(items[2])") }
        XCTAssertEqual(to, "uds:/tmp/socks/100.sock")
        XCTAssertEqual(report, "TASK-12 готово: кнопка экспорта, 12 тестов зелёные.")

        guard case let .reply(_, reply, showWho) = items[3] else { return XCTFail("\(items[3])") }
        XCTAssertEqual(reply, "## Сделано\n\n- кнопка экспорта\n\nПроверено: `pytest`, 12 тестов.")
        XCTAssertTrue(showWho)
        guard case let .turnEnd(_, ms) = items[4] else { return XCTFail("\(items[4])") }
        XCTAssertEqual(ms, 26000)

        // Входящее от другой роли — со своим отправителем и адресом.
        guard case let .incoming(_, from2, addr2, note) = items[5] else { return XCTFail("\(items[5])") }
        XCTAssertEqual(from2, "Ревьюер")
        XCTAssertEqual(addr2, "uds:/tmp/socks/200.sock")
        XCTAssertEqual(note, "Замечание по TASK-12: нет теста на пустой отчёт.")
        XCTAssertFalse(entries.contains { if case let .reply(t) = $0.kind { return t.contains("субагента") } else { return false } })

        // Элементы ленты, собранные по отрезкам, совпадают с группировкой всей ленты.
        XCTAssertEqual(feed.items, items)
    }

    /// Новое в конце и догруженное начало пересчитывают только край ленты, а итог тот же, что у полной.
    func testIncrementalFeedEqualsFull() throws {
        let entries = try fixtureEntries()
        let full = ThreadFeed(entries)
        for k in 0...entries.count {
            var tail = ThreadFeed(Array(entries.prefix(k)))
            tail.replaceTail(from: k, with: Array(entries[k...]))
            XCTAssertEqual(tail, full, "дописано с \(k)")

            // Разбор переписал последнюю запись (склеил блоки ответа) и добавил новые.
            var rewrite = ThreadFeed(Array(entries.prefix(k)))
            let from = max(k - 1, 0)
            rewrite.replaceTail(from: from, with: Array(entries[from...]))
            XCTAssertEqual(rewrite, full, "переписано с \(from)")

            // Догруженное начало встаёт своими отрезками перед показанными: те не пересобираются.
            var head = ThreadFeed(Array(entries[k...]))
            let shown = head
            let anchor = head.prepend(Array(entries.prefix(k)))
            let page = ThreadFeed(Array(entries.prefix(k)))
            XCTAssertEqual(head.entries, full.entries, "начало до \(k)")
            XCTAssertEqual(head.items, page.items + shown.items, "начало до \(k)")
            XCTAssertEqual(head.segments.suffix(shown.segments.count).map(\.build), shown.segments.map(\.build), "начало до \(k)")
            XCTAssertEqual(anchor, shown.items.first?.id)
        }
    }

    /// Подгрузка начала не меняет показанные строки. Ранний ответ того же отрезка не снимает подпись автора
    /// у показанного ответа, ранние действия не сливаются с показанным блоком действий: иначе строка меняет высоту
    /// или id, и читаемое место уезжает.
    func testPrependKeepsShownItems() {
        func e(_ id: String, _ kind: ChatKind) -> ChatEntry { ChatEntry(id: id, time: nil, kind: kind) }
        let task = e("in", .incoming(fromName: "Менеджер", fromAddr: "uds:/tmp/m.sock", text: "TASK-1"))
        let cases: [(String, earlier: [ChatEntry], shown: [ChatEntry])] = [
            ("ответ после ответа", [task, e("r1", .reply("смотрю код"))],
             [e("r2", .reply("нашёл")), e("t1", .tool(name: "Read", summary: "a.swift")), e("r3", .reply("готово"))]),
            ("действия после действий", [task, e("t0", .tool(name: "Bash", summary: "ls")), e("t1", .tool(name: "Bash", summary: "pwd"))],
             [e("t2", .tool(name: "Read", summary: "a.swift")), e("t3", .tool(name: "Edit", summary: "a.swift")), e("r1", .reply("готово"))]),
        ]
        for (name, earlier, shownEntries) in cases {
            var feed = ThreadFeed(shownEntries)
            let shown = feed
            let anchor = feed.prepend(earlier)
            XCTAssertEqual(feed.items.suffix(shown.items.count), shown.items[...], name)
            XCTAssertEqual(feed.segments.suffix(shown.segments.count).map(\.build), shown.segments.map(\.build), name)
            XCTAssertEqual(anchor, shown.items.first?.id, name)
            XCTAssertEqual(feed.entries, earlier + shownEntries, name)

            // Новое в конце после подгрузки стык страниц не сдвигает.
            feed.replaceTail(from: feed.count, with: [e("r9", .reply("ещё"))])
            XCTAssertEqual(Array(feed.items.prefix(feed.items.count - 1).suffix(shown.items.count)), shown.items, name)
        }
    }

    /// Модель целиком: открывается с конца, сама догружает начало, пока записей мало, следует за новым
    /// и после stop больше не меняется.
    @MainActor
    func testModelFollowsAndStops() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-thread-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try fixture("agent-transcript.jsonl").write(to: url)

        let model = AgentThreadModel()
        model.start(url: url, pageBytes: 300)
        try await until("вся сессия") { model.phase == .ready && !model.hasEarlier && !model.loadingEarlier }
        let kinds = model.feed.entries.map(\.kind)
        XCTAssertEqual(kinds.first, .incoming(fromName: "Менеджер", fromAddr: "uds:/tmp/socks/100.sock",
                                              text: "TASK-12 — кнопка экспорта в отчёте.\nЗона: src/report."))
        XCTAssertEqual(kinds.filter { if case .turnEnd = $0 { return true } else { return false } }.count, 2)
        XCTAssertEqual(kinds.last, .turnEnd(durationMs: 2000))

        let revision = model.liveRevision
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"type": "user", "uuid": "u9", "timestamp": "2026-10-17T09:20:00.000Z", "message": {"role": "user", "content": "<cross-session-message from=\"uds:/tmp/socks/100.sock\" from-name=\"Менеджер\">\nTASK-13\n</cross-session-message>"}}"# + "\n").utf8))
        try await until("новая задача") { model.liveRevision > revision }
        XCTAssertEqual(model.feed.segments.last?.id, "u9")

        model.stop()
        let count = model.feed.count
        try fh.write(contentsOf: Data((#"{"type": "system", "subtype": "turn_duration", "uuid": "d9", "durationMs": 5}"# + "\n").utf8))
        try fh.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.feed.count, count)
        XCTAssertFalse(model.isRunning)
    }

    /// Длинная сессия менеджера: записей втрое больше прежнего потолка в 600. Лента открывается с конца страницей и
    /// догружает начало страницами, пока оно есть; ничего не теряется и не дублируется, порядок прежний.
    @MainActor
    func testLongSessionPagesInFullWithoutTheOldCap() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-long-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        let turns = 1500
        var text = ""
        for i in 0..<turns {
            text += #"{"type": "user", "uuid": "u\#(i)", "timestamp": "2026-10-17T09:00:00.000Z", "message": {"role": "user", "content": "вопрос \#(i)"}}"# + "\n"
            text += #"{"type": "assistant", "uuid": "a\#(i)", "timestamp": "2026-10-17T09:00:01.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "ответ \#(i)"}]}}"# + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)

        let model = AgentThreadModel()
        model.start(url: url, pageBytes: 32 << 10)
        try await until("первая страница") { model.phase == .ready }
        XCTAssertTrue(model.hasEarlier, "страница с конца не вся сессия")
        XCTAssertLessThan(model.feed.count, turns * 2, "сразу целиком не читается")

        var pages = 0
        while model.hasEarlier {
            let before = model.prependRevision
            model.loadEarlier()
            try await until("страница \(pages + 1)", timeout: 5) { model.prependRevision > before && !model.loadingEarlier }
            pages += 1
            if pages > 400 { return XCTFail("страницы не кончаются") }
        }
        XCTAssertGreaterThan(pages, 1, "начало подгружается страницами")
        XCTAssertGreaterThan(model.feed.count, 600, "больше прежнего потолка в 600 записей")
        let replies = model.feed.entries.compactMap { e -> String? in if case let .reply(t) = e.kind { return t } else { return nil } }
        XCTAssertEqual(replies, (0..<turns).map { "ответ \($0)" }, "порядок прежний, пропусков и повторов нет")
        model.stop()
    }

    /// Нет session_id — пустое состояние, а не ожидание файла.
    @MainActor
    func testNoSession() {
        let model = AgentThreadModel()
        model.start(sessionID: nil, cwd: "/repo")
        XCTAssertEqual(model.phase, .noSession)
        XCTAssertFalse(model.isRunning)
    }

    @MainActor
    private func until(_ what: String, timeout: TimeInterval = 3, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

final class ThreadFollowTests: XCTestCase {
    /// Следование определяется положением: низ виден — следует, как бы владелец туда ни попал.
    func testFollowsByPositionOnly() {
        var f = ThreadFollow()
        XCTAssertTrue(f.follows)
        f.arrived()
        XCTAssertFalse(f.unseen, "у конца новое не копится")

        f.scrolled(distanceFromBottom: 400)
        XCTAssertFalse(f.follows)
        XCTAssertFalse(f.shouldStickToEnd)
        f.arrived()
        f.arrived()
        XCTAssertTrue(f.unseen)

        f.scrolled(distanceFromBottom: 120)
        XCTAssertFalse(f.follows)
        XCTAssertTrue(f.unseen, "пока низ не виден, кнопка остаётся")

        f.scrolled(distanceFromBottom: ThreadFollow.tolerance)
        XCTAssertTrue(f.follows)
        XCTAssertFalse(f.unseen, "дошёл до низа любым способом — кнопка гаснет")
        XCTAssertTrue(f.shouldStickToEnd)
    }

    func testJumpToEnd() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 900)
        f.arrived()
        f.jumpedToEnd()
        XCTAssertTrue(f.follows)
        XCTAssertFalse(f.unseen)
    }

    /// Плавная прокрутка к концу идёт по шагам: пока двигаемся к концу, следование не снимается;
    /// шаг прочь от конца снимает его, а возврат к низу или кнопка возвращают.
    func testSmoothScrollTowardEndKeepsFollowing() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 180, from: 200)
        XCTAssertTrue(f.follows, "лента едет к концу сама")
        f.scrolled(distanceFromBottom: 90, from: 180)
        XCTAssertTrue(f.follows)
        f.scrolled(distanceFromBottom: 0, from: 90)
        XCTAssertTrue(f.follows)

        f.scrolled(distanceFromBottom: 300, from: 0)
        XCTAssertFalse(f.follows, "прокрутили выше — не следим")
        f.arrived()
        XCTAssertTrue(f.unseen)
        f.scrolled(distanceFromBottom: 280, from: 300)
        XCTAssertFalse(f.follows, "движение к концу не по следованию его не включает, пока низ не виден")
        XCTAssertTrue(f.unseen)

        f.jumpedToEnd()
        XCTAssertTrue(f.follows)
        XCTAssertFalse(f.unseen, "кнопка — снова следим")
    }
}

@MainActor
final class ThreadModelRestartTests: XCTestCase {
    /// Свёрнутая и снова развёрнутая панель вызывает ensureStarted для той же сессии: чтение не начинается заново.
    func testEnsureStartedDoesNotRestartSameSessionButRestartsOnAnotherOne() throws {
        let home = NSTemporaryDirectory() + "home-\(UUID().uuidString)"
        for id in ["s1", "s2"] {
            let url = TranscriptParser.transcriptURL(cwd: "/tmp/proj", sessionID: id, home: home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: url, atomically: true, encoding: .utf8)
        }
        let model = AgentThreadModel()
        defer { model.stop() }
        let before = AgentThreadModel.benchStarts
        model.ensureStarted(sessionID: "s1", cwd: "/tmp/proj", home: home)
        model.ensureStarted(sessionID: "s1", cwd: "/tmp/proj", home: home)
        XCTAssertEqual(AgentThreadModel.benchStarts - before, 1, "повторный вызов для той же сессии ничего не запускает")
        XCTAssertTrue(model.isRunning)
        model.ensureStarted(sessionID: "s2", cwd: "/tmp/proj", home: home)
        XCTAssertEqual(AgentThreadModel.benchStarts - before, 2, "другая сессия — новое чтение")
        model.stop()
        model.ensureStarted(sessionID: "s2", cwd: "/tmp/proj", home: home)
        XCTAssertEqual(AgentThreadModel.benchStarts - before, 3, "после остановки запускается снова")
    }
}

final class ReadingStaysPutTests: XCTestCase {
    /// Сдвиг прочь от конца сразу после роста без ввода владельца — раскладка; с вводом — владелец.
    func testUserInputAlwaysBeatsLayoutShiftClassification() {
        // раскладка: 300 pt от конца, рост был 0,1 с назад, ввода не было
        XCTAssertTrue(ThreadFollow.isLayoutShift(distance: 300, previous: 0, sinceGrowth: 0.1, sinceUserInput: 5))
        // тот же сдвиг, но владелец крутил колесо 0,05 с назад — это уход, а не раскладка
        XCTAssertFalse(ThreadFollow.isLayoutShift(distance: 300, previous: 0, sinceGrowth: 0.1, sinceUserInput: 0.05))
        // рост давно кончился — сдвиг не раскладка
        XCTAssertFalse(ThreadFollow.isLayoutShift(distance: 300, previous: 0, sinceGrowth: 1.0, sinceUserInput: 5))
        // движение к концу раскладкой не считается
        XCTAssertFalse(ThreadFollow.isLayoutShift(distance: 0, previous: 300, sinceGrowth: 0.1, sinceUserInput: 5))
    }

    /// Владелец прокрутил вверх среди потока событий (рост каждые 0,1 с): следование снято сразу и 20 событий подряд его не возвращают.
    func testReaderIsNotCarriedAwayByTwentyEventsInARow() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 0)
        XCTAssertTrue(f.shouldStickToEnd)
        // жест вверх на 600 pt в разгар роста: ввод был только что, раскладкой сдвиг не считается
        let shift = ThreadFollow.isLayoutShift(distance: 600, previous: 0, sinceGrowth: 0.05, sinceUserInput: 0.02)
        XCTAssertFalse(shift)
        f.scrolled(distanceFromBottom: 600, from: 0)
        XCTAssertFalse(f.follows)
        for i in 0..<20 {
            f.arrived()
            XCTAssertFalse(f.shouldStickToEnd, "событие \(i): лента не должна прокручиваться к концу")
            // событие растит ленту ниже: расстояние до конца увеличивается, читающий остаётся не у края
            f.scrolled(distanceFromBottom: 600 + CGFloat(i + 1) * 40, from: 600 + CGFloat(i) * 40)
            XCTAssertFalse(f.follows)
        }
        XCTAssertTrue(f.unseen, "вместо прокрутки — «Новые ↓»")
    }

    /// У края лента следует за концом, как раньше: 20 событий подряд не накапливают «Новые ↓».
    func testAtTheEdgeFollowingContinuesThroughTwentyEvents() {
        var f = ThreadFollow()
        for _ in 0..<20 {
            f.arrived()
            XCTAssertTrue(f.shouldStickToEnd)
            // рост на 80 pt, прокрутка к концу идёт плавно: расстояние убывает, следование не снимается
            f.scrolled(distanceFromBottom: 80, from: 80)
            f.scrolled(distanceFromBottom: 40, from: 80)
            f.scrolled(distanceFromBottom: 0, from: 40)
            XCTAssertTrue(f.follows)
        }
        XCTAssertFalse(f.unseen)
    }

    /// Шаг владельца вверх снимает следование на любом расстоянии, даже внутри допуска у конца; раскладка
    /// и успокоение после роста в допуске его не возвращают, движение к концу — возвращает.
    func testOwnerStepUpInsideToleranceLeavesEnd() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 20)
        f.scrolled(distanceFromBottom: 23, from: 20, byOwner: true, end: 20)
        XCTAssertFalse(f.follows, "3 pt вверх рукой владельца — уже не у конца")
        f.scrolled(distanceFromBottom: 23, from: 23)
        XCTAssertFalse(f.follows, "успокоение после роста на том же месте следование не возвращает")
        f.arrived()
        XCTAssertTrue(f.unseen)
        f.scrolled(distanceFromBottom: 21, from: 23, byOwner: true, end: 20)
        XCTAssertTrue(f.follows, "к концу в допуске — снова следует")
        XCTAssertFalse(f.unseen)
    }

    /// Самый медленный трекпад на Retina: сдвиг в один пиксель (0,5 pt) за событие. Первый же шаг вверх снимает
    /// следование, шаг вниз в допуске его возвращает.
    func testHalfPointOwnerStepsLeaveAndReturn() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 20)
        var d: CGFloat = 20
        for _ in 0..<4 {
            f.scrolled(distanceFromBottom: d + 0.5, from: d, byOwner: true, end: 20)
            d += 0.5
            XCTAssertFalse(f.follows, "шаг 0,5 pt вверх на \(d) pt — уже не у конца")
        }
        f.scrolled(distanceFromBottom: d - 0.5, from: d, byOwner: true, end: 20)
        XCTAssertTrue(f.follows, "шаг 0,5 pt вниз в допуске — снова следует")
    }

    /// Без ввода владельца сдвиг в допуске следование не снимает, как раньше; отскок трекпада у конца (за конец и
    /// обратно в конец) — тоже.
    func testLayoutDriftAndBounceAtEndKeepFollowing() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 20)
        f.scrolled(distanceFromBottom: 26, from: 20, byOwner: false, end: 20)
        XCTAssertTrue(f.follows, "раскладка сдвинула на 6 pt — лента следует")
        f.scrolled(distanceFromBottom: 20, from: 26, byOwner: false, end: 20)
        f.scrolled(distanceFromBottom: 4, from: 20, byOwner: true, end: 20)
        f.scrolled(distanceFromBottom: 20, from: 4, byOwner: true, end: 20)
        XCTAssertTrue(f.follows, "отскок у конца возвращает в конец, а не выше")
    }

    /// Возврат к концу любым способом снова включает следование и гасит «Новые ↓».
    func testReturningToTheEdgeResumesFollowing() {
        var f = ThreadFollow()
        f.scrolled(distanceFromBottom: 500, from: 0)
        f.arrived()
        XCTAssertTrue(f.unseen)
        f.scrolled(distanceFromBottom: 10, from: 200)
        XCTAssertTrue(f.follows)
        XCTAssertFalse(f.unseen)
    }
}

// MARK: пауза читателя

extension TranscriptFollowerTests {
    private var openedCount: (FollowerLog) -> Int {
        { log in log.all.filter { if case .opened = $0 { return true } else { return false } }.count }
    }

    /// Дописанное за паузу не приходит, пока пауза; после `resume()` приходит один раз, без повтора первой страницы.
    func testSuspendHoldsEventsAndResumeDeliversAppendedOnce() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        try "{\"a\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { !log.opened.isEmpty }
        f.suspend()
        XCTAssertTrue(f.isSuspended)
        try append(url, "{\"b\":2}\n{\"c\":")
        f.loadEarlier()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(log.all.count, 1, "на паузе событий нет")
        try append(url, "3}\n")
        f.resume()
        wait("дописанное за паузу") { log.appended.count == 2 }
        XCTAssertEqual(log.appended, [#"{"b":2}"#, #"{"c":3}"#])
        XCTAssertEqual(openedCount(log), 1, "первая страница не читается заново")
        try append(url, "{\"d\":4}\n")
        wait("после паузы файл снова под наблюдением") { log.appended.count == 3 }
        XCTAssertFalse(f.isSuspended)
    }

    /// Файл заменили за паузу (новый inode) — после `resume()` он открывается заново.
    func testResumeReopensReplacedFile() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        try "{\"a\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { !log.opened.isEmpty }
        f.suspend()
        try FileManager.default.removeItem(at: url)
        try "{\"x\":1}\n{\"y\":2}\n".write(to: url, atomically: true, encoding: .utf8)
        f.resume()
        wait("файл открыт заново") { self.openedCount(log) == 2 }
        XCTAssertEqual(Array(log.opened.suffix(2)), [#"{"x":1}"#, #"{"y":2}"#])
        XCTAssertTrue(log.appended.isEmpty)
    }

    /// Файл усекли за паузу — после `resume()` он открывается заново, а не дочитывается с прежнего смещения.
    func testResumeReopensTruncatedFile() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        try "{\"a\":1}\n{\"b\":2}\n".write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { log.opened.count == 2 }
        f.suspend()
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: 0)
        try fh.write(contentsOf: Data("{\"z\":0}\n".utf8))
        try fh.close()
        f.resume()
        wait("файл открыт заново") { self.openedCount(log) == 2 }
        XCTAssertEqual(log.opened.last, #"{"z":0}"#)
    }

    /// Файла не было и нет: пауза снимает ожидание, после `resume()` наблюдатель снова ждёт и открывает файл, когда он появится.
    func testResumeWhileWaitingForFile() throws {
        let url = dir.appendingPathComponent("later.jsonl")
        let log = FollowerLog()
        let f = TranscriptFollower(url: url)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("ожидание файла") { log.waited }
        f.suspend()
        try "{\"a\":1}\n".write(to: url, atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(log.opened.isEmpty, "на паузе файл не открывается")
        f.resume()
        wait("файл открыт после паузы") { log.opened == [#"{"a":1}"#] }
    }

    /// Первая страница может быть больше остальных: ранние страницы идут прежним размером.
    func testFirstPageCanBeLargerThanEarlierPages() throws {
        let url = dir.appendingPathComponent("s.jsonl")
        let lines = (0..<100).map { #"{"n":\#($0)}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let log = FollowerLog()
        let f = TranscriptFollower(url: url, pageBytes: 50, firstPageBytes: 500)
        f.start { log.add($0) }
        defer { f.stop() }
        wait("первая страница") { !log.opened.isEmpty }
        XCTAssertGreaterThan(log.opened.count, 30)
        XCTAssertEqual(log.opened, Array(lines.suffix(log.opened.count)))
        f.loadEarlier()
        wait("ранняя страница") { !log.earlierPages.isEmpty }
        XCTAssertLessThan(log.earlierPages[0].0.count, 6)
        XCTAssertEqual(log.earlierPages[0].0 + log.opened, Array(lines.suffix(log.earlierPages[0].0.count + log.opened.count)))
    }
}

extension AgentThreadTests {
    /// Модель на паузе не меняет ленту; после `resume()` дописанное встаёт в конец один раз.
    @MainActor
    func testModelSuspendResumeKeepsFeedAndAppendsOnce() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-pause-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("s.jsonl")
        try fixture("agent-transcript.jsonl").write(to: url)

        let model = AgentThreadModel()
        model.start(url: url)
        try await until("лента") { model.phase == .ready && !model.loadingEarlier }
        let ids = model.feed.entries.map(\.id)
        model.suspend()
        XCTAssertTrue(model.isSuspended)
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((#"{"type": "system", "subtype": "turn_duration", "uuid": "p1", "durationMs": 7}"# + "\n").utf8))
        try fh.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(model.feed.entries.map(\.id), ids, "на паузе лента не меняется")
        model.resume()
        XCTAssertFalse(model.isSuspended)
        try await until("дописанное после паузы") { model.feed.entries.last?.id == "p1" }
        XCTAssertEqual(model.feed.entries.map(\.id), ids + ["p1"])
        model.stop()
    }
}

/// Живой кусок по кусочкам: лента, собранная из обновлений `ThreadParsing`, совпадает с разбором файла целиком —
/// при склейке блоков ответа, повторных id и любом делении строк на куски.
final class ThreadParsingChunkTests: XCTestCase {
    func testChunkedUpdatesRebuildTheSameFeed() {
        var rng = SplitMix(seed: 5)
        for round in 0..<400 {
            var lines: [String] = []
            var msg = 0
            for i in 0..<Int.random(in: 1...30, using: &rng) {
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: lines.append(#"{"type":"user","uuid":"u\#(i)","message":{"role":"user","content":"задача \#(i)"}}"#)
                case 1: msg += 1; lines.append(#"{"type":"assistant","uuid":"a\#(i)","message":{"id":"m\#(msg)","content":[{"type":"text","text":"ответ \#(i)"}]}}"#)
                case 2: lines.append(#"{"type":"assistant","uuid":"a\#(i)","message":{"id":"m\#(msg)","content":[{"type":"text","text":"ещё \#(i)"}]}}"#)
                case 3: lines.append(#"{"type":"assistant","uuid":"t\#(i)","message":{"id":"m\#(msg)","content":[{"type":"tool_use","id":"tool\#(Int.random(in: 0..<4, using: &rng))","name":"Bash","input":{"command":"ls \#(i)"}}]}}"#)
                case 4: lines.append(#"{"type":"system","subtype":"turn_duration","uuid":"d\#(i)","durationMs":\#(i)}"#)
                default: lines.append(#"{"type":"user","uuid":"r\#(i)","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#)
                }
            }
            let parsing = ThreadParsing()
            var feed = ThreadFeed()
            var rest = lines[...]
            let firstCount = Int.random(in: 0...rest.count, using: &rng)
            for u in parsing.handle(.opened(lines: Array(rest.prefix(firstCount)), hasEarlier: false)) {
                if case let .reset(e, _, _) = u { feed = ThreadFeed(e) }
            }
            rest = rest.dropFirst(firstCount)
            while !rest.isEmpty {
                let n = Int.random(in: 1...rest.count, using: &rng)
                for u in parsing.handle(.appended(Array(rest.prefix(n)))) {
                    if case let .live(from?, tail, _) = u { feed.replaceTail(from: from, with: tail) }
                }
                rest = rest.dropFirst(n)
            }
            var full = TranscriptParser()
            full.maxEntries = .max
            full.feed(lines: lines.map { Substring($0) })
            XCTAssertEqual(feed.entries, full.entries, "раунд \(round)")
            if feed.entries != full.entries { break }
        }
    }
}
