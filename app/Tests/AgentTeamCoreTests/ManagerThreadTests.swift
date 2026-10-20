import XCTest
@testable import AgentTeamCore

/// Транскрипт менеджера читает одна модель проекта (`ProjectModel.managerThread`): из неё и лента, и `chat`, контекст,
/// ход и сверка очереди. Модель засыпает вместе с проектом и следует за продолжением сессии в новом файле.
@MainActor
final class ManagerThreadTests: XCTestCase {
    private var root: String!
    private var home: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "agtest-mgr-\(getpid())-\(UUID().uuidString.prefix(6))"
        home = root + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    private func owner(_ id: String, _ text: String) -> String {
        #"{"type":"user","uuid":"\#(id)","message":{"role":"user","content":"\#(text)"}}"#
    }
    private func reply(_ id: String, _ text: String, tokens: Int = 100) -> String {
        #"{"type":"assistant","uuid":"\#(id)","message":{"id":"m-\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(tokens)},"content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private func end(_ id: String) -> String { #"{"type":"system","subtype":"turn_duration","uuid":"\#(id)","durationMs":5}"# }

    private func transcript(_ sid: String, cwd: String) -> URL {
        TranscriptParser.transcriptURL(cwd: cwd, sessionID: sid, home: home)
    }

    private func write(_ url: URL, _ lines: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
    }

    private func append(_ url: URL, _ lines: [String]) throws {
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try fh.close()
    }

    /// Проект с менеджером `boss` и его сессией в state.json.
    private func project(session: String, cwd: String, defaults given: UserDefaults? = nil) throws -> ProjectModel {
        let repo = root + "/repo"
        try FileManager.default.createDirectory(atPath: repo + "/agents", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repo + "/.team", withIntermediateDirectories: true)
        try "project: shop\nmanager: boss\n".write(toFile: repo + "/agents/team.yaml", atomically: true, encoding: .utf8)
        try #"{"boss#1": {"session_id": "\#(session)", "cwd": "\#(cwd)"}}"#
            .write(toFile: repo + "/.team/state.json", atomically: true, encoding: .utf8)
        let defaults = try given ?? XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        return ProjectModel(repo: repo, session: "team-shop", cli: nil, defaults: defaults, claudeHome: home)
    }

    private func until(_ what: String, timeout: TimeInterval = 3, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Лента, `chat`, контекст и ход — из одной модели; ход и контекст идут за дописанными строками.
    func testChatUsageAndBusyComeFromTheOneReader() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        try write(url, [owner("u1", "привет"), reply("a1", "здравствуйте", tokens: 1000), end("d1"), owner("u2", "дальше")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("лента") { m.chat.count == 4 }
        XCTAssertEqual(m.chat.map(\.id), m.managerThread.feed.entries.map(\.id))
        XCTAssertEqual(m.usage?.contextTokens, 1000)
        XCTAssertTrue(m.managerBusy, "последнее — сообщение владельца, ход идёт")

        try append(url, [reply("a2", "готово", tokens: 2000), end("d2")])
        try await until("конец хода") { !m.managerBusy }
        XCTAssertEqual(m.usage?.contextTokens, 2000)
        XCTAssertEqual(m.chat.last?.kind, .turnEnd(durationMs: 5))
    }

    /// Отправленное снимается с отметки, как только запись владельца пришла в живой кусок ленты.
    func testPendingReconciledByLiveUpdate() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        try write(url, [owner("u1", "привет"), reply("a1", "да"), end("d1")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("лента") { m.chat.count == 3 }
        m.addPending(text: "сделай отчёт", images: [])
        XCTAssertEqual(m.pending.count, 1)
        try append(url, [owner("u2", "сделай отчёт")])
        try await until("карточка снята") { m.pending.isEmpty }
        XCTAssertTrue(m.managerBusy)
    }

    /// Проект ушёл с экрана — читатель спит: дописанное не приходит, у модели нет живых наблюдателей; вернулся —
    /// дописанное приходит один раз.
    func testReaderSleepsWithProject() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        try write(url, [owner("u1", "привет"), reply("a1", "да"), end("d1")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("лента") { m.chat.count == 3 }
        m.suspend()
        XCTAssertTrue(m.managerThread.isSuspended)
        XCTAssertFalse(m.hasLiveWatchers, "спящий проект не читает транскрипт менеджера")
        try append(url, [owner("u2", "ещё")])
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(m.chat.count, 3)
        m.resume()
        XCTAssertFalse(m.managerThread.isSuspended)
        try await until("дописанное после возврата") { m.chat.count == 4 }
        XCTAssertEqual(m.chat.map(\.id), ["u1", "m-a1:text:a1:0", "d1", "u2"])
    }

    /// Claude Code продолжил сессию в новом файле: лента переходит на него; status, назвавший любую сессию цепочки,
    /// чтение не перезапускает.
    func testFollowsContinuedInAndKeepsChain() async throws {
        let cwd = "/work/shop"
        let old = transcript("s1", cwd: cwd)
        try write(old, [owner("u1", "привет"), reply("a1", "да"), end("d1")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("лента") { m.chat.count == 3 }

        let new = transcript("s2", cwd: cwd)
        try write(new, [owner("u5", "после clear")])
        try append(old, [#"{"type":"continued-in","continuedInSessionId":"s2"}"#])
        try await until("переход в новый файл") { m.managerThread.sessionID == "s2" }
        try await until("лента нового файла") { m.chat.last?.id == "u5" }
        XCTAssertTrue(m.managerBusy)
        XCTAssertTrue(m.managerThread.follows(sessionID: "s1"))
        XCTAssertTrue(m.managerThread.follows(sessionID: "s2"))

        try append(new, [reply("a5", "ок"), end("d5")])
        try await until("дописанное в новом файле") { !m.managerBusy }
        XCTAssertEqual(m.chat.last?.id, "d5")
    }

    /// Файл открыт по сессии запуска, а цепочка уже ведёт дальше: читается конец цепочки.
    func testOpensEndOfChainFromLaunchSession() async throws {
        let cwd = "/work/shop"
        try write(transcript("s1", cwd: cwd), [owner("u1", "старое"), #"{"type":"continued-in","continuedInSessionId":"s2"}"#])
        try write(transcript("s2", cwd: cwd), [owner("u2", "новое")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("конец цепочки") { m.chat.map(\.id) == ["u2"] }
        XCTAssertEqual(m.managerThread.sessionID, "s2")
        XCTAssertTrue(m.managerThread.follows(sessionID: "s1"), "сессия запуска — звено той же цепочки")
    }
}

extension ManagerThreadTests {
    /// Прерывание меняет только ход: записей не добавляет, поэтому ревизия ленты стоит (группировка не пересчитывается,
    /// «Новые ↓» не появляется), а проект узнаёт о конце хода.
    func testStateOnlyUpdateKeepsRevision() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        try write(url, [owner("u1", "сделай"), reply("a1", "делаю")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("ход идёт") { m.chat.count == 2 && m.managerBusy }
        let revision = m.managerThread.liveRevision
        let chatRevision = m.chatRevision
        try append(url, [#"{"type":"user","uuid":"i1","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#])
        try await until("прерывание закончило ход") { !m.managerBusy }
        XCTAssertEqual(m.managerThread.liveRevision, revision)
        XCTAssertEqual(m.chatRevision, chatRevision)
    }

    /// В state.json нет каталога, файла ещё нет: искать негде. Ответ status с той же сессией и каталогом открывает файл.
    func testStatusWithCwdOpensSessionStateCouldNotLocate() async throws {
        let cwd = "/work/shop"
        let m = try project(session: "s1", cwd: cwd)
        try #"{"boss#1": {"session_id": "s1"}}"#.write(toFile: m.repo + "/.team/state.json", atomically: true, encoding: .utf8)
        m.start()
        defer { m.stop() }
        XCTAssertFalse(m.managerThread.isRunning)
        try write(transcript("s1", cwd: cwd), [owner("u1", "привет")])
        let manager = Agent(name: "boss#1", role: "boss", kind: "manager", sessionID: "s1", cwd: cwd)
        m.statusArrived(TeamStatus(project: "shop", repo: m.repo, session: "team-shop", sessionAlive: true, tracker: nil, agents: [manager]))
        try await until("файл открыт") { m.chat.map(\.id) == ["u1"] }
    }

    /// Пока файла новой сессии нет, ход менеджера не сбрасывается: удержанные сообщения не уходят в запускающийся Claude Code.
    func testWaitingForFileKeepsBusy() async throws {
        let cwd = "/work/shop"
        let m = try project(session: "s1", cwd: cwd)
        m.managerBusy = true
        m.start()
        defer { m.stop() }
        try await until("ожидание файла") { m.managerThread.phase == .waiting }
        XCTAssertTrue(m.managerBusy)
    }
}

/// После `/clear` status отдаёт новую сессию, пока панель жива; лента переходит на её транскрипт.
extension ManagerThreadTests {
    private func clearStatus(_ m: ProjectModel, session: String, cwd: String) -> TeamStatus {
        let boss = Agent(name: "boss#1", role: "boss", kind: "manager", sessionID: session, cwd: cwd)
        return TeamStatus(project: "shop", repo: m.repo, session: "team-shop", sessionAlive: true, tracker: nil, agents: [boss])
    }

    /// Файл старой сессии не ведёт в новую (`continued-in` нет), state.json помнит старую: status с новой переключает ленту.
    func testManagerSwitchesToNewSessionFromStatus() async throws {
        let cwd = "/work/shop"
        let old = transcript("s1", cwd: cwd)
        try write(old, [owner("u1", "старое"), reply("a1", "ответ"), end("d1")])
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        try await until("старая лента") { m.chat.map(\.id).contains("u1") }

        // Новый файл ещё не появился: старые сообщения уже не показываются.
        m.statusArrived(clearStatus(m, session: "s2", cwd: cwd))
        try await until("старая лента убрана") { m.chat.isEmpty }
        XCTAssertEqual(m.managerThread.phase, .waiting)

        let new = transcript("s2", cwd: cwd)
        try write(new, [owner("n1", "после clear")])
        try await until("лента новой сессии") { m.chat.map(\.id) == ["n1"] }
        XCTAssertEqual(m.managerThread.sessionID, "s2")

        // Старый файл дописывается — в ленту это не попадает; новый — попадает.
        try append(old, [owner("u2", "эхо старого")])
        try append(new, [reply("n2", "новый ответ"), end("d2")])
        try await until("дописанное в новом") { m.chat.last?.id == "d2" }
        XCTAssertFalse(m.chat.map(\.id).contains("u2"))
        XCTAssertFalse(m.chat.map(\.id).contains("u1"))
    }

    /// Лента агента: смена session_id в status переключает её на транскрипт новой сессии.
    func testAgentThreadSwitchesToNewSession() async throws {
        let cwd = "/work/shop-dev"
        try write(transcript("d1", cwd: cwd), [owner("u1", "старое")])
        try write(transcript("d2", cwd: cwd), [owner("n1", "новое")])
        let m = try project(session: "s-none", cwd: "/work/shop")
        m.start()
        defer { m.stop() }
        let thread = m.openAgentThread(Agent(name: "dev#1", role: "dev", sessionID: "d1", cwd: cwd))
        try await until("лента агента") { thread.feed.count == 1 }
        let same = m.openAgentThread(Agent(name: "dev#1", role: "dev", sessionID: "d2", cwd: cwd))
        XCTAssertTrue(same === thread)
        try await until("новая сессия") { thread.sessionID == "d2" && thread.feed.count == 1 }
        XCTAssertFalse(thread.follows(sessionID: "d1") && thread.sessionID == "d1")
    }

    /// state.json уже хранит текущую сессию (после `/clear`), а закреплённое записано по сессии запуска: status возвращает его.
    func testPinsFollowLaunchSessionAfterClear() async throws {
        let cwd = "/work/shop"
        try write(transcript("s2", cwd: cwd), [owner("n1", "после clear")])
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let m = try project(session: "s2", cwd: cwd, defaults: defaults)
        PinStore.save([PinnedEntry(id: "u1", excerpt: "было", time: nil)], defaults, key: PinStore.key(repo: m.repo, session: "s1"))
        try #"{"boss#1": {"session_id": "s2", "launch_session_id": "s1", "cwd": "\#(cwd)"}}"#
            .write(toFile: m.repo + "/.team/state.json", atomically: true, encoding: .utf8)
        m.start()
        defer { m.stop() }
        XCTAssertEqual(m.pins.map(\.id), ["u1"], "быстрый старт берёт сессию запуска из state.json")
        var boss = Agent(name: "boss#1", role: "boss", kind: "manager", sessionID: "s2", cwd: cwd)
        boss.launchSessionID = "s1"
        m.statusArrived(TeamStatus(project: "shop", repo: m.repo, session: "team-shop", sessionAlive: true, tracker: nil, agents: [boss]))
        XCTAssertEqual(m.pins.map(\.id), ["u1"])
    }
}

/// Ленты агентов живут в проекте (Ш6): одна модель на агента для панели и «Диалога», сон вместе с проектом,
/// ушедший агент ленту не держит.
extension ManagerThreadTests {
    private func status(_ m: ProjectModel, agents: [Agent]) -> TeamStatus {
        TeamStatus(project: "shop", repo: m.repo, session: "team-shop", sessionAlive: true, tracker: nil, agents: agents)
    }

    func testAgentThreadLivesInProjectAndSleepsWithIt() async throws {
        let cwd = "/work/shop-dev"
        let url = transcript("d1", cwd: cwd)
        try write(url, [owner("u1", "задача"), reply("a1", "делаю")])
        let m = try project(session: "s-none", cwd: "/work/shop")
        m.start()
        defer { m.stop() }
        let dev = Agent(name: "dev#1", role: "dev", sessionID: "d1", cwd: cwd)
        let thread = m.openAgentThread(dev)
        XCTAssertTrue(m.agentThread("dev#1") === thread, "панель и «Диалог» показывают одну модель")
        try await until("лента агента") { thread.feed.count == 2 }
        XCTAssertTrue(m.openAgentThread(dev) === thread)

        m.suspend()
        XCTAssertTrue(thread.isSuspended)
        XCTAssertFalse(m.hasLiveWatchers, "спящий проект не читает и транскрипты агентов")
        try append(url, [end("e1")])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(thread.feed.count, 2)
        m.resume()
        try await until("дописанное после возврата") { thread.feed.count == 3 }
    }

    func testOpenOnSleepingProjectSleepsAndGoneAgentIsDropped() async throws {
        let cwd = "/work/shop-dev"
        try write(transcript("d1", cwd: cwd), [owner("u1", "задача")])
        let m = try project(session: "s-none", cwd: "/work/shop")
        m.start()
        defer { m.stop() }
        let dev = Agent(name: "dev#1", role: "dev", sessionID: "d1", cwd: cwd)
        m.statusArrived(status(m, agents: [dev]))
        m.suspend()
        let thread = m.openAgentThread(dev)
        XCTAssertTrue(thread.isSuspended, "лента скрытого проекта сразу засыпает")
        m.resume()
        XCTAssertEqual(m.agentThreadCount, 1)
        m.statusArrived(status(m, agents: []))
        XCTAssertEqual(m.agentThreadCount, 0, "агента нет — ленты нет")
        XCTAssertFalse(thread.isRunning)
    }
}

/// Конец хода в транскрипте сам двигает очередь: удержанное (например, «Передать» с экрана агента при закрытом чате)
/// уходит в панель без участия вида.
@MainActor
private final class RecordingPane: ManagerPaneWriter {
    var messages: [String] = []
    func writeMessage(text: String, images: [URL], to pane: String) async throws { messages.append(text) }
    func sendKeys(_ keys: [String], to pane: String) async throws {}
    func sendLiteral(_ text: String, to pane: String) async throws {}
    func paneState(_ pane: String) -> ManagerPaneState { ManagerPaneState() }
}

extension ManagerThreadTests {
    func testHeldMessageLeavesWhenTranscriptEndsTurn() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        try write(url, [owner("u1", "сделай"), reply("a1", "делаю")])
        let m = try project(session: "s1", cwd: cwd)
        m.livePanes = { [PaneInfo(session: "team-shop", paneID: "%1", role: "boss", dead: false, pid: 1, path: cwd)] }
        let pane = RecordingPane()
        m.outbox.writer = pane
        m.start()
        defer { m.stop() }
        try await until("ход идёт") { m.managerBusy }
        m.outbox.send(text: ProjectModel.handoffRequest(for: "dev#1"), images: [])
        XCTAssertEqual(m.pending.first?.held, true)
        try append(url, [end("d1")])
        try await until("удержанное ушло после конца хода") { pane.messages.count == 1 }
        XCTAssertEqual(pane.messages, [ProjectModel.handoffRequest(for: "dev#1")])
    }

    /// Проект ушёл с экрана, а в очереди удержанное: читатель менеджера не спит, конец хода отпускает очередь (К1 цикла 2).
    /// Очередь опустела — читатель засыпает.
    func testHeldMessageLeavesWhileProjectHidden() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        try write(url, [owner("u1", "сделай"), reply("a1", "делаю")])
        let m = try project(session: "s1", cwd: cwd)
        m.livePanes = { [PaneInfo(session: "team-shop", paneID: "%1", role: "boss", dead: false, pid: 1, path: cwd)] }
        let pane = RecordingPane()
        m.outbox.writer = pane
        m.start()
        defer { m.stop() }
        try await until("ход идёт") { m.managerBusy }
        m.outbox.send(text: "после хода", images: [], fromField: true)
        m.suspend()
        XCTAssertFalse(m.managerThread.isSuspended, "с удержанным в очереди читатель менеджера не спит")
        try append(url, [end("d1")])
        try await until("удержанное ушло у скрытого проекта") { pane.messages == ["после хода"] }
        XCTAssertTrue(m.managerThread.isSuspended, "очередь опустела — читатель заснул")
    }

    /// Субагенты читает модель проекта: один опрос на проект, пока полоса на экране и проект выбран (В1 цикла 2).
    func testSubagentsPolledByProjectOnlyWhileActive() async throws {
        let cwd = "/work/shop"
        let url = transcript("s1", cwd: cwd)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let src = try XCTUnwrap(Bundle.module.url(forResource: "running", withExtension: nil, subdirectory: "Fixtures/subagents"))
        try fm.copyItem(at: src.appendingPathComponent("session.jsonl"), to: url)
        try fm.copyItem(at: src.appendingPathComponent("session"), to: url.deletingPathExtension())
        for case let f as URL in fm.enumerator(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)?.allObjects ?? [] {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        }
        let m = try project(session: "s1", cwd: cwd)
        m.start()
        defer { m.stop() }
        m.watchSubagents(sessionID: "s1", cwd: cwd, true)
        try await until("субагенты прочитаны") { m.subagents["s1"]?.running.count == 2 }
        m.suspend()
        XCTAssertFalse(m.hasLiveWatchers, "у невыбранного проекта опроса субагентов нет")
        m.resume()
        XCTAssertTrue(m.hasLiveWatchers)
        m.watchSubagents(sessionID: "s1", cwd: cwd, false)
        XCTAssertNil(m.subagents["s1"], "полоса ушла — данных и опроса нет")
    }

    /// Статус агента с открытой лентой меняется по её событию, в тот же момент, что лента, — не через 5 с опроса (В5).
    func testAgentStatusFollowsFeedEvent() async throws {
        let cwd = "/work/shop-dev"
        let url = transcript("d1", cwd: cwd)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = iso.string(from: Date())
        func rec(_ body: String) -> String { "{" + body + #","timestamp":"\#(now)"}"# }
        try write(url, [rec(#""type":"user","uuid":"u1","message":{"role":"user","content":"задача"}"#),
                        rec(#""type":"assistant","uuid":"a1","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"делаю"}]}"#)])
        let m = try project(session: "s-none", cwd: "/work/shop")
        m.start()
        defer { m.stop() }
        let dev = Agent(name: "dev#1", role: "dev", sessionID: "d1", cwd: cwd)
        let thread = m.openAgentThread(dev)
        m.statusArrived(status(m, agents: [dev]))
        try await until("ход идёт") { m.activity["dev#1"]?.inTurn == true }
        try await until("лента") { thread.feed.count == 2 }
        try append(url, [rec(#""type":"system","subtype":"turn_duration","durationMs":5,"uuid":"e1""#)])
        try await until("статус сменился по событию ленты", timeout: 2) { m.activity["dev#1"]?.inTurn == false }
        XCTAssertEqual(thread.feed.count, 3)
    }
}

