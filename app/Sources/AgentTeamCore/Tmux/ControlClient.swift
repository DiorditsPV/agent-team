import Foundation

public enum ControlError: Error, Equatable, Sendable {
    case notConnected
    case commandFailed([String])
    case exited
}

/// Одно соединение `tmux -C attach` на всё приложение. Команды уходят по stdin, ответы
/// сопоставляются по порядку (FIFO): tmux отвечает на команды клиента строго в порядке получения.
public final class ControlClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (ControlEvent) -> Void

    public let tmuxPath: String
    public let socketName: String?
    private let environment: [String: String]
    /// `-u`: вывод в UTF-8 независимо от локали. Без UTF-8 локали (приложение из Dock) tmux заменяет
    /// табуляцию и кириллицу на `_`, и строки list-panes не разбираются. Выключается только в тесте.
    let forceUTF8: Bool

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var parser = ControlParser()
    /// Ответы приходят по порядку команд; у команды без ожидания (fire) место в очереди — nil.
    private var pending: [CheckedContinuation<[String], Error>?] = []
    private var handler: EventHandler?
    private var exitHandler: (@Sendable () -> Void)?
    private let readQueue = DispatchQueue(label: "agentteam.tmux.read")
    /// Запись в stdin tmux — на своей очереди, вне замка и вне главного потока: если tmux перестанет читать, встанет
    /// только эта очередь, а не интерфейс; и чтение ответов (под тем же замком) не ждёт записи — иначе tmux, упёршись
    /// в наш непрочитанный вывод, перестал бы читать stdin, и запись с чтением ждали бы друг друга.
    private let writeQueue = DispatchQueue(label: "agentteam.tmux.write")

    /// Запись в умерший `tmux -C` не должна убивать приложение: SIGPIPE игнорируется, EPIPE приходит ошибкой записи.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    public convenience init(tmuxPath: String, socketName: String? = nil, environment: [String: String] = ToolLocator.environment) {
        self.init(tmuxPath: tmuxPath, socketName: socketName, environment: environment, forceUTF8: true)
    }

    init(tmuxPath: String, socketName: String?, environment: [String: String], forceUTF8: Bool) {
        _ = Self.ignoreSigpipe
        self.tmuxPath = tmuxPath
        self.socketName = socketName
        self.forceUTF8 = forceUTF8
        var env = environment
        env.removeValue(forKey: "TMUX")
        env.removeValue(forKey: "TMUX_PANE")
        self.environment = env
    }

    public var isConnected: Bool {
        lock.withLock { process?.isRunning == true }
    }

    /// Базовые аргументы tmux: UTF-8 и отдельный сервер (`-L`).
    public var baseArguments: [String] {
        (forceUTF8 ? ["-u"] : []) + (socketName.map { ["-L", $0] } ?? [])
    }

    public func start(session: String, onEvent: @escaping EventHandler, onExit: @escaping @Sendable () -> Void) throws {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmuxPath)
        // ignore-size: размер окна приложения не влияет на панели. read-only не ставится —
        // с ним не работает send-keys.
        // -N: attach-session умеет сам поднимать сервер; если сервер только что умер, нового не создаём.
        p.arguments = baseArguments + ["-N", "-C", "attach-session", "-f", "ignore-size", "-t", TmuxTarget.session(session)]
        p.environment = environment
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        lock.withLock {
            handler = onEvent
            exitHandler = onExit
            parser = ControlParser()
            stdin = inPipe.fileHandleForWriting
            process = p
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            self.readQueue.sync { self.ingest(data) }
        }
        p.terminationHandler = { [weak self] _ in
            self?.didExit()
        }
        try p.run()
    }

    public func stop() {
        let (p, fh) = lock.withLock { () -> (Process?, FileHandle?) in
            let r = (process, stdin)
            process = nil
            stdin = nil
            exitHandler = nil
            return r
        }
        // Закрытие — после уже поставленных записей: иначе запись пошла бы в закрытый дескриптор, а его номер мог
        // достаться другому файлу.
        if let fh { writeQueue.async { try? fh.close() } }
        if let p, p.isRunning { p.terminate() }
        failPending()
    }

    /// Команда tmux; ответ — строки между `%begin` и `%end`.
    @discardableResult
    public func run(_ command: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String], Error>) in
            lock.lock()
            guard let fh = stdin, process?.isRunning == true else {
                lock.unlock()
                c.resume(throwing: ControlError.notConnected)
                return
            }
            pending.append(c)
            send(command, to: fh)
            lock.unlock()
        }
    }

    /// Ставит запись в очередь; вызывается под замком — порядок записей совпадает с порядком мест в `pending`.
    /// Запись не удалась — соединение негодно: процесс останавливается, и обработчик выхода отвечает всем ждущим.
    private func send(_ command: String, to fh: FileHandle) {
        let data = Data((command + "\n").utf8)
        writeQueue.async { [weak self] in
            do { try fh.write(contentsOf: data) } catch {
                guard let self else { return }
                self.lock.withLock { self.process }?.terminate()
            }
        }
    }

    /// Команда без ожидания ответа. Пишется по порядку вызовов: pause и on одной панели не могут поменяться местами.
    public func fire(_ command: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let fh = stdin, process?.isRunning == true else { return }
        pending.append(nil)
        send(command, to: fh)
    }

    private func ingest(_ data: Data) {
        let (events, h) = lock.withLock { (parser.feed(data), handler) }
        for e in events {
            if case let .response(_, flags, ok, lines) = e {
                guard flags & 1 == 1 else { continue }   // блок от самого attach
                let c: CheckedContinuation<[String], Error>? = lock.withLock {
                    pending.isEmpty ? nil : pending.removeFirst()
                } ?? nil
                if ok { c?.resume(returning: lines) } else { c?.resume(throwing: ControlError.commandFailed(lines)) }
                continue
            }
            h?(e)
        }
    }

    private func didExit() {
        let h = lock.withLock { () -> (@Sendable () -> Void)? in
            let h = exitHandler
            process = nil
            stdin = nil
            return h
        }
        failPending()
        h?()
    }

    private func failPending() {
        let list = lock.withLock { () -> [CheckedContinuation<[String], Error>?] in
            let l = pending
            pending = []
            return l
        }
        for c in list { c?.resume(throwing: ControlError.exited) }
    }
}
