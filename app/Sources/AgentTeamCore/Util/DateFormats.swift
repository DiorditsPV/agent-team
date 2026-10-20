import Foundation

/// Форматтеры дат по ключу (формат, локаль, часовой пояс, календарь): создаются один раз и больше не меняются, поэтому
/// ими можно пользоваться из любого потока. Подписи времени считаются в `body` при каждой перерисовке, а создание
/// `DateFormatter` на каждый вызов было заметной долей этой работы.
public enum DateFormats {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    public static func string(_ date: Date, _ format: String, locale: String? = "ru_RU", timeZone: TimeZone = .current,
                              calendar: Calendar? = nil) -> String {
        let key = [format, locale ?? "", timeZone.identifier, calendar.map { "\($0.identifier)|\($0.timeZone.identifier)" } ?? ""]
            .joined(separator: "\u{1}")
        let f: DateFormatter = lock.withLock {
            if let f = cache[key] { return f }
            let f = DateFormatter()
            if let locale { f.locale = Locale(identifier: locale) }
            if let calendar { f.calendar = calendar }
            f.timeZone = timeZone
            f.dateFormat = format
            cache[key] = f
            return f
        }
        return f.string(from: date)
    }
}

/// «1 агент», «2 агента», «5 агентов» — форма слова по числу.
public enum RussianPlural {
    public static func word(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1, m100 != 11 { return one }
        if (2...4).contains(m10), !(12...14).contains(m100) { return few }
        return many
    }
}
