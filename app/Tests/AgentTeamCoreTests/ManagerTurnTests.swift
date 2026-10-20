import XCTest
@testable import AgentTeamCore

/// Ход менеджера (`managerBusy`) по транскрипту: границы те же, что у хода агента. Без них после «Стоп» ход не кончался:
/// Claude Code после прерывания `turn_duration` не пишет, и очередь владельца удерживалась бы навсегда.
final class ManagerTurnTests: XCTestCase {
    private func busy(_ lines: [String]) -> Bool {
        var p = TranscriptParser()
        p.feed(lines: lines.map { Substring($0) })
        return p.turnInProgress
    }

    private let owner = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"сделай"}}"#
    private let answer = #"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"делаю"}]}}"#
    private let tool = #"{"type":"assistant","uuid":"a2","message":{"id":"m2","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
    private let end = #"{"type":"system","subtype":"turn_duration","uuid":"d1","durationMs":5}"#

    func testTurnEndsByTurnDuration() {
        XCTAssertTrue(busy([owner, answer]))
        XCTAssertFalse(busy([owner, answer, end]))
    }

    /// Запись прерывания — служебная строка (в ленту не попадает), но ход ею кончается. Образец — запись Claude Code
    /// после Esc: текстовый блок «[Request interrupted by user]» или «… for tool use».
    func testInterruptEndsTurn() {
        let interrupted = #"{"type":"user","uuid":"u2","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let forTool = #"{"type":"user","uuid":"u3","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        XCTAssertFalse(busy([owner, answer, interrupted]))
        XCTAssertFalse(busy([owner, tool, forTool]))
        var p = TranscriptParser()
        p.feed(lines: [Substring(owner), Substring(answer), Substring(interrupted)])
        XCTAssertFalse(p.entries.contains { if case let .owner(t) = $0.kind { return t.hasPrefix("[Request") } else { return false } },
                       "прерывание не показывается как сообщение владельца")
        XCTAssertTrue(busy([owner, answer, interrupted, owner]), "новое сообщение после прерывания начинает ход")
    }

    func testApiErrorEndsTurn() {
        let apiError = #"{"type":"assistant","uuid":"a3","isApiErrorMessage":true,"message":{"id":"m3","model":"<synthetic>","content":[{"type":"text","text":"API Error: 529 overloaded"}]}}"#
        XCTAssertFalse(busy([owner, answer, apiError]))
    }

    func testCompactSummaryEndsTurnAndNextAnswerStartsOne() {
        let summary = #"{"type":"user","uuid":"c1","isCompactSummary":true,"message":{"role":"user","content":"This session is being continued…"}}"#
        XCTAssertFalse(busy([owner, answer, summary]))
        XCTAssertTrue(busy([owner, answer, summary, answer]))
    }

    /// Уведомление харнесса и сообщение в очереди начинают ход: до первого ответа менеджер уже занят (Д11).
    func testNotificationAndQueuedCommandStartTurn() {
        let note = #"{"type":"user","uuid":"n1","message":{"role":"user","content":"<task-notification><summary>фон готов</summary></task-notification>"}}"#
        let queued = #"{"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","prompt":"ещё"}}"#
        XCTAssertTrue(busy([owner, answer, end, note]))
        XCTAssertTrue(busy([owner, answer, end, queued]))
    }

    /// Команды владельца в самом Claude Code (`/model`) и их вывод ход не начинают.
    func testLocalCommandDoesNotStartTurn() {
        let cmd = #"{"type":"user","uuid":"k1","message":{"role":"user","content":"<command-name>/model</command-name>"}}"#
        XCTAssertFalse(busy([owner, answer, end, cmd]))
    }
}
