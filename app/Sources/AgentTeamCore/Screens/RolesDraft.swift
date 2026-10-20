import Foundation

/// Правка роли на экране «Роли»: четыре поля, которые решает человек. Сохраняется через `team role set`
/// только тем, что изменилось, — остальное CLI не трогает.
public struct RoleDraft: Equatable, Sendable {
    public var title: String
    public var model: String
    public var description: String
    public var start: String

    public init(title: String, model: String, description: String, start: String) {
        self.title = title
        self.model = model
        self.description = description
        self.start = start
    }

    /// Исходное состояние роли. Режим запуска — из team.yaml (`startOverride`), иначе из описания роли.
    public init(role: RoleInfo, startOverride: String? = nil) {
        title = role.title ?? ""
        model = role.model ?? ""
        description = role.description ?? ""
        start = startOverride ?? role.start ?? "manual"
    }

    public enum Field: String, CaseIterable, Sendable {
        case title, model, description, start

        public var label: String {
            switch self {
            case .title: return "название"
            case .model: return "модель"
            case .description: return "описание"
            case .start: return "режим запуска"
            }
        }
    }

    public func changed(from base: RoleDraft) -> [Field] {
        var out: [Field] = []
        if title.trimmed != base.title.trimmed { out.append(.title) }
        if model != base.model { out.append(.model) }
        if description.trimmed != base.description.trimmed { out.append(.description) }
        if start != base.start { out.append(.start) }
        return out
    }

    /// Пометка в шапке: «описание изменено», «изменены: модель, описание».
    public static func badge(_ fields: [Field]) -> String? {
        switch fields.count {
        case 0: return nil
        case 1:
            switch fields[0] {
            case .title: return "название изменено"
            case .model: return "модель изменена"
            case .description: return "описание изменено"
            case .start: return "режим запуска изменён"
            }
        default: return "изменены: " + fields.map(\.label).joined(separator: ", ")
        }
    }

    /// Аргументы `saveRole`: nil у неизменённых полей.
    public func changes(from base: RoleDraft) -> (title: String?, model: String?, description: String?, start: String?) {
        let c = Set(changed(from: base))
        return (c.contains(.title) ? title.trimmed : nil,
                c.contains(.model) ? model : nil,
                c.contains(.description) ? description.trimmed : nil,
                c.contains(.start) ? start : nil)
    }

    public var isValid: Bool { !title.trimmed.isEmpty }

    public subscript(field: Field) -> String {
        get {
            switch field {
            case .title: return title
            case .model: return model
            case .description: return description
            case .start: return start
            }
        }
        set {
            switch field {
            case .title: title = newValue
            case .model: model = newValue
            case .description: description = newValue
            case .start: start = newValue
            }
        }
    }
}

/// Несохранённая правка роли: только поля, которые тронул владелец, поверх актуального состояния роли. Пока правка
/// открыта, роль может измениться снаружи (`team role set` менеджера, правка файла): нетронутые поля показывают и
/// сохраняют уже новое значение. Снимок всех полей отправил бы при сохранении старые значения и откатил чужую правку.
public struct RoleEdits: Equatable, Sendable {
    public private(set) var values: [RoleDraft.Field: String] = [:]

    public init() {}

    /// Тронутых полей нет (или все вернулись к роли): правки нет.
    public var isEmpty: Bool { values.isEmpty }

    /// Что видит владелец: роль с его правками.
    public func applied(to base: RoleDraft) -> RoleDraft {
        var d = base
        for (f, v) in values { d[f] = v }
        return d
    }

    /// Владелец изменил форму: поля, отличающиеся от показанного, запоминаются; поле, вернувшееся к значению роли
    /// буква в букву, перестаёт быть правкой.
    public mutating func record(_ new: RoleDraft, base: RoleDraft) {
        let shown = applied(to: base)
        for f in RoleDraft.Field.allCases where new[f] != shown[f] { values[f] = new[f] }
        // Сравнение точное, не по обрезанному тексту: иначе набранный в конце пробел исчезал бы из поля.
        values = values.filter { $0.value != base[$0.key] }
    }

    /// Правка `sent` сохранена: убираются поля, которые с отправки не менялись. Сравнение буква в букву с тем, что
    /// лежало в правке, а не с обрезанным отправленным значением.
    public mutating func settle(sent: RoleEdits) {
        values = values.filter { sent.values[$0.key] != $0.value }
    }

    /// Снимает правку одного поля и отдаёт её значение; остальные поля остаются правкой.
    @discardableResult
    public mutating func remove(_ field: RoleDraft.Field) -> String? { values.removeValue(forKey: field) }

    /// Возвращает снятую правку поля (сохранение, ради которого её сняли, не удалось).
    public mutating func restore(_ field: RoleDraft.Field, _ value: String) { values[field] = value }

    /// Тронутые поля, которые отличаются от роли сейчас.
    public func changed(from base: RoleDraft) -> [RoleDraft.Field] { applied(to: base).changed(from: base) }

    /// Аргументы `saveRole`: только тронутые и отличающиеся поля, остальные — nil (CLI их не трогает).
    public func changes(from base: RoleDraft) -> (title: String?, model: String?, description: String?, start: String?) {
        applied(to: base).changes(from: base)
    }
}

/// Сводка технических настроек роли для правой колонки.
public enum RoleSummary {
    /// «app/ +5», «shop: app/ +5», пусто — «—».
    public static func zone(_ zone: [String], repo: String? = nil) -> String {
        guard let first = zone.first else { return repo.map { "репозиторий \($0)" } ?? "—" }
        let head = zone.count > 1 ? "\(first) +\(zone.count - 1)" : first
        return repo.map { "\($0): \(head)" } ?? head
    }

    /// Имя репозитория из worktree.repo («../shop» → «shop»); nil — репозиторий проекта.
    public static func repoName(_ repo: String?) -> String? {
        guard let repo, !repo.isEmpty else { return nil }
        let name = (repo as NSString).lastPathComponent
        return name.isEmpty ? repo : name
    }

    /// Число непустых строк текста инструкции.
    public static func lineCount(_ text: String?) -> Int {
        (text ?? "").split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
