import XCTest
@testable import AgentTeamCore

/// Приложение, открытое из Dock: без LANG и LC_*, с урезанным PATH. Сервер tmux — отдельный (`-L agtest-*`).
final class LaunchEnvironmentTests: XCTestCase {
    var tmux = ""
    var socket = ""
    /// Окружение как у процесса из launchd: без локали.
    var bare: [String: String] = [:]

    override func setUpWithError() throws {
        tmux = try XCTUnwrap(ToolLocator.find("tmux"), "нужен tmux")
        socket = "agtest-\(getpid())-\(Int.random(in: 0..<100_000))"
        bare = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]
        if let t = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] { bare["TMUX_TMPDIR"] = t }
    }

    override func tearDown() {
        _ = try? tmuxRun(["kill-server"])
        try? FileManager.default.removeItem(atPath: TmuxHub.socketDirectory(environment: bare) + "/" + socket)
    }

    @discardableResult
    func tmuxRun(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-L", socket, "-f", "/dev/null"] + args
        p.environment = bare
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func listPanes(forceUTF8: Bool) async throws -> [PaneInfo] {
        let c = ControlClient(tmuxPath: tmux, socketName: socket, environment: bare, forceUTF8: forceUTF8)
        try c.start(session: "team-x", onEvent: { _ in }, onExit: {})
        defer { c.stop() }
        return TmuxListing.parsePanes(try await c.run(TmuxListing.listPanesCommand))
    }

    /// Без LANG tmux заменяет табуляцию и кириллицу на `_`; `-u` возвращает UTF-8 независимо от локали.
    func testControlClientParsesCyrillicRoleWithoutLocale() async throws {
        XCTAssertNil(bare["LANG"])
        XCTAssertFalse(bare.keys.contains { $0.hasPrefix("LC_") })
        try tmuxRun(["new-session", "-d", "-s", "team-x", "-c", "/tmp", "sh"])
        try tmuxRun(["set-option", "-p", "-t", "team-x:0.0", "@team_role", "разработчик#1"])

        let panes = try await listPanes(forceUTF8: true)
        XCTAssertEqual(panes.count, 1)
        XCTAssertEqual(panes.first?.role, "разработчик#1")
        XCTAssertEqual(panes.first?.session, "team-x")

        // Та же команда без -u: строка не разбирается — это и видел владелец («0 агентов»).
        let broken = try await listPanes(forceUTF8: false)
        XCTAssertTrue(broken.isEmpty || broken.first?.role != "разработчик#1")
    }

    /// Хаб без локали в окружении видит панели с кириллицей (разовый list-sessions и канал control mode).
    @MainActor
    func testHubWithoutLocaleSeesAgents() async throws {
        try tmuxRun(["new-session", "-d", "-s", "team-x", "-c", "/tmp", "sh"])
        try tmuxRun(["set-option", "-p", "-t", "team-x:0.0", "@team_role", "менеджер#1"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        hub.environmentOverride = bare
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        XCTAssertEqual(hub.attachedSession, "team-x")
        XCTAssertEqual(hub.panes.map(\.role), ["менеджер#1"])
        XCTAssertEqual(hub.agentCounts["team-x"], 1)
    }
}

/// «Поднять команду» из приложения: `team up` на тестовом сервере с подменой claude.
///
/// Инструмент — из AGENT_TEAM_TOOL (каталог клона или исполняемый team), иначе из репозитория, в котором лежит
/// пакет приложения. Каталог сокетов tmux (TMUX_TMPDIR) — временный, поэтому живой сервер владельца не задевается,
/// даже если инструмент не знает TEAM_TMUX_SOCKET; тогда тест пропускается.
final class TeamUpTests: XCTestCase {
    var tmux = ""
    var socket = ""
    var tmp = ""
    var savedEnv: [String: String?] = [:]

    override func setUpWithError() throws {
        tmux = try XCTUnwrap(ToolLocator.find("tmux"), "нужен tmux")
        socket = "agtest-\(getpid())-\(Int.random(in: 0..<100_000))"
        // Короткий путь: у сокета Unix предел длины около 104 байт.
        var template = Array("/tmp/agt-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw XCTSkip("mkdtemp не удался") }
        tmp = String(cString: made)
    }

    override func tearDown() {
        let env = ["TMUX_TMPDIR": tmp, "PATH": ToolLocator.searchPath.joined(separator: ":")]
        for label in [socket, "default"] { run(tmux, ["-L", label, "kill-server"], env: env) }
        for (k, v) in savedEnv {
            if let v { setenv(k, v, 1) } else { unsetenv(k) }
        }
        savedEnv = [:]
        if tmp.hasPrefix("/tmp/agt-") { try? FileManager.default.removeItem(atPath: tmp) }
    }

    func setEnv(_ k: String, _ v: String) {
        if savedEnv[k] == nil { savedEnv[k] = .some(ProcessInfo.processInfo.environment[k]) }
        setenv(k, v, 1)
    }

    @discardableResult
    func run(_ exe: String, _ args: [String], env: [String: String]? = nil, cwd: String? = nil) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let env { p.environment = env }
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Инструмент team для теста или nil.
    func toolPath() -> String? {
        if let t = ProcessInfo.processInfo.environment["AGENT_TEAM_TOOL"], !t.isEmpty { return t }
        // app/Tests/AgentTeamCoreTests/<файл> → корень репозитория.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        return FileManager.default.fileExists(atPath: root + "/pyproject.toml") ? root : nil
    }

    func makeProject(name: String) throws -> String {
        let repo = tmp + "/proj"
        let fm = FileManager.default
        try fm.createDirectory(atPath: repo + "/agents/roles", withIntermediateDirectories: true)
        try """
        project: \(name)
        worktree_root: ../wt
        layout: panes
        manager: boss
        roles:
          - {role: boss, start: manual}
          - {role: worker, start: always}
        """.write(toFile: repo + "/agents/team.yaml", atomically: true, encoding: .utf8)
        try "---\nrole: boss\ntitle: Менеджер\nkind: manager\n---\nТы менеджер.\n"
            .write(toFile: repo + "/agents/roles/boss.md", atomically: true, encoding: .utf8)
        try "---\nrole: worker\ntitle: Исполнитель\nkind: executor\nworktree: {dir: worker, branch: worker}\n---\nТы исполнитель.\n"
            .write(toFile: repo + "/agents/roles/worker.md", atomically: true, encoding: .utf8)
        let git = ToolLocator.find("git") ?? "/usr/bin/git"
        let id = ["-c", "user.name=t", "-c", "user.email=t@t"]
        guard run(git, ["init", "-q", "-b", "main", repo]) == 0,
              run(git, ["-C", repo] + id + ["add", "-A"]) == 0,
              run(git, ["-C", repo] + id + ["commit", "-qm", "init"]) == 0 else { throw XCTSkip("git не создал репозиторий") }
        return repo
    }

    @MainActor
    func testTeamUpFromAppOnTestSocket() async throws {
        guard let tool = toolPath() else { throw XCTSkip("нет инструмента team: задайте AGENT_TEAM_TOOL") }
        // Всё, что поднимет team, — во временном каталоге сокетов и без сети.
        setEnv("TMUX_TMPDIR", tmp)
        setEnv("UV_OFFLINE", "1")
        setEnv("UV_PROJECT_ENVIRONMENT", tmp + "/venv")
        // Подмена claude: через полторы секунды — вопрос о доверии, как у новой сессии в незнакомой папке.
        setEnv("TEAM_CLAUDE_BIN", "sh -c 'sleep 1.5; echo \"Do you trust the files in this folder?\"; exec cat'")

        let name = "agt\(Int.random(in: 0..<100_000))"
        let repo = try makeProject(name: name)
        let session = "team-" + name
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        defaults.set(tool, forKey: "toolPath")
        let app = AppModel(defaults: defaults, socketName: socket, loginEnvironment: false)
        await app.loadEnvironment()
        XCTAssertNotNil(app.cli, "team не найден: \(tool)")
        XCTAssertTrue(app.addProject(repo: repo))
        XCTAssertEqual(app.projects.first { $0.session == session }?.running, false)
        defer { app.hub.disconnect() }

        let ok = await app.up(repo: repo)
        let socketDir = TmuxHub.socketDirectory(environment: ["TMUX_TMPDIR": tmp])
        if FileManager.default.fileExists(atPath: socketDir + "/default") {
            throw XCTSkip("инструмент \(tool) не знает TEAM_TMUX_SOCKET: сессия поднялась на сервере по умолчанию во временном каталоге")
        }
        XCTAssertTrue(ok, app.project?.lastActionMessage ?? "")

        // Проект открывается, когда появилась сессия: хаб прикреплён к ней, агенты видны.
        let attached = await waitFor(10) { app.hub.attachedSession == session }
        XCTAssertTrue(attached, "сессия не появилась: \(app.hub.sessions)")
        XCTAssertEqual(app.selectedSession, session)
        XCTAssertEqual(app.projects.first { $0.session == session }?.running, true)
        // Хаб мог прикрепиться по kqueue ещё на первой панели: вторая приходит уведомлением о раскладке.
        let both = await waitFor(5) { Set(app.hub.panes.filter { $0.session == session }.map(\.role)) == ["boss#1", "worker#1"] }
        XCTAssertTrue(both, "панели: \(app.hub.panes.map(\.role)); team up: \(app.project?.lastActionMessage ?? "")")

        // Вопрос о доверии у скрытых панелей (ни одна не показана на экране) попадает в признак «ждёт человека».
        let manager = try XCTUnwrap(app.hub.livePane(session: session, role: "boss"))
        let asked = await waitFor(10) { app.hub.output(for: manager).asksTrust }
        XCTAssertTrue(asked, "вопрос о доверии менеджера не замечен")
    }

    @MainActor
    func waitFor(_ timeout: TimeInterval, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }
}
