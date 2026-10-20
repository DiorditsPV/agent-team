import XCTest
@testable import AgentTeamCore

final class SidebarStateTests: XCTestCase {
    @MainActor
    func testSidebarCollapsedIsRemembered() throws {
        let name = "agtest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        XCTAssertFalse(first.sidebarCollapsed)          // по умолчанию панель открыта
        first.sidebarCollapsed = true
        let second = AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false)
        XCTAssertTrue(second.sidebarCollapsed)
        second.sidebarCollapsed = false
        XCTAssertFalse(AppModel(defaults: defaults, socketName: "agtest-none-\(getpid())", loginEnvironment: false).sidebarCollapsed)
    }
}
