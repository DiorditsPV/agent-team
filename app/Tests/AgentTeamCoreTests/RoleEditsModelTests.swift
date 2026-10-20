import Foundation
import XCTest
@testable import AgentTeamCore

/// Правки ролей в модели проекта и выбор роли.
final class RoleEditsModelTests: XCTestCase {
    let base = RoleDraft(title: "Разработчик", model: "sonnet", description: "Код", start: "always")

    func tempDir(_ tag: String) throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-roleedits-\(tag)-\(getpid())")
        try? FileManager.default.removeItem(at: d)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Фальшивый team: `role set` пишет аргументы в журнал и ждёт файла-ворот, остальные команды отвечают сразу.
    func makeCLI(in dir: URL, fail: Bool = false) throws -> TeamCLI {
        let log = dir.appendingPathComponent("calls"), gate = dir.appendingPathComponent("release")
        let script = dir.appendingPathComponent("team")
        let reply = fail ? "echo 'team: роль занята' >&2; exit 1" : #"echo '{"role":"developer"}'"#
        try """
        #!/bin/sh
        case "$1" in
        role)
          echo "$*" >> '\(log.path)'
          while [ ! -e '\(gate.path)' ]; do sleep 0.05; done
          \(reply);;
        roles) echo '[]';;
        *) echo '{}';;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return try XCTUnwrap(TeamCLI.resolve(toolPath: script.path))
    }

    func calls(_ dir: URL) -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func release(_ dir: URL) { FileManager.default.createFile(atPath: dir.appendingPathComponent("release").path, contents: Data()) }

    @MainActor
    func waitUntil(timeout: TimeInterval = 20, _ condition: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func model(_ dir: URL, cli: TeamCLI?) -> ProjectModel {
        ProjectModel(repo: dir.path, session: "team-p", cli: cli, defaults: UserDefaults(suiteName: "agtest-re-\(getpid())")!)
    }

    @MainActor
    func type(_ p: ProjectModel, description: String) {
        var form = (p.roleEdits["developer"] ?? RoleEdits()).applied(to: base)
        form.description = description
        p.recordRoleEdit("developer", form: form, base: base)
    }

    /// Находка 14: правка лежит в модели проекта, а не в экране. Экран «Роли» пересоздаётся при смене раздела
    /// и читает её заново; перечитывание ролей правку не трогает.
    @MainActor
    func testEditLivesInProjectModel() async throws {
        let dir = try tempDir("lives")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: nil)
        type(p, description: "Длинное описание роли")
        p.refreshAll()
        XCTAssertEqual(p.roleEdits["developer"]?.applied(to: base).description, "Длинное описание роли")
        p.discardRoleEdits("developer")
        XCTAssertNil(p.roleEdits["developer"])
    }

    /// Находка 14: текст, допечатанный, пока `team role set` работает, после сохранения остаётся правкой.
    /// Отправлено «Код и тесты», в поле уже «Код и тесты, ревью» — стирать нечего.
    @MainActor
    func testTextTypedDuringSaveSurvives() async throws {
        let dir = try tempDir("typed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: try makeCLI(in: dir))
        type(p, description: "Код и тесты")
        let save = Task { await p.saveRoleEdits("developer", base: base) }
        try await waitUntil { !self.calls(dir).isEmpty }
        XCTAssertTrue(p.savingRoles.contains("developer"))
        let again = await p.saveRoleEdits("developer", base: base)
        XCTAssertFalse(again, "второе сохранение до ответа не отправляется")
        type(p, description: "Код и тесты, ревью")
        release(dir)
        let ok = await save.value
        XCTAssertTrue(ok)
        XCTAssertEqual(calls(dir), ["role set developer --description Код и тесты"])
        XCTAssertEqual(p.roleEdits["developer"]?.applied(to: base).description, "Код и тесты, ревью",
                       "допечатанное во время сохранения не стирается")
        XCTAssertFalse(p.savingRoles.contains("developer"))
    }

    /// Сохранённая без допечатки правка стирается; при сбое `team role set` правка остаётся.
    @MainActor
    func testSavedEditClearedFailedKept() async throws {
        let dir = try tempDir("cleared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: try makeCLI(in: dir))
        type(p, description: "Код и тесты")
        release(dir)
        let ok = await p.saveRoleEdits("developer", base: base)
        XCTAssertTrue(ok)
        XCTAssertNil(p.roleEdits["developer"])

        let failDir = try tempDir("failed")
        defer { try? FileManager.default.removeItem(at: failDir) }
        let q = model(failDir, cli: try makeCLI(in: failDir, fail: true))
        type(q, description: "Код и тесты")
        release(failDir)
        let failed = await q.saveRoleEdits("developer", base: base)
        XCTAssertFalse(failed)
        XCTAssertEqual(q.roleEdits["developer"]?.applied(to: base).description, "Код и тесты")
    }

    /// Находка 15: после общей роли выбор роли проекта (создание роли, щелчок в «Составе») открывает её,
    /// а не первую роль проекта; одноимённая общая роль не перехватывает выбор.
    @MainActor
    func testSelectRoleSetsBlock() throws {
        let roles = try JSONDecoder().decode([RoleInfo].self, from: Data(#"""
        [{"role":"developer"},{"role":"tester"},{"role":"judge"},
         {"role":"judge","source":"library"},{"role":"reviewer","source":"library"}]
        """#.utf8))
        let app = AppModel(defaults: UserDefaults(suiteName: "agtest-sel-\(getpid())")!, socketName: "agtest-none-\(getpid())",
                           loginEnvironment: false)
        let open = { RoleGroups.resolve(app.selectedRole, shared: app.selectedRoleShared, in: roles) }

        app.selectRole("reviewer", shared: true)
        XCTAssertEqual(open()?.role, "reviewer")
        XCTAssertEqual(open()?.isShared, true)

        app.selectRole("tester")                         // создана роль tester
        XCTAssertEqual(open()?.role, "tester")
        XCTAssertEqual(open()?.isShared, false)

        app.selectRole("judge", shared: true)
        app.selectRole("judge")                          // щелчок по judge в «Составе»
        XCTAssertEqual(open()?.isShared, false, "открывается роль проекта, а не общая с тем же именем")

        app.selectRole("judge", shared: true)
        app.selectRole(nil)                              // смена проекта
        XCTAssertFalse(app.selectedRoleShared)
    }

    // MARK: режим запуска в списке ролей

    @MainActor
    func withRoles(_ p: ProjectModel) async throws {
        p.rolesOverride = try JSONDecoder().decode([RoleInfo].self, from: Data(#"""
        [{"role":"manager","kind":"manager","title":"Менеджер","start":"always"},
         {"role":"developer","title":"Разработчик","model":"sonnet","description":"Код","start":"always"}]
        """#.utf8))
        p.start()                              // загрузки идут только у открытого проекта
        try await waitUntil { !p.roles.isEmpty }
        XCTAssertEqual(p.roleStartRows.map(\.role), ["developer"], "у менеджера переключателя нет")
    }

    @MainActor
    func pick(_ p: ProjectModel, start: String) {
        var form = (p.roleEdits["developer"] ?? RoleEdits()).applied(to: base)
        form.start = start
        p.recordRoleEdit("developer", form: form, base: base)
    }

    /// Выбор в списке уходит одним `--start`. Начатые в карточке название, модель и описание остаются черновиком;
    /// правка режима в карточке снимается, а карточка сразу показывает выбранное — то же значение, что список.
    @MainActor
    func testListStartKeepsCardDraft() async throws {
        let dir = try tempDir("start-keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: try makeCLI(in: dir))
        defer { p.stop() }
        try await withRoles(p)
        type(p, description: "Код и тесты")
        pick(p, start: "manual")
        XCTAssertEqual(p.roleStartShown("developer"), "manual", "список показывает значение карточки")
        release(dir)
        let ok = await p.saveRoleStart("developer", "on_demand")
        XCTAssertTrue(ok)
        XCTAssertEqual(calls(dir), ["role set developer --start on_demand"])
        let role = try XCTUnwrap(p.role(named: "developer"))
        XCTAssertEqual(p.roleEdits["developer"]?.applied(to: p.roleBase(role)).description, "Код и тесты")
        XCTAssertNil(p.roleEdits["developer"]?.values[.start], "правка режима в карточке снята")
        XCTAssertEqual(p.roleBase(role).start, "on_demand", "карточка до перечитывания team.yaml показывает выбранное")
        XCTAssertEqual(p.roleStartShown("developer"), "on_demand")
        XCTAssertEqual(p.roleEdits["developer"]?.changed(from: p.roleBase(role)), [.description])
    }

    /// Сбой `team role set`: правка режима возвращается в карточку, текст ошибки — у строки списка, а не всплывающим
    /// сообщением; черновик описания на месте.
    @MainActor
    func testListStartFailureRestoresDraft() async throws {
        let dir = try tempDir("start-fail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: try makeCLI(in: dir, fail: true))
        defer { p.stop() }
        try await withRoles(p)
        type(p, description: "Код и тесты")
        pick(p, start: "manual")
        release(dir)
        let ok = await p.saveRoleStart("developer", "on_demand")
        XCTAssertFalse(ok)
        XCTAssertEqual(p.roleEdits["developer"]?.values[.start], "manual")
        XCTAssertEqual(p.roleEdits["developer"]?.values[.description], "Код и тесты")
        XCTAssertEqual(p.roleStartShown("developer"), "manual")
        XCTAssertTrue(p.roleStarts.errors["developer"]?.contains("роль занята") ?? false, "\(p.roleStarts.errors)")
        XCTAssertNil(p.lastActionMessage)
        XCTAssertFalse(p.savingRoles.contains("developer"))
    }

    /// Пока режим сохраняется, ни второй выбор в списке, ни «Сохранить» карточки по этой роли не отправляются.
    @MainActor
    func testListStartBlocksSecondSave() async throws {
        let dir = try tempDir("start-busy")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: try makeCLI(in: dir))
        defer { p.stop() }
        try await withRoles(p)
        let save = Task { await p.saveRoleStart("developer", "on_demand") }
        try await waitUntil { !self.calls(dir).isEmpty }
        XCTAssertTrue(p.savingRoles.contains("developer"))
        let again = await p.saveRoleStart("developer", "manual")
        XCTAssertFalse(again)
        type(p, description: "Код и тесты")
        let card = await p.saveRoleEdits("developer", base: base)
        XCTAssertFalse(card, "карточка не сохраняется поверх")
        release(dir)
        let ok = await save.value
        XCTAssertTrue(ok)
        XCTAssertEqual(calls(dir), ["role set developer --start on_demand"])
    }

    /// Выбор сохранённого режима, когда в карточке начата другая правка режима: правка снимается, team не вызывается.
    @MainActor
    func testListPickOfSavedStartDropsDraftOnly() async throws {
        let dir = try tempDir("start-same")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = model(dir, cli: try makeCLI(in: dir))
        defer { p.stop() }
        try await withRoles(p)
        pick(p, start: "on_demand")
        let ok = await p.saveRoleStart("developer", "always")
        XCTAssertFalse(ok)
        XCTAssertNil(p.roleEdits["developer"])
        XCTAssertEqual(p.roleStartShown("developer"), "always")
        XCTAssertTrue(calls(dir).isEmpty)
    }
}
