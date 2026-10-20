import XCTest
@testable import AgentTeamCore

/// Модель агента в строке состояния — из транскрипта, коротким именем; после `/model` — новая.
final class ModelNameTests: XCTestCase {
    func testShortNamesOfKnownIDs() {
        XCTAssertEqual(ModelName.short("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(ModelName.short("claude-sonnet-5-5"), "Sonnet 5.5")
        XCTAssertEqual(ModelName.short("claude-haiku-4-5-20251001"), "Haiku 4.5", "дата выпуска в имя не входит")
        XCTAssertEqual(ModelName.short("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(ModelName.short("claude-opus-5"), "Opus 5")
        XCTAssertEqual(ModelName.short("claude-opus-5-5[1m]"), "Opus 5.5", "окно контекста в имя не входит")
        XCTAssertEqual(ModelName.short("claude-3-5-sonnet-20241022"), "Sonnet 3.5", "старый порядок: версия, потом семейство")
        XCTAssertEqual(ModelName.short("opus"), "Opus", "поле model роли")
    }

    func testUnknownIDIsShownAsIsWithoutPrefix() {
        XCTAssertEqual(ModelName.short("claude-nova-1-2"), "nova-1-2")
        XCTAssertEqual(ModelName.short("gpt-5.1-codex"), "gpt-5.1-codex")
        XCTAssertEqual(ModelName.short("claude-opus-next"), "opus-next", "версия не из чисел — как есть")
    }

    func testNoModel() {
        for id in ["", "  ", "inherit", "default", "<synthetic>"] { XCTAssertNil(ModelName.short(id), id) }
    }

    func testModelCommandOutput() {
        let set = "<local-command-stdout>Set model to `Sonnet 5.5` and saved as your default for new sessions</local-command-stdout>"
        XCTAssertEqual(ModelName.fromModelCommand(set), "Sonnet 5.5")
        XCTAssertEqual(ModelName.fromModelCommand("<local-command-stdout>Set model to `Opus 5 (1M context)` and saved as your default</local-command-stdout>"), "Opus 5")
        XCTAssertEqual(ModelName.fromModelCommand("<local-command-stdout>Set model to \u{1B}[1mHaiku 4.5\u{1B}[22m</local-command-stdout>"), "Haiku 4.5")
        XCTAssertEqual(ModelName.fromModelCommand("<local-command-stdout>Set model to claude-fable-5-1</local-command-stdout>"), "Fable 5.1")
        XCTAssertNil(ModelName.fromModelCommand("<local-command-stdout>Kept model as Sonnet 5.5</local-command-stdout>"))
        XCTAssertEqual(ModelName.fromModelCommand("<local-command-stdout>Set model to `Opus 5.5 (1M context) (default)` and saved as your default for new sessions</local-command-stdout>"),
                       "Opus 5.5", "все пояснения в скобках снимаются")
    }

    func testUsageDisplayModelUsesSameParser() {
        XCTAssertEqual(UsageInfo(model: "claude-opus-5-5[1m]", contextTokens: 1).displayModel, "Opus 5.5")
        XCTAssertEqual(UsageInfo(model: "claude-nova-1", contextTokens: 1).displayModel, "nova-1")
    }

    // MARK: транскрипт

    private let t0 = "2026-10-18T10:00:00.000Z", t1 = "2026-10-18T10:00:05.000Z", t2 = "2026-10-18T10:00:09.000Z"
    private let t3 = "2026-10-18T10:01:00.000Z", t4 = "2026-10-18T10:01:30.000Z"

    private func owner(_ ts: String, _ text: String) -> Substring {
        Substring(#"{"type":"user","isSidechain":false,"timestamp":"\#(ts)","message":{"role":"user","content":"\#(text)"}}"#)
    }
    private func answer(_ ts: String, _ model: String) -> Substring {
        Substring(#"{"type":"assistant","isSidechain":false,"timestamp":"\#(ts)","message":{"model":"\#(model)","id":"m\#(ts)","role":"assistant","content":[{"type":"text","text":"ok"}]}}"#)
    }
    private func end(_ ts: String) -> Substring {
        Substring(#"{"type":"system","subtype":"turn_duration","isSidechain":false,"timestamp":"\#(ts)","durationMs":9000}"#)
    }
    private func modelCommand(_ ts: String, _ name: String) -> Substring {
        Substring(#"{"type":"user","isSidechain":false,"timestamp":"\#(ts)","message":{"role":"user","content":"<local-command-stdout>Set model to `\#(name)` and saved as your default for new sessions</local-command-stdout>"}}"#)
    }

    /// Простаивающий агент: последняя запись — конец хода, модель — в ответе до него.
    func testIdleAgentModelComesFromAnswerBeforeTurnEnd() {
        let lines = [owner(t0, "go"), answer(t1, "claude-sonnet-5-5"), end(t2)]
        let a = AgentActivity.parse(lines: lines)
        XCTAssertFalse(a.inTurn)
        XCTAssertEqual(a.model, "Sonnet 5.5")
    }

    func testSyntheticAnswerDoesNotHideModel() {
        let lines = [owner(t0, "go"), answer(t1, "claude-opus-5-5"), answer(t2, "<synthetic>"), end(t3)]
        XCTAssertEqual(AgentActivity.parse(lines: lines).model, "Opus 5.5")
    }

    /// После `/model` в строке новая модель сразу, до следующего ответа; следующий ответ подтверждает её.
    func testModelCommandSwitchesModelBeforeNextAnswer() {
        let base = [owner(t0, "go"), answer(t1, "claude-opus-5-5"), end(t2)]
        let switched = base + [modelCommand(t3, "Sonnet 5.5")]
        XCTAssertEqual(AgentActivity.parse(lines: switched).model, "Sonnet 5.5")
        // Дочитывание: новые строки — только вывод команды (действием не считается), модель всё равно меняется.
        let polled = AgentActivity.continued(AgentActivity.parse(lines: base), with: [modelCommand(t3, "Sonnet 5.5")])
        XCTAssertEqual(polled.model, "Sonnet 5.5")
        XCTAssertNotEqual(polled, AgentActivity.parse(lines: base), "смена модели — изменение итога, экран перерисуется")
        XCTAssertEqual(polled, AgentActivity.parse(lines: switched))
        let answered = switched + [owner(t4, "next"), answer(t4, "claude-sonnet-5-5")]
        XCTAssertEqual(AgentActivity.parse(lines: answered).model, "Sonnet 5.5")
    }

    /// Вывод `/model` записью `system/local_command` (так Claude Code пишет «Kept model as» и вывод других команд).
    func testModelCommandAsSystemLocalCommandRecord() {
        let system = Substring(#"{"type":"system","subtype":"local_command","isSidechain":false,"timestamp":"\#(t3)","content":"<local-command-stdout>Set model to `Sonnet 5.5` and saved as your default for new sessions</local-command-stdout>","level":"info"}"#)
        let kept = Substring(#"{"type":"system","subtype":"local_command","isSidechain":false,"timestamp":"\#(t4)","content":"<local-command-stdout>Kept model as `Sonnet 5.5`</local-command-stdout>","level":"info"}"#)
        let lines = [owner(t0, "go"), answer(t1, "claude-opus-5-5"), end(t2), system]
        XCTAssertEqual(AgentActivity.parse(lines: lines).model, "Sonnet 5.5")
        XCTAssertEqual(AgentActivity.parse(lines: lines + [kept]).model, "Sonnet 5.5", "«Kept model as» модель не меняет")
    }

    /// Цитата вывода `/model` внутри обычного сообщения (например, другая сессия пересылает кусок теста) модель не меняет.
    func testQuotedModelCommandInMessageIsIgnored() {
        let quoted = owner(t3, "проверь: <local-command-stdout>Set model to `Haiku 4.5` and saved as your default</local-command-stdout>")
        let lines = [owner(t0, "go"), answer(t1, "claude-opus-5-5"), end(t2), quoted]
        XCTAssertEqual(AgentActivity.parse(lines: lines).model, "Opus 5.5")
    }

    /// Дочитывание с границей хода в новых строках не теряет модель, найденную раньше.
    func testContinuedKeepsModelAcrossBoundedChunk() {
        let first = AgentActivity.parse(lines: [owner(t0, "go"), answer(t1, "claude-haiku-4-5-20251001")])
        let next = AgentActivity.continued(first, with: [end(t2)])
        XCTAssertEqual(next.model, "Haiku 4.5")
    }

    @MainActor
    func testProjectModelNameFallsBackToRoleField() {
        let p = ProjectModel(repo: NSTemporaryDirectory(), session: "team-x", cli: nil, defaults: UserDefaults(suiteName: "ModelNameTests")!)
        let inherit = Agent(name: "dev#1", role: "dev", model: "inherit")
        XCTAssertNil(p.modelName(of: inherit), "inherit ничего не говорит о модели")
        let role = Agent(name: "dev#2", role: "dev", model: "sonnet")
        XCTAssertEqual(p.modelName(of: role), "Sonnet")
        p.setActivityForTest("dev#2", AgentActivity(lastAction: Date(), model: "Opus 5.5"))
        XCTAssertEqual(p.modelName(of: role), "Opus 5.5", "транскрипт главнее поля роли")
    }
}
