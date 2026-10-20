import XCTest
@testable import AgentTeamCore

/// Фоновые субагенты по файлам Claude Code. Фикстуры — живой прогон claude 2.1.295 на временном сокете tmux:
/// сессия запустила два субагента Explore в фоне и закончила ход. `running` — снимок файлов на 18-й секунде (оба
/// работают, экран: «⏺ main / ◯ Explore Список Swift-файлов AgentTeamCore / ◯ Explore Заголовки H2 в SPEC.md»),
/// `done` — после завершения обоих. Пути и служебные записи вычищены.
final class BackgroundAgentsTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        super.tearDown()
    }

    /// Копия фикстуры во временный каталог: время изменения файлов — «сейчас», как у живой сессии.
    private func session(_ name: String) throws -> URL {
        let src = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/subagents"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bg-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: dir)
        dirs.append(dir)
        // copyItem сохраняет время изменения, то есть время checkout: через `stale` после него субагенты считались бы
        // оборванными, и тест падал бы в зависимости от того, когда склонирован репозиторий.
        let fm = FileManager.default
        for case let f as URL in fm.enumerator(at: dir, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator() {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        }
        return dir.appendingPathComponent("session.jsonl")
    }

    func testTwoRunningBackgroundAgentsWithTaskAndAction() throws {
        let bg = BackgroundAgents.read(transcript: try session("running"))
        XCTAssertEqual(bg.running.count, 2)
        XCTAssertEqual(Set(bg.running.map(\.type)), ["Explore"])
        XCTAssertEqual(Set(bg.running.map(\.task)), ["Список Swift-файлов AgentTeamCore", "Заголовки H2 в SPEC.md"])
        XCTAssertTrue(bg.running.allSatisfy(\.background))
        let spec = try XCTUnwrap(bg.running.first { $0.task.contains("SPEC") })
        XCTAssertEqual(spec.action, "Read · /home/owner/shop/docs/SPEC.md")
        let files = try XCTUnwrap(bg.running.first { $0.task.contains("Swift") })
        XCTAssertEqual(files.action.map { $0.hasPrefix("Bash · ") }, true)
        XCTAssertTrue(bg.turnWaits, "ход кончился с pendingBackgroundAgentCount 2 — он их ждёт")
    }

    func testFinishedAgentsDisappear() throws {
        let bg = BackgroundAgents.read(transcript: try session("done"))
        XCTAssertEqual(bg.running, [])
        XCTAssertFalse(bg.turnWaits)
    }

    func testOneFinishedOtherStillRunning() throws {
        // Уведомление пришло только об одном: второй остаётся.
        let url = try session("running")
        let id = try XCTUnwrap(BackgroundAgents.read(transcript: url).running.first { $0.task.contains("SPEC") }?.id)
        let note = #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>\#(id)</task-id>\n<status>completed</status>"}"#
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((note + "\n").utf8))
        try h.close()
        let bg = BackgroundAgents.read(transcript: url)
        XCTAssertEqual(bg.running.map(\.task), ["Список Swift-файлов AgentTeamCore"])
        XCTAssertTrue(bg.turnWaits)
    }

    func testSilentAgentIsStale() throws {
        let url = try session("running")
        let sub = BackgroundAgents.directory(transcript: url)
        let old = Date().addingTimeInterval(-BackgroundAgents.stale - 60)
        for f in try FileManager.default.contentsOfDirectory(atPath: sub.path) where f.hasSuffix(".jsonl") {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: sub.appendingPathComponent(f).path)
        }
        XCTAssertEqual(BackgroundAgents.read(transcript: url), .none)
    }

    func testForegroundAgentFinishesByToolResult() throws {
        let url = try session("running")
        let sub = BackgroundAgents.directory(transcript: url)
        let meta = #"{"agentType":"general-purpose","description":"Обычный субагент","toolUseId":"toolu_fg1","requestShape":"foreground"}"#
        try Data(meta.utf8).write(to: sub.appendingPathComponent("agent-fg1.meta.json"))
        try Data(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Смотрю код."}]}}"#.utf8 + [10]).write(to: sub.appendingPathComponent("agent-fg1.jsonl"))
        var bg = BackgroundAgents.read(transcript: url)
        let fg = try XCTUnwrap(bg.running.first { $0.id == "fg1" })
        XCTAssertFalse(fg.background)
        XCTAssertEqual(fg.action, "Смотрю код.")
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_fg1","content":"готово"}]}}"#
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data((result + "\n").utf8))
        try h.close()
        bg = BackgroundAgents.read(transcript: url)
        XCTAssertNil(bg.running.first { $0.id == "fg1" })
    }

    func testNoSubagentsDirectory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString).jsonl")
        XCTAssertEqual(BackgroundAgents.read(transcript: url), .none)
    }

    func testElapsedText() {
        let a = BackgroundAgent(id: "a", type: "Explore", task: "t", started: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(a.elapsedText(now: Date(timeIntervalSince1970: 12)), "12 с")
        XCTAssertEqual(a.elapsedText(now: Date(timeIntervalSince1970: 185)), "3 мин 05 с")
    }
}
