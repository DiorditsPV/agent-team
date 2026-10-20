import AgentTeamCore
import AppKit
import QuartzCore

/// Замер прыжка позиции при подгрузке сверху (`AGENT_TEAM_HISTORY_BENCH`, `AGENT_TEAM_READ_BENCH`): верх строк в окне
/// и сдвиги якорной строки. Общий для всех лент на `FeedScroller`.
extension FeedScroller {
    nonisolated(unsafe) static var benchRowY: [String: CGFloat] = [:]
    /// Положение окна прокрутки в момент сообщения строки и сейчас: строка за краем окна о сдвиге прокрутки не сообщает,
    /// и замер по записанному месту не видел бы её сдвиг (`RowTracker.origins`).
    nonisolated(unsafe) static var benchRowOrigin: [String: CGFloat] = [:]
    nonisolated(unsafe) static var benchOrigin: (@MainActor () -> CGFloat)?
    @MainActor static func benchPlace(_ id: String) -> CGFloat? {
        let now = benchOrigin?() ?? 0
        return benchRowY[id].map { $0 - (now - (benchRowOrigin[id] ?? now)) }
    }
    nonisolated(unsafe) static var benchBefore: (id: String, y: CGFloat)?
    /// Сколько замеров прыжка ещё ждёт своего часа (стенд не прокручивает ленту, пока они не закончатся).
    nonisolated(unsafe) static var benchPending = 0
    nonisolated(unsafe) static var benchJumps: [Double] = []
    /// Сколько подгрузок пришло между подгрузкой и замером её прыжка (0 — замер чистый).
    nonisolated(unsafe) static var benchChained: [Int] = []
    nonisolated(unsafe) static var benchDocHeight: (@MainActor () -> CGFloat)?
    /// Проба, которую не выбирает прокрутка: строка ближе всех к середине окна (её место ленивая лента сообщает надёжно),
    /// кроме якоря. Её сдвиг на каждой подгрузке и за шаг стенда с подгрузками — проверка самого выбора якоря: замер по
    /// якорю показал бы 0 и при неверном якоре.
    nonisolated(unsafe) static var benchViewHeight: (@MainActor () -> CGFloat)?
    /// Проба по кадру (истина того, что видит владелец): кадр окна ленты при запросе страницы и перед следующим шагом
    /// стенда; сдвиг содержимого между ними — `ContentShift`.
    nonisolated(unsafe) static var benchCapture: (@MainActor () -> (rows: [[Float]], scale: CGFloat))?
    nonisolated(unsafe) static var benchImageBefore: (rows: [[Float]], scale: CGFloat)?
    /// Кадр в момент прихода первой страницы цепочки, до изменения ленты: сдвиг от него — только от подгрузки; сдвиг от
    /// кадра при запросе включает и то, что лента досчитала после шага прокрутки стенда.
    nonisolated(unsafe) static var benchImageArrival: (rows: [[Float]], scale: CGFloat)?

    /// Кадр окна прокрутки: на каждую строку пикселей 96 значений яркости.
    @MainActor static func captureRows(_ view: NSView) -> (rows: [[Float]], scale: CGFloat) {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds), let data = rep.bitmapData else { return ([], 1) }
        view.cacheDisplay(in: bounds, to: rep)
        let w = rep.pixelsWide, h = rep.pixelsHigh, bpr = rep.bytesPerRow, spp = max(rep.samplesPerPixel, 1), cols = 96
        var out: [[Float]] = []
        out.reserveCapacity(h)
        for y in 0..<h {
            var row = [Float](repeating: 0, count: cols)
            for c in 0..<cols {
                let x = min(w - 1, c * w / cols + w / (2 * cols))
                let p = data + y * bpr + x * spp
                row[c] = spp >= 3 ? (Float(p[0]) + Float(p[1]) + Float(p[2])) / 3 : Float(p[0])
            }
            out.append(row)
        }
        return (out, bounds.height > 0 ? CGFloat(h) / bounds.height : 1)
    }
    nonisolated(unsafe) static var benchMiddleBefore: (id: String, y: CGFloat)?
    nonisolated(unsafe) static var benchMiddleJumps: [Double] = []
    @MainActor static func benchMiddleRow(excluding: String?) -> (id: String, y: CGFloat)? {
        let h = benchViewHeight?() ?? 0
        var best: (id: String, y: CGFloat)?
        for id in benchRowY.keys where id != excluding {
            guard let y = benchPlace(id), y >= h * 0.15, y < h * 0.85 else { continue }
            if best == nil || abs(y - h / 2) < abs(best!.y - h / 2) { best = (id, y) }
        }
        return best
    }
    static let benchOn = ["AGENT_TEAM_HISTORY_BENCH", "AGENT_TEAM_READ_BENCH", "AGENT_TEAM_DIALOG_BENCH"].contains { ProcessInfo.processInfo.environment[$0] != nil }

    /// Стенд включён — замеры прокрутки идут сюда (`FeedScroller.benchHook`).
    static func installBenchHook() {
        if benchOn { benchHook = FeedBenchRecorder() }
    }

    /// Где тот же элемент стоит в окне после подгрузки и возврата прокрутки; один замер на одну подгрузку.
    static func benchRecordJump(ids: [String], revision: @escaping @MainActor () -> Int = { 0 }) {
        guard let b = benchBefore else { return }
        benchBefore = nil
        benchPending += 1
        let id = ids.contains(b.id) ? b.id : nil
        let middle = benchMiddleBefore
        benchMiddleBefore = nil
        let rev0 = MainActor.assumeIsolated { revision() }
        // Траектория для разбора (`AGENT_TEAM_JUMP_TRACE=<файл>`): место строки каждые 0,25 с и номер подгрузки.
        if let trace = ProcessInfo.processInfo.environment["AGENT_TEAM_JUMP_TRACE"], let id {
            let t0 = Date()
            for k in 1...16 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.25) {
                    MainActor.assumeIsolated {
                        let y = benchPlace(id).map { String(format: "%.1f", Double($0 - b.y)) } ?? "нет"
                        let line = String(format: "%.2f rev%d +%.2fs %@ сдвиг %@ доки %.0f\n", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000),
                                          rev0, Date().timeIntervalSince(t0), id, y,
                                          Double(benchDocHeight?() ?? -1))
                        if let h = FileHandle(forWritingAtPath: trace) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
                        else { try? line.write(toFile: trace, atomically: false, encoding: .utf8) }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            MainActor.assumeIsolated {
                if let id, let after = benchPlace(id) {
                    benchJumps.append(Double(after - b.y))
                    benchChained.append(revision() - rev0)
                }
                if let middle, let after = benchPlace(middle.id) { benchMiddleJumps.append(Double(after - middle.y)) }
            }
            benchPending -= 1
        }
    }

    /// Прокрутка ленты от конца до начала шагами по 1200 pt: кадр шага, упоры, прыжок видимой строки на каждой подгрузке.
    static func runHistoryBench(path: String, scroller: FeedScroller, model thread: AgentThreadModel) async {
        var waited = 0
        while scroller.scroll == nil, waited < 30 { try? await Task.sleep(nanoseconds: 1_000_000_000); waited += 1 }
        guard let scroll = scroller.scroll else {
            try? "СТЕНД НЕ ШЁЛ: окно прокрутки ленты не найдено за 30 с\n".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let clip = scroll.contentView
        benchDocHeight = { scroll.documentView?.frame.height ?? -1 }
        benchOrigin = { clip.bounds.origin.y }
        benchViewHeight = { clip.bounds.height }
        // Проба за шаг: строка у середины окна после шага прокрутки и её место перед следующим шагом, если между ними
        // пришли подгрузки.
        var stepProbe: (id: String, y: CGFloat, rev: Int)?
        var stepJumps: [Double] = []
        benchCapture = { captureRows(clip) }
        AgentThreadModel.benchWillPrepend = { model in
            if model === thread, benchImageArrival == nil, benchImageBefore != nil {
                benchImageArrival = captureRows(clip)
                benchHook?.note("кадр до: страница пришла")
            }
        }
        var arrivalShifts: [String] = []
        var arrivalWorst: Double = 0
        var imageShifts: [String] = []
        var imageWorst: Double = 0
        func frame() async {
            CATransaction.flush()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            CATransaction.flush()
            NSApp.windows.first { $0.title == "agent-team" }?.displayIfNeeded()
        }
        // Самопроверка пробы по кадру на настоящем окне: стенд сам сдвигает окно на 37 pt — проба обязана показать 37.
        // Идёт на третьем шаге, вдали от конца: у конца лента сама встаёт обратно в конец, и кадр сдвигается иначе.
        var selfTest = "не проверена"
        func runSelfTest() async -> String {
            let y0 = clip.bounds.origin.y
            guard y0 > 100 else { return "не проверена (окно у верха)" }
            await frame()
            let a = captureRows(clip)
            clip.scroll(to: NSPoint(x: 0, y: y0 - 37))
            scroll.reflectScrolledClipView(clip)
            await frame()
            let b = captureRows(clip)
            let shift = ContentShift.measure(before: a.rows, after: b.rows)
            if let dir = ProcessInfo.processInfo.environment["AGENT_TEAM_SHIFT_DUMP"] {
                for (name, f) in [("a", a), ("b", b)] {
                    let lines = f.rows.map { $0.map { String(Int($0)) }.joined(separator: " ") }.joined(separator: "\n")
                    try? lines.write(toFile: dir + "/selftest-\(name).txt", atomically: true, encoding: .utf8)
                }
            }
            clip.scroll(to: NSPoint(x: 0, y: y0))
            scroll.reflectScrolledClipView(clip)
            await frame()
            return (shift.pixels.map { String(format: "%.1f pt", Double($0) / Double(a.scale)) } ?? "нет совпадения")
                + String(format: " (ошибка %.1f, строк пикселей %d, масштаб %.1f)", shift.error, a.rows.count, Double(a.scale))
        }
        let t0 = CACurrentMediaTime()
        var frames: [Double] = []
        var stuck = 0
        var steps = 0
        // Замер засчитывается при видимом окне: перекрытое окно ленивая лента раскладывает иначе.
        var hidden: [Int] = []
        func visible() -> Bool { scroll.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false }
        let revision0 = thread.prependRevision
        var lastSeenRevision = thread.prependRevision
        let entries0 = thread.feed.count
        while steps < 4000 {
            steps += 1
            // Шаги прокрутки не накладываются на подгрузку и замер её прыжка: ждём тишины, иначе сдвиг даёт сам стенд.
            // После подгрузки закрепление само тянет следующую страницу, и под нагрузкой цепочка идёт дольше паузы:
            // тишина проверяется ещё раз прямо перед шагом, вместе с закреплённой строкой.
            func busy() -> Bool {
                thread.loadingEarlier || FeedScroller.benchPending > 0 || FeedScroller.benchBefore != nil
                    || scroller.tracker.pinID != nil || thread.prependRevision != lastSeenRevision
            }
            var quiet = 0.0
            repeat {
                while quiet < 30.0, busy() {
                    lastSeenRevision = thread.prependRevision
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    quiet += 0.1
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                quiet += 0.8
            } while busy() && quiet < 30.0
            lastSeenRevision = thread.prependRevision
            if steps == 3 { selfTest = await runSelfTest() }
            if let p = stepProbe, thread.prependRevision != p.rev, let y = benchPlace(p.id) { stepJumps.append(Double(y - p.y)) }
            stepProbe = nil
            if let before = benchImageBefore {
                benchImageBefore = nil
                let now = captureRows(clip)
                if let arrival = benchImageArrival {
                    benchImageArrival = nil
                    let s = ContentShift.measure(before: arrival.rows, after: now.rows)
                    if let px = s.pixels {
                        let pt = Double(px) / Double(arrival.scale)
                        arrivalWorst = max(arrivalWorst, abs(pt))
                        arrivalShifts.append(String(format: "%.1f", pt))
                    } else {
                        arrivalWorst = .infinity
                        arrivalShifts.append("нет")
                    }
                }
                let shift = ContentShift.measure(before: before.rows, after: now.rows)
                benchHook?.note(String(format: "кадр после: шаг %d, подгрузка %d, сдвиг %@, ошибка %.1f", steps, thread.prependRevision,
                                       shift.pixels.map { String($0) } ?? "нет", shift.error))
                if let px = shift.pixels {
                    let pt = Double(px) / Double(before.scale)
                    imageWorst = max(imageWorst, abs(pt))
                    imageShifts.append(String(format: "%.1f", pt))
                } else {
                    imageWorst = .infinity
                    imageShifts.append("нет")
                }
            }
            let f0 = CACurrentMediaTime()
            let revBefore = thread.prependRevision
            clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.origin.y - 1200)))
            scroll.reflectScrolledClipView(clip)
            await frame()
            frames.append((CACurrentMediaTime() - f0) * 1000)
            if !visible() { hidden.append(steps) }
            if thread.prependRevision == revBefore, let m = benchMiddleRow(excluding: nil) { stepProbe = (m.id, m.y, revBefore) }
            if clip.bounds.origin.y <= 1 {
                if !thread.hasEarlier && !thread.loadingEarlier { break }
                // ждём страницу; не пришла за 3 с — упор
                var waited = 0.0
                while waited < 3.0, thread.prependRevision == revBefore, thread.hasEarlier {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 0.05
                }
                if thread.prependRevision == revBefore { stuck += 1; if stuck >= 3 { break } }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await frame()
            }
        }
        let arrivalMax: String = arrivalWorst.isFinite ? String(format: "%.1f", arrivalWorst) : "нет совпадения"
        let arrivalLine = "сдвиг кадра от прихода страницы до затишья: максимум \(arrivalMax) pt, замеров \(arrivalShifts.count): "
            + arrivalShifts.joined(separator: " ")
        let requestMax: String = imageWorst.isFinite ? String(format: "%.1f", imageWorst) : "нет совпадения"
        let requestLine = "сдвиг кадра от запроса страницы до затишья: максимум \(requestMax) pt, замеров \(imageShifts.count): "
            + imageShifts.joined(separator: " ")
        let sorted = frames.sorted()
        let lines = [
            "записей в ленте: было \(entries0), стало \(thread.feed.count); подгружено страниц: \(thread.prependRevision - revision0)",
            "шагов прокрутки \(steps), время \(String(format: "%.1f", CACurrentMediaTime() - t0)) с, упоров \(stuck)",
            "до начала дошли: \(!thread.hasEarlier && clip.bounds.origin.y <= 1 ? "да" : "нет")",
            "окно перекрыто на шагах: \(hidden.count) из \(steps)" + (hidden.isEmpty ? "" : " (" + hidden.map(String.init).joined(separator: " ") + ")"),
            String(format: "кадр шага: среднее %.1f ms, p95 %.1f ms, максимум %.1f ms", frames.reduce(0, +) / Double(max(frames.count, 1)),
                   sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.last ?? 0),
            String(format: "прыжок позиции при подгрузке (положение того же элемента в окне до и после): максимум %.0f pt, по модулю в среднем %.1f pt, замеров %d (ожидание 0)",
                   FeedScroller.benchJumps.map { abs($0) }.max() ?? 0,
                   FeedScroller.benchJumps.isEmpty ? 0 : FeedScroller.benchJumps.map { abs($0) }.reduce(0, +) / Double(FeedScroller.benchJumps.count), FeedScroller.benchJumps.count),
            "из них до 2 pt: \(FeedScroller.benchJumps.filter { abs($0) <= 2 }.count), до 50 pt: \(FeedScroller.benchJumps.filter { abs($0) <= 50 }.count), больше 200 pt: \(FeedScroller.benchJumps.filter { abs($0) > 200 }.count)",
            "прыжки по подгрузкам: " + FeedScroller.benchJumps.prefix(40).map { String(format: "%.0f", $0) }.joined(separator: " "),
            "подгрузок до замера: " + FeedScroller.benchChained.prefix(40).map(String.init).joined(separator: " "),
            String(format: "строка у середины окна на подгрузке: максимум %.0f pt, замеров %d: ", FeedScroller.benchMiddleJumps.map { abs($0) }.max() ?? 0,
                   FeedScroller.benchMiddleJumps.count) + FeedScroller.benchMiddleJumps.prefix(40).map { String(format: "%.0f", $0) }.joined(separator: " "),
            String(format: "строка у середины окна за шаг с подгрузками: максимум %.0f pt, замеров %d: ", stepJumps.map { abs($0) }.max() ?? 0,
                   stepJumps.count) + stepJumps.prefix(40).map { String(format: "%.0f", $0) }.joined(separator: " "),
            "самопроверка пробы по кадру (окно сдвинуто на 37 pt): " + selfTest,
            arrivalLine,
            requestLine,
        ]
        try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Замеры прокрутки для стендов: место строк, якорь подгрузки, прыжок после неё.
@MainActor
final class FeedBenchRecorder: FeedScrollerBenchHook {
    func rowMoved(_ id: String, y: CGFloat) {
        FeedScroller.benchRowY[id] = y
        FeedScroller.benchRowOrigin[id] = FeedScroller.benchOrigin?()
    }
    func anchorChosen(_ id: String, y: CGFloat) {
        FeedScroller.benchBefore = (id, y)
        FeedScroller.benchMiddleBefore = FeedScroller.benchMiddleRow(excluding: id)
    }
    func prepended(ids: [String], revision: @escaping @MainActor () -> Int) { FeedScroller.benchRecordJump(ids: ids, revision: revision) }
    func pageRequested() {
        if FeedScroller.benchImageBefore == nil, let capture = FeedScroller.benchCapture {
            FeedScroller.benchImageBefore = capture()
            note("кадр до: запрос страницы")
        }
    }
    func note(_ text: String) {
        guard let trace = ProcessInfo.processInfo.environment["AGENT_TEAM_JUMP_TRACE"] else { return }
        let line = String(format: "%.2f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + text + "\n"
        if let h = FileHandle(forWritingAtPath: trace) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
        else { try? line.write(toFile: trace, atomically: false, encoding: .utf8) }
    }
}

