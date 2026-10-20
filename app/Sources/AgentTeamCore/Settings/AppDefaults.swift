import Foundation

/// Хранилище настроек приложения.
///
/// Обычный запуск пишет в домен приложения (UserDefaults.standard). Проверочный (`--snapshot`, `--bench`) работает
/// на временном наборе: значения копируются из настроек владельца, запись идёт только во временный набор, и тот
/// удаляется при выходе. Иначе снимок разработчика менял бы выбранный проект и вид у приложения владельца.
public enum AppDefaults {
    /// Аргументы запуска, при которых настройки не должны попасть в домен владельца.
    public static func isProbeRun(_ arguments: [String]) -> Bool {
        arguments.contains("--snapshot") || arguments.contains("--bench")
    }

    /// Проверочный запуск: снимок, стенд (`--bench`, `AGENT_TEAM_DIAG`) или запуск сценария снимков README
    /// (`AGENT_TEAM_SNAPSHOT_ACTIVATE`). Окна такого запуска ставятся на неосновной экран (`CheckPlacement`) независимо
    /// от того, активируется ли приложение: основной экран — рабочий стол владельца.
    public static func isCheckRun(_ arguments: [String], environment: [String: String]) -> Bool {
        isProbeRun(arguments) || environment["AGENT_TEAM_SNAPSHOT_ACTIVATE"] == "1"
            || !(environment["AGENT_TEAM_DIAG"] ?? "").isEmpty
    }

    /// Активировать ли приложение при запуске. Обычный запуск — да. Проверочный — нет: стол у владельца общий, и
    /// активированное приложение забрало бы его ввод. Исключение — снимок (`--snapshot`) с явным флагом
    /// `AGENT_TEAM_SNAPSHOT_ACTIVATE=1`: кадрам README нужно активное окно (цветные кнопки окна), и флаг ставит сценарий
    /// снимков, который перед запуском ждёт, пока владелец не печатает. Цена активации: приложение становится
    /// активным, и клавиатура владельца идёт в его окно до возврата фокуса; окно при этом на втором экране, но ввод
    /// владельца перехватывается. Поэтому сценарий ждёт паузы в наборе, а кадрам нужен лишь вид активного окна.
    public static func activatesOnLaunch(_ arguments: [String], environment: [String: String]) -> Bool {
        guard isProbeRun(arguments) else { return true }
        return arguments.contains("--snapshot") && environment["AGENT_TEAM_SNAPSHOT_ACTIVATE"] == "1"
    }

    nonisolated(unsafe) private static var sandboxName: String?

    /// Набор для этого запуска. Определяется один раз при первом обращении, до создания моделей.
    nonisolated(unsafe) public static let store: UserDefaults = {
        guard isProbeRun(CommandLine.arguments) else { return .standard }
        // Снимки для публичных материалов идут на пустом наборе: список проектов и пути владельца в кадр не попадают.
        let fresh = ProcessInfo.processInfo.environment["AGENT_TEAM_FRESH_DEFAULTS"] == "1"
        let owner = fresh ? [:] : UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "dev.agent-team.app") ?? [:]
        let (suite, name) = makeSandbox(copying: owner)
        sandboxName = name
        return suite
    }()

    /// Временный набор с копией значений. Имя уникально для запуска.
    public static func makeSandbox(copying values: [String: Any]) -> (UserDefaults, String) {
        let name = "agentteam-probe-\(getpid())-\(UUID().uuidString.prefix(8))"
        let suite = UserDefaults(suiteName: name)!
        for (k, v) in values { suite.set(v, forKey: k) }
        return (suite, name)
    }

    /// Удаляет временный набор вместе с файлом настроек. Для обычного запуска ничего не делает.
    public static func cleanup() {
        guard let name = sandboxName else { return }
        sandboxName = nil
        remove(sandbox: name)
    }

    public static func remove(sandbox name: String) {
        // Файл удаляется после того, как демон настроек сбросил состояние: иначе он пишет пустой файл заново.
        UserDefaults.standard.removePersistentDomain(forName: name)
        CFPreferencesAppSynchronize(name as CFString)
        let file = NSHomeDirectory() + "/Library/Preferences/\(name).plist"
        try? FileManager.default.removeItem(atPath: file)
        // Демон настроек может записать пустой файл уже после выхода процесса: подчищаем отдельным коротким процессом.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 3; rm -f \"$1\"", "sh", file]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
