import Observation
import XCTest
@testable import AgentTeamCore

private final class Counter: @unchecked Sendable { var n = 0 }

final class LiveToggleTests: XCTestCase {
    func testOwnMenuCommandsAreRecognized() {
        XCTAssertEqual(ClaudeOwnMenus.command(in: "/rewind"), "rewind")
        XCTAssertEqual(ClaudeOwnMenus.command(in: "  /Resume  старая сессия "), "resume")
        XCTAssertEqual(ClaudeOwnMenus.command(in: "/model sonnet"), "model")
        XCTAssertNil(ClaudeOwnMenus.command(in: "/compact"))          // без своего меню: работает и из поля приложения
        XCTAssertNil(ClaudeOwnMenus.command(in: "расскажи про /rewind"))
        XCTAssertNil(ClaudeOwnMenus.command(in: "/rewindx"))
        XCTAssertNil(ClaudeOwnMenus.command(in: ""))
    }

    /// Переключатель применяется в открытом окне: наблюдатели видят смену без перезапуска, настройка сохраняется.
    @MainActor
    func testSwitchingAppliesToObserversWithoutRestart() {
        let name = "agent-team-tests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: [])
        XCTAssertFalse(m.liveInputOn)
        let fired = Counter()
        withObservationTracking({ _ = m.liveInputOn }, onChange: { fired.n += 1 })
        m.settings.liveInput = true
        XCTAssertEqual(fired.n, 1, "вид, читавший liveInputOn, перерисуется")
        XCTAssertTrue(m.liveInputOn)
        XCTAssertTrue(DisplaySettingsStore.load(d).liveInput)
        fired.n = 0
        withObservationTracking({ _ = m.liveInputOn }, onChange: { fired.n += 1 })
        m.settings.liveInput = false
        XCTAssertEqual(fired.n, 1)
        XCTAssertFalse(m.liveInputOn)
    }
}
