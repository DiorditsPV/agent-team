import Foundation

/// Режим запуска роли в списке ролей проекта: постоянная (`always`, поднимается с `team up`) или по требованию
/// (`on_demand`). `manual` выбирается в карточке роли; в списке он виден и остаётся вариантом, пока открыт проект.
public enum RoleStart {
    public static let always = "always"
    public static let onDemand = "on_demand"
    public static let manual = "manual"

    public static func label(_ start: String) -> String {
        switch start {
        case always: return "постоянная"
        case onDemand: return "по требованию"
        case manual: return "вручную"
        default: return start
        }
    }

    /// Строки ролей проекта. Режим берётся так же, как в карточке роли (`RoleDraft`): из team.yaml, иначе из описания
    /// роли, иначе `manual`. Менеджера в списке нет: он поднимается всегда, вместе с командой. Общих ролей библиотеки
    /// тоже нет: их нет в team.yaml проекта, и `team role set` их не меняет.
    public static func rows(roles: [RoleInfo], starts: [String: String]) -> [RoleStartRow] {
        roles.filter { $0.kind != "manager" && !$0.isShared }.map { r in
            let title = r.title.flatMap { $0.isEmpty ? nil : $0 } ?? r.role
            return RoleStartRow(role: r.role, title: title, start: RoleDraft(role: r, startOverride: starts[r.role]).start)
        }
    }
}

public struct RoleStartRow: Equatable, Sendable, Identifiable {
    public var role: String
    public var title: String
    /// Сохранённый режим: из team.yaml или описания роли.
    public var start: String
    public var id: String { role }

    public init(role: String, title: String, start: String) {
        self.role = role
        self.title = title
        self.start = start
    }
}

/// Сохранения режима из списка ролей: что выбрано и ещё не дошло до team.yaml, что сохраняется сейчас, какие ошибки CLI
/// показать у строк. Живёт в модели проекта: список стоит и на экране «Роли», и на экране технических настроек роли.
public struct RoleStartEdits: Equatable, Sendable {
    /// Выбранный режим, пока перечитанный team.yaml его не показал: без этого строка мигнула бы старым значением.
    public private(set) var pending: [String: String] = [:]
    /// Сохранённый режим в момент выбора: если team.yaml показал другой, режим сменили иначе (карточкой роли, менеджер),
    /// и ожидание снимается — иначе строка и карточка показывали бы выбор, которого в файле уже нет.
    private var pendingFrom: [String: String] = [:]
    public private(set) var saving: Set<String> = []
    public private(set) var errors: [String: String] = [:]
    /// Роли, у которых при открытии проекта был `manual`: вариант «вручную» у них остаётся, — иначе он исчез бы после
    /// первого щелчка, сегменты сдвинулись бы под курсором и вернуться к `manual` было бы нельзя.
    public private(set) var manualKept: Set<String> = []

    public init() {}

    public func shown(_ row: RoleStartRow) -> String { pending[row.role] ?? row.start }

    /// Варианты строки. `shown` — что видит владелец: в списке это значение карточки, с её несохранённой правкой.
    public func options(_ row: RoleStartRow, shown: String? = nil) -> [String] {
        manualKept.contains(row.role) || (shown ?? self.shown(row)) == RoleStart.manual
            ? [RoleStart.manual, RoleStart.always, RoleStart.onDemand]
            : [RoleStart.always, RoleStart.onDemand]
    }

    /// Свежий список ролей: ожидание снимается, когда team.yaml показал выбранное или другой режим; ушедшие роли
    /// забываются.
    public mutating func sync(_ rows: [RoleStartRow]) {
        let names = Set(rows.map(\.role))
        for r in rows where r.start == RoleStart.manual { manualKept.insert(r.role) }
        for r in rows where !saving.contains(r.role) {
            guard let p = pending[r.role] else { continue }
            if r.start == p || r.start != pendingFrom[r.role] { pending[r.role] = nil }
        }
        pending = pending.filter { names.contains($0.key) }
        pendingFrom = pendingFrom.filter { pending[$0.key] != nil }
        saving = saving.filter { names.contains($0) }
        errors = errors.filter { names.contains($0.key) }
        manualKept = manualKept.filter { names.contains($0) }
    }

    /// Начинает сохранение. `false` — по роли уже идёт сохранение или режим не меняется.
    public mutating func begin(_ row: RoleStartRow, start: String) -> Bool {
        guard !saving.contains(row.role), start != shown(row) else { return false }
        pending[row.role] = start
        pendingFrom[row.role] = row.start
        saving.insert(row.role)
        errors[row.role] = nil
        return true
    }

    /// Итог `team role set`. Ошибка откатывает строку к сохранённому режиму и остаётся у неё до следующего выбора.
    public mutating func finish(_ role: String, error: String?) {
        saving.remove(role)
        if let error {
            pending[role] = nil
            pendingFrom[role] = nil
            errors[role] = error
        }
    }
}
