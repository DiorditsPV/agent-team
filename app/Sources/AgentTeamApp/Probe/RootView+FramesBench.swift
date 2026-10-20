import AgentTeamCore
import AppKit
import QuartzCore

/// Стенд «лента неподвижна» (`AGENT_TEAM_FRAMES_BENCH=<файл>`, только в проверочном запуске): чат менеджера
/// наблюдается `AGENT_TEAM_FRAMES_SECONDS` секунд (по умолчанию 8), каждые 1/120 с — высота ленты, положение окна и
/// место опорной строки. `AGENT_TEAM_FRAMES_READ=1` — сначала лента уходит в середину (читающий выше конца).
/// Снаружи в это время меняется экран панели менеджера (мигание кружка): неподвижная лента — ноль изменений высоты
/// и сдвиг опорной строки 0 pt.
extension RootView {
    func runFramesBench() async {
        guard AppDefaults.isProbeRun(CommandLine.arguments),
              let path = ProcessInfo.processInfo.environment["AGENT_TEAM_FRAMES_BENCH"], let project = app.project else { return }
        let env = ProcessInfo.processInfo.environment
        let seconds = Double(env["AGENT_TEAM_FRAMES_SECONDS"] ?? "") ?? 8
        var lines: [String] = []
        func finish() { try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8) }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        let scroller = FeedScroller.remembered(FeedScroller.chatKey(session: project.session))
        guard let scroll = scroller.scroll, let doc = scroll.documentView else { lines.append("СТЕНД НЕ ШЁЛ: прокрутка чата не найдена"); finish(); return }
        let clip = scroll.contentView
        if env["AGENT_TEAM_FRAMES_READ"] == "1" {
            NotificationCenter.default.post(name: .benchUserInput, object: nil)
            clip.scroll(to: NSPoint(x: 0, y: max(0, (doc.frame.height - clip.bounds.height) / 2)))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let ref = scroller.tracker.rows.filter { $0.value >= 0 && $0.value < scroller.viewH }.min { $0.value < $1.value }
        lines.append(String(format: "начало: высота %.0f, окно %.0f, от конца %.0f, следует %@, опорная %@ на %.0f, черновик %@",
                            Double(doc.frame.height), Double(clip.bounds.origin.y), Double(doc.frame.height - clip.bounds.maxY),
                            scroller.follow.follows ? "да" : "нет", ref?.key ?? "нет", Double(ref?.value ?? -1),
                            project.managerBusy ? "ход идёт" : "хода нет"))
        var heights = Set<Int>()
        var heightChanges = 0, originChanges = 0
        var lastH = doc.frame.height, lastO = clip.bounds.origin.y
        var maxShift: CGFloat = 0
        var log: [String] = []
        func screenNote() -> String {
            guard let pane = project.managerPaneID else { return "нет панели менеджера" }
            let out = app.hub.output(for: pane)
            let line = out.lines.map(\.plain).first { $0.contains("Advising") }.map { String($0.prefix(3)) } ?? "нет строки"
            return "черновик «\(out.reply.map { String($0.text.prefix(50)) } ?? "нет")» строка «\(line.prefix(40))»"
        }
        let t0 = CACurrentMediaTime()
        var frames = 0
        var lastNote = screenNote()
        var noteChanges = 0
        log.append("+0.00 " + lastNote)
        while CACurrentMediaTime() - t0 < seconds {
            frames += 1
            let h = doc.frame.height, o = clip.bounds.origin.y
            heights.insert(Int(h.rounded()))
            if abs(h - lastH) > 0.5 {
                heightChanges += 1; lastH = h
                if log.count < 12 { log.append(String(format: "+%.2f высота %.0f: ", CACurrentMediaTime() - t0, Double(h)) + screenNote()) }
            }
            if abs(o - lastO) > 0.5 { originChanges += 1; lastO = o }
            if let ref, let y = scroller.tracker.rows[ref.key] { maxShift = max(maxShift, abs(y - ref.value)) }
            let note = screenNote()
            if note != lastNote {
                noteChanges += 1; lastNote = note
                if log.count < 12 { log.append(String(format: "+%.2f ", CACurrentMediaTime() - t0) + note) }
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        lines.append("кадров \(frames), разных высот ленты \(heights.count), смен высоты \(heightChanges), сдвигов окна \(originChanges), смен черновика \(noteChanges)")
        lines.append(String(format: "сдвиг опорной строки: максимум %.1f pt", Double(maxShift)))
        lines.append(contentsOf: log)
        finish()
    }
}
