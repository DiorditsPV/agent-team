import Foundation

/// Задача агента для шапок и подсказок: название (его читает владелец), номер трекера и время установки.
/// У старого CLI названия нет — показывается номер.
public struct TaskLabel: Equatable, Sendable {
    public var number: String?
    public var title: String?
    public var ts: Int?

    public init(number: String? = nil, title: String? = nil, ts: Int? = nil) {
        self.number = number.flatMap { $0.isEmpty ? nil : $0 }
        self.title = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.ts = ts
    }

    /// Задачи нет: ни номера, ни названия.
    public var isEmpty: Bool { number == nil && title == nil }

    /// Что писать в шапке: название, при его отсутствии номер.
    public var text: String? { title ?? number }

    /// Подсказка: полное название, номер и время установки; каждое — отдельной строкой.
    public func tooltip(timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        if let title { lines.append(title) }
        if let number { lines.append("Задача " + number) }
        if let ts {
            lines.append("Установлена " + DateFormats.string(Date(timeIntervalSince1970: TimeInterval(ts)), "d MMM, HH:mm", timeZone: timeZone))
        }
        return lines.joined(separator: "\n")
    }

    /// Из агента `team status --json` (новые поля task, task_title, task_ts).
    public init(agent: Agent) {
        self.init(number: agent.task, title: agent.taskTitle, ts: agent.taskTS)
    }

    /// Старый team: задача — по журналу. Последнее событие `task` (или любое с номером задачи) решает:
    /// событие `task` без номера — задача снята. Название берётся из события `task` с тем же номером.
    public static func fromEvents(_ newestFirst: [TeamEvent], agent: String) -> TaskLabel? {
        let mine = newestFirst.filter { $0.agent == agent }
        guard let e = mine.first(where: { $0.type == "task" || ($0.task?.isEmpty == false) }) else { return nil }
        guard let number = e.task, !number.isEmpty else { return nil }
        let setter = mine.first { $0.type == "task" && $0.task == number }
        let label = TaskLabel(number: number, title: setter?.title, ts: setter?.ts ?? e.ts)
        return label.isEmpty ? nil : label
    }

    /// Название задачи для строки журнала: у события `task` своё; иначе название того же агента по номеру.
    /// Один номер у разных агентов может называться по-разному (у каждого своя часть работы).
    public static func eventTitle(_ e: TeamEvent, in events: [TeamEvent]) -> String? {
        if let t = e.title, !t.isEmpty { return t }
        guard let number = e.task, !number.isEmpty else { return nil }
        return events.first { $0.type == "task" && $0.agent == e.agent && $0.task == number && ($0.title?.isEmpty == false) }?.title
    }
}
