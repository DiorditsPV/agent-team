import Foundation
import XCTest
@testable import AgentTeamCore

final class RoleGroupsTests: XCTestCase {
    /// Схема `team roles --json --library`: source project|library, extends у наследующей роли.
    let stub = """
    [{"role":"manager","title":"Менеджер","kind":"manager","source":"project"},
     {"role":"judge-lite","title":"Судья проекта","source":"project","extends":"judge"},
     {"role":"developer","title":"Разработчик"},
     {"role":"judge","title":"Судья","source":"library","body":"# Судья"},
     {"role":"writer","title":"Писатель","source":"library"}]
    """

    func roles() throws -> [RoleInfo] { try JSONDecoder().decode([RoleInfo].self, from: Data(stub.utf8)) }

    func testDecodesSourceAndExtends() throws {
        let r = try roles()
        XCTAssertTrue(r[3].isShared)
        XCTAssertTrue(r[1].isInheriting)
        XCTAssertEqual(r[1].extends, "judge")
        XCTAssertFalse(r[2].isShared)          // без source — роль проекта
        XCTAssertFalse(r[2].isInheriting)
    }

    func testInheritLabelAndMembership() throws {
        let r = try roles()
        let project = r.filter { !$0.isShared }
        let lib = r.filter(\.isShared)
        XCTAssertEqual(RoleGroups.baseLabel(r[1], shared: lib), "← общая judge")   // по extends
        XCTAssertNil(RoleGroups.baseLabel(r[2], shared: lib))                              // developer — своей общей нет
        var same = r[2]; same.role = "writer"
        XCTAssertEqual(RoleGroups.baseLabel(same, shared: lib), "← общая writer")   // то же имя, без extends
        XCTAssertTrue(RoleGroups.isInProject(r[3], projectRoles: project))    // judge — через extends
        XCTAssertFalse(RoleGroups.isInProject(r[4], projectRoles: project))   // writer — можно добавить
    }

    func testSharedRolesHideWhenInProject() throws {
        let stub2 = """
        [{"role":"manager","kind":"manager","source":"project"},
         {"role":"judge-lite","source":"project","extends":"judge"},
         {"role":"architect","source":"library"},
         {"role":"judge","source":"library"},
         {"role":"manager","source":"library"},
         {"role":"writer","source":"library"}]
        """
        let r = try JSONDecoder().decode([RoleInfo].self, from: Data(stub2.utf8))
        let shown = RoleGroups.addableShared(r.filter(\.isShared), projectRoles: r.filter { !$0.isShared })
        // judge подключён через extends, manager — по имени: отдельной строкой их нет; остальные — в порядке библиотеки.
        XCTAssertEqual(shown.map(\.role), ["architect", "writer"])
    }

    @MainActor
    func testProjectRolesKeepTeamYamlOrder() async throws {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-roles-order", session: "team-ro", cli: nil)
        m.rolesOverride = try JSONDecoder().decode([RoleInfo].self, from: Data("""
        [{"role":"manager","source":"project"},{"role":"tester","source":"project"},{"role":"app-developer","source":"project"},
         {"role":"developer","source":"project"},{"role":"architect","source":"library"},{"role":"judge","source":"library"}]
        """.utf8))
        m.start()   // загрузки идут только у открытого проекта
        for _ in 0..<100 where m.roles.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(m.projectRoles.map(\.role), ["manager", "tester", "app-developer", "developer"], "порядок team.yaml, не по алфавиту")
        XCTAssertEqual(m.sharedRoles.map(\.role), ["architect", "judge"])
        XCTAssertEqual(m.libraryRoles.map(\.role), ["architect", "judge"])
    }

    func testResolveSeparatesBlocksWithSameName() throws {
        var r = try roles()
        r.append(RoleInfo(role: "judge", title: "Судья проекта"))
        XCTAssertEqual(RoleGroups.resolve("judge", shared: true, in: r)?.title, "Судья")
        XCTAssertEqual(RoleGroups.resolve("judge", shared: false, in: r)?.title, "Судья проекта")
        XCTAssertEqual(RoleGroups.resolve("nope", shared: false, in: r)?.role, "manager")   // по умолчанию — первая роль проекта
        XCTAssertNil(RoleGroups.resolve("nope", shared: true, in: r))
    }
}
