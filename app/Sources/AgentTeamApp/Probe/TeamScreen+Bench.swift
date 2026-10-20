import AgentTeamCore
import AppKit
import SwiftUI

/// Стенд замера экрана «Команда»; в обычном запуске сразу выходит.
extension TeamScreen {
    /// Замер переключения панелей (`AGENT_TEAM_TOGGLE_BENCH=<файл>`, только в проверочном запуске): время от действия до готового
    /// кадра — принудительная фиксация транзакции, два оборота главной очереди, отрисовка окна. Пишет строки в файл.
    func runToggleBench() async {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TEAM_TOGGLE_BENCH"], app.project === project else { return }
        try? await Task.sleep(nanoseconds: 14_000_000_000)
        guard let first = agents.first?.key else { return }
        var lines: [String] = ["agents \(agents.count)"]
        func frame() async {
            CATransaction.flush()
            for _ in 0..<2 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
            CATransaction.flush()
            NSApp.windows.first { $0.title == "agent-team" }?.displayIfNeeded()
        }
        func measure(_ label: String, _ action: () -> Void) async {
            let starts0 = AgentThreadModel.benchStarts, data0 = AgentThreadModel.benchFirstData.count
            let t0 = CACurrentMediaTime()
            action()
            await frame()
            let ms = (CACurrentMediaTime() - t0) * 1000
            try? await Task.sleep(nanoseconds: 2_500_000_000)       // лента успевает загрузиться между замерами
            let data = AgentThreadModel.benchFirstData.dropFirst(data0)
            lines.append(String(format: "%@ кадр %.0f ms; запусков моделей %d; первые записи в %d панелях, макс. %.0f ms", label, ms,
                                AgentThreadModel.benchStarts - starts0, data.count, data.max() ?? 0))
        }
        for round in 1...3 {
            await measure("collapse-one #\(round)") { collapsed.insert(first) }
            await measure("expand-one   #\(round)") { collapsed.remove(first) }
            await measure("collapse-all #\(round)") { collapsed = Set(agents.map(\.key)) }
            await measure("expand-all   #\(round)") { collapsed = [] }
        }
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
