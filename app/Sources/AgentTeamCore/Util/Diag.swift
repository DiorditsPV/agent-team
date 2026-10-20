import Foundation

/// Счётчики замера ленты (`AGENT_TEAM_DIAG=<файл>`, только в проверочном запуске): сколько раз за секунду вычислено тело
/// чата, сработали рост документа и прокрутки к концу, плюс высота ленты. Раз в секунду фоновая очередь дописывает строку
/// в файл и обнуляет счётчики: строки идут и тогда, когда главный поток занят, а `lag` показывает, сколько секунд главная
/// очередь не отвечала. Без переменной ничего не считается и не пишется.
public enum Diag {
    public static let on = ProcessInfo.processInfo.environment["AGENT_TEAM_DIAG"].map { !$0.isEmpty } ?? false
    /// Первая страница транскрипта менеджера в байтах (`AGENT_TEAM_DIAG_FIRSTPAGE`): стенд кладёт в ленту всю историю.
    public static let firstPage = ProcessInfo.processInfo.environment["AGENT_TEAM_DIAG_FIRSTPAGE"].flatMap(UInt64.init)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var values: [String: Double] = [:]
    nonisolated(unsafe) private static var lastMain = Date()
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    public static func inc(_ key: String) {
        guard on else { return }
        lock.lock(); counts[key, default: 0] += 1; lock.unlock()
    }

    public static func set(_ key: String, _ value: Double) {
        guard on else { return }
        lock.lock(); values[key] = value; lock.unlock()
    }

    /// Запуск записи: файл создаётся заново, главная очередь отмечается раз в 0,25 с.
    @MainActor public static func start() {
        guard on, timer == nil, let path = ProcessInfo.processInfo.environment["AGENT_TEAM_DIAG"] else { return }
        FileManager.default.createFile(atPath: path, contents: Data())
        let handle = FileHandle(forWritingAtPath: path)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            lock.lock(); lastMain = Date(); lock.unlock()
        }
        let t0 = Date()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler {
            lock.lock()
            let c = counts, v = values, lag = Date().timeIntervalSince(lastMain)
            counts = [:]
            lock.unlock()
            var line = String(format: "t=%.0f lag=%.2f", Date().timeIntervalSince(t0), lag)
            for k in c.keys.sorted() { line += " \(k)=\(c[k]!)" }
            for k in v.keys.sorted() { line += String(format: " %@=%.0f", k, v[k]!) }
            handle?.write(Data((line + "\n").utf8))
        }
        t.resume()
        timer = t
    }
}
