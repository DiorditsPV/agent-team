import Foundation

/// Проверка инструмента для окна «Окружение»: найденный путь, версия и что сделать, если чего-то нет.
/// Приложение ничего не устанавливает: команда исправления только показывается для копирования.
public struct ToolCheck: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String?
    public var version: String?
    public var ok: Bool
    /// Что не так (нет, старая версия).
    public var problem: String?
    /// Команда, которую владелец может скопировать и выполнить сам.
    public var fix: String?
    /// Пояснение к исправлению.
    public var hint: String?
    public var id: String { name }
}

public enum EnvironmentCheck {
    public static let minTmux = (3, 2)

    /// `tmux -V`: «tmux 3.6b», «tmux next-3.4», «tmux 3.2a» → (мажор, минор); «tmux master» — nil.
    public static func tmuxVersion(_ text: String) -> (Int, Int)? {
        guard let r = text.range(of: #"\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = text[r].split(separator: ".").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    /// Версия первой строкой вывода, без имени программы.
    static func firstLine(_ r: ProcessResult) -> String? {
        guard r.status == 0 else { return nil }
        let line = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? ""
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Версия из вывода `team --version`: «team 0.1.0» → «0.1.0». «team unknown» (пакет без метаданных)
    /// и любой другой вывод без версии — nil.
    public static func teamVersion(output text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == "team", words[1] != "unknown" else { return nil }
        return String(words[1])
    }

    /// Версия установленного team; старый team без `--version` отвечает ошибкой — «неизвестна», без сообщения об ошибке.
    public static func teamVersion(cli: TeamCLI?) async -> String {
        guard let cli else { return unknownVersion }
        let r = await Shell.run(cli.executable, cli.prefixArgs + ["--version"], environment: cli.environment, timeout: 10)
        guard r.status == 0 else { return unknownVersion }
        return teamVersion(output: String(decoding: r.stdout, as: UTF8.self)) ?? unknownVersion
    }

    public static let unknownVersion = "неизвестна"

    /// Только поиск путей, без запуска процессов: открывать ли окно «Окружение» само.
    public static func missingEssentials(cli: TeamCLI?) -> Bool {
        ToolLocator.find("tmux") == nil || cli == nil
    }

    /// Все проверки параллельно; каждая версия — один короткий вызов со сроком.
    public static func run(toolPath: String, cli: TeamCLI?) async -> [ToolCheck] {
        async let tmux = checkTmux()
        async let git = simple("git", args: ["--version"], fix: "xcode-select --install",
                               hint: "git входит в Command Line Tools от Apple.")
        async let uv = simple("uv", args: ["--version"], fix: "curl -LsSf https://astral.sh/uv/install.sh | sh",
                              hint: "uv запускает инструмент team из его репозитория.")
        async let claude = simple("claude", args: ["--version"], fix: "curl -fsSL https://claude.ai/install.sh | bash",
                                  hint: "Claude Code запускается в каждой панели роли.")
        async let team = checkTeam(toolPath: toolPath, cli: cli)
        return await [tmux, git, uv, claude, team]
    }

    static func checkTmux() async -> ToolCheck {
        guard let path = ToolLocator.find("tmux") else {
            return ToolCheck(name: "tmux", ok: false, problem: "не найден", fix: "brew install tmux",
                             hint: "Нужен tmux \(minTmux.0).\(minTmux.1) или новее; команда — для Homebrew.")
        }
        let line = firstLine(await Shell.run(path, ["-V"], environment: ToolLocator.environment, timeout: 5))
        if let v = line.flatMap(tmuxVersion), v < minTmux {
            return ToolCheck(name: "tmux", path: path, version: line, ok: false,
                             problem: "нужна версия \(minTmux.0).\(minTmux.1) или новее", fix: "brew upgrade tmux",
                             hint: "Приложению нужны подписки и пауза вывода control mode.")
        }
        return ToolCheck(name: "tmux", path: path, version: line, ok: true)
    }

    static func simple(_ name: String, args: [String], fix: String, hint: String) async -> ToolCheck {
        guard let path = ToolLocator.find(name) else {
            return ToolCheck(name: name, ok: false, problem: "не найден", fix: fix, hint: hint)
        }
        let line = firstLine(await Shell.run(path, args, environment: ToolLocator.environment, timeout: 5))
        return ToolCheck(name: name, path: path, version: line, ok: true)
    }

    /// Знает ли `team` JSON-контракт: старая версия (например, установленная глобально до команд --json)
    /// находится, но приложению не годится.
    public static func supportsJSON(helpText: String) -> Bool {
        helpText.contains("--json")
    }

    static func checkTeam(toolPath: String, cli: TeamCLI?) async -> ToolCheck {
        guard let cli else {
            return ToolCheck(name: "team", ok: false, problem: toolPath.isEmpty ? "не найден" : "не найден по пути из настроек",
                             fix: "uv sync",
                             hint: "Укажите в настройках каталог клона agent-team и выполните в нём эту команду: она создаёт .venv с командой team.")
        }
        let call = ([cli.executable] + cli.prefixArgs).joined(separator: " ")
        let version = await teamVersion(cli: cli)
        let help = await Shell.run(cli.executable, cli.prefixArgs + ["status", "--help"], environment: cli.environment, timeout: 10)
        // Не ответил или упал — это не «старая версия»: старая отвечает справкой без --json.
        if help.timedOut || (help.status != 0 && help.stdout.isEmpty) {
            return ToolCheck(name: "team", path: call, version: version, ok: false,
                             problem: help.timedOut ? "не ответил за 10 с" : "не запускается (код \(help.status))",
                             fix: "uv sync",
                             hint: "Проверьте команду в терминале: " + call + " status --help. "
                                + (help.stderr.isEmpty ? "" : "Ошибка: " + String(help.stderr.prefix(200))))
        }
        guard supportsJSON(helpText: String(decoding: help.stdout, as: UTF8.self)) else {
            return ToolCheck(name: "team", path: call, version: version, ok: false, problem: "без --json — старая версия",
                             fix: "uv sync",
                             hint: "Приложению нужен team с командами --json. Укажите в настройках каталог свежего клона agent-team и выполните в нём эту команду.")
        }
        return ToolCheck(name: "team", path: call, version: version, ok: true)
    }
}
