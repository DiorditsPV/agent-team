import XCTest
@testable import AgentTeamCore

/// Отдельные сессии Claude Code: запись по pid, имена tmux, хранение списка.
final class SoloStoreTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for d in cleanup { try? FileManager.default.removeItem(at: d) }
        cleanup = []
    }

    private func tempHome(files: [String: String]) throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("solo-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".claude/sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        cleanup.append(home)
        return home.path
    }

    // MARK: запись по pid

    func testPlainRecord() throws {
        let home = try tempHome(files: ["42.json": #"{"sessionId":"s1","status":"busy","statusUpdatedAt":1700000000000}"#])
        let rec = try XCTUnwrap(ClaudeSessionRecord.read(pid: 42, home: home))
        XCTAssertEqual(rec.sessionID, "s1")
        XCTAssertEqual(rec.state, "busy")
        XCTAssertEqual(rec.statusUpdatedAt, 1700000000000)
        XCTAssertFalse(rec.parked)
    }

    func testParkedWithJobTakesJobRecord() throws {
        let home = try tempHome(files: [
            "42.json": #"{"sessionId":"s1","status":"idle","parkedJobId":"job9"}"#,
            "77.json": #"{"sessionId":"s2","status":"waiting","jobId":"job9"}"#,
            "78.json": #"{"sessionId":"s3","jobId":"other"}"#,
        ])
        let rec = try XCTUnwrap(ClaudeSessionRecord.read(pid: 42, home: home))
        XCTAssertEqual(rec.sessionID, "s2")
        XCTAssertEqual(rec.state, "waiting")
        XCTAssertTrue(rec.parked)
    }

    func testParkedWithoutJobKeepsPaneRecord() throws {
        let home = try tempHome(files: ["42.json": #"{"sessionId":"s1","status":"idle","parkedJobId":"gone"}"#])
        let rec = try XCTUnwrap(ClaudeSessionRecord.read(pid: 42, home: home))
        XCTAssertEqual(rec.sessionID, "s1")
        XCTAssertTrue(rec.parked)
    }

    func testBrokenJSONAndMissingFile() throws {
        let home = try tempHome(files: ["42.json": "{не json", "43.json": #"{"status":"idle"}"#])
        XCTAssertNil(ClaudeSessionRecord.read(pid: 42, home: home))
        XCTAssertNil(ClaudeSessionRecord.read(pid: 43, home: home))
        XCTAssertNil(ClaudeSessionRecord.read(pid: 99, home: home))
        XCTAssertNil(ClaudeSessionRecord.read(pid: 0, home: home))
        XCTAssertNil(ClaudeSessionRecord.read(pid: 1, home: "/nonexistent-\(UUID().uuidString)"))
    }

    func testUnknownStatusIsUnknownState() throws {
        let home = try tempHome(files: ["42.json": #"{"sessionId":"s1","status":"weird"}"#])
        let rec = ClaudeSessionRecord.read(pid: 42, home: home)
        XCTAssertNil(rec?.state)
        XCTAssertEqual(ClaudeState(record: rec), .unknown)
        XCTAssertEqual(ClaudeState(record: nil), .unknown)
    }

    // MARK: имена

    func testNameForPlainDirectory() {
        let id = UUID(uuidString: "3F2A0000-0000-0000-0000-000000000000")!
        XCTAssertEqual(SoloNaming.tmuxName(cwd: "/Users/x/dev/agent-team", id: id), "cc-agent-team-3f2a")
    }

    func testCyrillicAndSpaces() {
        let id = UUID(uuidString: "AAAA0000-0000-0000-0000-000000000000")!
        XCTAssertEqual(SoloNaming.tmuxName(cwd: "/Users/x/Мой проект", id: id), "cc-claude-aaaa")
        XCTAssertEqual(SoloNaming.sanitized(cwd: "/a/My  Cool_App v2"), "my-cool-app-v2")
        XCTAssertEqual(SoloNaming.sanitized(cwd: "/a/Проект app"), "app")
    }

    func testLongPathIsCut() {
        let long = "/x/" + String(repeating: "a", count: 100)
        XCTAssertEqual(SoloNaming.sanitized(cwd: long).count, 40)
        let dashed = "/x/" + String(repeating: "a", count: 39) + "-bbb"
        XCTAssertFalse(SoloNaming.sanitized(cwd: dashed).hasSuffix("-"))
    }

    func testSameDirectoryDifferentIDs() {
        let a = SoloNaming.tmuxName(cwd: "/p/app", id: UUID())
        let b = SoloNaming.tmuxName(cwd: "/p/app", id: UUID())
        XCTAssertNotEqual(a, b)
        let id = UUID()
        let first = SoloNaming.tmuxName(cwd: "/p/app", id: id)
        let unique = SoloNaming.uniqueTmuxName(cwd: "/p/app", id: id, taken: [first])
        XCTAssertNotEqual(unique, first)
        XCTAssertTrue(unique.hasPrefix(first))
    }

    // MARK: хранилище

    private func store() throws -> SoloStore {
        SoloStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)")))
    }

    func testAddAndLoad() throws {
        let s = try store()
        XCTAssertEqual(s.load(), [])
        let added = s.add(SoloSession(cwd: "/p/app", launchSessionID: "L1"))
        XCTAssertEqual(s.load(), [added])
        XCTAssertEqual(added.title, "app")
        XCTAssertEqual(added.sessionID, "L1")
        XCTAssertTrue(added.tmuxName.hasPrefix("cc-app-"))
    }

    func testSessionIDChangeKeepsLaunch() throws {
        let s = try store()
        let a = s.add(SoloSession(cwd: "/p/app", launchSessionID: "L1"))
        s.setSessionID("L2", for: a.id)
        let got = try XCTUnwrap(s.load().first)
        XCTAssertEqual(got.sessionID, "L2")
        XCTAssertEqual(got.launchSessionID, "L1")
        XCTAssertEqual(got.tmuxName, a.tmuxName)
    }

    func testRenameAndRemove() throws {
        let s = try store()
        let a = s.add(SoloSession(cwd: "/p/a"))
        let b = s.add(SoloSession(cwd: "/p/b"))
        s.rename("Новая", for: a.id)
        XCTAssertEqual(s.load().first?.title, "Новая")
        s.remove(a.id)
        XCTAssertEqual(s.load().map(\.id), [b.id])
        s.setSessionID("x", for: UUID())
        XCTAssertEqual(s.load().count, 1)
    }

    func testCollisionOfNamesGetsLongerSuffix() throws {
        let s = try store()
        let hex = "3f2a"
        let id1 = UUID(uuidString: "\(hex)0000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "\(hex)0000-0000-0000-0000-000000000002")!
        let a = s.add(SoloSession(id: id1, cwd: "/p/app"))
        let b = s.add(SoloSession(id: id2, cwd: "/p/app"))
        XCTAssertNotEqual(a.tmuxName, b.tmuxName)
    }

    func testOldFormatWithoutFields() throws {
        let suite = "agtest-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        let id = UUID()
        d.set(Data(#"[{"id":"\#(id.uuidString)","cwd":"/p/old"}]"#.utf8), forKey: SoloStore.key)
        let got = try XCTUnwrap(SoloStore(defaults: d).load().first)
        XCTAssertEqual(got.id, id)
        XCTAssertEqual(got.title, "old")
        XCTAssertEqual(got.launchSessionID, "")
        XCTAssertEqual(got.sessionID, "")
        XCTAssertTrue(got.tmuxName.hasPrefix("cc-old-"))
    }

    func testBrokenEntrySkippedOthersKept() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let good = UUID()
        d.set(Data(#"[{"id":"\#(good.uuidString)","cwd":"/p/ok"},{"id":42,"cwd":7},{"cwd":"/p/noid"}]"#.utf8), forKey: SoloStore.key)
        let s = SoloStore(defaults: d)
        XCTAssertEqual(s.load().map(\.id), [good])
        s.rename("Новая", for: good)
        XCTAssertEqual(s.load().first?.title, "Новая")
    }

    func testUnreadableDataIsEmptyAndBackedUp() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        d.set(Data("мусор".utf8), forKey: SoloStore.key)
        let s = SoloStore(defaults: d)
        XCTAssertEqual(s.load(), [])
        s.add(SoloSession(cwd: "/p/app"))
        XCTAssertEqual(d.data(forKey: SoloStore.key + ".unreadable"), Data("мусор".utf8), "сырые данные не потеряны")
        XCTAssertEqual(s.load().count, 1)
    }

    func testAddKeepsGivenNameAndRepeatAddIsStable() throws {
        let s = try store()
        let rec = SoloSession(cwd: "/p/app", tmuxName: "cc-taken-0001")
        XCTAssertEqual(s.add(rec).tmuxName, "cc-taken-0001")
        XCTAssertEqual(s.add(rec).tmuxName, "cc-taken-0001", "повторный add своей записи имя не меняет")
        XCTAssertEqual(s.load().count, 1)
    }

    func testAddAvoidsLiveNamesOfOtherBuilds() throws {
        let s = try store()
        let rec = SoloSession(cwd: "/p/app")
        let added = s.add(rec, alsoTaken: [rec.tmuxName])
        XCTAssertNotEqual(added.tmuxName, rec.tmuxName)
        XCTAssertTrue(added.tmuxName.hasPrefix(rec.tmuxName))
    }

    func testDefaultLaunchSessionIDIsUUID() {
        let r = SoloSession(cwd: "/p/app")
        XCTAssertNotNil(UUID(uuidString: r.launchSessionID))
        XCTAssertEqual(r.sessionID, r.launchSessionID)
    }
}
