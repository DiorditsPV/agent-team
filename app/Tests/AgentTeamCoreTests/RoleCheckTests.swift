import XCTest
@testable import AgentTeamCore

/// Поле `role_check` из `team status --json`: разбор и удержание записи в панель менеджера, пока в ней не сессия роли.
@MainActor
final class RoleCheckTests: XCTestCase {
    private func status(_ agents: String) throws -> TeamStatus {
        let json = #"{"project":"shop","repo":"/tmp/shop","session":"team-shop","session_alive":true,"tracker":null,"agents":["#
            + agents + "]}"
        return try JSONDecoder().decode(TeamStatus.self, from: Data(json.utf8))
    }

    private func agent(_ name: String, kind: String = "executor", check: String?) -> String {
        let field = check.map { #","role_check":"# + $0 } ?? ""
        return #"{"name":"\#(name)","role":"\#(name.split(separator: "#")[0])","kind":"\#(kind)","alive":true,"pane_id":"%1"\#(field)}"#
    }

    // MARK: разбор

    func testAbsentAndNullGiveNoCheck() throws {
        let s = try status(agent("developer#1", check: nil) + "," + agent("developer#2", check: "null"))
        XCTAssertNil(s.agents[0].roleCheck, "у старого CLI поля нет")
        XCTAssertNil(s.agents[1].roleCheck, "null — агента нет")
        XCTAssertFalse(s.agents[0].notRole)
        XCTAssertFalse(s.agents[1].notRole)
    }

    func testOkTrueAndOkNullAreNotAlerts() throws {
        let s = try status(agent("developer#1", check: #"{"ok":true,"reason":null,"pid":10,"pane_pid":10,"job_id":null,"session_id":"s1"}"#)
                           + "," + agent("developer#2", check: #"{"ok":null,"reason":null,"pid":null,"pane_pid":11,"job_id":null,"session_id":null}"#))
        XCTAssertEqual(s.agents[0].roleCheck?.ok, true)
        XCTAssertEqual(s.agents[0].roleCheck?.sessionID, "s1")
        XCTAssertFalse(s.agents[0].notRole)
        XCTAssertNotNil(s.agents[1].roleCheck)
        XCTAssertNil(s.agents[1].roleCheck?.ok, "нет данных")
        XCTAssertEqual(s.agents[1].roleCheck?.panePID, 11)
        XCTAssertFalse(s.agents[1].notRole, "ok null — без алерта")
    }

    func testBackgroundReasonWithJob() throws {
        let s = try status(agent("manager#1", kind: "manager",
                                 check: #"{"ok":false,"reason":"background","pid":4242,"pane_pid":100,"job_id":"j-7","session_id":"s2"}"#))
        let c = try XCTUnwrap(s.agents[0].roleCheck)
        XCTAssertTrue(s.agents[0].notRole)
        XCTAssertEqual(c.jobID, "j-7")
        XCTAssertEqual(c.pid, 4242)
        XCTAssertEqual(c.panePID, 100)
        XCTAssertEqual(c.reasonText, "разговор ушёл в фоновую задачу Claude Code (задача j-7, pid 4242), у неё нет промпта роли")
        XCTAssertEqual(c.mark, "в фоне")
    }

    func testOtherProcessAndNoRolePrompt() throws {
        let s = try status(agent("developer#1", check: #"{"ok":false,"reason":"other_process","pid":77}"#)
                           + "," + agent("developer#2", check: #"{"ok":false,"reason":"no_role_prompt","pid":null}"#))
        XCTAssertEqual(s.agents[0].roleCheck?.reasonText, "разговор ведёт другой процесс, pid 77, не запущенный team")
        XCTAssertEqual(s.agents[0].roleCheck?.mark, "чужой процесс")
        XCTAssertEqual(s.agents[1].roleCheck?.reasonText, "процесс панели запущен без файла роли")
        XCTAssertEqual(s.agents[1].roleCheck?.mark, "без роли")
    }

    func testUnknownReasonAndOddValuesDoNotBreakStatus() throws {
        // Неизвестная причина, pid строкой, ok не логическое: status разбирается, агент не теряется.
        let s = try status(agent("developer#1", check: #"{"ok":false,"reason":"new_kind","pid":"55"}"#)
                           + "," + agent("developer#2", check: #"{"ok":"yes"}"#)
                           + "," + agent("developer#3", check: #""broken""#))
        XCTAssertEqual(s.agents.count, 3)
        XCTAssertEqual(s.agents[0].roleCheck?.reasonText, "причина «new_kind»")
        XCTAssertEqual(s.agents[0].roleCheck?.mark, "не роль")
        XCTAssertEqual(s.agents[0].roleCheck?.pid, 55)
        XCTAssertNil(s.agents[1].roleCheck?.ok, "непонятное ok — нет данных, не тревога")
        XCTAssertFalse(s.agents[1].notRole)
        XCTAssertNil(s.agents[2].roleCheck)
    }

    func testRoleCheckSurvivesEncodeDecode() throws {
        let s = try status(agent("manager#1", kind: "manager", check: #"{"ok":false,"reason":"background","job_id":"j1"}"#))
        let back = try JSONDecoder().decode(TeamStatus.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.agents[0].roleCheck, s.agents[0].roleCheck)
    }

    func testNotRoleAgentsManagerFirst() throws {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-rolecheck", session: "team-shop", cli: nil)
        m.statusArrived(try status(agent("developer#1", check: #"{"ok":false,"reason":"no_role_prompt"}"#)
                                   + "," + agent("reviewer#1", check: #"{"ok":true}"#)
                                   + "," + agent("manager#1", kind: "manager", check: #"{"ok":false,"reason":"background"}"#)))
        XCTAssertEqual(m.notRoleAgents.map(\.name), ["manager#1", "developer#1"])
        XCTAssertTrue(m.managerNotRole)
    }

    // MARK: очередь

    private var pane: RolePane!

    private func model() -> ProjectModel {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-rolehold", session: "team-shop", cli: nil)
        m.livePanes = { [PaneInfo(session: "team-shop", paneID: "%1", role: "manager", dead: false, pid: 1, path: "/tmp")] }
        pane = RolePane()
        m.outbox.writer = pane
        m.outbox.commandSettle = 0
        m.outbox.commandPoll = 0.01
        return m
    }

    private func managerStatus(_ check: String) throws -> TeamStatus { try status(agent("manager#1", kind: "manager", check: check)) }
    private let background = #"{"ok":false,"reason":"background","job_id":"j1"}"#

    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 50_000_000) }

    func testManagerNotRoleHoldsSendAndFlushUntilRestored() async throws {
        let m = model()
        m.statusArrived(try managerStatus(background))
        XCTAssertTrue(m.outbox.send(text: "первое", images: [], fromField: true), "сообщение принято в очередь, не потеряно")
        await settle()
        XCTAssertEqual(pane.messages, [], "в панель без сессии роли ничего не пишется")
        XCTAssertEqual(m.heldCount, 1)
        XCTAssertEqual(m.pending.first.flatMap { m.outbox.holdReason($0) }, ManagerOutbox.roleHoldReason)

        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, [], "flush тоже стоит")

        // ok null — нет данных: это не тревога, очередь трогается сама.
        m.statusArrived(try managerStatus(#"{"ok":null}"#))
        await settle()
        XCTAssertEqual(pane.messages, ["первое"], "сессия роли вернулась — удержанное ушло без нового действия")
        XCTAssertEqual(m.heldCount, 0)
    }

    func testSendNowInterruptAndTypeIntoLineWriteNothing() async throws {
        let m = model()
        m.statusArrived(try managerStatus(background))
        m.managerBusy = true
        pane.state.turnRunning = true
        m.outbox.send(text: "срочно", images: [])
        let id = try XCTUnwrap(m.pending.first?.id)
        m.outbox.sendNow(id)
        XCTAssertFalse(m.outbox.interrupt(requireTurn: true))
        XCTAssertFalse(m.outbox.escapeAllowed)
        m.outbox.typeIntoLine("/model")
        await settle()
        XCTAssertEqual(pane.keys, [], "ни Esc «↑ сейчас», ни «Стоп»")
        XCTAssertEqual(pane.literals, [])
        XCTAssertEqual(pane.messages, [])
        XCTAssertEqual(m.heldCount, 1)
    }

    func testQuitDoesNotDumpQueueIntoForeignSession() async throws {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "в очереди", images: [])
        m.statusArrived(try managerStatus(background))
        let sent = await m.outbox.sendAllHeld()
        XCTAssertFalse(sent)
        XCTAssertEqual(pane.messages, [])
        XCTAssertEqual(m.outbox.error, "Очередь team-shop не отправлена: " + ManagerOutbox.roleHoldReason)
        XCTAssertEqual(m.heldCount, 1, "неотправленное остаётся в очереди")
    }

    func testStatusFlipDuringDeliveryHoldsAgain() async throws {
        let m = model()
        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        // Свежий захват снимается асинхронно: за это время status успевает показать чужую сессию.
        pane.onFresh = { [unowned m] in m.statusArrived(try! self.managerStatus(self.background)) }
        m.outbox.send(text: "между захватом и записью", images: [])
        await settle()
        XCTAssertEqual(pane.messages, [])
        XCTAssertEqual(m.heldCount, 1, "сообщение снова ждёт")
        pane.onFresh = nil
        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        await settle()
        XCTAssertEqual(pane.messages, ["между захватом и записью"])
    }

    func testQueueWaitsForFirstStatus() async throws {
        let m = model()
        m.cli = TeamCLI(executable: "/nonexistent/team")
        XCTAssertTrue(m.awaitingFirstStatus)
        m.outbox.send(text: "до status", images: [])
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, [], "до первой проверки роли в панель не пишется")
        XCTAssertEqual(m.pending.first.flatMap { m.outbox.holdReason($0) }, ManagerOutbox.statusHoldReason)

        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        await settle()
        XCTAssertEqual(pane.messages, ["до status"], "первый status с сессией роли отпускает очередь")
    }

    func testQueueWaitsForFirstStatusThatShowsForeignSession() async throws {
        let m = model()
        m.cli = TeamCLI(executable: "/nonexistent/team")
        m.outbox.send(text: "до status", images: [])
        m.statusArrived(try managerStatus(background))
        await settle()
        XCTAssertEqual(pane.messages, [], "первый status показал чужую сессию — очередь стоит дальше")
        XCTAssertEqual(m.pending.first.flatMap { m.outbox.holdReason($0) }, ManagerOutbox.roleHoldReason)
    }

    /// Подставной team: пишет аргументы в журнал; restart идёт 0,3 с и завершается с заданным кодом.
    private func fakeTeam(restartExit: Int) throws -> (TeamCLI, String) {
        let dir = NSTemporaryDirectory() + "agtest-role-restore-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // team запускается в каталоге проекта.
        try FileManager.default.createDirectory(atPath: NSTemporaryDirectory() + "agtest-rolehold", withIntermediateDirectories: true)
        let log = dir + "/calls.log"
        let script = dir + "/team"
        let body = """
        #!/bin/sh
        case "$1" in
          restart) echo "$@" >> "\(log)"; sleep 0.3
                   [ \(restartExit) -eq 0 ] && { echo "окно developer#2 поднято"; echo "developer#2: разговор роли в панели"; exit 0; }
                   echo "team: в панели идёт фоновая задача, restart её не трогает" >&2; exit \(restartExit);;
        esac
        exit 1
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (TeamCLI(executable: script, environment: ProcessInfo.processInfo.environment), log)
    }

    private let devNoRole = #"{"ok":false,"reason":"no_role_prompt"}"#

    func testRestoreRoleRunsRestartAndShowsResult() async throws {
        let m = model()
        let (cli, log) = try fakeTeam(restartExit: 0)
        m.cli = cli
        m.statusArrived(try status(agent("developer#2", check: devNoRole)))
        let run = Task { await m.restoreRole("developer#2") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(m.busyActions.contains("restart:developer#2"), "кнопка знает, что restart идёт")
        await run.value
        XCTAssertEqual(try String(contentsOfFile: log, encoding: .utf8), "restart developer#2\n", "restart без --fresh")
        XCTAssertEqual(m.roleRestore["developer#2"], RoleRestore(ok: true, message: "developer#2: разговор роли в панели"))
        XCTAssertFalse(m.busyActions.contains("restart:developer#2"))

        // Роль вернулась — итог снимается: потеряй агент роль снова, плашка не покажет старое «выполнено».
        m.statusArrived(try status(agent("developer#2", check: #"{"ok":true}"#)))
        XCTAssertNil(m.roleRestore["developer#2"])
    }

    func testRestoreRoleFailureShowsCLIError() async throws {
        let m = model()
        let (cli, _) = try fakeTeam(restartExit: 1)
        m.cli = cli
        m.statusArrived(try status(agent("developer#2", check: devNoRole)))
        await m.restoreRole("developer#2")
        XCTAssertEqual(m.roleRestore["developer#2"],
                       RoleRestore(ok: false, message: "team: в панели идёт фоновая задача, restart её не трогает"))
        m.statusArrived(try status(agent("developer#2", check: devNoRole)))
        XCTAssertNotNil(m.roleRestore["developer#2"], "пока роли нет, ошибка видна на плашке")
    }

    /// Подставной team, чей ответ status меняется: файл status.json пишет тест. Каждый вызов — строка в журнале.
    private func liveTeam() throws -> (TeamCLI, status: String, log: String) {
        let dir = NSTemporaryDirectory() + "agtest-role-fresh-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: NSTemporaryDirectory() + "agtest-rolehold", withIntermediateDirectories: true)
        let status = dir + "/status.json", log = dir + "/calls.log", script = dir + "/team"
        let body = """
        #!/bin/sh
        echo "$@" >> "\(log)"
        [ "$1" = status ] && { cat "\(status)"; exit 0; }
        exit 1
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (TeamCLI(executable: script, environment: ProcessInfo.processInfo.environment), status, log)
    }

    private func writeStatus(_ path: String, manager check: String) throws {
        let json = #"{"project":"shop","repo":"/tmp/shop","session":"team-shop","session_alive":true,"tracker":null,"agents":["#
            + agent("manager#1", kind: "manager", check: check) + "]}"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Вызовы status (запись в журнал команды `team log` — отдельный вызов, его не считаем).
    private func calls(_ log: String) -> Int {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("status") }.count
    }

    func testRoleGoneToBackgroundBetweenPollsHoldsWrite() async throws {
        // Последний опрос видел сессию роли; до следующего разговор ушёл в фон. Запись подтверждает роль свежим status.
        let m = model()
        let (cli, statusFile, log) = try liveTeam()
        m.cli = cli
        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        XCTAssertFalse(m.managerWriteHeld, "по последнему опросу писать можно")
        try writeStatus(statusFile, manager: background)

        m.outbox.send(text: "в разговор без роли", images: [])
        let held = await waitHeld(m)
        XCTAssertTrue(held)
        XCTAssertEqual(pane.messages, [], "свежий status показал фон — в панель не пишется")
        XCTAssertTrue(m.managerNotRole)
        XCTAssertEqual(m.heldCount, 1)
        XCTAssertEqual(calls(log), 1, "один вызов status перед записью")

        // Роль вернули: следующий status отпускает очередь, запись снова подтверждается.
        try writeStatus(statusFile, manager: #"{"ok":true}"#)
        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        let sent = await waitSent(m, ["в разговор без роли"])
        XCTAssertTrue(sent)
        XCTAssertEqual(calls(log), 2)
    }

    func testFreshCheckBeforeSendNowEsc() async throws {
        let m = model()
        let (cli, statusFile, _) = try liveTeam()
        m.cli = cli
        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        m.managerBusy = true
        pane.state.turnRunning = true
        m.outbox.send(text: "срочно", images: [])
        try writeStatus(statusFile, manager: background)
        m.outbox.sendNow(try XCTUnwrap(m.pending.first?.id))
        let held = await waitHeld(m)
        XCTAssertTrue(held)
        XCTAssertEqual(pane.keys, [], "Esc не ушёл в сессию без роли")
        XCTAssertEqual(pane.messages, [])
    }

    func testSignalExitDoesNotWaitForFreshStatus() async throws {
        // Выход по сигналу со сроком: свежего status нет, решает последний ответ.
        let m = model()
        let (cli, statusFile, log) = try liveTeam()
        m.cli = cli
        try writeStatus(statusFile, manager: background)
        m.managerBusy = true
        m.outbox.send(text: "до первого status", images: [])
        let unconfirmed = await m.outbox.sendAllHeld(freshRole: false)
        XCTAssertFalse(unconfirmed, "роль ещё не подтверждалась — в панель не пишется, удержанное вернётся в черновик")
        XCTAssertEqual(pane.messages, [])

        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        let sent = await m.outbox.sendAllHeld(freshRole: false)
        XCTAssertTrue(sent)
        XCTAssertEqual(pane.messages, ["до первого status"], "последний ответ — сессия роли")
        XCTAssertEqual(calls(log), 0, "status при выходе по сигналу не вызывался")
    }

    func testIdleQueueDoesNotCallStatus() async throws {
        // В простое (очередь пуста) свежих проверок нет: вызов status — только перед записью.
        let m = model()
        let (cli, _, log) = try liveTeam()
        m.cli = cli
        m.statusArrived(try managerStatus(#"{"ok":true}"#))
        m.outbox.flush()
        await settle()
        XCTAssertEqual(calls(log), 0)
    }

    private func waitHeld(_ m: ProjectModel) async -> Bool {
        for _ in 0..<100 {
            if !m.outbox.sending, m.heldCount == 1 { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func waitSent(_ m: ProjectModel, _ expected: [String]) async -> Bool {
        for _ in 0..<100 {
            if pane.messages == expected { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testAgentNotRoleDoesNotHoldManagerQueue() async throws {
        let m = model()
        m.statusArrived(try status(agent("manager#1", kind: "manager", check: #"{"ok":true}"#)
                                   + "," + agent("developer#1", check: #"{"ok":false,"reason":"no_role_prompt"}"#)))
        XCTAssertFalse(m.managerNotRole)
        m.outbox.send(text: "менеджеру", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["менеджеру"], "чужая сессия в панели агента не держит очередь менеджера")
    }
}

/// Подставная панель менеджера: что в неё ушло и какое у неё состояние.
@MainActor
private final class RolePane: ManagerPaneWriter {
    var messages: [String] = []
    var keys: [[String]] = []
    var literals: [String] = []
    var state = ManagerPaneState()
    var onFresh: (() -> Void)?

    func writeMessage(text: String, images: [URL], to pane: String) async throws { messages.append(text) }
    func sendKeys(_ keys: [String], to pane: String) async throws { self.keys.append(keys) }
    func sendLiteral(_ text: String, to pane: String) async throws { literals.append(text) }
    func paneState(_ pane: String) -> ManagerPaneState { state }
    func freshPaneState(_ pane: String) async -> ManagerPaneState { onFresh?(); return state }
}
