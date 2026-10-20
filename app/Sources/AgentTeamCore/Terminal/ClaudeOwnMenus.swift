import Foundation

/// Команды Claude Code, у которых в терминале своё интерактивное меню или экран: поле приложения их не показывает,
/// они работают в строке Claude Code.
public enum ClaudeOwnMenus {
    public static let commands: Set<String> = [
        "rewind", "resume", "model", "config", "permissions", "mcp", "agents", "hooks", "memory", "theme",
        "status", "doctor", "login", "logout", "ide", "terminal-setup", "output-style", "statusline", "help",
        "add-dir", "install-github-app", "privacy-settings",
    ]

    /// Имя команды, если набранный текст — вызов такой команды («/rewind», «/resume старая сессия»).
    public static func command(in draft: String) -> String? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }
        let name = t.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        return commands.contains(name) ? name : nil
    }
}
