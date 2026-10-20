import Foundation

/// Закреплённая запись чата менеджера. Ключ — id записи транскрипта (он собран из uuid записи и переживает перезапуск);
/// отрывок и время хранятся рядом, чтобы список в шапке работал и для записи, которой нет в загруженной части ленты.
public struct PinnedEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var excerpt: String
    public var time: Date?

    public init(id: String, excerpt: String, time: Date?) {
        self.id = id
        self.excerpt = excerpt
        self.time = time
    }

    /// Первая строка текста записи для списка закреплённых.
    public static func excerpt(of kind: ChatKind) -> String? {
        let text: String
        switch kind {
        case let .reply(t), let .owner(t): text = t
        case let .incoming(_, _, t): text = t
        default: return nil
        }
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }
}

/// Хранение закреплённого по проекту и сессии менеджера: у новой сессии свой набор, прежний не теряется.
public enum PinStore {
    public static func key(repo: String, session: String?) -> String { "pins." + repo + "." + (session ?? "") }

    public static func load(_ defaults: UserDefaults, key: String) -> [PinnedEntry] {
        guard let data = defaults.data(forKey: key), let pins = try? JSONDecoder().decode([PinnedEntry].self, from: data) else { return [] }
        return pins
    }

    public static func save(_ pins: [PinnedEntry], _ defaults: UserDefaults, key: String) {
        if pins.isEmpty { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(pins) { defaults.set(data, forKey: key) }
    }
}

/// Просьба прокрутить ленту к записи; `token` отличает повторную просьбу к той же записи.
public struct PinJump: Equatable, Sendable {
    public var id: String
    public var token = UUID()
}
