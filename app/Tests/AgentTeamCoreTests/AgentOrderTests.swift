import XCTest
@testable import AgentTeamCore

/// Порядок колонки агентов и фильтр — по одной классификации статуса; свёрнутость не двигает агента.
final class AgentOrderTests: XCTestCase {
    private func agent(_ role: String, _ n: Int = 1, pane: String? = nil) -> Agent {
        Agent(name: "\(role)#\(n)", role: role, n: n, paneID: pane ?? "%\(role.count)\(n)")
    }

    func testGroupsFromStatus() {
        XCTAssertEqual(AgentGroup(.working), .working)
        XCTAssertEqual(AgentGroup(.waiting("ждёт права")), .waiting)
        XCTAssertEqual(AgentGroup(.quiet(minutes: 5)), .idle)
        XCTAssertEqual(AgentGroup(.noData), .idle)
        XCTAssertEqual(AgentGroup(.stopped), .stopped)
    }

    func testWorkingThenWaitingThenIdleThenStopped() {
        let g: [String: AgentGroup] = ["writer#1": .idle, "developer#1": .waiting, "tester#1": .working,
                                       "reviewer#1": .stopped, "architect#1": .working]
        let list = ["writer", "developer", "tester", "reviewer", "architect"].map { agent($0) }
        let order = AgentOrder.sorted(list) { g[$0.key]! }.map(\.name)
        XCTAssertEqual(order, ["architect#1", "tester#1", "developer#1", "writer#1", "reviewer#1"])
    }

    /// Внутри группы — по роли и номеру; порядок входа (status и панели tmux) на итог не влияет.
    func testStableWithinGroupWhateverInputOrder() {
        let list = [agent("developer", 2), agent("developer", 1), agent("app", 3), agent("developer", 10), agent("app", 1)]
        let expected = ["app#1", "app#3", "developer#1", "developer#2", "developer#10"]
        for seed in 0..<20 {
            var rng = SeededRandom(seed: UInt64(seed))
            let shuffled = list.shuffled(using: &rng)
            XCTAssertEqual(AgentOrder.sorted(shuffled) { _ in .idle }.map(\.name), expected, "перестановка \(seed)")
        }
    }

    func testFilterUsesSameGroups() {
        let g: [String: AgentGroup] = ["a#1": .working, "b#1": .waiting, "c#1": .idle, "d#1": .stopped]
        let list = ["d", "c", "b", "a"].map { agent($0) }
        let group: (Agent) -> AgentGroup = { g[$0.key]! }
        XCTAssertEqual(AgentOrder.visible(list, filter: .working, group: group).map(\.name), ["a#1"],
                       "«Работают» — только те, у кого идёт ход, а не все живые")
        XCTAssertEqual(AgentOrder.visible(list, filter: .waiting, group: group).map(\.name), ["b#1"])
        XCTAssertEqual(AgentOrder.visible(list, filter: .all, group: group).map(\.name), ["a#1", "b#1", "c#1", "d#1"])
        XCTAssertTrue(AgentOrder.visible(["c", "d"].map { agent($0) }, filter: .working, group: group).isEmpty,
                      "под фильтр никто не попал — пустой список, экран показывает пустое состояние")
    }

    // MARK: ключ агента

    /// Два агента одной роли — разные ключи; ключ — имя, `pane:%id` — только у второго агента с тем же именем.
    func testKeysAreUniquePerAgent() {
        let d1 = agent("developer", 1, pane: "%3"), d2 = agent("developer", 2, pane: "%7")
        XCTAssertNotEqual(d1.key, d2.key)
        XCTAssertEqual(d1.key, "developer#1")
        let stray = Agent(name: "developer#1", role: "developer", n: 1, paneID: "%9")
        let keyed = ProjectModel.uniqueKeys([d1, d2, stray])
        XCTAssertEqual(keyed.map(\.key), ["developer#1", "developer#2", "pane:%9"])
        XCTAssertEqual(keyed[2].id, "pane:%9")
    }

    func testPaneWithoutStatusRecordIsKeyedByName() {
        let a = ProjectModel.agent(fromPane: PaneInfo(session: "team-x", paneID: "%12", role: "developer#3", dead: false, pid: 1, path: "/tmp"))
        XCTAssertEqual(a.key, "developer#3")
    }

    /// Новая панель видна в tmux раньше, чем в кеше `team status` (и так же после restart, пока у записи старый
    /// pane_id): агент сначала идёт из панели, потом из status. Ключ и свёрнутость при этом не меняются.
    @MainActor
    func testKeySurvivesStatusCatchingUpWithPane() {
        let p = ProjectModel(repo: NSTemporaryDirectory(), session: "team-x", cli: nil, defaults: UserDefaults(suiteName: "AgentOrderTests")!)
        p.livePanes = { [PaneInfo(session: "team-x", paneID: "%12", role: "developer#3", dead: false, pid: 1, path: "/tmp")] }
        p.statusArrived(TeamStatus(project: "x", repo: NSTemporaryDirectory(), session: "team-x", sessionAlive: true, tracker: nil, agents: []))
        let before = p.teamAgents
        XCTAssertEqual(before.map(\.key), ["developer#3"], "из панели, записи ещё нет")
        let collapsed: Set<String> = [before[0].key]
        // После restart у записи сначала старая панель, её нет среди живых: агент снова из панели.
        p.statusArrived(TeamStatus(project: "x", repo: NSTemporaryDirectory(), session: "team-x", sessionAlive: true, tracker: nil,
                                   agents: [Agent(name: "developer#3", role: "developer", n: 3, kind: "executor", paneID: "%5")]))
        XCTAssertEqual(p.teamAgents.map(\.key), ["developer#3"])
        p.statusArrived(TeamStatus(project: "x", repo: NSTemporaryDirectory(), session: "team-x", sessionAlive: true, tracker: nil,
                                   agents: [Agent(name: "developer#3", role: "developer", n: 3, kind: "executor", paneID: "%12")]))
        let after = p.teamAgents
        XCTAssertEqual(after.map(\.key), ["developer#3"], "status догнал панель — ключ тот же")
        XCTAssertEqual(AgentOrder.items(after, filter: .all, collapsed: collapsed) { _ in .idle }.map(\.collapsed), [true],
                       "свёрнутость сохранилась")
    }

    /// Два агента одной роли сворачиваются и разворачиваются независимо: свёрнутость держится по ключу.
    func testSameRoleAgentsCollapseIndependently() {
        let d1 = agent("developer", 1), d2 = agent("developer", 2)
        let items = { (c: Set<String>) in AgentOrder.items([d1, d2], filter: .all, collapsed: c) { _ in .idle }.map(\.collapsed) }
        XCTAssertEqual(items([]), [false, false])
        XCTAssertEqual(items([d1.key]), [true, false], "свернулся только первый")
        XCTAssertEqual(items([d2.key]), [false, true], "свернулся только второй")
    }

    /// Вероятная причина «разворачиваешь одного — разворачиваются оба»: агент из status `developer#1` на `%3` и живая
    /// панель `%9` с подписью роли без номера (так подписывал старый CLI) — оба получали имя `developer#1`, делили
    /// запись свёрнутости и id строки ForEach. Теперь второй агент с тем же именем получает ключ по своей панели.
    @MainActor
    func testStrayPaneWithCollidingNameGetsOwnKey() {
        let p = ProjectModel(repo: NSTemporaryDirectory(), session: "team-x", cli: nil, defaults: UserDefaults(suiteName: "AgentOrderTests")!)
        let d1 = Agent(name: "developer#1", role: "developer", n: 1, kind: "executor", paneID: "%3")
        p.statusArrived(TeamStatus(project: "x", repo: NSTemporaryDirectory(), session: "team-x", sessionAlive: true, tracker: nil, agents: [d1]))
        p.livePanes = { [PaneInfo(session: "team-x", paneID: "%3", role: "developer#1", dead: false, pid: 1, path: "/tmp"),
                         PaneInfo(session: "team-x", paneID: "%9", role: "developer", dead: false, pid: 2, path: "/tmp")] }
        let agents = p.teamAgents
        XCTAssertEqual(agents.map(\.name), ["developer#1", "developer#1"], "имена совпали")
        XCTAssertEqual(Set(agents.map(\.key)).count, 2, "ключи разные")
        let items = AgentOrder.items(agents, filter: .all, collapsed: [agents[1].key]) { _ in .idle }
        XCTAssertEqual(items.filter(\.collapsed).map(\.agent.paneID), ["%9"], "свернулся только агент панели %9")
    }

    // MARK: раскладка одним списком

    /// Свёрнут агент или развёрнут — его индекс в колонке тот же, и рамка раскрывается на его месте.
    func testToggleDoesNotChangeIndex() {
        let list = ["a", "b", "c", "d", "e"].map { agent($0) }
        let g: [String: AgentGroup] = ["a#1": .working, "b#1": .waiting, "c#1": .idle, "d#1": .idle, "e#1": .working]
        let all = Set(list.map(\.key))
        let collapsedAll = AgentOrder.items(list, filter: .all, collapsed: all) { g[$0.key]! }
        let third = collapsedAll[2].agent
        let expandedThird = AgentOrder.items(list, filter: .all, collapsed: all.subtracting([third.key])) { g[$0.key]! }
        XCTAssertEqual(collapsedAll.map(\.agent.key), expandedThird.map(\.agent.key), "порядок тот же")
        XCTAssertEqual(expandedThird.firstIndex { $0.agent.key == third.key }, 2, "третий остался третьим")
        XCTAssertFalse(expandedThird[2].collapsed)
        for cols in [1, 2] {
            let before = AgentColumnLayout.frames(collapsed: collapsedAll.map(\.collapsed), width: 400, columns: cols, gap: 4, paneHeight: 200, rowHeight: 44)
            let after = AgentColumnLayout.frames(collapsed: expandedThird.map(\.collapsed), width: 400, columns: cols, gap: 4, paneHeight: 200, rowHeight: 44)
            XCTAssertEqual(before[2].y, after[2].y, "столбцов \(cols): третий раскрывается на своём месте")
            XCTAssertEqual(after[2].height, 200)
            XCTAssertLessThan(after[1].y, after[2].y)
            XCTAssertLessThan(after[2].y, after[3].y, "следующие сдвигаются вниз, но остаются после него")
        }
    }

    func testPaneLimitDropsOnlyExtraExpanded() {
        let list = ["a", "b", "c"].map { agent($0) }
        let items = AgentOrder.items(list, filter: .all, collapsed: ["b#1"], paneLimit: 1) { _ in .idle }
        XCTAssertEqual(items.map(\.agent.name), ["a#1", "b#1"])
    }

    func testTwoColumnsWithCollapsedRowsBetween() {
        // развёрнут, развёрнут, свёрнут, развёрнут: ряд из двух, строка, одинокая панель во всю ширину.
        let f = AgentColumnLayout.frames(collapsed: [false, false, true, false], width: 404, columns: 2, gap: 4, paneHeight: 100, rowHeight: 44)
        XCTAssertEqual(f[0], ColumnFrame(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(f[1], ColumnFrame(x: 204, y: 0, width: 200, height: 100))
        XCTAssertEqual(f[2], ColumnFrame(x: 0, y: 104, width: 404, height: 44))
        XCTAssertEqual(f[3], ColumnFrame(x: 0, y: 152, width: 404, height: 100))
        XCTAssertEqual(AgentColumnLayout.height(f), 252)
        XCTAssertEqual(AgentColumnLayout.paneRows(collapsed: [false, false, true, false], columns: 2), 2)
        // Строка прерывает неполный ряд: одинокая панель перед ней тоже во всю ширину.
        let g = AgentColumnLayout.frames(collapsed: [false, true, false, false], width: 404, columns: 2, gap: 4, paneHeight: 100, rowHeight: 44)
        XCTAssertEqual(g[0].width, 404)
        XCTAssertEqual(g[1].y, 104)
        XCTAssertEqual(g[2], ColumnFrame(x: 0, y: 152, width: 200, height: 100))
        XCTAssertEqual(AgentColumnLayout.paneRows(collapsed: [false, true, false, false], columns: 2), 2)
    }

    func testOneColumnMatchesOldGrid() {
        let f = AgentColumnLayout.frames(collapsed: [true, false, false], width: 300, columns: 1, gap: 4, paneHeight: 100, rowHeight: 44)
        XCTAssertEqual(f.map(\.y), [0, 48, 152])
        XCTAssertEqual(AgentColumnLayout.paneRows(collapsed: [true, false, false], columns: 1), 2)
        XCTAssertEqual(SplitLayout.paneHeight(available: 1000, collapsedRows: 1, paneRows: 2, gap: 4),
                       SplitLayout.paneHeight(available: 1000, collapsedRows: 1, panes: 2, columns: 1, gap: 4))
    }
}

/// Воспроизводимые перестановки для теста устойчивости порядка.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
