import AgentTeamCore
import AppKit
import SwiftUI

/// Шаги проверочного запуска (аргументы `--bench`, `--pin`, `--pin-jump`, `--view-image`): обход проектов, закрепление
/// записей и раскрытие картинки для снимков. В обычном запуске не вызываются.
extension RootView {
    /// Обход проектов тем же вызовом, что и клик в боковой панели: каждые 3 с следующий проект.
    func runBench(_ o: LaunchOptions) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for _ in 0..<o.benchRounds {
            for s in o.bench {
                app.select(s.hasPrefix(TmuxListing.teamPrefix) ? s : TmuxListing.teamPrefix + s)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        if !o.benchStay { NSApp.terminate(nil) }
    }

    /// Для снимка: ждёт ленту и закрепляет последние записи с текстом.
    func pinLastEntries(_ n: Int) async {
        for _ in 0..<40 {
            if let p = app.project, !p.chat.isEmpty {
                for e in p.chat.reversed().filter({ PinnedEntry.excerpt(of: $0.kind) != nil }).prefix(n).reversed() where !p.isPinned(e.id) { p.togglePin(e) }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Для снимка: закрепляет запись по id и просит ленту перейти к ней, когда лента загрузится.
    func pinAndJump(_ id: String) async {
        for _ in 0..<40 where app.project == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        guard let p = app.project else { return }
        p.addPin(PinnedEntry(id: id, excerpt: "вопрос из начала сессии", time: nil))
        // Лента открывается с конца: даём ей показаться, затем просим перейти к записи из начала.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        p.requestJump(to: id)
    }

    /// Для снимка: ждёт транскрипт и раскрывает последнюю картинку ленты.
    func openFirstChatImage() async {
        for _ in 0..<40 {
            if let img = app.project?.chat.last(where: { !$0.images.isEmpty })?.images.first {
                app.viewedImage = ViewedImage(id: img.id, base64: img.base64)
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Стенд переключений (`AGENT_TEAM_MODE_BENCH=<файл>`): сколько раз читался транскрипт (запуски моделей лент) на
    /// каждом переходе «Команда → Менеджер → Команда» и «экран агента → назад». Ожидание — 0: ленты живут в проекте.
    func runModeBench() async {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TEAM_MODE_BENCH"] else { return }
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        var lines: [String] = []
        if let p = app.project, let pane = p.managerPaneID {
            lines.append("панель менеджера \(pane): менеджер \(p.managerBusy ? "в ходе" : "без хода"), ждёт ответа: \(app.hub.output(for: pane).needsHuman ? "да" : "нет"), вывод стримится: \(app.hub.streamingPanes.contains(pane) ? "да" : "нет")")
        }
        func step(_ label: String, _ action: () -> Void) async {
            let before = AgentThreadModel.benchStarts
            action()
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            lines.append("\(label): чтений транскрипта \(AgentThreadModel.benchStarts - before)")
        }
        await step("Команда → Менеджер") { app.section = .team; app.mode = .manager }
        await step("Менеджер → Команда") { app.mode = .team }
        let agent = app.project?.teamAgents.first { $0.alive }?.name
        if let agent, let session = app.project?.session {
            // Панель агента прокручена владельцем выше конца: после экрана агента она возвращается на то же место.
            func distance() -> CGFloat? {
                guard let scroll = FeedScroller.remembered(FeedScroller.agentKey(session: session, agent: agent, dense: true)).scroll, let doc = scroll.documentView else { return nil }
                return doc.frame.height - scroll.contentView.bounds.maxY
            }
            lines.append(String(format: "панель %@ до конца при открытии: %.0f pt", agent, distance() ?? -1))
            if let scroll = FeedScroller.remembered(FeedScroller.agentKey(session: session, agent: agent, dense: true)).scroll {
                NotificationCenter.default.post(name: .benchUserInput, object: nil)
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 200)))
                scroll.reflectScrolledClipView(clip)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            let scroller = FeedScroller.remembered(FeedScroller.agentKey(session: session, agent: agent, dense: true))
            let top = scroller.tracker.rows.filter { $0.value >= 0 && $0.value < scroller.viewH }.min { $0.value < $1.value }
            let before = distance()
            await step("Команда → экран агента \(agent)") { app.openAgent(agent) }
            await step("экран агента → Команда") { app.openedAgent = nil }
            let after = distance()
            lines.append(String(format: "панель %@ до конца: до экрана агента %.0f pt, после возврата %.0f pt (внизу могло прибавиться новое)", agent, before ?? -1, after ?? -1))
            if let top {
                let now = scroller.tracker.rows[top.key]
                lines.append(String(format: "верхняя видимая строка %@: до экрана агента %.0f pt от верха окна, после возврата %@", top.key, top.value,
                                    now.map { String(format: "%.0f pt", $0) } ?? "не в окне"))
            }
        } else {
            lines.append("живых агентов нет: переход на экран агента не проверен")
        }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
