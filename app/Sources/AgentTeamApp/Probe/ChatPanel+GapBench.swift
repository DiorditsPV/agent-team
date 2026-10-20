import AgentTeamCore
import AppKit
import SwiftUI

/// Рамка строки вне `ForEach` для стенда пустот (`AGENT_TEAM_GAP_BENCH`); без стенда ничего не делает.
struct BenchFrame: ViewModifier {
    let key: String
    let on: Bool
    @State private var token = UUID()
    private func record(_ frame: CGRect) {
        ChatPanel.benchRowFrame[key] = frame
        ChatPanel.benchRowOwner[key] = token
    }
    func body(content: Content) -> some View {
        if on {
            // onGeometryChange у строки, появившейся после прыжка прокрутки, иногда не сообщает первое значение (строка стоит в окне,
            // а рамки нет); чтение на onAppear это закрывает.
            content
                .background {
                    GeometryReader { g in
                        let frame = g.frame(in: .named("chatDoc"))
                        Color.clear
                            .onAppear { record(frame) }
                            .onChange(of: frame) { _, new in record(new) }
                    }
                }
                // Строка ушла из ленты — рамка снимается, но только если её писал этот же экземпляр: при пересоздании строки
                // с тем же id новый экземпляр пишет рамку раньше, чем старый получает onDisappear, и снятие стирало бы живую.
                .onDisappear {
                    guard ChatPanel.benchRowOwner[key] == token else { return }
                    ChatPanel.benchRowFrame[key] = nil
                    ChatPanel.benchRowOwner[key] = nil
                }
        } else {
            content
        }
    }
}

extension ChatPanel {
    /// Рамки строк ленты в её координатах (стенд пустот).
    nonisolated(unsafe) static var benchRowFrame: [String: CGRect] = [:]
    nonisolated(unsafe) static var benchRowOwner: [String: UUID] = [:]
    static let gapBenchOn = ProcessInfo.processInfo.environment["AGENT_TEAM_GAP_BENCH"] != nil
    nonisolated(unsafe) static var gapBenchTaken = false
    nonisolated(unsafe) static var benchDupIDs = 0

    /// Стенд пустот и прыжков ленты (`AGENT_TEAM_GAP_BENCH=<файл>`, демо-проект на временном сокете, подставной экран
    /// менеджера). Циклы «черновик появился → вырос → заменён блоком транскрипта» в двух порядках (экран стёрт раньше
    /// прихода блока и позже), с двумя сообщениями «в очереди» и уходом одного из них в транскрипт; в двух положениях:
    /// у края и читающий выше. Каждый кадр мерятся:
    /// - наибольший просвет между соседними видимыми строками (допуск — межзаписный интервал плюс 2 pt);
    /// - у читающего — сдвиг опорной строки в окне (ожидание 0);
    /// - у края — обратный рывок: насколько опорная строка уходит вниз после того, как уже поднялась, сверх усадки ленты
    ///   (когда черновик выше блока или снят по сроку, лента у края уходит вниз ровно на усадку — это не рывок; ожидание 0);
    /// - кадры, где черновик и его блок видны одновременно (ожидание 0);
    /// - повторы id в ленте (ожидание 0).
    /// Рамки строк пишет `BenchFrame` (в координатах ленты, на onAppear и при смене). Строка стенда — «ок» или «ПЛОХО».
    ///
    /// Порядок запуска: `scripts/gap-bench.sh` (демо-проект на временном сокете, подставной claude, копия Dev-сборки со своим
    /// bundle id; приложение останавливается по своему pid, ввод с клавиатуры не нужен). Один прогон за раз. С `GAP_BREAK=1`
    /// (`AGENT_TEAM_GAP_BENCH_BREAK`) после обычных сценариев идут четыре намеренно сломанных, и все они обязаны быть «ПЛОХО».
    func runGapBench() async {
        guard let path = ProcessInfo.processInfo.environment["AGENT_TEAM_GAP_BENCH"], app.project === project else { return }
        try? await Task.sleep(nanoseconds: 12_000_000_000)
        guard !Self.gapBenchTaken, let scroll = chatScroll, scroll.window != nil else { return }
        Self.gapBenchTaken = true
        gapBenchActive = true
        let clip = scroll.contentView
        var entries: [ChatEntry] = []
        for i in 0..<14 {
            let t = Date(timeIntervalSince1970: 1_760_000_000 + Double(i) * 60)
            entries.append(ChatEntry(id: "g\(i)-o", time: t, kind: .owner("Задача \(i): проверь сборку")))
            entries.append(ChatEntry(id: "g\(i)-a", time: t, kind: .reply("Ход \(i). Сборка прошла, **тесты зелёные**.\n\n- первое замечание\n- второе замечание, подлиннее, чтобы строка переносилась и занимала не одну строку ленты")))
        }
        project.benchFreezeChat(entries)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let limit = ChatFont.gap(16) + 2
        var lines: [String] = []
        func tick() async {
            // Кадр не принуждается (CATransaction.flush, displayIfNeeded): принудительная отрисовка посреди прохода раскладки
            // показывала промежуточные состояния, которых на экране нет, — прокрутка у края «прыгала» на 85–260 pt на один кадр.
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        func visibleRows() -> [(key: String, value: CGRect)] {
            // Рамки — в координатах ленты; в окно их переводит прокрутка AppKit (её ленивая лента не скрывает от замера).
            let top = clip.bounds.origin.y
            return Self.benchRowFrame.map { (key: $0.key, value: $0.value.offsetBy(dx: 0, dy: -top)) }
                .filter { $0.value.maxY > 0 && $0.value.minY < viewH && $0.value.height > 0 }.sorted { $0.value.minY < $1.value.minY }
        }
        func worstGap() -> (CGFloat, String) {
            let rows = visibleRows()
            var w: (CGFloat, String) = (0, "")
            for (x, y) in zip(rows, rows.dropFirst()) where y.key != "~bottom" && y.value.minY - x.value.maxY > w.0 {
                w = (y.value.minY - x.value.maxY, x.key + " → " + y.key)
            }
            return w
        }
        var cycle = 0
        var shotCycles = Set<Int>()
        var dupMax = 0
        var trace: [String] = []
        /// От нижней строки ленты до нижнего края окна (у края — около вертикального отступа ленты).
        func endDistance() -> CGFloat {
            guard let b = Self.benchRowFrame["~bottom"] else { return -9999 }   // нижняя строка не реализована: конец далеко
            return clip.bounds.maxY - (b.maxY + (wide ? 14 : 20))
        }
        /// Один цикл: действия по времени (мс от начала), замеры каждый кадр до `total` мс.
        func run(_ label: String, reader: Bool, total: Double, _ steps: [(Double, @MainActor () -> Void)]) async {
            cycle += 1
            Self.benchDupIDs = 0
            // Положение ставится с проверкой: прокрутка сразу после предыдущего цикла иногда не держится (лента возвращается к концу
            // или не доходит до него), и замер не в том положении ничего не доказывает. До пяти попыток; не встало — цикл «ПЛОХО».
            var placed = false
            for _ in 0..<5 where !placed {
                if reader {
                    NotificationCenter.default.post(name: .benchUserInput, object: nil)
                    let doc = scroll.documentView?.frame.height ?? 0
                    clip.scroll(to: NSPoint(x: 0, y: max(0, doc - clip.bounds.height - 500)))
                    scroll.reflectScrolledClipView(clip)
                    follow.scrolled(distanceFromBottom: 500)
                } else {
                    // К концу: ленивая лента уточняет высоту документа по мере реализации строк, поэтому несколько раз,
                    // с ограничением границ AppKit.
                    for _ in 0..<4 {
                        let r = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: 10_000_000), size: clip.bounds.size))
                        clip.scroll(to: r.origin)
                        scroll.reflectScrolledClipView(clip)
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    }
                    follow.jumpedToEnd()
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                placed = reader ? (!follow.shouldStickToEnd && endDistance() < -300) : (follow.shouldStickToEnd && endDistance() >= 0 && endDistance() < 60)
            }
            // Опорная строка — видимая запись транскрипта (не хвост) ближе к середине окна.
            let ref = visibleRows().filter { !$0.key.hasPrefix("~") && !$0.key.hasPrefix("pending-") && $0.key != "live-reply" && $0.value.minY > 20 }.min { abs($0.value.midY - viewH / 2) < abs($1.value.midY - viewH / 2) }
            let startInfo = String(format: "следует %@, до конца %.0f", follow.shouldStickToEnd ? "да" : "нет", endDistance())
            func screenY(_ key: String) -> CGFloat? { Self.benchRowFrame[key].map { $0.minY - clip.bounds.origin.y } }
            let y0 = ref.flatMap { screenY($0.key) } ?? 0
            var pending = steps
            let t0 = CACurrentMediaTime()
            var maxGap: (CGFloat, String) = (0, "")
            var maxShift: CGFloat = 0
            var lowest = y0
            var back: CGFloat = 0
            var both = 0
            var frames = 0
            var yRange = (CGFloat.infinity, -CGFloat.infinity)
            var docRange = (CGFloat.infinity, -CGFloat.infinity)
            var shrink: CGFloat = 0
            var bottomTop: CGFloat = -.infinity
            var seen = 0
            while (CACurrentMediaTime() - t0) * 1000 < total {
                let ms = (CACurrentMediaTime() - t0) * 1000
                while let f = pending.first, f.0 <= ms { pending.removeFirst(); f.1() }
                await tick()
                frames += 1
                let g = worstGap()
                if g.0 > maxGap.0 {
                    maxGap = g
                    if g.0 > limit, !shotCycles.contains(cycle), let v = NSApp.windows.first(where: { $0.title == "agent-team" })?.contentView,
                       let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        shotCycles.insert(cycle); v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".gap\(cycle).png"))
                    }
                }
                let dh = scroll.documentView?.frame.height ?? 0
                docRange = (min(docRange.0, dh), max(docRange.1, dh))
                // Усадка — по измеренной нижней строке, не по высоте документа: ленивая лента уточняет высоту при прокрутке.
                if let b = Self.benchRowFrame["~bottom"]?.maxY { bottomTop = max(bottomTop, b); shrink = max(shrink, bottomTop - b) }
                trace.append(String(format: "%d\t%d\t%@\t%.0f\t%.0f\t%.0f\t%@", cycle, Int(ms), ref?.key ?? "-", ref.flatMap { screenY($0.key) } ?? -1, clip.bounds.origin.y, dh,
                                    liveReply == nil ? "-" : "live"))
                if let ref, let y = screenY(ref.key) {
                    seen += 1
                    yRange = (min(yRange.0, y), max(yRange.1, y))
                    maxShift = max(maxShift, abs(y - y0))
                    lowest = min(lowest, y)
                    back = max(back, y - lowest)
                }
                let keys = Set(visibleRows().map(\.key))
                if keys.contains("live-reply"), keys.contains(where: { $0.hasPrefix("r\(cycle)-") }) { both += 1 }
            }
            let dups = Self.benchDupIDs
            dupMax = max(dupMax, dups)
            let gapBad = maxGap.0 > limit
            // У края при следовании за концом строка уходит вниз ровно на столько, на сколько усох документ (черновик выше блока или
            // снят по сроку): это не рывок. Рывок — то, что сверх усадки.
            let moveBad = reader ? maxShift > 0.5 : back > shrink + 0.5
            lines.append(String(format: "%@ %@ [%@]: кадров %d; просвет %.0f pt (%@); %@ %.1f pt (усадка ленты %.0f); черновик и блок вместе: %d кадров; повторов id %d%@; опорная %@ y %.0f…%.0f (в %d кадрах); высота документа %.0f…%.0f; до конца в итоге %.0f pt; в начале: %@; в конце следует %@",
                                gapBad || moveBad || both > 0 || dups > 0 || !placed ? "ПЛОХО" : "ок   ", label, reader ? "читающий выше" : "у края", frames,
                                maxGap.0, maxGap.1, reader ? "сдвиг опорной" : "обратный рывок", reader ? maxShift : back, shrink, both, dups, placed ? "" : "; ПОЛОЖЕНИЕ НЕ ПОСТАВЛЕНО",
                                ref?.key ?? "нет", yRange.0, yRange.1, seen, docRange.0, docRange.1,
                                endDistance(), startInfo, follow.shouldStickToEnd ? "да" : "нет"))
        }
        func reply(_ n: Int) -> String { "Ответ \(n). " + String(repeating: "Менеджер пишет длинный ответ, строки переносятся и растут по мере генерации. ", count: 8) }
        func grow(_ n: Int, _ parts: Int) -> String { String(reply(n).prefix(reply(n).count * parts / 5)) }
        func addReply(_ n: Int) {
            project.benchFreezeChat(project.chat + [ChatEntry(id: "r\(n)-a", time: Date(), kind: .reply(reply(n)))])
        }
        func draftCycle(_ label: String, reader: Bool, screenFirst: Bool) async {
            let n = cycle + 1
            var steps: [(Double, @MainActor () -> Void)] = (1...5).map { k in (Double(k) * 150, { benchScreen = LiveReply(text: grow(n, k), startCut: false) }) }
            if screenFirst {
                steps.append((1000, { benchScreen = nil }))           // вызов инструмента стёр текст с экрана
                steps.append((1600, { addReply(n) }))                  // блок дошёл до ленты позже
            } else {
                steps.append((1000, { addReply(n) }))                  // блок в ленте, экран ещё показывает текст
                steps.append((1400, { benchScreen = nil }))
            }
            await run(label, reader: reader, total: 2600, steps)
        }
        let q1 = project.addPending(text: "Первое сообщение в очереди", images: [], held: true)
        _ = project.addPending(text: "Второе сообщение в очереди, подлиннее, чтобы заняло две строки ленты и было видно, где кончается", images: [], held: true)
        for reader in [false, true] {
            await draftCycle("черновик → блок, экран стёрт раньше", reader: reader, screenFirst: true)
            await draftCycle("черновик → блок, блок пришёл раньше", reader: reader, screenFirst: false)
        }
        // Первое из очереди ушло в транскрипт: карточка снимается, запись владельца встаёт в ленту.
        await run("сообщение очереди ушло в транскрипт", reader: false, total: 1500, [(100, {
            project.benchFreezeChat(project.chat + [ChatEntry(id: "q1-o", time: Date(), kind: .owner("Первое сообщение в очереди"))])
            project.reconcilePending()
            _ = q1
        })])
        for reader in [false, true] {
            await draftCycle("черновик → блок при очереди, экран стёрт раньше", reader: reader, screenFirst: true)
        }
        // Черновик без блока (прерванный ход): держится срок и уходит.
        await run("черновик без блока снят по сроку", reader: false, total: 8000, [
            (100, { benchScreen = LiveReply(text: "Прерванный ответ, блок в транскрипт не придёт.", startCut: false) }),
            (600, { benchScreen = nil }),
        ])
        // Срок черновика без блока может кончиться после цикла; следующие циклы ждут, пока он снят.
        for _ in 0..<150 where liveReply != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        lines.append(String(format: "черновик после срока: %@", liveReply == nil ? "снят" : "висит"))
        // Намеренно сломанные случаи (`AGENT_TEAM_GAP_BENCH_BREAK=1`): стенд сам вносит дефект, и каждая строка обязана быть «ПЛОХО».
        // Так проверяется, что стенд ловит то, ради чего написан; без переменной этих циклов нет.
        if ProcessInfo.processInfo.environment["AGENT_TEAM_GAP_BENCH_BREAK"] != nil {
            func nudge(_ dy: CGFloat) { clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y + dy)); scroll.reflectScrolledClipView(clip) }
            await run("СЛОМАНО: лента прыгнула на 40 pt", reader: true, total: 1500, [(600, { nudge(40) })])
            await run("СЛОМАНО: лента отъехала от края на 30 pt", reader: false, total: 1500, [(100, { nudge(-60) }), (500, { nudge(30) })])
            await run("СЛОМАНО: блок пришёл, а черновик с другим текстом остался", reader: false, total: 2000, [
                (100, { benchScreen = LiveReply(text: "Черновик, который блок не заменяет.", startCut: false) }),
                (500, { addReply(cycle) }),
            ])
            benchScreen = nil
            await run("СЛОМАНО: одна запись дважды", reader: false, total: 1000, [(100, {
                let e = ChatEntry(id: "dup-1", time: Date(), kind: .reply("Запись с повторяющимся id."))
                project.benchFreezeChat(project.chat + [e, e])
            })])
        }
        lines.append("\(dupMax > 0 ? "ПЛОХО" : "ок   ") повторов id в ленте за весь стенд (наибольшее за кадр): \(dupMax)")
        try? trace.joined(separator: "\n").write(toFile: path + ".trace", atomically: true, encoding: .utf8)
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
