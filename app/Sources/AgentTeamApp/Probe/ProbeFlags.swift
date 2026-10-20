import AgentTeamCore
import Foundation

/// Переменные окружения проверочных запусков, прочитанные один раз при старте, а не в `body` при каждой перерисовке.
enum ProbeFlags {
    /// Для снимка (`AGENT_TEAM_PANE_LIMIT=5`): сколько развёрнутых панелей показать на «Команде».
    static let paneLimit = Int(ProcessInfo.processInfo.environment["AGENT_TEAM_PANE_LIMIT"] ?? "") ?? .max

    /// Сценарий клавиш живой строки (`AGENT_TEAM_LIVE_SCRIPT`). Действует только в проверочном запуске (`--snapshot`,
    /// `--bench`): переменная, унаследованная обычным запуском, иначе набрала бы текст в панель настоящего менеджера.
    static let liveScript: String? = AppDefaults.isProbeRun(CommandLine.arguments)
        ? ProcessInfo.processInfo.environment["AGENT_TEAM_LIVE_SCRIPT"] : nil

    /// Черновик для снимка (`AGENT_TEAM_DRAFT="/co"`): подставляется в поле, список подсказок открывается. Только
    /// в проверочном запуске: в обычном подменённый черновик сохранился бы как черновик владельца.
    static let draft: String? = AppDefaults.isProbeRun(CommandLine.arguments)
        ? ProcessInfo.processInfo.environment["AGENT_TEAM_DRAFT"].flatMap { $0.isEmpty ? nil : $0 } : nil

    /// Через сколько секунд нажать «строку Claude Code» (`AGENT_TEAM_TOGGLE_LIVE_AFTER=3`). Только в проверочном запуске:
    /// в обычном нажатие записало бы настройку владельца.
    static let toggleLiveAfter: Double? = AppDefaults.isProbeRun(CommandLine.arguments)
        ? ProcessInfo.processInfo.environment["AGENT_TEAM_TOGGLE_LIVE_AFTER"].flatMap(Double.init) : nil
}
