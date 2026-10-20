import Foundation

/// Деление списка ролей экрана «Роли» на два блока: роли проекта и общая библиотека.
public enum RoleGroups {
    /// Общая роль, на которой основана роль проекта: из `extends` или, если роль проекта лежит под тем же именем, что
    /// и общая, — эта общая роль. Строка списка пишет «← общая <имя>».
    public static func baseName(_ role: RoleInfo, shared: [RoleInfo]) -> String? {
        if role.isInheriting, let e = role.extends, !e.isEmpty { return e }
        return shared.contains { $0.role == role.role } ? role.role : nil
    }

    public static func baseLabel(_ role: RoleInfo, shared: [RoleInfo]) -> String? {
        baseName(role, shared: shared).map { "← общая \($0)" }
    }

    /// Общая роль уже подключена к проекту: у проекта есть роль с этим именем или наследующая от неё.
    public static func isInProject(_ shared: RoleInfo, projectRoles: [RoleInfo]) -> Bool {
        projectRoles.contains { $0.role == shared.role || $0.extends == shared.role }
    }

    /// Общие роли в списке — только те, что ещё можно добавить: одна роль — одна строка, поэтому общая роль, которая
    /// уже есть в проекте (то же имя или `extends`), отдельной строкой не показывается. Порядок библиотеки сохраняется.
    public static func addableShared(_ shared: [RoleInfo], projectRoles: [RoleInfo]) -> [RoleInfo] {
        shared.filter { !isInProject($0, projectRoles: projectRoles) }
    }

    /// Роль, которую открывает выбор: имя + блок (имена в блоках могут совпадать).
    public static func resolve(_ name: String?, shared: Bool, in roles: [RoleInfo]) -> RoleInfo? {
        let pool = roles.filter { $0.isShared == shared }
        return pool.first { $0.role == name } ?? (shared ? nil : pool.first)
    }
}
