import AgentTeamCore
import AppKit
import SwiftUI

/// Стенд «очередь не уводит читающего» (`AGENT_TEAM_STAY_BENCH=<файл>`, только с `--bench`, синтетическая лента
/// `AGENT_TEAM_CHAT_SYNTH`): лента в середине, число ожидающих растёт и падает — видимая строка стоит на месте (0 pt).
/// Затем своя отправка из поля: лента встаёт на конец и снова следует за ним.
///
/// Ожидающие добавляются уже ушедшими (`held: false`): в панель менеджера они не пишутся, а снятие одного не отправляет
/// удержанных — их нет (стенд проверяет это до начала и иначе не идёт).
extension ChatPanel {
    func runStayBench() async {
        guard AppDefaults.isProbeRun(CommandLine.arguments),
              let path = ProcessInfo.processInfo.environment["AGENT_TEAM_STAY_BENCH"], app.project === project else { return }
        var lines: [String] = []
        func finish() { try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8) }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        guard !project.hasHeld else { lines.append("СТЕНД НЕ ШЁЛ: в очереди есть удержанные сообщения"); finish(); return }
        project.benchFreezeChat(Self.benchSynthChat(ProcessInfo.processInfo.environment["AGENT_TEAM_CHAT_SYNTH"].flatMap(Int.init) ?? 120))
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let scroll = chatScroll, let doc = scroll.documentView else { lines.append("прокрутка: NSScrollView не найден"); finish(); return }
        let clip = scroll.contentView
        func fromEnd() -> CGFloat { doc.frame.height - clip.bounds.maxY }

        // Середина ленты (повтор, пока окно не встанет дальше трёх экранов от конца: высоты ленивой ленты оценочные).
        for _ in 0..<5 {
            NotificationCenter.default.post(name: .benchUserInput, object: nil)
            clip.scroll(to: NSPoint(x: 0, y: max(0, (doc.frame.height - clip.bounds.height) / 2)))
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if fromEnd() > clip.bounds.height * 3 { break }
        }
        guard fromEnd() > clip.bounds.height * 3 else {
            lines.append(String(format: "СТЕНД НЕ УДЕРЖАЛ СЕРЕДИНУ: окно в %.0f pt от конца", fromEnd())); finish(); return
        }
        // Опорная строка — из строк, реализованных сейчас (`tracker.rows`: свёрнутая ленивой лентой строка оттуда уходит).
        let ids = Set(project.chat.map(\.id))
        guard let ref = scroller.tracker.rows.filter({ ids.contains($0.key) && $0.value > 40 && $0.value < clip.bounds.height - 300 }).min(by: { $0.value < $1.value }) else {
            lines.append("опорная строка не найдена"); finish(); return
        }
        lines.append(String(format: "середина: окно в %.0f pt от конца; опорная строка %@ на %.0f pt", fromEnd(), ref.key, ref.value))
        // Сдвиг видимой строки и расстояние окна до конца: лента, уведённая к концу, сворачивает опорную строку.
        func shift() -> String {
            let row = scroller.tracker.rows[ref.key].map { String(format: "%.1f pt", Double($0 - ref.value)) } ?? "строка ушла из окна"
            return row + String(format: ", окно в %.0f pt от конца", fromEnd())
        }

        let a = project.addPending(text: "стенд: первое", images: [])
        try? await Task.sleep(nanoseconds: 800_000_000)
        lines.append("ожидающих 0 → 1: сдвиг опорной строки \(shift())")
        let b = project.addPending(text: "стенд: второе", images: [])
        try? await Task.sleep(nanoseconds: 800_000_000)
        lines.append("ожидающих 1 → 2: сдвиг \(shift())")
        project.dropPending(a)
        try? await Task.sleep(nanoseconds: 800_000_000)
        lines.append("ожидающих 2 → 1 (первое дошло): сдвиг \(shift())")
        project.dropPending(b)
        try? await Task.sleep(nanoseconds: 800_000_000)
        lines.append("ожидающих 1 → 0: сдвиг \(shift()); «Новые ↓» \(follow.unseen ? "показана" : "нет")")

        // Своя отправка из поля — тот же счётчик, что поднимает `send()`; в панель ничего не уходит.
        ownSendJump += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        lines.append(String(format: "своя отправка: окно в %.0f pt от конца, следует за концом: %@", fromEnd(), follow.follows ? "да" : "нет"))
        finish()
    }
}
