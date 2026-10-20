import Foundation

/// Группа агента по статусу — одна классификация для порядка колонки и фильтра «Работают / Ждут».
public enum AgentGroup: Int, Comparable, Sendable {
    /// Идёт ход — плашка «работает».
    case working
    /// Ждёт ответа человека: доверие, право, вопрос.
    case waiting
    /// Простаивает или данных нет.
    case idle
    /// Панель завершилась.
    case stopped

    public init(_ state: AgentState) {
        switch state {
        case .working: self = .working
        case .waiting: self = .waiting
        case .quiet, .noData: self = .idle
        case .stopped: self = .stopped
        }
    }

    public static func < (a: AgentGroup, b: AgentGroup) -> Bool { a.rawValue < b.rawValue }
}

/// Фильтр колонки агентов: «Все», «Работают» (идёт ход), «Ждут» (ждут ответа).
public enum AgentFilter: Hashable, Sendable {
    case all, working, waiting

    public func includes(_ g: AgentGroup) -> Bool {
        switch self {
        case .all: return true
        case .working: return g == .working
        case .waiting: return g == .waiting
        }
    }
}

/// Порядок колонки агентов: работающие, потом ждущие, потом простаивающие и остановленные. Внутри группы — по роли
/// и номеру, затем по ключу: итог не зависит от порядка входа (status и панели tmux приходят в разном порядке), и на
/// опросе без смены статусов ничего не переезжает. Свёрнут агент или развёрнут, на порядок не влияет.
public enum AgentOrder {
    public static func sorted(_ agents: [Agent], group: (Agent) -> AgentGroup) -> [Agent] {
        agents.map { (group($0), $0) }.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            if a.1.role != b.1.role { return a.1.role < b.1.role }
            if a.1.n != b.1.n { return a.1.n < b.1.n }
            return a.1.key < b.1.key
        }.map(\.1)
    }

    /// Агенты колонки под фильтром, в порядке колонки.
    public static func visible(_ agents: [Agent], filter: AgentFilter, group: (Agent) -> AgentGroup) -> [Agent] {
        sorted(agents, group: group).filter { filter.includes(group($0)) }
    }

    /// Элементы колонки: агенты под фильтром в порядке колонки и свёрнут ли каждый — по его ключу. Свёрнутость на
    /// порядок не влияет. `paneLimit` — для снимков: развёрнутых не больше стольких, лишние не показываются.
    public static func items(_ agents: [Agent], filter: AgentFilter, collapsed: Set<String>, paneLimit: Int = .max,
                             group: (Agent) -> AgentGroup) -> [ColumnItem] {
        var expanded = 0
        return visible(agents, filter: filter, group: group).compactMap { a in
            let c = collapsed.contains(a.key)
            if !c { expanded += 1; if expanded > paneLimit { return nil } }
            return ColumnItem(agent: a, collapsed: c)
        }
    }
}

/// Агент в колонке и свёрнут ли он.
public struct ColumnItem: Equatable, Sendable {
    public var agent: Agent
    public var collapsed: Bool
    public init(agent: Agent, collapsed: Bool) { self.agent = agent; self.collapsed = collapsed }
}

/// Рамка элемента колонки агентов.
public struct ColumnFrame: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Раскладка колонки агентов одним списком: свёрнутый агент — строка на всю ширину на своём месте в порядке,
/// развёрнутые идут рядами по `columns`. Ряд, который строка прервала или список закончил неполным, отдаёт
/// единственной панели всю ширину. Так разворачивание не переносит агента в другую группу: индекс тот же.
public enum AgentColumnLayout {
    /// Сколько рядов панелей даёт последовательность (`true` — свёрнут).
    public static func paneRows(collapsed: [Bool], columns: Int) -> Int {
        var rows = 0, pending = 0
        for c in collapsed {
            if c { if pending > 0 { rows += 1; pending = 0 } } else {
                pending += 1
                if pending == max(columns, 1) { rows += 1; pending = 0 }
            }
        }
        return rows + (pending > 0 ? 1 : 0)
    }

    public static func frames(collapsed: [Bool], width: Double, columns: Int, gap: Double,
                              paneHeight: Double, rowHeight: Double) -> [ColumnFrame] {
        let cols = max(columns, 1)
        let colW = (width - gap * Double(cols - 1)) / Double(cols)
        var out = [ColumnFrame](repeating: ColumnFrame(x: 0, y: 0, width: 0, height: 0), count: collapsed.count)
        var y = 0.0
        var pending: [Int] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let alone = pending.count == 1 && cols > 1
            for (j, i) in pending.enumerated() {
                out[i] = ColumnFrame(x: alone ? 0 : Double(j) * (colW + gap), y: y, width: alone ? width : colW, height: paneHeight)
            }
            y += paneHeight + gap
            pending = []
        }
        for (i, c) in collapsed.enumerated() {
            if c {
                flush()
                out[i] = ColumnFrame(x: 0, y: y, width: width, height: rowHeight)
                y += rowHeight + gap
            } else {
                pending.append(i)
                if pending.count == cols { flush() }
            }
        }
        flush()
        return out
    }

    /// Высота всей колонки по рамкам.
    public static func height(_ frames: [ColumnFrame]) -> Double { frames.map { $0.y + $0.height }.max() ?? 0 }
}
