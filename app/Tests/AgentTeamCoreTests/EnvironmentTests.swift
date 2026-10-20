import XCTest
@testable import AgentTeamCore

/// Окружение login-шелла, проверка инструментов и поиск проектов по транскриптам Claude Code.
final class EnvironmentTests: XCTestCase {
    func testParseEnv0BetweenMarkers() {
        var d = Data("приглашение .zshrc\nmotd\n".utf8)
        d.append(Data("\0AGT_ENV_BEGIN\0".utf8))
        d.append(Data("PATH=/opt/homebrew/bin:/usr/bin\0LANG=ru_RU.UTF-8\0MULTI=a\nb\0EMPTY=\0=bad\0".utf8))
        d.append(Data("\0AGT_ENV_END\0".utf8))
        d.append(Data("хвост".utf8))
        let env = LoginEnvironment.parseEnv0(d)
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(env["LANG"], "ru_RU.UTF-8")
        XCTAssertEqual(env["MULTI"], "a\nb")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(env.count, 4)
    }

    func testParseEnv0WithoutMarkers() {
        let env = LoginEnvironment.parseEnv0(Data("A=1\0B=x=y\0".utf8))
        XCTAssertEqual(env, ["A": "1", "B": "x=y"])
    }

    func testMergeTakesPathAndLocaleOnly() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/h", "CLAUDE_CODE_SSE_PORT": "1", "CLAUDECODE": "1", "TMUX": "x"]
        let login = ["PATH": "/opt/homebrew/bin:/usr/bin", "LANG": "ru_RU.UTF-8", "LC_TIME": "C", "SECRET": "s"]
        let env = LoginEnvironment.merge(base: base, login: login, extraDirs: ["/usr/local/bin", "/usr/bin"])
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
        XCTAssertEqual(env["LANG"], "ru_RU.UTF-8")
        XCTAssertEqual(env["LC_TIME"], "C")
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertNil(env["SECRET"])
        XCTAssertNil(env["CLAUDE_CODE_SSE_PORT"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["TMUX"])
    }

    /// Из Dock: PATH урезан, LANG нет, шелл не ответил — каталоги Homebrew и UTF-8 всё равно есть.
    func testMergeFallbackForcesUTF8() {
        let env = LoginEnvironment.merge(base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], login: nil, extraDirs: ["/opt/homebrew/bin"])
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        // LC_ALL важнее LANG: при LC_ALL=C локаль не UTF-8.
        XCTAssertFalse(LoginEnvironment.isUTF8(["LANG": "ru_RU.UTF-8", "LC_ALL": "C"]))
        XCTAssertTrue(LoginEnvironment.isUTF8(["LC_CTYPE": "en_US.utf8"]))
    }

    /// Настоящий шелл с маркерами: вывод до маркера (как от .zshrc) отбрасывается.
    func testCaptureRunsShell() async throws {
        let env = await LoginEnvironment.run("/bin/sh", ["-c", "echo мусор; " + LoginEnvironment.script], timeout: 3)
        XCTAssertNotNil(env?["PATH"])
        XCTAssertNil(env?["мусор"])
    }

    /// Шелл, который не завершается (фоновый процесс держит канал), не держит приложение дольше срока.
    func testCaptureTimesOut() async {
        let start = Date()
        let env = await LoginEnvironment.run("/bin/sh", ["-c", "sleep 30"], timeout: 0.5)
        XCTAssertNil(env)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testTmuxVersion() {
        XCTAssertTrue(EnvironmentCheck.tmuxVersion("tmux 3.6b")! == (3, 6))
        XCTAssertTrue(EnvironmentCheck.tmuxVersion("tmux next-3.4")! == (3, 4))
        XCTAssertTrue(EnvironmentCheck.tmuxVersion("tmux 3.1c")! < EnvironmentCheck.minTmux)
        XCTAssertNil(EnvironmentCheck.tmuxVersion("tmux master"))
    }

    func testTeamWithoutJSONIsAProblem() {
        XCTAssertFalse(EnvironmentCheck.supportsJSON(helpText: "usage: team status [-h]\n"))
        XCTAssertTrue(EnvironmentCheck.supportsJSON(helpText: "usage: team status [-h] [--json]\n"))
    }

    func testTeamVersionFromOutput() {
        XCTAssertEqual(EnvironmentCheck.teamVersion(output: "team 0.1.0\n"), "0.1.0")
        XCTAssertNil(EnvironmentCheck.teamVersion(output: "team unknown\n"))     // пакет без метаданных
        XCTAssertNil(EnvironmentCheck.teamVersion(output: ""))
        XCTAssertNil(EnvironmentCheck.teamVersion(output: "usage: team [-h]"))
    }

    func testTeamVersionNewAndOldTeam() async throws {
        let dir = NSTemporaryDirectory() + "agtest-ver-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        func fake(_ name: String, _ body: String) throws -> TeamCLI {
            let path = dir + "/" + name
            try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return TeamCLI(executable: path, environment: ProcessInfo.processInfo.environment)
        }
        let new = try fake("new", "echo 'team 0.1.0'")
        let old = try fake("old", "echo 'team: error: unrecognized arguments: --version' >&2; exit 2")
        let bare = try fake("bare", "echo 'team unknown'")
        let v = await EnvironmentCheck.teamVersion(cli: new)
        XCTAssertEqual(v, "0.1.0")
        let o = await EnvironmentCheck.teamVersion(cli: old)
        XCTAssertEqual(o, "неизвестна")
        let b = await EnvironmentCheck.teamVersion(cli: bare)
        XCTAssertEqual(b, "неизвестна")
        let n = await EnvironmentCheck.teamVersion(cli: nil)
        XCTAssertEqual(n, "неизвестна")
    }

    // MARK: поиск проектов

    func testCwdFromHead() {
        let head = """
        {"type":"summary","summary":"x"}
        {"type":"user","cwd":"/tmp/a \\"b\\"/проект","sessionId":"1"}
        {"type":"user","cwd":"/tmp/другой
        """
        XCTAssertEqual(ProjectDiscovery.cwd(fromHead: Data(head.utf8)), "/tmp/a \"b\"/проект")
        XCTAssertNil(ProjectDiscovery.cwd(fromHead: Data(#"{"type":"summary"}"#.utf8)))
        // Обрезанная на полуслове строка без закрывающей кавычки не даёт пути.
        XCTAssertNil(ProjectDiscovery.cwd(fromHead: Data(#"{"cwd":"/tmp/обре"#.utf8)))
    }

    func testScanFindsProjectsByTranscripts() throws {
        let root = try tempDir()
        let projects = root + "/claude-projects"
        // Проект с agents/team.yaml; сессия шла в его подкаталоге.
        let repo = root + "/shop"
        try mkdir(repo + "/agents")
        try mkdir(repo + "/src/deep")
        try mkdir(repo + "/.git")
        try "project: shop\n".write(toFile: repo + "/agents/team.yaml", atomically: true, encoding: .utf8)
        // Worktree роли: свой agents/team.yaml и .git-файл — должен свестись к основному репозиторию.
        let wt = root + "/wt/dev"
        try mkdir(wt + "/agents")
        try "project: shop\n".write(toFile: wt + "/agents/team.yaml", atomically: true, encoding: .utf8)
        try "gitdir: \(repo)/.git/worktrees/dev\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        // Каталог без команды.
        let plain = root + "/notes"
        try mkdir(plain)

        try transcript(projects + "/-shop-src", "old.jsonl", cwd: "/нет/такого", age: 100)
        try transcript(projects + "/-shop-src", "new.jsonl", cwd: repo + "/src/deep", age: 10, summaryFirst: true)
        try transcript(projects + "/-wt-dev", "s.jsonl", cwd: wt, age: 5)
        try transcript(projects + "/-notes", "s.jsonl", cwd: plain, age: 1)
        try transcript(projects + "/-gone", "s.jsonl", cwd: root + "/удалён", age: 1)
        try mkdir(projects + "/-empty")

        XCTAssertEqual(ProjectDiscovery.scan(root: projects), [repo])
        XCTAssertEqual(ProjectDiscovery.repo(containing: wt + "/sub"), repo)
        XCTAssertNil(ProjectDiscovery.repo(containing: plain))
        XCTAssertTrue(ProjectDiscovery.isClaudeServiceDir(NSHomeDirectory() + "/.claude/jobs/x/tmp"))
        XCTAssertFalse(ProjectDiscovery.isClaudeServiceDir(NSHomeDirectory() + "/.claudette/x"))
        XCTAssertEqual(ProjectDiscovery.scan(root: root + "/нет"), [])
    }

    /// Найденные проекты появляются в боковой панели остановленными, скрытые — нет.
    @MainActor
    func testDiscoveredProjectsInSidebar() async throws {
        let root = try tempDir()
        let repo = root + "/shop"
        try mkdir(repo + "/agents")
        try "project: shop\n".write(toFile: repo + "/agents/team.yaml", atomically: true, encoding: .utf8)
        try transcript(root + "/projects/-shop", "s.jsonl", cwd: repo, age: 1)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let app = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        await app.discoverProjects(root: root + "/projects")
        XCTAssertEqual(app.projects.map(\.session), ["team-shop"])
        XCTAssertEqual(app.projects.first?.running, false)
        XCTAssertEqual(app.projects.first?.repo, repo)
        app.hideProject(repo: repo)
        XCTAssertTrue(app.projects.isEmpty)
    }

    // MARK: помощники

    private var cleanup: [String] = []

    override func tearDown() {
        for d in cleanup { try? FileManager.default.removeItem(atPath: d) }
        cleanup = []
    }

    private func tempDir() throws -> String {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-env-\(UUID().uuidString.prefix(8))").path
        try mkdir(d)
        cleanup.append(d)
        return d
    }

    private func mkdir(_ p: String) throws {
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
    }

    private func transcript(_ dir: String, _ name: String, cwd: String, age: TimeInterval, summaryFirst: Bool = false) throws {
        try mkdir(dir)
        var lines: [String] = []
        if summaryFirst { lines.append(#"{"type":"summary","summary":"без cwd"}"#) }
        let cwdJSON = String(decoding: try JSONEncoder().encode(cwd), as: UTF8.self)
        lines.append(#"{"type":"user","cwd":\#(cwdJSON),"message":{"role":"user","content":"x"}}"#)
        let path = dir + "/" + name
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
}

/// Проверочный запуск (--snapshot, --bench) не пишет в настройки владельца.
final class ProbeDefaultsTests: XCTestCase {
    func testProbeRunDetection() {
        XCTAssertTrue(AppDefaults.isProbeRun(["x", "--project", "a", "--snapshot", "/tmp/a.png"]))
        XCTAssertTrue(AppDefaults.isProbeRun(["x", "--bench", "a,b"]))
        XCTAssertFalse(AppDefaults.isProbeRun(["x", "--project", "a"]))
    }

    /// Проверочный запуск — по любому из трёх признаков; обычный запуск сборки владельца — нет.
    func testCheckRunDetection() {
        XCTAssertFalse(AppDefaults.isCheckRun(["x", "--project", "a"], environment: [:]))
        XCTAssertFalse(AppDefaults.isCheckRun(["x"], environment: ["AGENT_TEAM_DIAG": "", "AGENT_TEAM_SNAPSHOT_ACTIVATE": "0"]))
        XCTAssertTrue(AppDefaults.isCheckRun(["x", "--snapshot", "/tmp/a.png"], environment: [:]), "снимок")
        XCTAssertTrue(AppDefaults.isCheckRun(["x", "--bench", "a"], environment: [:]), "стенд")
        XCTAssertTrue(AppDefaults.isCheckRun(["x"], environment: ["AGENT_TEAM_DIAG": "1"]), "замер стенда")
        XCTAssertTrue(AppDefaults.isCheckRun(["x", "--snapshot", "/tmp/a.png"], environment: ["AGENT_TEAM_SNAPSHOT_ACTIVATE": "1"]),
                      "активирующий снимок README — тоже проверочный запуск")
        XCTAssertTrue(AppDefaults.isCheckRun(["x"], environment: ["AGENT_TEAM_SNAPSHOT_ACTIVATE": "1"]))
    }

    /// Обычный запуск активирует приложение; проверочный — нет (стол владельца общий), кроме снимка с явным флагом
    /// сценария снимков README.
    func testActivationOnLaunch() {
        let flag = ["AGENT_TEAM_SNAPSHOT_ACTIVATE": "1"]
        XCTAssertTrue(AppDefaults.activatesOnLaunch(["x", "--project", "a"], environment: [:]))
        XCTAssertFalse(AppDefaults.activatesOnLaunch(["x", "--snapshot", "/tmp/a.png"], environment: [:]))
        XCTAssertTrue(AppDefaults.activatesOnLaunch(["x", "--snapshot", "/tmp/a.png"], environment: flag))
        XCTAssertFalse(AppDefaults.activatesOnLaunch(["x", "--bench", "a"], environment: flag), "стенд с флагом — всё равно нет")
        XCTAssertFalse(AppDefaults.activatesOnLaunch(["x", "--snapshot", "/tmp/a.png"], environment: ["AGENT_TEAM_SNAPSHOT_ACTIVATE": "yes"]))
    }

    /// Модель на временном наборе: значения владельца видны, запись идёт во временный набор, домен владельца не меняется,
    /// после удаления набора ничего не остаётся.
    @MainActor
    func testSandboxLeavesOwnerDomainUntouched() async throws {
        let ownerName = "agtest-owner-\(UUID().uuidString.prefix(8))"
        let owner = try XCTUnwrap(UserDefaults(suiteName: ownerName))
        defer { owner.removePersistentDomain(forName: ownerName) }
        owner.set("team-demo-shop", forKey: "selectedSession")
        owner.set(["/x/shop"], forKey: "projects")
        var display = DisplaySettings()
        display.chat.size = 17
        DisplaySettingsStore.save(display, to: owner)
        let snapshot = owner.persistentDomain(forName: ownerName) ?? [:]

        let (sandbox, name) = AppDefaults.makeSandbox(copying: snapshot)
        defer { AppDefaults.remove(sandbox: name) }
        XCTAssertEqual(sandbox.string(forKey: "selectedSession"), "team-demo-shop")
        XCTAssertEqual(DisplaySettingsStore.load(sandbox).chat.size, 17)

        // Что делает запуск: выбор проекта, изменение вида, ширина колонки, подключение проекта.
        let app = AppModel(defaults: sandbox, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        app.select("team-other")
        let model = DisplayModel(defaults: sandbox)
        model.settings.chat.size = 20
        model.selectTheme("light")
        sandbox.set(777.0, forKey: TeamLayoutKeys.width)

        XCTAssertEqual(sandbox.string(forKey: "selectedSession"), "team-other")
        let after = owner.persistentDomain(forName: ownerName) ?? [:]
        XCTAssertEqual(NSDictionary(dictionary: after), NSDictionary(dictionary: snapshot), "домен владельца изменился")
        XCTAssertNil(owner.object(forKey: TeamLayoutKeys.width))

        AppDefaults.remove(sandbox: name)
        XCTAssertNil(UserDefaults(suiteName: name)?.string(forKey: "selectedSession"))
    }
}

private enum TeamLayoutKeys { static let width = "teamAgentsWidth" }
