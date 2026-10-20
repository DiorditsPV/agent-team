import Foundation

/// Окружение login-шелла владельца для дочерних процессов.
///
/// Приложение из Finder или Dock получает от launchd PATH=/usr/bin:/bin:/usr/sbin:/sbin и не получает LANG.
/// Без UTF-8 локали tmux заменяет табуляцию и кириллицу на `_`, а tmux, uv и claude из Homebrew и ~/.local/bin
/// не находятся. Поэтому один раз при старте берётся окружение шелла владельца; из него — только PATH, LANG и LC_*.
public enum LoginEnvironment {
    static let begin = "AGT_ENV_BEGIN"
    static let end = "AGT_ENV_END"

    /// Команда для шелла: служебные маркеры отделяют `env -0` от того, что печатают .zshrc, приглашение и motd.
    static var script: String { "printf '\\0\(begin)\\0'; env -0; printf '\\0\(end)\\0'" }

    /// Переменные между маркерами. Без маркеров — весь вывод как `env -0`.
    public static func parseEnv0(_ data: Data) -> [String: String] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        if let b = fields.firstIndex(of: begin) {
            fields = Array(fields[(b + 1)...])
            if let e = fields.firstIndex(of: end) { fields = Array(fields[..<e]) }
        }
        var env: [String: String] = [:]
        for f in fields {
            guard let eq = f.firstIndex(of: "="), eq != f.startIndex else { continue }
            let key = String(f[..<eq])
            guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            env[key] = String(f[f.index(after: eq)...])
        }
        return env
    }

    /// Шелл владельца из базы пользователей: в окружении launchd SHELL может не быть.
    public static var userShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Окружение login-шелла. Сначала интерактивный (`-i -l`): PATH и LANG у владельца часто задаются в .zshrc,
    /// который шелл без `-i` не читает. Не вышло — просто login (`-l`). Не вышло и так — nil.
    public static func capture(shell: String = userShell, timeout: TimeInterval = 3) async -> [String: String]? {
        for flags in [["-i", "-l"], ["-l"]] {
            if let env = await run(shell, flags + ["-c", script], timeout: timeout), env["PATH"] != nil { return env }
        }
        return nil
    }

    /// Запуск со строгим сроком: ответ отдаётся по конечному маркеру или по сроку, не дожидаясь закрытия канала, —
    /// фоновый процесс из .zshrc, унаследовавший stdout, держал бы канал открытым бесконечно. По сроку шелл гасится.
    static func run(_ shell: String, _ args: [String], timeout: TimeInterval) async -> [String: String]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: String]?, Never>) in
            let state = CaptureState(cont)
            let out = Pipe()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = "dumb"
            for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDECODE" || k == "TMUX" || k == "TMUX_PANE" {
                env.removeValue(forKey: k)
            }
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty {
                    fh.readabilityHandler = nil
                    state.finish()
                } else if state.append(d) {
                    // Конечный маркер получен: фоновый процесс шелла может держать канал, ждать EOF незачем.
                    fh.readabilityHandler = nil
                    state.finish()
                }
            }
            do {
                try p.run()
            } catch {
                out.fileHandleForReading.readabilityHandler = nil
                state.fail()
                return
            }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard state.isPending, pid > 0 else { return }
                kill(pid, SIGKILL)
                out.fileHandleForReading.readabilityHandler = nil
                state.finish()
            }
        }
    }

    /// Переменные окружения для дочерних процессов: база процесса, PATH и локаль из login-шелла.
    /// PATH дополняется обычными каталогами Homebrew и ~/.local/bin; локаль без UTF-8 заменяется на en_US.UTF-8.
    public static func merge(base: [String: String], login: [String: String]?, extraDirs: [String]) -> [String: String] {
        var env = base
        for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDECODE" || k == "TMUX" || k == "TMUX_PANE" {
            env.removeValue(forKey: k)
        }
        if let login {
            for (k, v) in login where k == "PATH" || k == "LANG" || k.hasPrefix("LC_") { env[k] = v }
        }
        var seen = Set<String>()
        let path = (env["PATH"] ?? "").split(separator: ":").map(String.init) + extraDirs
        env["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        if !isUTF8(env) { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    /// Действующая кодировка символов: LC_ALL, затем LC_CTYPE, затем LANG.
    public static func isUTF8(_ env: [String: String]) -> Bool {
        let value = [env["LC_ALL"], env["LC_CTYPE"], env["LANG"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let v = value.lowercased()
        return v.contains("utf-8") || v.contains("utf8")
    }
}

/// Результат захвата отдаётся ровно один раз: по концу вывода или по сроку.
private final class CaptureState: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var cont: CheckedContinuation<[String: String]?, Never>?

    init(_ c: CheckedContinuation<[String: String]?, Never>) { cont = c }

    var isPending: Bool { lock.withLock { cont != nil } }

    /// true — пришёл конечный маркер.
    func append(_ d: Data) -> Bool {
        lock.withLock {
            data.append(d)
            return data.range(of: Self.endMarker) != nil
        }
    }

    static let endMarker = Data(("\0" + LoginEnvironment.end + "\0").utf8)

    func finish() {
        let (c, d) = lock.withLock { () -> (CheckedContinuation<[String: String]?, Never>?, Data) in
            let c = cont
            cont = nil
            return (c, data)
        }
        guard let c else { return }
        // Без завершающего маркера вывод неполон (срок вышел посреди env) — такой результат не берётся.
        let complete = d.range(of: Self.endMarker) != nil
        c.resume(returning: complete ? LoginEnvironment.parseEnv0(d) : nil)
    }

    func fail() {
        let c = lock.withLock { () -> CheckedContinuation<[String: String]?, Never>? in
            let c = cont
            cont = nil
            return c
        }
        c?.resume(returning: nil)
    }
}
