import XCTest
@testable import AgentTeamCore

/// Закреплённые записи чата менеджера: хранение по проекту и сессии, переживает перезапуск.
@MainActor
final class PinTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "agtest-pin-\(UUID().uuidString)"))
    }

    private func reply(_ id: String, _ text: String) -> ChatEntry {
        ChatEntry(id: id, time: Date(timeIntervalSince1970: 1_760_000_000), kind: .reply(text))
    }

    private func model(_ d: UserDefaults, repo: String = "/tmp/agtest-pin") -> ProjectModel {
        ProjectModel(repo: repo, session: "team-pin", cli: nil, defaults: d)
    }

    func testPinToggleAndOrder() throws {
        let m = model(try defaults())
        m.togglePin(reply("a:text:1", "Первый ответ\nвторая строка"))
        m.togglePin(reply("b:text:2", "Второй"))
        XCTAssertEqual(m.pins.map(\.id), ["a:text:1", "b:text:2"])
        XCTAssertEqual(m.pins[0].excerpt, "Первый ответ", "отрывок — первая строка")
        XCTAssertTrue(m.isPinned("a:text:1"))
        m.togglePin(reply("a:text:1", "Первый ответ"))
        XCTAssertEqual(m.pins.map(\.id), ["b:text:2"], "повторное нажатие открепляет")
        m.unpin("b:text:2")
        XCTAssertTrue(m.pins.isEmpty)
    }

    func testOnlyTextEntriesCanBePinned() throws {
        let m = model(try defaults())
        m.togglePin(ChatEntry(id: "t", time: nil, kind: .tool(name: "Bash", summary: "ls")))
        m.togglePin(ChatEntry(id: "e", time: nil, kind: .turnEnd(durationMs: 5)))
        XCTAssertTrue(m.pins.isEmpty)
        m.togglePin(ChatEntry(id: "o", time: nil, kind: .owner("моё сообщение")))
        m.togglePin(ChatEntry(id: "i", time: nil, kind: .incoming(fromName: "dev", fromAddr: "x", text: "от агента")))
        XCTAssertEqual(m.pins.map(\.id), ["o", "i"])
    }

    /// Хранение: набор живёт в настройках по проекту и сессии менеджера; новая сессия начинает с пустого, прежний набор цел.
    func testPersistenceByProjectAndSession() throws {
        let d = try defaults()
        let key1 = PinStore.key(repo: "/tmp/p1", session: "sess-1")
        PinStore.save([PinnedEntry(id: "u1", excerpt: "один", time: nil)], d, key: key1)
        XCTAssertEqual(PinStore.load(d, key: key1).map(\.id), ["u1"], "переживает перезапуск: читается из настроек")
        XCTAssertTrue(PinStore.load(d, key: PinStore.key(repo: "/tmp/p1", session: "sess-2")).isEmpty, "у новой сессии свой набор")
        XCTAssertTrue(PinStore.load(d, key: PinStore.key(repo: "/tmp/p2", session: "sess-1")).isEmpty, "у другого проекта свой")
        PinStore.save([], d, key: key1)
        XCTAssertNil(d.data(forKey: key1), "пустой набор ключа не держит")
    }

    func testModelReloadsPinsOnNewInstance() throws {
        let d = try defaults()
        let first = model(d)
        first.loadPins()
        first.togglePin(reply("keep", "останется"))
        // Ключ без сессии (транскрипт не открыт): тот же при следующем запуске.
        let second = model(d)
        second.loadPins()
        XCTAssertEqual(second.pins.map(\.id), ["keep"])
    }

    func testJumpRequestsAreDistinct() throws {
        let m = model(try defaults())
        m.requestJump(to: "x")
        let a = m.pinJump
        m.pinJump = nil
        m.requestJump(to: "x")
        XCTAssertNotEqual(a, m.pinJump, "повторная просьба к той же записи — новое событие")
    }
}

/// Прыжок к закреплённой записи старше загруженной части: страницы подгружаются до неё.
@MainActor
final class PinLoadUntilTests: XCTestCase {
    private func session(turns: Int) throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-pinload-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = ""
        for i in 0..<turns {
            text += #"{"type": "user", "uuid": "u\#(i)", "timestamp": "2026-10-17T09:00:00.000Z", "message": {"role": "user", "content": "вопрос \#(i)"}}"# + "\n"
            text += #"{"type": "assistant", "uuid": "a\#(i)", "timestamp": "2026-10-17T09:00:01.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "ответ \#(i)"}]}}"# + "\n"
        }
        let url = dir.appendingPathComponent("s.jsonl")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return (dir, url)
    }

    private func ready(_ model: AgentThreadModel, _ url: URL) async throws {
        model.start(url: url, pageBytes: 8 << 10)
        for _ in 0..<150 where model.phase != .ready { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.phase, .ready)
    }

    func testLoadsPagesUntilEntryIsInFeed() async throws {
        let (dir, url) = try session(turns: 400)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AgentThreadModel()
        try await ready(model, url)
        let first = model.feed.count
        XCTAssertTrue(model.hasEarlier)
        XCTAssertFalse(model.contains(entryID: "u3"), "начало сессии сразу не загружено")
        let before = model.prependRevision
        let found = await model.loadEarlier(until: "u3")
        XCTAssertTrue(found)
        XCTAssertTrue(model.contains(entryID: "u3"))
        XCTAssertGreaterThan(model.prependRevision - before, 1, "подгружено несколько страниц")
        XCTAssertGreaterThan(model.feed.count, first)
        model.stop()
    }

    func testStopsAtNearestPageAndAlreadyLoadedIsInstant() async throws {
        let (dir, url) = try session(turns: 400)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AgentThreadModel()
        try await ready(model, url)
        let nearest = "u\(400 - 1 - 60)"
        let found = await model.loadEarlier(until: nearest)
        XCTAssertTrue(found)
        XCTAssertTrue(model.hasEarlier, "дальше нужного не грузим")
        let rev = model.prependRevision
        let again = await model.loadEarlier(until: nearest)
        XCTAssertTrue(again)
        XCTAssertEqual(model.prependRevision, rev, "запись уже в ленте — страниц не просим")
        model.stop()
    }

    func testEntryFromAnotherSessionIsNotFoundAfterReachingTheStart() async throws {
        let (dir, url) = try session(turns: 150)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AgentThreadModel()
        try await ready(model, url)
        let found = await model.loadEarlier(until: "нет-такой-записи")
        XCTAssertFalse(found)
        XCTAssertFalse(model.hasEarlier, "дошли до начала сессии")
        model.stop()
    }
}
