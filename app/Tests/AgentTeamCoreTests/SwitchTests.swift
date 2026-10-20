import XCTest
@testable import AgentTeamCore

/// Быстрое переключение проектов: кэш моделей, панели до status, чтение транскрипта с конца, пауза хвоста.
final class SwitchTests: XCTestCase {
    private var cleanup: [String] = []

    override func tearDown() {
        for d in cleanup { try? FileManager.default.removeItem(atPath: d) }
        cleanup = []
    }

    private func tempDir() throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-sw-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        cleanup.append(d)
        return d
    }

    private func project(_ name: String, in root: String) throws -> String {
        let repo = root + "/" + name
        try FileManager.default.createDirectory(atPath: repo + "/agents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.team", withIntermediateDirectories: true)
        try "project: \(name)\nmanager: boss\n".write(toFile: repo + "/agents/team.yaml", atomically: true, encoding: .utf8)
        return repo
    }

    /// Невыбранный проект остаётся в кэше без наблюдателей и хвостов; возврат — тот же объект, снова живой.
    /// Старше `cachedProjects` — остановлен и выброшен.
    @MainActor
    func testModelCacheSuspendsUnselected() async throws {
        let root = try tempDir()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let app = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        var repos: [String] = []
        for n in ["p1", "p2", "p3", "p4", "p5"] {
            let r = try project(n, in: root)
            repos.append(r)
            XCTAssertTrue(app.addProject(repo: r))
        }
        app.select("team-p1")
        let first = try XCTUnwrap(app.project)
        XCTAssertTrue(first.active)
        XCTAssertTrue(first.hasLiveWatchers)

        app.select("team-p2")
        XCTAssertFalse(first.active)
        XCTAssertFalse(first.hasLiveWatchers, "у невыбранного проекта не должно быть подписок")
        XCTAssertTrue(app.project?.hasLiveWatchers == true)

        app.select("team-p1")
        XCTAssertTrue(app.project === first, "возврат к проекту — та же модель с данными")
        XCTAssertTrue(first.active)
        XCTAssertTrue(first.hasLiveWatchers)
        XCTAssertEqual(app.openModels.filter { $0.active }.count, 1)

        for s in ["team-p3", "team-p4", "team-p5"] { app.select(s) }
        XCTAssertEqual(app.models.count, AppModel.cachedProjects)
        XCTAssertNil(app.models["team-p2"], "самый давний вытеснен")
        XCTAssertFalse(app.openModels.contains { $0.session == "team-p2" })
        for m in app.openModels where m !== app.project { XCTAssertFalse(m.hasLiveWatchers) }
    }

    /// Модель с удержанными сообщениями менеджеру не вытесняется: вместо неё уходит следующая по давности (К1 цикла 2).
    @MainActor
    func testModelWithHeldQueueIsNotEvicted() async throws {
        let root = try tempDir()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let app = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        for n in ["p1", "p2", "p3", "p4", "p5", "p6"] { XCTAssertTrue(app.addProject(repo: try project(n, in: root))) }
        app.select("team-p1")
        let first = try XCTUnwrap(app.project)
        let id = first.addPending(text: "после хода", images: [], held: true)
        for s in ["team-p2", "team-p3", "team-p4", "team-p5"] { app.select(s) }
        XCTAssertTrue(app.models["team-p1"] === first, "очередь не пропадает вместе с моделью")
        XCTAssertNil(app.models["team-p2"])
        XCTAssertEqual(app.heldMessages, 1)
        first.removePending(id)
        app.select("team-p6")
        XCTAssertNil(app.models["team-p1"], "очередь пуста — модель вытесняется как обычно")
        XCTAssertEqual(app.models.count, AppModel.cachedProjects)
    }

    /// Выход по SIGTERM: удержанное, которое не ушло (менеджер не запущен), встаёт в сохраняемый черновик перед
    /// набранным и переживает перезапуск.
    @MainActor
    func testSignalExitReturnsUnsentQueueToDraft() async throws {
        let root = try tempDir()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let app = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        let repo = try project("p1", in: root)
        XCTAssertTrue(app.addProject(repo: repo))
        app.select("team-p1")
        let p = try XCTUnwrap(app.project)
        p.draft = "набираю дальше"
        p.addPending(text: "первое", images: [], held: true)
        p.addPending(text: "второе", images: [], held: true)
        let failure = await app.flushHeldForSignal()
        XCTAssertNotNil(failure)
        XCTAssertEqual(app.heldMessages, 0)
        XCTAssertEqual(ProjectModel(repo: repo, session: "team-p1", cli: nil, defaults: defaults).draft,
                       "первое\nвторое\nнабираю дальше")
        XCTAssertEqual(ProjectModel.draft(returning: "", before: "x"), "x")
        XCTAssertEqual(ProjectModel.draft(returning: "y", before: ""), "y")
    }

    /// Запись в панель зависла — выход по сигналу не ждёт её дольше срока: удержанное уходит в черновик.
    @MainActor
    func testSignalExitDoesNotHangOnStuckWrite() async throws {
        let root = try tempDir()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let app = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        XCTAssertTrue(app.addProject(repo: try project("p1", in: root)))
        app.select("team-p1")
        let p = try XCTUnwrap(app.project)
        p.livePanes = { [PaneInfo(session: "team-p1", paneID: "%1", role: "boss", dead: false, pid: 1, path: root)] }
        let stuck = StuckPane()
        p.outbox.writer = stuck
        p.addPending(text: "зависнет", images: [], held: true)
        let started = Date()
        let failure = await app.flushHeldForSignal(deadline: 0.3)
        XCTAssertNotNil(failure)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(p.draft, "зависнет")
    }

    /// Панели «Команды» видны по списку панелей tmux ещё до ответа team status; менеджер в сетку не попадает.
    @MainActor
    func testAgentsFromPanesBeforeStatus() throws {
        let root = try tempDir()
        let repo = try project("shop", in: root)
        let m = ProjectModel(repo: repo, session: "team-shop", cli: nil)
        m.livePanes = {
            [PaneInfo(session: "team-shop", paneID: "%1", role: "boss#1", dead: false, pid: 1, path: repo),
             PaneInfo(session: "team-shop", paneID: "%2", role: "dev#2", dead: false, pid: 2, path: repo + "/wt"),
             PaneInfo(session: "team-shop", paneID: "%3", role: "", dead: false, pid: 3, path: repo)]
        }
        XCTAssertNil(m.status)
        XCTAssertEqual(m.teamAgents.map(\.name), ["dev#2"])
        XCTAssertEqual(m.teamAgents.first?.paneID, "%2")
        XCTAssertEqual(m.teamAgents.first?.cwd, repo + "/wt")
    }

    /// session_id менеджера из .team/state.json — в обоих видах ключа.
    func testManagerSessionFromState() throws {
        let repo = try project("shop", in: try tempDir())
        try #"{"boss#1": {"session_id": "s-1", "cwd": "/tmp/x"}, "dev#1": {"session_id": "s-2"}}"#
            .write(toFile: repo + "/.team/state.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectModel.managerSession(repo: repo, managerRole: "boss")?.0, "s-1")
        XCTAssertEqual(ProjectModel.managerSession(repo: repo, managerRole: "boss")?.1, "/tmp/x")
        try #"{"boss": {"session_id": "s-old"}}"#.write(toFile: repo + "/.team/state.json", atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectModel.managerSession(repo: repo, managerRole: "boss")?.0, "s-old")
        XCTAssertNil(ProjectModel.managerSession(repo: repo, managerRole: "manager"))
    }

    /// Транскрипт читается с конца: при старте приходят только последние строки, обрезанная первая отбрасывается.
    func testTranscriptReadFromEnd() throws {
        let dir = try tempDir()
        let url = URL(fileURLWithPath: dir + "/t.jsonl")
        let lines = (1...2000).map { #"{"type":"user","uuid":"u\#($0)","message":{"role":"user","content":"строка \#($0)"}}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let got = LockedArray()
        let arrived = expectation(description: "хвост")
        let tail = JSONLTail(url: url, initialBytes: 4096)
        tail.start { l in
            got.append(l.map(String.init))
            arrived.fulfill()
        }
        wait(for: [arrived], timeout: 3)
        tail.stop()
        let read = got.all
        XCTAssertEqual(read.last, lines.last)
        XCTAssertLessThan(read.count, 60, "прочитан хвост, а не весь файл (\(size) байт)")
        XCTAssertTrue(lines.suffix(read.count).elementsEqual(read), "только целые последние строки, по порядку")

        var p = TranscriptParser()
        p.feed(lines: read.map { Substring($0) })
        XCTAssertEqual(p.entries.last?.kind, .owner("строка 2000"))
    }

    /// Пауза хвоста: за паузу ничего не приходит, после возобновления дописанное приходит один раз, с того же места.
    func testTailSuspendResumeContinuesFromOffset() throws {
        let dir = try tempDir()
        let url = URL(fileURLWithPath: dir + "/e.jsonl")
        try Data("{\"a\":1}\n".utf8).write(to: url)
        let got = LockedArray()
        let first = expectation(description: "первая строка")
        let resumed = expectation(description: "дописанное за паузу")
        let tail = JSONLTail(url: url)
        tail.start { l in
            got.append(l.map(String.init))
            let n = got.all.count
            if n == 1 { first.fulfill() }
            if n == 3 { resumed.fulfill() }
        }
        wait(for: [first], timeout: 3)
        tail.suspend()
        XCTAssertTrue(tail.isSuspended)
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("{\"a\":2}\n{\"a\":3}\n".utf8))
        try fh.close()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(got.all.count, 1, "на паузе строки не читаются")
        tail.resume()
        wait(for: [resumed], timeout: 3)
        tail.stop()
        XCTAssertEqual(got.all, ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}"])
    }
}

final class SplitLayoutTests: XCTestCase {
    func testAgentsWidthLimits() {
        // Широкое окно: сохранённая ширина, пока чату остаётся не меньше 420.
        XCTAssertEqual(SplitLayout.agentsWidth(stored: 500, total: 1200), 500)
        XCTAssertEqual(SplitLayout.agentsWidth(stored: 900, total: 1200), 1200 - 420 - 1)
        // Агентам не меньше 320.
        XCTAssertEqual(SplitLayout.agentsWidth(stored: 100, total: 1200), 320)
        // Окна на оба минимума не хватает: агентам их минимум.
        XCTAssertEqual(SplitLayout.agentsWidth(stored: 420, total: 700), 320)
        XCTAssertEqual(SplitLayout.defaultAgents, 420)
    }
}

final class SelectKeepsAgentTests: XCTestCase {
    /// Экран агента открыт до того, как проект найден; повторный select той же сессии его не сбрасывает,
    /// а переход на другой проект — сбрасывает.
    @MainActor
    func testReselectingSameSessionKeepsOpenedAgent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-sel-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: root + "/p1/agents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/p2/agents", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for n in ["p1", "p2"] { try "project: \(n)\n".write(toFile: root + "/\(n)/agents/team.yaml", atomically: true, encoding: .utf8) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let app = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)

        app.select("team-p1")                      // каталога пока нет: проект не создаётся
        XCTAssertNil(app.project)
        app.openedAgent = "dev#1"
        XCTAssertTrue(app.addProject(repo: root + "/p1"))   // каталог найден — select той же сессии
        XCTAssertEqual(app.openedAgent, "dev#1")
        app.select("team-p1")
        XCTAssertEqual(app.openedAgent, "dev#1")

        XCTAssertTrue(app.addProject(repo: root + "/p2"))
        XCTAssertNil(app.openedAgent, "смена проекта сбрасывает выбор агента")
    }
}

@MainActor
private final class StuckPane: ManagerPaneWriter {
    func writeMessage(text: String, images: [URL], to pane: String) async throws { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    func sendKeys(_ keys: [String], to pane: String) async throws {}
    func sendLiteral(_ text: String, to pane: String) async throws {}
    func paneState(_ pane: String) -> ManagerPaneState { ManagerPaneState() }
}
