import Foundation

/// Запись процесса Claude Code из `<home>/.claude/sessions/<pid>.json`. Повторяет `sessions.lookup` CLI:
/// у одиночной сессии нет `team status`, поэтому текущую сессию приложение находит само.
public struct ClaudeSessionRecord: Equatable, Sendable {
    public var sessionID: String
    public var status: String?
    public var statusUpdatedAt: Double?
    public var jobID: String?
    public var parkedJobID: String?
    /// Разговор ушёл в фон, и запись принадлежит процессу фоновой задачи.
    public var parked: Bool

    public init(sessionID: String, status: String? = nil, statusUpdatedAt: Double? = nil, jobID: String? = nil,
                parkedJobID: String? = nil, parked: Bool = false) {
        self.sessionID = sessionID
        self.status = status
        self.statusUpdatedAt = statusUpdatedAt
        self.jobID = jobID
        self.parkedJobID = parkedJobID
        self.parked = parked
    }

    /// Состояние, которое показывает приложение; непроверенное значение — `nil`.
    public var state: String? {
        guard let status, ["busy", "idle", "waiting"].contains(status) else { return nil }
        return status
    }

    static func sessionsDirectory(home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/sessions")
    }

    private static func parse(_ url: URL) -> ClaudeSessionRecord? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = obj["sessionId"] as? String, !sid.isEmpty
        else { return nil }
        return ClaudeSessionRecord(
            sessionID: sid, status: obj["status"] as? String,
            statusUpdatedAt: (obj["statusUpdatedAt"] as? NSNumber)?.doubleValue,
            jobID: obj["jobId"] as? String, parkedJobID: obj["parkedJobId"] as? String)
    }

    /// Запись живого разговора по pid панели. С `parkedJobId` отдаётся запись фоновой задачи с тем же `jobId`
    /// (признак `parked`); задачи нет — запись панели, тоже с признаком. Нет файла или JSON битый — `nil`.
    public static func read(pid: Int, home: String = TranscriptParser.claudeHome) -> ClaudeSessionRecord? {
        let dir = sessionsDirectory(home: home)
        guard pid > 0, var rec = parse(dir.appendingPathComponent("\(pid).json")) else { return nil }
        guard let job = rec.parkedJobID, !job.isEmpty else { return rec }
        rec.parked = true
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if var other = parse(f), other.jobID == job {
                other.parked = true
                return other
            }
        }
        return rec
    }
}
