import Foundation

/// Границы раскладки «чат менеджера | колонка агентов».
public enum SplitLayout {
    public static let minPaneHeight = 200.0
    public static let collapsedRowHeight = 44.0

    /// Высота карточки агента: высота колонки за вычетом свёрнутых строк делится между рядами панелей,
    /// чтобы под панелями не оставалось пустого места; ниже минимума колонка прокручивается.
    public static func paneHeight(available: Double, collapsedRows: Int, panes: Int, columns: Int, gap: Double) -> Double {
        guard panes > 0 else { return minPaneHeight }
        return paneHeight(available: available, collapsedRows: collapsedRows, paneRows: (panes + columns - 1) / columns, gap: gap)
    }

    /// То же по числу рядов панелей: в колонке одним списком свёрнутая строка может прервать ряд
    /// (`AgentColumnLayout.paneRows`).
    public static func paneHeight(available: Double, collapsedRows: Int, paneRows rows: Int, gap: Double) -> Double {
        guard rows > 0 else { return minPaneHeight }
        let free = available - Double(collapsedRows) * (collapsedRowHeight + gap) - gap * Double(rows - 1)
        return max(minPaneHeight, (free / Double(rows)).rounded(.down))
    }

    public static let minChat: Double = 420
    public static let minAgents: Double = 320
    public static let defaultAgents: Double = 420

    /// Ширина колонки агентов в пределах: агентам не меньше 320, чату не меньше 420 (с учётом границы в 1 pt).
    /// Если окна не хватает на оба минимума, агентам остаётся их минимум.
    public static func agentsWidth(stored: Double, total: Double) -> Double {
        let upper = max(minAgents, total - minChat - 1)
        return min(max(stored, minAgents), upper)
    }
}
