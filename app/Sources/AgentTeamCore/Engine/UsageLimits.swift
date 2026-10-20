import Foundation

/// Лимиты подписки Claude для боковой панели: текущее окно (5 часов) и недельный лимит — процент и время сброса.
///
/// Источники, оба локальные (приложение в сеть не ходит):
/// - `.team/statusline.json` проектов — последний JSON строки состояния роли с `rate_limits` (его пишет обёртка
///   statusLine, которую `team` ставит ролям). Claude Code обновляет лимиты по заголовкам ответа API, то есть после
///   каждого ответа модели в любой роли;
/// - запасной — `cachedUsageUtilization` в `~/.claude.json`: Claude Code пишет его, только когда открывают `/usage`,
///   поэтому он бывает старым на сутки; возраст показывается в подсказке.
/// Берётся самый свежий по времени наблюдения.
public struct UsageLimits: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var percent: Int
        public var resetsAt: Date?

        public init(percent: Int, resetsAt: Date?) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    public enum Source: Equatable, Sendable { case statusLine, usageCache }

    public var fiveHour: Window?
    public var sevenDay: Window?
    /// `false` — лимиты подписки к сессии не относятся (ключ API, Bedrock, Vertex): строки нет.
    public var available: Bool
    /// Когда Claude Code видел эти числа: время записи файла строки состояния или `fetchedAtMs` кеша.
    public var observedAt: Date
    public var source: Source

    public init(fiveHour: Window?, sevenDay: Window?, available: Bool = true, observedAt: Date, source: Source) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.available = available
        self.observedAt = observedAt
        self.source = source
    }

    /// Порог предупреждения, %.
    public static let warnPercent = 80

    // MARK: разбор

    /// JSON строки состояния Claude Code: `rate_limits.five_hour|seven_day.used_percentage` и `resets_at` (unix-секунды).
    public static func statusLine(_ data: Data, observedAt: Date) -> UsageLimits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if root["rate_limits_available"] as? Bool == false {
            return UsageLimits(fiveHour: nil, sevenDay: nil, available: false, observedAt: observedAt, source: .statusLine)
        }
        guard let limits = root["rate_limits"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = limits[key] as? [String: Any], let p = number(w["used_percentage"]) else { return nil }
            return Window(percent: Int(p.rounded()), resetsAt: number(w["resets_at"]).map { Date(timeIntervalSince1970: $0) })
        }
        let out = UsageLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"), observedAt: observedAt, source: .statusLine)
        return out.fiveHour == nil && out.sevenDay == nil ? nil : out
    }

    /// `~/.claude.json`: `cachedUsageUtilization.utilization.five_hour|seven_day.utilization` и `resets_at` (ISO 8601),
    /// время записи — `fetchedAtMs`.
    public static func usageCache(_ data: Data) -> UsageLimits? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let ms = number(cache["fetchedAtMs"]),
              let u = cache["utilization"] as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = u[key] as? [String: Any], let p = number(w["utilization"]) else { return nil }
            return Window(percent: Int(p.rounded()), resetsAt: (w["resets_at"] as? String).flatMap(isoDate))
        }
        let out = UsageLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                              observedAt: Date(timeIntervalSince1970: ms / 1000), source: .usageCache)
        return out.fiveHour == nil && out.sevenDay == nil ? nil : out
    }

    /// Самое свежее из файлов строки состояния проектов и кеша `/usage`.
    public static func load(repos: [String], home: String) -> UsageLimits? {
        let fm = FileManager.default
        var found: [UsageLimits] = []
        for repo in Set(repos) {
            let path = (repo as NSString).appendingPathComponent(".team/statusline.json")
            guard let attrs = try? fm.attributesOfItem(atPath: path), let mtime = attrs[.modificationDate] as? Date,
                  let data = fm.contents(atPath: path), let l = statusLine(data, observedAt: mtime) else { continue }
            found.append(l)
        }
        if let data = fm.contents(atPath: (home as NSString).appendingPathComponent(".claude.json")), let l = usageCache(data) {
            found.append(l)
        }
        return found.max { $0.observedAt < $1.observedAt }
    }

    private static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        return nil
    }

    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Python пишет микросекунды (шесть знаков): форматтер понимает до трёх.
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        if let d = f.date(from: trimmed) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: показ

    public struct Line: Equatable, Sendable {
        public var text: String
        public var warning: Bool
    }

    /// Строки боковой панели: «5 ч: 62 % · сброс 18:40», «неделя: 41 %». Прошедший сброс — «окно сброшено»: числа
    /// относятся к прошлому окну. Лимиты к сессии не относятся — строк нет.
    public func lines(now: Date, calendar: Calendar = .current) -> [Line] {
        guard available else { return [] }
        var out: [Line] = []
        if let w = fiveHour {
            if let r = w.resetsAt, r <= now {
                out.append(Line(text: "5 ч: окно сброшено", warning: false))
            } else {
                let reset = w.resetsAt.map { " · сброс " + Self.clock($0, calendar: calendar) } ?? ""
                out.append(Line(text: "5 ч: \(w.percent) %" + reset, warning: w.percent >= Self.warnPercent))
            }
        }
        if let w = sevenDay {
            if let r = w.resetsAt, r <= now {
                out.append(Line(text: "неделя: окно сброшено", warning: false))
            } else {
                out.append(Line(text: "неделя: \(w.percent) %", warning: w.percent >= Self.warnPercent))
            }
        }
        return out
    }

    /// Подсказка при наведении: оба окна с датой сброса и откуда числа, с возрастом.
    public func details(now: Date, calendar: Calendar = .current) -> String {
        func row(_ title: String, _ w: Window?) -> String? {
            guard let w else { return nil }
            let reset = w.resetsAt.map { ($0 <= now ? "сброшено " : "сброс ") + Self.dayClock($0, now: now, calendar: calendar) } ?? "время сброса неизвестно"
            return "\(title): \(w.percent) % · \(reset)"
        }
        let rows = [row("Текущее окно (5 ч)", fiveHour), row("Неделя", sevenDay)].compactMap { $0 }
        let from = source == .statusLine ? "по строке состояния роли" : "по кешу /usage Claude Code"
        return (rows + ["\(from), \(Self.age(now.timeIntervalSince(observedAt)))"]).joined(separator: "\n")
    }

    static func clock(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    static func dayClock(_ d: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return "сегодня " + clock(d, calendar: calendar) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "d MMMM"
        return f.string(from: d) + " " + clock(d, calendar: calendar)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 90 { return "только что" }
        if s < 3600 { return "\(s / 60) мин назад" }
        if s < 48 * 3600 { return "\(s / 3600) ч назад" }
        return "\(s / 86400) дн назад"
    }
}
