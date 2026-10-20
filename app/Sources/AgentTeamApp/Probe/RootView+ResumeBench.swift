import AgentTeamCore
import AppKit
import QuartzCore
import SwiftUI

/// Стенд «возврат в приложение» (`AGENT_TEAM_RESUME_BENCH=<файл>`, только в проверочном запуске; файлы транскриптов
/// для дописывания — `AGENT_TEAM_RESUME_FILES=<путь>,<путь>`, копии в подставном каталоге Claude): окно скрывается, в
/// транскрипты дописываются записи, окно показывается. Каждые 1/120 с снимается положение прокрутки всех видимых лент;
/// кадр с промежуточным положением (не там, где лента стояла при показе, и не там, где встала) — видимое пролистывание.
extension RootView {
    func runResumeBench() async {
        guard AppDefaults.isProbeRun(CommandLine.arguments),
              let path = ProcessInfo.processInfo.environment["AGENT_TEAM_RESUME_BENCH"] else { return }
        let files = (ProcessInfo.processInfo.environment["AGENT_TEAM_RESUME_FILES"] ?? "").split(separator: ",").map(String.init)
        let count = Int(ProcessInfo.processInfo.environment["AGENT_TEAM_RESUME_COUNT"] ?? "") ?? 12
        var lines: [String] = []
        func finish() { try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8) }
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        // Окно стенда — впереди: перекрытое окно ленты доводит без анимации, и замер не показал бы пролистывания.
        // Без активации приложения: стол у владельца общий, фокус и его ввод остаются там, где были.
        func front() async {
            NSApp.windows.first { $0.title == "agent-team" }?.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        func windowVisible() -> Bool {
            NSApp.windows.first { $0.title == "agent-team" }.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        }
        for _ in 0..<5 where !windowVisible() { await front() }

        func visible() -> [(key: String, scroller: FeedScroller)] {
            FeedScroller.rememberedByKey.compactMap { k, s in
                guard let sc = s.scroll, sc.window?.isVisible == true, sc.window?.occlusionState.contains(.visible) == true else { return nil }
                return (k, s)
            }.sorted { $0.key < $1.key }
        }
        let before = visible()
        lines.append("лент на экране: \(before.count); следуют: " + before.map { "\($0.key)=\($0.scroller.follow.follows)" }.joined(separator: " "))

        func counts() -> String {
            guard let p = app.project else { return "нет проекта" }
            let agents = (p.status?.agents ?? []).filter(\.alive).map { "\($0.name)=\(p.agentThread($0.name).feed.count)/\($0.sessionID ?? "-")" }
            return "чат \(p.chat.count) (\(p.managerThread.sessionID ?? "-")); " + agents.joined(separator: " ")
        }
        lines.append("до: " + counts())
        // Как окно уходит из вида: hide — приложение скрыто; cover — окно перекрыто другим (другое приложение поверх,
        // другой экран); batch — окно видно, записи приходят пачкой.
        let mode = ProcessInfo.processInfo.environment["AGENT_TEAM_RESUME_MODE"] ?? "hide"
        lines.append("режим: \(mode)")
        var cover: NSWindow?
        switch mode {
        case "cover":
            if let w = NSApp.windows.first(where: { $0.title == "agent-team" }) {
                let c = NSWindow(contentRect: w.frame.insetBy(dx: -40, dy: -40), styleMask: .borderless, backing: .buffered, defer: false)
                c.backgroundColor = .black
                c.isOpaque = true
                c.level = .floating
                c.orderFrontRegardless()
                cover = c
            }
        case "batch": break
        default: NSApp.hide(nil)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if let w = NSApp.windows.first(where: { $0.title == "agent-team" }) {
            lines.append("окно видно: \(w.occlusionState.contains(.visible))")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Пачка пишется в файл одной записью: так накопленное лежит в файле, когда приложение просыпается после фона,
        // и наблюдатель читает его одним разом.
        for f in files {
            guard let h = FileHandle(forWritingAtPath: f) else { lines.append("не открыть \(f)"); continue }
            h.seekToEndOfFile()
            var chunk = ""
            for k in 0..<count {
                let id = UUID().uuidString
                let text = "Запись стенда \(k + 1) из \(count): пока окно было скрыто, агент писал дальше.\\n\\nВторой абзац, чтобы строка была повыше."
                chunk += #"{"type":"assistant","uuid":"\#(id)","timestamp":"\#(iso.string(from: Date()))","message":{"id":"m-\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
            }
            h.write(Data(chunk.utf8))
            h.closeFile()
        }
        if mode != "batch" { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        let visibleAtBatch = windowVisible()
        lines.append("скрыто, после дописывания: " + counts())
        // Показ и кадры.
        var samples: [String: [CGFloat]] = [:]
        var distances: [String: [CGFloat]] = [:]
        var changes: [String: [String]] = [:]
        var lastState: [String: String] = [:]
        switch mode {
        case "cover":
            cover?.orderOut(nil); cover = nil
            NSApp.windows.first { $0.title == "agent-team" }?.orderFrontRegardless()
        case "batch": break
        default:
            // Возврат — показ окон без активации: ленты решают по видимости окна, а не по тому, активно ли приложение.
            NSApp.unhideWithoutActivation()
            NSApp.windows.first { $0.title == "agent-team" }?.orderFrontRegardless()
        }
        let t0 = CACurrentMediaTime()
        let window = Double(ProcessInfo.processInfo.environment["AGENT_TEAM_RESUME_WATCH"] ?? "") ?? 4
        while CACurrentMediaTime() - t0 < window {
            // Без активации окно, показанное одним выводом вперёд, бывает ещё под окнами активного приложения: вывод
            // повторяется, пока окно не станет видно (первую секунду).
            if mode != "batch", CACurrentMediaTime() - t0 < 1, !windowVisible() {
                NSApp.windows.first { $0.title == "agent-team" }?.orderFrontRegardless()
            }
            for (k, s) in visible() {
                guard let sc = s.scroll, let doc = sc.documentView else { continue }
                // Видимое положение: при анимации окна AppKit модельное положение сразу конечное, а на экране — слой.
                let o = sc.contentView.layer?.presentation()?.bounds.origin.y ?? sc.contentView.bounds.origin.y
                samples[k, default: []].append(o)
                let d = doc.frame.height - sc.contentView.bounds.maxY
                distances[k, default: []].append(d)
                let st = String(format: "o=%.0f h=%.0f d=%.0f f=%@", o, doc.frame.height, d, s.follow.follows ? "1" : "0")
                if lastState[k] != st {
                    lastState[k] = st
                    changes[k, default: []].append(String(format: "+%.3f %@", CACurrentMediaTime() - t0, st))
                }
            }
            try? await Task.sleep(nanoseconds: 8_000_000)
        }
        lines.append("после показа: " + counts())
        var total = 0, offEnd = 0
        for (k, o) in samples.sorted(by: { $0.key < $1.key }) {
            guard let first = o.first, let last = o.last else { continue }
            let mid = o.filter { abs($0 - first) > 1 && abs($0 - last) > 1 }.count
            let follows = FeedScroller.rememberedByKey[k]?.follow.follows ?? false
            if follows { total += mid }
            // Кадры, где следующая лента не у конца: расстояние до конца отличается от конечного (нижний отступ).
            let end = distances[k]?.last ?? 0
            let notAtEnd = (distances[k] ?? []).filter { abs($0 - end) > 1 }.count
            if follows { offEnd += notAtEnd }
            lines.append(String(format: "%@: кадров %d, промежуточных %d, путь %.0f pt, от конца в первом кадре %.0f, в последнем %.0f, следует %@",
                                k, o.count, mid, last - first, distances[k]?.first ?? -1, distances[k]?.last ?? -1, follows ? "да" : "нет"))
        }
        lines.append("окно видно при пачке: \(visibleAtBatch ? "да" : "нет"), при показе: \(windowVisible() ? "да" : "нет")")
        lines.append("промежуточных кадров у следующих лент: \(total)")
        lines.append("кадров не у конца у следующих лент: \(offEnd)")
        for (k, c) in changes.sorted(by: { $0.key < $1.key }) {
            lines.append("== \(k)")
            lines.append(contentsOf: c.prefix(60))
        }
        finish()
    }
}
