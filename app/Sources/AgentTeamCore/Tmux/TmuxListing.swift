import Foundation

/// Панель из `list-panes -a -F`.
public struct PaneInfo: Equatable, Sendable {
    public var session: String
    public var paneID: String
    public var role: String      // опция @team_role; пусто — панель не роль
    public var dead: Bool
    public var pid: Int
    public var path: String
    public var soloID: String    // опция @solo_id; пусто — панель не отдельной сессии

    public init(session: String, paneID: String, role: String, dead: Bool, pid: Int, path: String, soloID: String = "") {
        self.session = session
        self.paneID = paneID
        self.role = role
        self.dead = dead
        self.pid = pid
        self.path = path
        self.soloID = soloID
    }
}

public enum TmuxListing {
    public static let teamPrefix = "team-"

    public static let paneFormat = ["#{session_name}", "#{pane_id}", "#{@team_role}", "#{pane_dead}", "#{pane_pid}",
                                    "#{pane_current_path}", "#{@solo_id}"].joined(separator: "\t")
    public static let sessionFormat = "#{session_name}"

    public static var listPanesCommand: String { "list-panes -a -F " + TmuxQuote.word(paneFormat) }
    public static var listSessionsCommand: String { "list-sessions -F " + TmuxQuote.word(sessionFormat) }

    public static func parsePanes(_ lines: [String]) -> [PaneInfo] {
        lines.compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { return nil }
            return PaneInfo(session: f[0], paneID: f[1], role: f[2], dead: f[3] == "1", pid: Int(f[4]) ?? 0, path: f[5],
                            soloID: f.count > 6 ? f[6] : "")
        }
    }

    /// Имена сессий `cc-*` — отдельные сессии Claude Code. `team` их не видит.
    public static func soloSessions(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix(SoloNaming.prefix) }.sorted()
    }

    public static func teamSessions(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix(teamPrefix) }.sorted()
    }

    /// Число живых панелей-ролей по сессиям `team-*`.
    public static func liveAgentCounts(_ panes: [PaneInfo]) -> [String: Int] {
        var out: [String: Int] = [:]
        for p in panes where p.session.hasPrefix(teamPrefix) {
            out[p.session, default: 0] += (!p.role.isEmpty && !p.dead) ? 1 : 0
        }
        return out
    }
}
