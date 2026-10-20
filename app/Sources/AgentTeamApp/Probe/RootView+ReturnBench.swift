import AgentTeamCore
import AppKit
import SwiftUI

/// Стенд «чат помнит место чтения» (`AGENT_TEAM_RETURN_BENCH=<файл>`, только с `--bench`, синтетическая лента
/// `AGENT_TEAM_CHAT_SYNTH`): чат менеджера прокручен в середину, владелец уходит в «Журнал» и на экран агента и
/// возвращается. Верхняя видимая строка встаёт на прежнее место окна (ожидание — сдвиг около 0 pt), а не на конец.
/// Стенд только переключает разделы: в панели ничего не пишется.
extension RootView {
    func runReturnBench() async {
        guard AppDefaults.isProbeRun(CommandLine.arguments),
              let path = ProcessInfo.processInfo.environment["AGENT_TEAM_RETURN_BENCH"] else { return }
        var lines: [String] = []
        func finish() { try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8) }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        guard let project = app.project else { lines.append("проект не открыт"); finish(); return }
        app.section = .team
        app.openedAgent = nil
        project.benchFreezeChat(ChatPanel.benchSynthChat(ProcessInfo.processInfo.environment["AGENT_TEAM_CHAT_SYNTH"].flatMap(Int.init) ?? 120))
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let scroller = FeedScroller.remembered(FeedScroller.chatKey(session: project.session))
        func fromEnd() -> CGFloat? {
            guard let scroll = scroller.scroll, let doc = scroll.documentView else { return nil }
            return doc.frame.height - scroll.contentView.bounds.maxY
        }
        guard let scroll = scroller.scroll, let doc = scroll.documentView else { lines.append("прокрутка чата не найдена"); finish(); return }
        let clip = scroll.contentView
        for _ in 0..<5 {
            NotificationCenter.default.post(name: .benchUserInput, object: nil)
            clip.scroll(to: NSPoint(x: 0, y: max(0, (doc.frame.height - clip.bounds.height) / 2)))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if (fromEnd() ?? 0) > clip.bounds.height * 3 { break }
        }
        let ids = Set(project.chat.map(\.id))
        guard (fromEnd() ?? 0) > clip.bounds.height * 3,
              let ref = scroller.tracker.rows.filter({ ids.contains($0.key) && $0.value > 40 && $0.value < scroller.viewH - 300 }).min(by: { $0.value < $1.value }) else {
            lines.append(String(format: "СТЕНД НЕ УДЕРЖАЛ СЕРЕДИНУ: окно в %.0f pt от конца", fromEnd() ?? -1)); finish(); return
        }
        lines.append(String(format: "середина: окно в %.0f pt от конца; опорная строка %@ на %.0f pt", fromEnd() ?? -1, ref.key, ref.value))
        func back(_ label: String, away: () -> Void) async {
            away()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            app.section = .team
            app.openedAgent = nil
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            // Без подталкивания окна: строки нового вида сообщают место сами, а уход строк старого вида с теми же id
            // их записи не стирает (FeedRowPosition).
            let row = scroller.tracker.rows[ref.key].map { String(format: "%.1f pt", Double($0 - ref.value)) } ?? "строки нет в окне"
            let top = scroller.tracker.rows.filter { ids.contains($0.key) && $0.value >= 0 && $0.value < scroller.viewH }.min { $0.value < $1.value }
            lines.append(String(format: "%@ и назад: сдвиг опорной строки %@, окно в %.0f pt от конца; верхняя видимая %@ на %.0f pt", label, row,
                                fromEnd() ?? -1, top?.key ?? "нет", top?.value ?? -1))
        }
        await back("«Журнал»") { app.section = .journal }
        if let agent = project.teamAgents.first(where: { $0.alive })?.name {
            await back("экран агента \(agent)") { app.openAgent(agent) }
        } else {
            lines.append("живых агентов нет: экран агента не проверен")
        }
        finish()
    }
}
