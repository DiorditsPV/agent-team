import XCTest
@testable import AgentTeamCore

func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

final class ContractTests: XCTestCase {
    func testStatus() throws {
        let s = try JSONDecoder().decode(TeamStatus.self, from: fixture("status.json"))
        XCTAssertEqual(s.session, "team-agent-team")
        XCTAssertNil(s.tracker)
        XCTAssertEqual(s.manager?.name, "manager#1")
        XCTAssertTrue(s.agents.allSatisfy { $0.name.contains("#") })
        let writer = try XCTUnwrap(s.agents.first { $0.role == "writer" })
        XCTAssertFalse(writer.alive)
        XCTAssertNil(writer.started)
        XCTAssertEqual(writer.branch, "team/writer")
    }

    func testNewContractFields() throws {
        let json = #"{"project":"p","repo":"/r","session":"team-p","session_alive":true,"agents":[{"name":"dev#1","task":"TASK-1","dirty":["a.swift","b.swift"]}]}"#
        let s = try JSONDecoder().decode(TeamStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.agents[0].task, "TASK-1")
        XCTAssertEqual(s.agents[0].dirty, ["a.swift", "b.swift"])
        let h = #"[{"id":"1-dev#1","agent":"dev#1","ts":1,"status":"used","used_at":5,"sections":{}}]"#
        XCTAssertEqual(try JSONDecoder().decode([Handoff].self, from: Data(h.utf8))[0].usedAt, 5)
    }

    func testTrackerAsStringObjectNullAndEmpty() throws {
        func status(_ tracker: String) throws -> TeamStatus {
            let json = #"{"project":"p","repo":"/r","session":"team-p","session_alive":true,\#(tracker.isEmpty ? "" : #""tracker":\#(tracker),"#)"agents":[]}"#
            return try JSONDecoder().decode(TeamStatus.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try status(#""linear""#).tracker, "linear")
        XCTAssertEqual(try status(#"{"kind":"linear","team":"PAV","limit":5}"#).tracker, "linear")      // объект из team.yaml
        XCTAssertNil(try status(#"{"team":"PAV"}"#).tracker)                                              // объект без kind
        XCTAssertNil(try status(#"{"kind":["a"]}"#).tracker)                                              // kind не строка
        XCTAssertNil(try status("null").tracker)
        XCTAssertNil(try status("{}").tracker)
        XCTAssertNil(try status("").tracker)                                                              // поля нет
        XCTAssertNil(try status(#""""#).tracker)                                                          // пустая строка
    }

    func testStatusToleratesMissingFields() throws {
        let json = #"{"project":"p","repo":"/r","session":"team-p","session_alive":false,"agents":[{"name":"dev#2"}]}"#
        let s = try JSONDecoder().decode(TeamStatus.self, from: Data(json.utf8))
        XCTAssertEqual(s.agents[0].role, "dev")
        XCTAssertFalse(s.agents[0].alive)
        XCTAssertFalse(s.agents[0].waitingHuman)
    }

    func testRolesAndUnreadableRole() throws {
        let roles = try JSONDecoder().decode([RoleInfo].self, from: fixture("roles.json"))
        XCTAssertEqual(roles.count, 4)
        let m = try XCTUnwrap(roles.first { $0.role == "manager" })
        XCTAssertEqual(m.running, 1)
        XCTAssertTrue(m.effectiveAllow.contains("Bash(git *)"))
        XCTAssertNil(m.worktree)
        let bad = #"[{"role":"broken","error":"не читается","zone":[],"includes":[],"allow":[],"effective_allow":[],"running":0}]"#
        let r = try JSONDecoder().decode([RoleInfo].self, from: Data(bad.utf8))
        XCTAssertEqual(r[0].error, "не читается")
        XCTAssertNil(r[0].title)
    }

    func testCheckEventsHandoffs() throws {
        let c = try JSONDecoder().decode(CheckReport.self, from: fixture("check.json"))
        XCTAssertEqual(c.passed, 11)
        let e = try JSONDecoder().decode([TeamEvent].self, from: fixture("events.json"))
        XCTAssertEqual(e.first?.type, "owner")
        XCTAssertNil(e.first?.task)
        let h = try JSONDecoder().decode([Handoff].self, from: fixture("handoffs.json"))
        XCTAssertEqual(h[0].sections.inProgress, "Сверка не начата.")
        XCTAssertFalse(h[0].isWaiting)
        XCTAssertTrue(h[1].isWaiting)
    }

    func testTeamYAMLSummary() {
        let y = """
        # комментарий
        project: agent-team
        layout: panes                  # роли панелями
        worktree_root: ../agent-team-wt
        manager: manager
        roles:
          - role: manager
            start: manual
          - role: developer
            start: always
        """
        let s = TeamYAMLSummary.parse(y)
        XCTAssertEqual(s.layout, "panes")
        XCTAssertEqual(s.manager, "manager")
        XCTAssertEqual(s.worktreeRoot, "../agent-team-wt")
        XCTAssertNil(s.tracker)
        XCTAssertEqual(s.starts, ["manager": "manual", "developer": "always"])
        let flow = TeamYAMLSummary.parse("roles:\n  - role: manager\n    start: manual\n  - {role: tester, start: on_demand}\n  - {role: \"qa\"}\n")
        XCTAssertEqual(flow.starts, ["manager": "manual", "tester": "on_demand"])
    }

    func testRoleNameAndToolRepo() {
        XCTAssertTrue(TeamCLI.validRoleName("app-dev_2"))
        XCTAssertFalse(TeamCLI.validRoleName("2dev"))
        XCTAssertFalse(TeamCLI.validRoleName("Dev"))
        XCTAssertEqual(ToolLocator.toolRepo(fromExecutable: "/a/b/agent-team/.venv/bin/team"), "/a/b/agent-team")
        XCTAssertNil(ToolLocator.toolRepo(fromExecutable: "/usr/local/bin/team"))
    }

    /// Вызов CLI через подставной исполняемый файл: приложение берёт JSON из stdout и ошибку из stderr.
    func testCLIInvocation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-cli-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("team")
        let status = String(decoding: try fixture("status.json"), as: UTF8.self)
        try """
        #!/bin/sh
        if [ "$1" = status ]; then cat <<'EOF'
        \(status)
        EOF
        else echo "team: error: argument cmd: invalid choice: '$1'" >&2; exit 2; fi
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = try XCTUnwrap(TeamCLI.resolve(toolPath: script.path))
        let s = try await cli.status(cwd: dir.path)
        XCTAssertEqual(s.agents.count, 4)
        do {
            _ = try await cli.roles(cwd: dir.path)
            XCTFail("ожидалась ошибка")
        } catch let TeamCLIError.failed(code, message) {
            XCTAssertEqual(code, 2)
            XCTAssertTrue(message.contains("invalid choice"))
        }
    }
}

final class CheckExitCodeTests: XCTestCase {
    /// check с ошибками: полный JSON в stdout и код 1 — отчёт разбирается; мусор с кодом 1 — ошибка со stderr.
    func testCheckReportWithExitCodeOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-check-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("team")
        try """
        #!/bin/sh
        if [ "$TEAM_FAKE" = garbage ]; then echo "Traceback" ; echo "boom" >&2; exit 1; fi
        echo '{"passed": 3, "issues": [{"level": "error", "title": "worktree developer", "detail": "не git-репозиторий"}]}'
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var cli = try XCTUnwrap(TeamCLI.resolve(toolPath: script.path))
        let report = try await cli.check(cwd: dir.path)
        XCTAssertEqual(report.passed, 3)
        XCTAssertEqual(report.problems.first?.level, "error")
        cli.environment["TEAM_FAKE"] = "garbage"
        do {
            _ = try await cli.check(cwd: dir.path)
            XCTFail("ожидалась ошибка")
        } catch let TeamCLIError.failed(code, message) {
            XCTAssertEqual(code, 1)
            XCTAssertEqual(message, "boom")
        }
    }
}

/// Действия над агентами уходят в CLI командами по контракту; ответ CLI — итогом действия.
final class ActionTests: XCTestCase {
    @MainActor
    func testActionsCallCLI() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-act-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.txt")
        let script = dir.appendingPathComponent("team")
        try """
        #!/bin/sh
        echo "$* | $TEAM_TMUX_SOCKET" >> '\(log.path)'
        case "$1" in
          status) echo '{"project":"p","repo":"/r","session":"team-p","session_alive":true,"agents":[{"name":"manager#1","kind":"manager"}]}' ;;
          roles|handoffs) echo '[]' ;;
          down) echo "team: агент не запущен" >&2; exit 1 ;;
          *) echo "$1: готово" ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let cli = try XCTUnwrap(AppModel.makeCLI(toolPath: script.path, socket: "agtest-sock"))
        let p = ProjectModel(repo: dir.path, session: "team-p", cli: cli, defaults: UserDefaults(suiteName: "agtest-\(getpid())")!)
        await p.spawn(role: "developer")
        XCTAssertEqual(p.lastActionMessage, "spawn: готово")
        await p.restart("developer#2", fresh: true)
        await p.down("developer#2")
        XCTAssertEqual(p.lastActionMessage, "team: агент не запущен")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("status") && !$0.hasPrefix("roles") && !$0.hasPrefix("handoffs") }
        XCTAssertEqual(calls, ["spawn developer | agtest-sock", "restart developer#2 --fresh | agtest-sock",
                               "down developer#2 | agtest-sock"])
        // Сообщение владельца в журнал: после «--», чтобы текст вида «--help» не стал флагом.
        p.forceStatus()
        for _ in 0..<30 where p.status?.manager == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(p.status?.manager?.name, "manager#1")
        p.logOwnerMessage("--help\nвторая строка")
        var logged = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? String(contentsOf: log, encoding: .utf8))?.contains("log owner manager#1 -- --help вторая строка | agtest-sock") == true { logged = true; break }
        }
        XCTAssertTrue(logged)
        XCTAssertEqual(ProjectModel.handoffRequest(for: "developer#2"),
                       "Подготовь передачу агента developer#2: team handoff developer#2, затем restart --fresh, когда файл заполнен.")
    }
}

final class StatusLoadingTests: XCTestCase {
    func makeCLI(_ body: String, in dir: URL) throws -> TeamCLI {
        let script = dir.appendingPathComponent("team")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return try XCTUnwrap(TeamCLI.resolve(toolPath: script.path))
    }

    func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-\(tag)-\(getpid())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Ждёт условие до срока: под нагрузкой запуск процесса занимает секунды, фиксированные паузы не годятся.
    @MainActor
    func waitUntil(timeout: TimeInterval = 20, _ condition: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Действие владельца во время идущей загрузки status не теряется: status перечитывается ещё раз.
    /// Загрузка держится файлом-воротами, а не временем: «во время загрузки» наступает по факту запуска скрипта.
    @MainActor
    func testForceStatusDuringLoadReloads() async throws {
        let dir = try tempDir("reload")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls")
        let gate = dir.appendingPathComponent("release")
        let cli = try makeCLI("""
        echo "$1" >> '\(log.path)'
        while [ ! -e '\(gate.path)' ]; do sleep 0.05; done
        echo '{"project":"p","repo":"/r","session":"team-p","session_alive":true,"agents":[]}'
        """, in: dir)
        let statusCalls = { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0 == "status" }.count }
        let p = ProjectModel(repo: dir.path, session: "team-p", cli: cli, defaults: UserDefaults(suiteName: "agtest-r-\(getpid())")!)
        p.forceStatus()
        try await waitUntil { statusCalls() >= 1 }
        XCTAssertEqual(statusCalls(), 1, "первая загрузка идёт и ждёт ворот")
        p.forceStatus()                       // во время первой загрузки
        FileManager.default.createFile(atPath: gate.path, contents: Data())
        try await waitUntil { statusCalls() >= 2 }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(statusCalls(), 2, "действие во время загрузки дало ровно одно повторное чтение")
    }

    /// Старый CLI (нет --json) отличается от сбоя нового: только у старого включается запасной путь.
    @MainActor
    func testLegacyCLIDetection() async throws {
        let dir = try tempDir("legacy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldDir = dir.appendingPathComponent("old"), brokenDir = dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
        let old = try makeCLI("echo \"team: error: unrecognized arguments: --json\" >&2; exit 2", in: oldDir)
        let p = ProjectModel(repo: dir.path, session: "team-p", cli: old, defaults: UserDefaults(suiteName: "agtest-l-\(getpid())")!)
        var called = false
        p.onLegacyCLI = { called = true }
        p.forceStatus()
        try await waitUntil { p.legacyCLI }
        XCTAssertTrue(p.legacyCLI)
        XCTAssertTrue(called)
        let broken = try makeCLI("echo \"team: нет agents/team.yaml\" >&2; exit 1", in: brokenDir)
        let q = ProjectModel(repo: dir.path, session: "team-q", cli: broken, defaults: UserDefaults(suiteName: "agtest-l2-\(getpid())")!)
        q.forceStatus()
        try await waitUntil { q.statusError != nil }
        XCTAssertNotNil(q.statusError)
        XCTAssertFalse(q.legacyCLI)
    }
}

final class TranscriptTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(TranscriptParser.projectSlug(cwd: "/Users/u/dev/shop/.worktrees/team-dev"), "-Users-u-dev-shop--worktrees-team-dev")
        XCTAssertEqual(TranscriptParser.projectSlug(cwd: "/a/agent-team-wt/app_dev"), "-a-agent-team-wt-app-dev")
    }

    func testKinds() throws {
        let text = String(decoding: try fixture("transcript.jsonl"), as: UTF8.self)
        var p = TranscriptParser()
        p.feed(lines: text.split(separator: "\n"))
        let kinds = p.entries.map(\.kind)
        XCTAssertEqual(kinds, [
            .owner("вливай 52 и 53 в тестовую линию"),
            .sendMessage(to: "uds:/tmp/cc-socks/24217.sock", text: "TASK-436: откат хранилища.\nВторая строка"),
            .tracker(action: "save_comment", summary: "TASK-436"),
            .reply("**Итог.** Влил.\n\n- первое\n- второе"),
            .turnEnd(durationMs: 10400),
            .incoming(fromName: "Разработчик", fromAddr: "uds:/tmp/cc-socks/24217.sock", text: "Беру TASK-449."),
            .invoked(name: "/clear", args: ""),         // вызов команды: в ленте не показывается, снимает карточку команды
            .incoming(fromName: "Разработчик", fromAddr: "uds:/tmp/cc-socks/24217.sock", text: "Готово, коммит 1a2b3c."),
            .owner("и ещё проверь тесты"),
        ])
        XCTAssertEqual(p.usage?.contextTokens, 130_002)
        XCTAssertEqual(p.usage?.contextPercent, 13)
        XCTAssertEqual(p.usage?.displayModel, "Opus 5.5")
        XCTAssertTrue(p.turnInProgress)
    }

    /// Файла и даже каталога ещё нет: хвост дожидается их по kqueue, без таймера.
    func testTailWaitsForMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-wait-\(getpid())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(".team/events.jsonl")
        let got = LockedArray()
        let arrived = expectation(description: "строка из появившегося файла")
        let tail = JSONLTail(url: url)
        tail.start { lines in
            got.append(lines.map(String.init))
            arrived.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.3)
        try Data("{\"ts\":1}\n".utf8).write(to: url)
        wait(for: [arrived], timeout: 3)
        tail.stop()
        XCTAssertEqual(got.all, ["{\"ts\":1}"])
    }

    func testServiceTextsAsCompactLines() {
        var p = TranscriptParser()
        let lines = [
            #"{"type":"user","uuid":"s1","message":{"role":"user","content":"<task-notification>\n<task-id>a1</task-id>\n<summary>Agent \"Сборка\" finished</summary>\n</task-notification>"}}"#,
            #"{"type":"user","uuid":"s2","message":{"role":"user","content":"<system-reminder>\nНапомнить про выкладку в 9:23\n</system-reminder>"}}"#,
            #"{"type":"assistant","uuid":"s3","message":{"model":"claude-opus-5-5","id":"m9","role":"assistant","content":[{"type":"tool_use","id":"t9","name":"CronDelete","input":{"id":"ef1f659d"}}]}}"#,
            #"{"type":"user","uuid":"s4","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
        ]
        p.feed(lines: lines.map { Substring($0) })
        XCTAssertEqual(p.entries.map(\.kind), [
            .tool(name: "уведомление", summary: "Agent \"Сборка\" finished"),
            .tool(name: "напоминание", summary: "Напомнить про выкладку в 9:23"),
            .tool(name: "напоминание снято", summary: "ef1f659d"),
            .invoked(name: "/clear", args: ""),         // вызов команды: в ленте не показывается
        ])
    }

    func testOpenOwnerWaits() {
        let evs = [
            TeamEvent(ts: 50, type: "report", agent: "dev#1", text: "готово", task: "TASK-2"),
            TeamEvent(ts: 40, type: "waiting", agent: "manager#1", text: "TASK-2: слияние по слову", task: "TASK-2"),
            TeamEvent(ts: 30, type: "waiting", agent: "manager#1", text: "TASK-1: слияние по слову", task: "TASK-1"),
            TeamEvent(ts: 20, type: "owner", agent: "owner", text: "вливай", task: "TASK-3"),
            TeamEvent(ts: 10, type: "waiting", agent: "manager#1", text: "TASK-3", task: "TASK-3"),
        ]
        XCTAssertEqual(ProjectModel.openWaits(evs).map(\.task), ["TASK-1"])
    }

    func testIncrementalTailOfFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-tail-\(getpid())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("t.jsonl")
        try Data("{\"a\":1}\n{\"a\":2".utf8).write(to: url)
        let got = LockedArray()
        let first = expectation(description: "первая строка")
        let second = expectation(description: "дописанная строка")
        let tail = JSONLTail(url: url)
        tail.start { lines in
            got.append(lines.map(String.init))
            if got.count == 1 { first.fulfill() }
            if got.count == 2 { second.fulfill() }
        }
        wait(for: [first], timeout: 3)
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data("}\n{\"a\":3}\n".utf8))
        try fh.close()
        wait(for: [second], timeout: 3)
        tail.stop()
        XCTAssertEqual(got.all, ["{\"a\":1}", "{\"a\":2}", "{\"a\":3}"])
    }
}

final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var batches = 0
    func append(_ xs: [String]) { lock.withLock { items += xs; batches += 1 } }
    var count: Int { lock.withLock { batches } }
    var all: [String] { lock.withLock { items } }
}

/// «Состав» показывает имя трекера, а не сырой flow-объект из team.yaml.
final class TeamYAMLTrackerTests: XCTestCase {
    func testTrackerFlowObjectShowsKind() {
        XCTAssertEqual(TeamYAMLSummary.parse("tracker: {kind: linear}\n").tracker, "linear")
        XCTAssertEqual(TeamYAMLSummary.parse("tracker: {kind: linear, project: Demo}\n").tracker, "linear")
        XCTAssertEqual(TeamYAMLSummary.parse("tracker: { project: Demo, kind: \"jira\" }\n").tracker, "jira")
        XCTAssertNil(TeamYAMLSummary.parse("tracker: {project: Demo}\n").tracker, "объект без kind — трекер не задан")
    }

    func testTrackerStringAndBlockObject() {
        XCTAssertEqual(TeamYAMLSummary.parse("tracker: linear\n").tracker, "linear")
        XCTAssertEqual(TeamYAMLSummary.parse("tracker:\n  kind: linear\n  project: Demo\nlayout: panes\n").tracker, "linear")
        let s = TeamYAMLSummary.parse("tracker:\n  project: Demo\nlayout: panes\nroles:\n  - role: a\n    kind: manager\n")
        XCTAssertNil(s.tracker, "kind роли не принимается за трекер")
        XCTAssertEqual(s.layout, "panes")
    }
}
