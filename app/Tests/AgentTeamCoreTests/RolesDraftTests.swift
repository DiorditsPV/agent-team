import Foundation
import XCTest
@testable import AgentTeamCore

final class RolesDraftTests: XCTestCase {
    func role(_ json: String) throws -> RoleInfo { try JSONDecoder().decode(RoleInfo.self, from: Data(json.utf8)) }

    func testDraftFromRoleAndTeamYAMLStart() throws {
        let r = try role(#"{"role":"developer","title":"Разработчик","model":"sonnet","description":"Код","start":"always"}"#)
        XCTAssert(RoleDraft(role: r) == RoleDraft(title: "Разработчик", model: "sonnet", description: "Код", start: "always"))
        XCTAssert(RoleDraft(role: r, startOverride: "on_demand").start == "on_demand")
        let bare = try role(#"{"role":"x"}"#)
        XCTAssert(RoleDraft(role: bare) == RoleDraft(title: "", model: "", description: "", start: "manual"))
    }

    func testChangesOnlyEditedFields() {
        let base = RoleDraft(title: "Разработчик", model: "sonnet", description: "Код", start: "always")
        var d = base
        XCTAssert(d.changed(from: base).isEmpty)
        XCTAssert(RoleDraft.badge(d.changed(from: base)) == nil)
        d.description = "Код  \n"                     // пробелы по краям — не правка
        XCTAssert(d.changed(from: base).isEmpty)
        d.description = "Код и тесты"
        XCTAssert(d.changed(from: base) == [.description])
        XCTAssert(RoleDraft.badge(d.changed(from: base)) == "описание изменено")
        d.model = "opus"
        XCTAssert(RoleDraft.badge(d.changed(from: base)) == "изменены: модель, описание")
        let c = d.changes(from: base)
        XCTAssert(c.title == nil && c.start == nil)
        XCTAssert(c.model == "opus" && c.description == "Код и тесты")
        d.title = "  "
        XCTAssert(!d.isValid)
    }

    /// Пока владелец правит описание, менеджер меняет модель через `team role set`. Сохранение отправляет
    /// только описание, модель остаётся новой.
    func testExternalChangeIsNotRolledBack() {
        let before = RoleDraft(title: "Разработчик", model: "sonnet", description: "Код", start: "always")
        var e = RoleEdits()
        var form = e.applied(to: before)
        form.description = "Код и тесты"
        e.record(form, base: before)
        XCTAssertEqual(e.values, [.description: "Код и тесты"])

        var after = before
        after.model = "opus"                               // team role set developer --model opus
        XCTAssertEqual(e.applied(to: after).model, "opus", "форма показывает новую модель")
        XCTAssertEqual(e.changed(from: after), [.description])
        XCTAssertEqual(RoleDraft.badge(e.changed(from: after)), "описание изменено")
        let c = e.changes(from: after)
        XCTAssertNil(c.model, "модель не отправляется и не откатывается")
        XCTAssertEqual(c.description, "Код и тесты")
        XCTAssertNil(c.title)
        XCTAssertNil(c.start)
    }

    func testEditReturnedToRoleValueIsDropped() {
        let base = RoleDraft(title: "Разработчик", model: "sonnet", description: "Код", start: "always")
        var e = RoleEdits()
        var form = e.applied(to: base)
        form.model = "opus"
        e.record(form, base: base)
        XCTAssertFalse(e.isEmpty)
        form.model = "sonnet"
        e.record(form, base: base)
        XCTAssertTrue(e.isEmpty)
        // Пробел в конце набираемого текста остаётся в поле, хотя правкой ещё не считается.
        form.description = "Код "
        e.record(form, base: base)
        XCTAssertEqual(e.applied(to: base).description, "Код ")
        XCTAssertEqual(e.changed(from: base), [])
    }

    func testSameFieldChangedOutsideKeepsOwnerValue() {
        let before = RoleDraft(title: "Разработчик", model: "sonnet", description: "Код", start: "always")
        var e = RoleEdits()
        var form = e.applied(to: before)
        form.model = "haiku"
        e.record(form, base: before)
        var after = before
        after.model = "opus"
        XCTAssertEqual(e.changes(from: after).model, "haiku", "своё поле владелец правит сам — сохраняется его значение")
    }

    func testSummary() {
        XCTAssert(RoleSummary.zone([]) == "—")
        XCTAssert(RoleSummary.zone(["app/"]) == "app/")
        XCTAssert(RoleSummary.zone(["app/", "server/", "job/"], repo: "shop") == "shop: app/ +2")
        XCTAssert(RoleSummary.repoName("../shop") == "shop")
        XCTAssert(RoleSummary.repoName(nil) == nil)
        XCTAssert(RoleSummary.lineCount("a\n\n- b\n  \nc") == 3)
    }
}

