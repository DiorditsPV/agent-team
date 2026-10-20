import XCTest
@testable import AgentTeamCore

/// Опрос активности читает только изменившееся. Дочитывание новых строк (`AgentActivity.continued`) должно
/// давать тот же итог, что полный разбор файла.
final class ActivityPollTests: XCTestCase {
    private func lines(_ fixtureName: String, subdirectory: String = "Fixtures") throws -> [Substring] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: fixtureName, withExtension: nil, subdirectory: subdirectory))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func full(_ l: ArraySlice<Substring>) -> AgentActivity { AgentActivity.scan(Array(l)).activity }

    /// Каждая точка разреза: прежний итог по началу файла + новые строки == полный разбор. Отдельно — дочитывание
    /// по одной строке подряд, как при частом опросе.
    private func assertEquivalent(_ all: [Substring], _ name: String) {
        for k in 0...all.count {
            let merged = AgentActivity.continued(full(all[..<k]), with: Array(all[k...]))
            XCTAssertEqual(merged, full(all[...]), "\(name): разрез на строке \(k)")
        }
        var step = full(all[..<0])
        for i in all.indices {
            step = AgentActivity.continued(step, with: [all[i]])
            XCTAssertEqual(step, full(all[...i]), "\(name): по строке, до \(i)")
        }
    }

    /// Одно правило хода: в каждой точке разреза «ход идёт» ленты (разбор вперёд) совпадает со статусом (разбор
    /// с конца). Расходились: плановый запуск, служебные записи, сообщение другой сессии вне хода.
    func testFeedAndStatusAgreeOnTurnAtEveryCut() throws {
        let sets = [("менеджер", try lines("transcript.jsonl")), ("агент", try lines("agent-transcript.jsonl")),
                    ("фоновые", try lines("session.jsonl", subdirectory: "Fixtures/subagents/running"))]
        for (name, all) in sets {
            var parser = TranscriptParser()
            for k in all.indices {
                parser.feed(lines: [all[k]])
                XCTAssertEqual(parser.turnInProgress, full(all[...k]).inTurn, "\(name): строка \(k)")
            }
        }
        // Плановый запуск и сообщение другой сессии вне хода начинают ход и там, и там.
        let fire = #"{"type":"system","subtype":"scheduled_task_fire","uuid":"f","timestamp":"2026-10-17T11:00:00.000Z"}"#
        let meta = #"{"type":"user","isMeta":true,"uuid":"m","timestamp":"2026-10-17T11:01:00.000Z","message":{"role":"user","content":"<cross-session-message from=\"x\">привет</cross-session-message>"}}"#
        let end = #"{"type":"system","subtype":"turn_duration","durationMs":1,"uuid":"e","timestamp":"2026-10-17T10:00:00.000Z"}"#
        for extra in [fire, meta] {
            var parser = TranscriptParser()
            parser.feed(lines: [Substring(end), Substring(extra)])
            XCTAssertTrue(parser.turnInProgress)
            XCTAssertTrue(full([Substring(end), Substring(extra)]).inTurn)
        }
        var parser = TranscriptParser()
        parser.feed(lines: [Substring(meta)])
        XCTAssertEqual(parser.entries.count, 1, "сообщение другой сессии вне хода — в ленте")
    }

    func testContinuedMatchesFullParseOnRealTranscripts() throws {
        assertEquivalent(try lines("transcript.jsonl"), "менеджер")
        assertEquivalent(try lines("agent-transcript.jsonl"), "агент")
        assertEquivalent(try lines("session.jsonl", subdirectory: "Fixtures/subagents/running"), "фоновые, идут")
        assertEquivalent(try lines("session.jsonl", subdirectory: "Fixtures/subagents/done"), "фоновые, завершены")
    }

    func testContinuedTracksQuestionAcrossChunks() {
        func r(_ type: String, _ s: Int, _ body: String) -> Substring {
            Substring(#"{"type":"\#(type)","timestamp":"2026-10-17T10:00:\#(String(format: "%02d", s)).000Z",\#(body)}"#)
        }
        let all: [Substring] = [
            r("system", 0, #""subtype":"turn_duration""#),
            r("user", 1, #""message":{"content":"вопрос владельца"}"#),
            r("assistant", 2, #""message":{"content":[{"type":"tool_use","id":"ask1","name":"AskUserQuestion","input":{}}]}"#),
            r("user", 3, #""message":{"content":[{"type":"tool_result","tool_use_id":"ask1","content":"да"}]}"#),
            r("assistant", 4, #""message":{"content":[{"type":"text","text":"готово"}]}"#),
            r("system", 5, #""subtype":"turn_duration""#),
        ]
        assertEquivalent(all, "вопрос")
        XCTAssertTrue(full(all[..<3]).pendingAsk)
        XCTAssertFalse(AgentActivity.continued(full(all[..<3]), with: [all[3]]).pendingAsk, "ответ в новых строках снимает вопрос")
    }

    // MARK: цена опроса

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("poll-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func transcript(_ sid: String) throws -> URL {
        let url = TranscriptParser.transcriptURL(cwd: "/work/shop", sessionID: sid, home: home.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func append(_ url: URL, _ text: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
        // Время изменения в файловой системе грубое: сдвигаем вперёд явно, как у настоящей дописи.
        let m = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes([.modificationDate: m.addingTimeInterval(1)], ofItemAtPath: url.path)
    }

    private let turn = [
        #"{"type":"user","timestamp":"2026-10-17T10:00:00.000Z","message":{"content":"задача"}}"#,
        #"{"type":"assistant","timestamp":"2026-10-17T10:00:05.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#,
    ]
    private let result = #"{"type":"user","timestamp":"2026-10-17T10:00:09.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private let end = #"{"type":"system","subtype":"turn_duration","timestamp":"2026-10-17T10:00:12.000Z","durationMs":12000}"#

    func testUnchangedFileIsNotReadAgain() throws {
        let url = try transcript("s1")
        try append(url, turn.joined(separator: "\n") + "\n")
        var t = ActivityTracker()
        let targets = [(name: "developer#1", sessionID: "s1", cwd: Optional("/work/shop"))]
        let first = t.refresh(targets, home: home.path)
        XCTAssertEqual(t.fullReads, 1)
        for _ in 0..<5 { XCTAssertEqual(t.refresh(targets, home: home.path), first) }
        XCTAssertEqual(t.fullReads, 1, "неизменившийся файл не ищется и не читается")
        XCTAssertEqual(t.appends, 0)
        XCTAssertEqual(t.stats, 5)
    }

    func testAppendedLinesAreReadIncrementallyAndMatchFullRead() throws {
        let url = try transcript("s1")
        try append(url, turn.joined(separator: "\n") + "\n")
        var t = ActivityTracker()
        let targets = [(name: "developer#1", sessionID: "s1", cwd: Optional("/work/shop"))]
        _ = t.refresh(targets, home: home.path)
        XCTAssertEqual(t.refresh(targets, home: home.path)["developer#1"]?.inTurn, true)

        // Запись дописывается не целиком: недописанная строка ждёт следующего прохода.
        let half = result.index(result.startIndex, offsetBy: 40)
        try append(url, String(result[..<half]))
        let mid = t.refresh(targets, home: home.path)["developer#1"]
        XCTAssertEqual(mid?.lastAction, AgentActivity.read(url: URL(fileURLWithPath: url.path))?.lastAction)
        try append(url, String(result[half...]) + "\n" + end + "\n")
        let after = t.refresh(targets, home: home.path)["developer#1"]
        XCTAssertEqual(after, AgentActivity.read(url: url))
        XCTAssertEqual(after?.inTurn, false)
        XCTAssertEqual(t.fullReads, 1, "после первого чтения — только дочитывание")
        XCTAssertEqual(t.appends, 2)
    }

    func testContinuationAndNewSessionReadInFull() throws {
        let a = try transcript("s1")
        try append(a, turn.joined(separator: "\n") + "\n")
        var t = ActivityTracker()
        var targets = [(name: "developer#1", sessionID: "s1", cwd: Optional("/work/shop"))]
        _ = t.refresh(targets, home: home.path)
        // Сессия продолжена в новом файле: запись continued-in ведёт к нему.
        let b = try transcript("s2")
        try append(b, turn[0] + "\n" + end + "\n")
        try append(a, #"{"type":"continued-in","continuedInSessionId":"s2"}"# + "\n")
        let got = t.refresh(targets, home: home.path)["developer#1"]
        XCTAssertEqual(got, AgentActivity.read(url: b))
        XCTAssertEqual(t.fullReads, 2)
        // Другая сессия агента (перезапуск) — тоже полное чтение.
        targets = [(name: "developer#1", sessionID: "s2", cwd: Optional("/work/shop"))]
        _ = t.refresh(targets, home: home.path)
        XCTAssertEqual(t.fullReads, 3)
    }
}
