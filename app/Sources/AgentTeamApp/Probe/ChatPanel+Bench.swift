import AgentTeamCore
import AppKit
import SwiftUI

/// Стенды замеров ленты чата менеджера. Включаются переменными окружения проверочного запуска и пишут отчёт в файл;
/// в обычном запуске каждый сразу выходит.
extension ChatPanel {
    /// Замер ленты чата (`AGENT_TEAM_CHAT_BENCH=<файл>`, только в проверочном запуске): время до готового кадра при наборе
    /// текста в поле и при прокрутке длинной ленты вверх шагами по 500 pt. Пишет строки в файл.
    func runChatBench() async {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TEAM_CHAT_BENCH"], app.project === project else { return }
        try? await Task.sleep(nanoseconds: 14_000_000_000)
        // AGENT_TEAM_CHAT_SYNTH=<ходов>: длинная синтетическая лента (владелец, три инструмента, ответ с Markdown, конец хода).
        if let n = ProcessInfo.processInfo.environment["AGENT_TEAM_CHAT_SYNTH"].flatMap(Int.init) {
            let e = Self.benchSynthChat(n)
            project.benchFreezeChat(e)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        var lines = ["записей чата \(project.chat.count)"]
        func frame() async {
            CATransaction.flush()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            CATransaction.flush()
            NSApp.windows.first { $0.title == "agent-team" }?.displayIfNeeded()
        }
        func stats(_ label: String, _ t: [Double]) -> String {
            let sorted = t.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "%@: кадров %d, среднее %.1f ms, p95 %.1f ms, максимум %.1f ms", label, t.count, t.reduce(0, +) / Double(t.count), p95, sorted.last ?? 0)
        }
        var typing: [Double] = []
        let calls0 = managerFeed.regrouped
        for i in 0..<40 {
            let t0 = CACurrentMediaTime()
            draft = String(repeating: "x", count: i + 1)
            await frame()
            typing.append((CACurrentMediaTime() - t0) * 1000)
        }
        draft = ""
        lines.append(stats("набор текста", typing))
        lines.append("пересчётов группировки за 40 нажатий: \(managerFeed.regrouped - calls0)")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let scroll = chatScroll {
            let clip = scroll.contentView
            var times: [Double] = []
            for _ in 0..<60 {
                let t0 = CACurrentMediaTime()
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 500)))
                scroll.reflectScrolledClipView(clip)
                await frame()
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            lines.append(stats("прокрутка вверх", times))
            lines.append(String(format: "после прокрутки: высота ленты %.0f pt, верх окна на %.0f pt", scroll.documentView?.frame.height ?? 0, clip.bounds.origin.y))
        } else {
            lines.append("прокрутка: NSScrollView не найден")
        }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Длинная синтетическая лента (`AGENT_TEAM_CHAT_SYNTH=<ходов>`): владелец, три инструмента, ответ с Markdown, конец хода.
    static func benchSynthChat(_ n: Int) -> [ChatEntry] {
        var e: [ChatEntry] = []
        for i in 0..<n {
            let t = Date(timeIntervalSince1970: 1_760_000_000 + Double(i) * 60)
            e.append(ChatEntry(id: "s\(i)-o", time: t, kind: .owner("Задача \(i): проверь сборку и расскажи, что нашёл")))
            e.append(ChatEntry(id: "s\(i)-b", time: t, kind: .tool(name: "Bash", summary: "swift test --filter Case\(i)")))
            e.append(ChatEntry(id: "s\(i)-r", time: t, kind: .tool(name: "Read", summary: "Sources/File\(i).swift")))
            e.append(ChatEntry(id: "s\(i)-t", time: t, kind: .tracker(action: "get_issue", summary: "TASK-\(i)")))
            e.append(ChatEntry(id: "s\(i)-a", time: t, kind: .reply("""
                Ход \(i). Сборка прошла, **тесты зелёные**: 246 прошли, 0 упали.

                - первое замечание по `File\(i).swift`
                - второе замечание, подлиннее, чтобы строка переносилась и занимала не одну строку ленты
                - третье

                ```swift
                let x = \(i)
                ```
                """)))
            e.append(ChatEntry(id: "s\(i)-e", time: t, kind: .turnEnd(durationMs: 12_000 + i)))
        }
        return e
    }

    /// Замер «читающий не уносится» (`AGENT_TEAM_READ_BENCH=<файл>`, нужна синтетическая лента `AGENT_TEAM_CHAT_SYNTH`):
    /// лента прокручивается в середину, затем 20 событий подряд (каждое растит ленту внизу) идут с интервалом 150 мс.
    /// Сдвиг видимого текста — изменение верха окна прокрутки (контент выше окна не меняется): ожидание 0 pt.
    func runReadBench() async {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TEAM_READ_BENCH"], app.project === project else { return }
        try? await Task.sleep(nanoseconds: 22_000_000_000)
        guard let scroll = chatScroll, let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        // Середина считается по высоте документа, а она у ленивой ленты оценочная: после прыжка строки реализуются,
        // документ укорачивается, и «середина» может оказаться у конца. Прыжок повторяется, пока окно не встанет дальше
        // трёх экранов от конца (не больше пяти раз); не встало — стенд так и пишет, а не «0 pt».
        var away: CGFloat = 0
        for _ in 0..<5 {
            let middle = max(0, (doc.frame.height - clip.bounds.height) / 2)
            NotificationCenter.default.post(name: .benchUserInput, object: nil)
            clip.scroll(to: NSPoint(x: 0, y: middle))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(nanoseconds: 1_500_000_000)       // тишина дольше окна роста: это положение читающего
            away = doc.frame.height - clip.bounds.maxY
            if away > clip.bounds.height * 3 { break }
        }
        let start = clip.bounds.origin.y
        let heldMiddle = away > clip.bounds.height * 3
        // Опорная строка: видимая в окне; её положение в окне и есть «видимый текст» (верх окна прокрутки ленивая лента
        // меняет и сама, когда уточняет оценки высот, поэтому по нему сдвиг не измерить).
        let viewTop = FeedScroller.benchRowY.filter { $0.value > 40 && $0.value < clip.bounds.height - 300 }.min { $0.value < $1.value }
        var shifts: [Double] = []
        var entries = project.chat
        for i in 0..<20 {
            let t = Date(timeIntervalSince1970: 1_770_000_000 + Double(i))
            entries.append(ChatEntry(id: "ev\(i)-b", time: t, kind: .tool(name: "Bash", summary: "событие \(i)")))
            if i % 3 == 0 { entries.append(ChatEntry(id: "ev\(i)-r", time: t, kind: .reply("Новый ответ \(i): достаточно длинный текст, чтобы строка переносилась и лента заметно росла вниз."))) }
            project.benchFreezeChat(entries)
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let ref = viewTop, let y = FeedScroller.benchRowY[ref.key] { shifts.append(Double(y - ref.value)) }
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let end = viewTop.flatMap { ref in FeedScroller.benchRowY[ref.key].map { Double($0 - ref.value) } } ?? 0
        let maxShift = shifts.map { abs($0) }.max() ?? 0
        let lines = [
            heldMiddle ? String(format: "середина ленты: верх окна %.0f pt из %.0f pt; опорная строка в окне на %.0f pt (%@)", start, doc.frame.height, viewTop?.value ?? -1, viewTop?.key ?? "не найдена")
                : String(format: "СТЕНД НЕ УДЕРЖАЛ СЕРЕДИНУ: окно в %.0f pt от конца — замер ниже не о читающем", away),
            String(format: "20 событий подряд: максимальный сдвиг опорной строки %.1f pt, итоговый %.1f pt, замеров %d", maxShift, end, shifts.count),
            "сдвиги по событиям: " + shifts.map { String(format: "%.0f", $0) }.joined(separator: " "),
        ]
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Замер прокрутки всей истории (`AGENT_TEAM_HISTORY_BENCH=<файл>`, реальная сессия менеджера, только чтение): от конца
    /// до начала шагами по 1200 pt. «Упор» — верх окна у нуля, ранние страницы есть, но за 3 с не пришли.
    func runHistoryBench() async {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TEAM_HISTORY_BENCH"], app.project === project else { return }
        try? await Task.sleep(nanoseconds: 16_000_000_000)
        await FeedScroller.runHistoryBench(path: path, scroller: scroller, model: thread)
    }
}
