import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    /// Процесс не уложился в срок и был остановлен: вывод неполный, `status` — не его код завершения.
    public var timedOut = false
}

public enum Shell {
    /// Запуск процесса без оболочки; ждёт завершения в фоне.
    ///
    /// Срок ограничивает весь вызов: по его истечении процессу — SIGTERM, через 2 с — SIGKILL, и вызов возвращается
    /// с `timedOut`, не дожидаясь конца вывода: канал вывода может держать потомок, унаследовавший его. Вывод каждого
    /// канала читает один поток до конца, поэтому куски не перемешиваются.
    public static func run(_ executable: String, _ args: [String], cwd: String? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval = 60) async -> ProcessResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            if let environment { p.environment = environment }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let run = RunState(cont)
            p.terminationHandler = { proc in run.exited(proc.terminationStatus) }
            do {
                try p.run()
            } catch {
                run.finish(ProcessResult(status: -1, stdout: Data(), stderr: "\(error)"))
                return
            }
            // Концы записи в нашем процессе Process закрывает сам после запуска: чтение доходит до конца, когда
            // закроют их процесс и его потомки.
            DispatchQueue.global(qos: .utility).async { run.stdoutDone(out.fileHandleForReading.readDataToEndOfFile()) }
            DispatchQueue.global(qos: .utility).async { run.stderrDone(err.fileHandleForReading.readDataToEndOfFile()) }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !run.isFinished else { return }
                run.markTimedOut()
                if p.isRunning { p.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if p.isRunning, pid > 0 { kill(pid, SIGKILL) }       // только свой процесс: 0 — вся группа
                    run.finish(ProcessResult(status: -1, stdout: run.partialOut,
                                             stderr: "не уложился в \(Int(timeout)) с", timedOut: true))
                }
            }
        }
    }
}

/// Состояние одного запуска: код завершения и оба канала; итог отдаётся один раз — когда есть всё или истёк срок.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<ProcessResult, Never>?
    private var status: Int32?
    private var out: Data?, err: Data?
    private var timedOut = false

    init(_ cont: CheckedContinuation<ProcessResult, Never>) { self.cont = cont }

    var isFinished: Bool { lock.withLock { cont == nil } }
    var partialOut: Data { lock.withLock { out ?? Data() } }
    func markTimedOut() { lock.withLock { timedOut = true } }

    func exited(_ s: Int32) { lock.withLock { status = s }; complete() }
    func stdoutDone(_ d: Data) { lock.withLock { out = d }; complete() }
    func stderrDone(_ d: Data) { lock.withLock { err = d }; complete() }

    private func complete() {
        let r: ProcessResult? = lock.withLock {
            guard let status, let out, let err else { return nil }
            return ProcessResult(status: status, stdout: out, stderr: String(decoding: err, as: UTF8.self), timedOut: timedOut)
        }
        if let r { finish(r) }
    }

    func finish(_ r: ProcessResult) {
        let c: CheckedContinuation<ProcessResult, Never>? = lock.withLock { defer { cont = nil }; return cont }
        c?.resume(returning: r)
    }
}

/// Поиск исполняемых файлов и окружение дочерних процессов. Приложение, запущенное из Finder, получает
/// от launchd урезанный PATH (/usr/bin:/bin:/usr/sbin:/sbin) и не получает LANG; окружение login-шелла
/// владельца загружается при старте (`configure`), до него — окружение процесса с обычными каталогами.
public enum ToolLocator {
    public static let extraDirs = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin",
                                   NSHomeDirectory() + "/.cargo/bin", "/usr/bin", "/bin"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: [String: String]?
    nonisolated(unsafe) private static var fromLoginShell = false

    /// Окружение из login-шелла (nil — не удалось получить) поверх окружения процесса.
    public static func configure(login: [String: String]?) {
        let env = LoginEnvironment.merge(base: ProcessInfo.processInfo.environment, login: login, extraDirs: extraDirs)
        lock.withLock {
            resolved = env
            fromLoginShell = login != nil
        }
    }

    /// Окружение взято из login-шелла владельца (для окна «Окружение»).
    public static var usesLoginShell: Bool { lock.withLock { fromLoginShell } }

    /// Окружение для дочерних процессов: tmux, team, git. Переменные tmux и родительской сессии Claude сняты.
    public static var environment: [String: String] {
        if let env = lock.withLock({ resolved }) { return env }
        return LoginEnvironment.merge(base: ProcessInfo.processInfo.environment, login: nil, extraDirs: extraDirs)
    }

    public static var searchPath: [String] {
        (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    }

    public static func find(_ name: String) -> String? {
        for dir in searchPath {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Репозиторий инструмента team по найденному `team`: `<repo>/.venv/bin/team` → `<repo>`.
    public static func toolRepo(fromExecutable path: String) -> String? {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let comps = resolved.split(separator: "/").map(String.init)
        guard comps.count >= 3, comps[comps.count - 1] == "team", comps[comps.count - 2] == "bin",
              comps[comps.count - 3] == ".venv" else { return nil }
        return "/" + comps.dropLast(3).joined(separator: "/")
    }
}

public enum TeamCLIError: Error, Equatable, Sendable {
    case failed(status: Int32, message: String)
    case badJSON(String)
}

/// Вызов CLI `team` как контракта. Логику инструмента приложение не повторяет.
public struct TeamCLI: Sendable {
    /// Как запускать: `<repo>/.venv/bin/team` напрямую (быстрее) или `uv run --project <repo> team`.
    public var executable: String
    public var prefixArgs: [String]
    public var environment: [String: String]

    public init(executable: String, prefixArgs: [String] = [], environment: [String: String] = ToolLocator.environment) {
        self.executable = executable
        self.prefixArgs = prefixArgs
        self.environment = environment
    }

    /// Из настроек: путь к репозиторию инструмента или к исполняемому `team`.
    public static func resolve(toolPath: String?) -> TeamCLI? {
        let fm = FileManager.default
        if let toolPath, !toolPath.isEmpty {
            let expanded = (toolPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: expanded, isDirectory: &isDir) {
                if !isDir.boolValue, fm.isExecutableFile(atPath: expanded) { return TeamCLI(executable: expanded) }
                let venv = (expanded as NSString).appendingPathComponent(".venv/bin/team")
                if fm.isExecutableFile(atPath: venv) { return TeamCLI(executable: venv) }
                if let uv = ToolLocator.find("uv") { return TeamCLI(executable: uv, prefixArgs: ["run", "--project", expanded, "team"]) }
            }
        }
        if let team = ToolLocator.find("team") { return TeamCLI(executable: team) }
        return nil
    }

    public static func defaultToolRepo() -> String? {
        guard let team = ToolLocator.find("team") else { return nil }
        return ToolLocator.toolRepo(fromExecutable: team)
    }

    public func run(_ args: [String], cwd: String) async -> ProcessResult {
        await Shell.run(executable, prefixArgs + args, cwd: cwd, environment: environment)
    }

    public func json<T: Decodable>(_ type: T.Type, _ args: [String], cwd: String) async throws -> T {
        let r = await run(args, cwd: cwd)
        guard r.status == 0 else { throw TeamCLIError.failed(status: r.status, message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        do {
            return try JSONDecoder().decode(T.self, from: r.stdout)
        } catch {
            throw TeamCLIError.badJSON("\(error)")
        }
    }

    public func status(cwd: String) async throws -> TeamStatus { try await json(TeamStatus.self, ["status", "--json"], cwd: cwd) }
    /// Роли проекта и общие роли библиотеки (`--library`). Старый team не знает флага — перезапрос без него:
    /// роли как раньше, блок общих ролей пуст.
    public func roles(cwd: String) async throws -> [RoleInfo] {
        do {
            return try await json(LossyList<RoleInfo>.self, ["roles", "--json", "--library"], cwd: cwd).items
        } catch {
            return try await json(LossyList<RoleInfo>.self, ["roles", "--json"], cwd: cwd).items
        }
    }
    /// `team check --json` при замечаниях уровня error пишет полный отчёт и выходит с кодом 1:
    /// отчёт разбирается при любом коде, ошибка — только если в stdout нет годного JSON.
    public func check(cwd: String) async throws -> CheckReport {
        let r = await run(["check", "--json"], cwd: cwd)
        if let report = try? JSONDecoder().decode(CheckReport.self, from: r.stdout) { return report }
        if r.status != 0 {
            throw TeamCLIError.failed(status: r.status, message: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw TeamCLIError.badJSON(String(decoding: r.stdout.prefix(200), as: UTF8.self))
    }
    /// Передачи; битая (без id) пропускается, остальные показываются.
    public func handoffs(cwd: String) async throws -> [Handoff] { try await json(LossyList<Handoff>.self, ["handoffs", "--json"], cwd: cwd).items }

    /// `team role set <роль> --title … --model … --description … --start …` — печатает JSON одной роли.
    /// `extends`: nil — не менять, "" — снять наследование, имя — унаследовать общую роль.
    public func roleSet(_ role: String, title: String?, model: String?, description: String?, start: String?, extends: String? = nil, cwd: String) async throws -> RoleInfo {
        var a = ["role", "set", role]
        if let extends { a += ["--extends", extends] }
        if let title { a += ["--title", title] }
        if let model { a += ["--model", model] }
        if let description { a += ["--description", description] }
        if let start { a += ["--start", start] }
        return try await json(RoleInfo.self, a, cwd: cwd)
    }

    /// С `extends` команда создаёт тонкую роль на основе общей (название и поля берутся из неё, режим запуска по умолчанию manual).
    public func roleNew(_ role: String, title: String? = nil, extends: String? = nil, model: String? = nil, description: String? = nil,
                        start: String? = nil, cwd: String) async throws -> RoleInfo {
        var a = ["role", "new", role]
        if let title { a += ["--title", title] }
        if let extends { a += ["--extends", extends] }
        if let model { a += ["--model", model] }
        if let description { a += ["--description", description] }
        if let start { a += ["--start", start] }
        return try await json(RoleInfo.self, a, cwd: cwd)
    }

    /// `team reap --json`: останавливает простаивающих агентов «по требованию»; без `idle_stop_minutes` печатает `[]`.
    public func reap(keep: [String], cwd: String) async throws -> [ReapEntry] {
        try await json(LossyList<ReapEntry>.self, Reap.arguments(keep: keep), cwd: cwd).items
    }

    /// `team set idle_stop_minutes <N|off> --json`: правка ключа верхнего уровня team.yaml.
    public func setIdleStop(_ input: IdleStopInput, cwd: String) async throws -> SetResult {
        guard let arg = input.argument else { throw TeamCLIError.failed(status: 2, message: IdleStopInput.hint) }
        return try await json(SetResult.self, ["set", "idle_stop_minutes", arg, "--json"], cwd: cwd)
    }

    /// Действия над агентами: возвращают текст CLI для показа пользователю.
    public func action(_ args: [String], cwd: String) async throws -> String {
        let r = await run(args, cwd: cwd)
        let out = String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0 else { throw TeamCLIError.failed(status: r.status, message: err.isEmpty ? out : err) }
        return out
    }

    public static func validRoleName(_ s: String) -> Bool {
        s.range(of: "^[a-z][a-z0-9_-]*$", options: .regularExpression) != nil
    }
}
