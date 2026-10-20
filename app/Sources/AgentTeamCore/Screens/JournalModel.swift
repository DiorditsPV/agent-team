import Foundation

/// Вид события журнала: по нему строка получает подпись, цвет и попадает под фильтр «Тип».
/// spawn, restart и down — одна группа «Запуск»: в фильтре это жизнь агента целиком.
public enum JournalKind: String, CaseIterable, Sendable {
    case task, report, commit, life, handoff, waiting, owner, other

    public init(type: String) {
        switch type {
        case "task": self = .task
        case "report": self = .report
        case "commit": self = .commit
        case "spawn", "restart", "down": self = .life
        case "handoff": self = .handoff
        case "waiting": self = .waiting
        case "owner": self = .owner
        default: self = .other
        }
    }

    /// Виды, которые показывает фильтр «Тип», в порядке макета.
    public static let filterable: [JournalKind] = [.task, .report, .commit, .life, .handoff, .waiting, .owner]

    public var filterLabel: String {
        switch self {
        case .task: return "Задача"
        case .report: return "Отчёт"
        case .commit: return "Коммит"
        case .life: return "Запуск"
        case .handoff: return "Передача"
        case .waiting: return "Ждёт вас"
        case .owner: return "Вы"
        case .other: return "Другое"
        }
    }

    /// Подпись строки: у группы «Запуск» — точный вид события.
    public static func rowLabel(type: String) -> String {
        switch type {
        case "spawn": return "Запуск"
        case "restart": return "Перезапуск"
        case "down": return "Остановка"
        default:
            let k = JournalKind(type: type)
            return k == .other ? type : k.filterLabel
        }
    }
}

/// Период ленты.
public enum JournalPeriod: String, CaseIterable, Sendable {
    case today, week, month, all

    public var label: String {
        switch self {
        case .today: return "Сегодня"
        case .week: return "7 дней"
        case .month: return "30 дней"
        case .all: return "Всё время"
        }
    }

    /// Начало периода; nil — без ограничения.
    public func since(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

public struct JournalFilter: Equatable, Sendable {
    /// Пусто — все виды.
    public var kinds: Set<JournalKind> = []
    public var agent: String?
    public var query = ""
    public var period: JournalPeriod = .all

    public init(kinds: Set<JournalKind> = [], agent: String? = nil, query: String = "", period: JournalPeriod = .all) {
        self.kinds = kinds
        self.agent = agent
        self.query = query
        self.period = period
    }

    public var isDefault: Bool { kinds.isEmpty && agent == nil && query.trimmingCharacters(in: .whitespaces).isEmpty && period == .all }

    /// Поиск — по тексту, задаче (в нём и коммит: CLI пишет хеш в текст) и имени агента, без учёта регистра.
    public func apply(_ events: [TeamEvent], now: Date = Date(), calendar: Calendar = .current) -> [TeamEvent] {
        let since = period.since(now: now, calendar: calendar).map { Int($0.timeIntervalSince1970) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { e in
            if let since, e.ts < since { return false }
            if !kinds.isEmpty, !kinds.contains(JournalKind(type: e.type)) { return false }
            if let agent, e.agent != agent { return false }
            if !q.isEmpty {
                let hay = [e.text, e.task ?? "", e.title ?? "", e.agent].joined(separator: "\n").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }
}

/// День ленты: заголовок и события дня в исходном порядке (новые сверху).
public struct JournalDay: Identifiable, Equatable, Sendable {
    public var start: Date
    public var title: String
    public var events: [TeamEvent]
    public var id: Date { start }

    /// Соседние события одного дня собираются в один день; ожидается лента, отсортированная от новых к старым.
    public static func group(_ events: [TeamEvent], now: Date = Date(), calendar: Calendar = .current) -> [JournalDay] {
        var out: [JournalDay] = []
        for e in events {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(e.ts)))
            if let last = out.last, last.start == day {
                out[out.count - 1].events.append(e)
            } else {
                out.append(JournalDay(start: day, title: title(day, now: now, calendar: calendar), events: [e]))
            }
        }
        return out
    }

    /// «Сегодня, 16 октября», «Вчера, 15 октября», «14 октября», в другой год — «30 декабря 2025».
    public static func title(_ day: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let date = DateFormats.string(day, sameYear ? "d MMMM" : "d MMMM yyyy", timeZone: calendar.timeZone, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        if day == today { return "Сегодня, " + date }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), day == y { return "Вчера, " + date }
        return date
    }
}

/// Время события коротко: сегодня — «19:50», вчера — «вчера, 23:40», раньше — «14 окт, 23:40».
public enum ShortTime {
    public static func label(_ ts: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let time = DateFormats.string(date, "HH:mm", timeZone: calendar.timeZone, calendar: calendar)
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day == today { return time }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), day == y { return "вчера, " + time }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let dayText = DateFormats.string(date, sameYear ? "d MMM" : "d MMM yyyy", timeZone: calendar.timeZone, calendar: calendar)
        return dayText.replacingOccurrences(of: ".", with: "") + ", " + time
    }

    /// «только что», «5 мин назад», «2 ч назад».
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "только что" }
        if s < 3600 { return "\(s / 60) мин назад" }
        return "\(s / 3600) ч назад"
    }
}
