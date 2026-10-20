import Foundation
import XCTest
@testable import AgentTeamCore

final class RoleStartsTests: XCTestCase {
    func role(_ json: String) throws -> RoleInfo { try JSONDecoder().decode(RoleInfo.self, from: Data(json.utf8)) }

    func roles() throws -> [RoleInfo] {
        [try role(#"{"role":"manager","kind":"manager","title":"Менеджер","start":"always"}"#),
         try role(#"{"role":"developer","title":"Разработчик","start":"always"}"#),
         try role(#"{"role":"reviewer","title":"Ревьюер","start":"on_demand"}"#),
         try role(#"{"role":"writer"}"#),
         try role(#"{"role":"developer","source":"library","title":"Разработчик (общая)","start":"manual"}"#),
         try role(#"{"role":"judge","source":"library","title":"Судья"}"#)]
    }

    func testRowsSkipManagerAndTakeStartLikeRolesScreen() throws {
        let rows = RoleStart.rows(roles: try roles(), starts: ["reviewer": "always"])
        XCTAssertEqual(rows.map(\.role), ["developer", "reviewer", "writer"])        // без менеджера и общих ролей библиотеки
        XCTAssertEqual(rows.map(\.start), ["always", "always", "manual"])   // team.yaml, затем роль, затем manual
        XCTAssertEqual(rows.map(\.title), ["Разработчик", "Ревьюер", "writer"])
        // Значение то же, что показывает экран «Роли».
        for (r, row) in zip(try roles().dropFirst().prefix(3), rows) {
            XCTAssertEqual(row.start, RoleDraft(role: r, startOverride: ["reviewer": "always"][r.role]).start)
        }
    }

    func testManualStaysAnOptionWhileScreenIsOpen() {
        let row = RoleStartRow(role: "writer", title: "writer", start: "manual")
        var e = RoleStartEdits()
        e.sync([row])
        XCTAssertEqual(e.options(row), ["manual", "always", "on_demand"])
        XCTAssertTrue(e.begin(row, start: "on_demand"))
        e.finish("writer", error: nil)
        let saved = RoleStartRow(role: "writer", title: "writer", start: "on_demand")
        e.sync([saved])
        XCTAssertEqual(e.shown(saved), "on_demand")
        XCTAssertEqual(e.options(saved), ["manual", "always", "on_demand"])  // вариант не пропал после щелчка
        let plain = RoleStartRow(role: "developer", title: "Разработчик", start: "always")
        e.sync([saved, plain])
        XCTAssertEqual(e.options(plain), ["always", "on_demand"])
    }

    func testPendingShownUntilTeamYAMLCatchesUp() {
        let row = RoleStartRow(role: "developer", title: "Разработчик", start: "always")
        var e = RoleStartEdits()
        XCTAssertTrue(e.begin(row, start: "on_demand"))
        XCTAssertEqual(e.shown(row), "on_demand")
        XCTAssertFalse(e.begin(row, start: "always"))                 // пока идёт сохранение, второй выбор не принимается
        e.finish("developer", error: nil)
        e.sync([row])                                                  // team.yaml ещё не перечитан
        XCTAssertEqual(e.shown(row), "on_demand")
        let fresh = RoleStartRow(role: "developer", title: "Разработчик", start: "on_demand")
        e.sync([fresh])
        XCTAssertNil(e.pending["developer"])
        XCTAssertEqual(e.shown(fresh), "on_demand")
        XCTAssertFalse(e.begin(fresh, start: "on_demand"))            // тот же режим не сохраняется
    }

    func testErrorRollsBackAndStaysOnItsRow() {
        let dev = RoleStartRow(role: "developer", title: "Разработчик", start: "always")
        let rev = RoleStartRow(role: "reviewer", title: "Ревьюер", start: "always")
        var e = RoleStartEdits()
        XCTAssertTrue(e.begin(dev, start: "on_demand"))
        e.finish("developer", error: "строка роли не найдена")
        XCTAssertEqual(e.shown(dev), "always")
        XCTAssertEqual(e.errors, ["developer": "строка роли не найдена"])
        XCTAssertTrue(e.saving.isEmpty)
        XCTAssertTrue(e.begin(rev, start: "on_demand"))
        XCTAssertEqual(e.errors["developer"], "строка роли не найдена")  // чужой выбор ошибку не стирает
        XCTAssertTrue(e.begin(dev, start: "on_demand"))
        XCTAssertNil(e.errors["developer"])                           // следующий выбор своей строки — стирает
    }

    func testGoneRolesAreForgotten() {
        let dev = RoleStartRow(role: "developer", title: "Разработчик", start: "manual")
        var e = RoleStartEdits()
        e.sync([dev])
        XCTAssertTrue(e.begin(dev, start: "always"))
        e.finish("developer", error: "ошибка")
        e.sync([])
        XCTAssertEqual(e, RoleStartEdits())
    }

    /// Режим сменили иначе (карточкой роли, менеджер), пока список ждал team.yaml: ожидание снимается, строка
    /// показывает файл, а не прежний выбор.
    func testPendingDroppedWhenTeamYAMLShowsAnotherStart() {
        let row = RoleStartRow(role: "developer", title: "Разработчик", start: "always")
        var e = RoleStartEdits()
        XCTAssertTrue(e.begin(row, start: "on_demand"))
        e.finish("developer", error: nil)
        e.sync([row])
        XCTAssertEqual(e.shown(row), "on_demand")
        let other = RoleStartRow(role: "developer", title: "Разработчик", start: "manual")
        e.sync([other])
        XCTAssertNil(e.pending["developer"])
        XCTAssertEqual(e.shown(other), "manual")
    }

    /// Вариант «вручную» появляется и по значению, которое показывает список (правка карточки), а не только по файлу.
    func testManualOptionFollowsShownValue() {
        let row = RoleStartRow(role: "developer", title: "Разработчик", start: "always")
        let e = RoleStartEdits()
        XCTAssertEqual(e.options(row), ["always", "on_demand"])
        XCTAssertEqual(e.options(row, shown: "manual"), ["manual", "always", "on_demand"])
    }

    func testLabels() {
        XCTAssertEqual(RoleStart.label("always"), "постоянная")
        XCTAssertEqual(RoleStart.label("on_demand"), "по требованию")
        XCTAssertEqual(RoleStart.label("manual"), "вручную")
    }
}
