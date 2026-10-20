import AgentTeamCore
import AppKit

/// Стенд «медленно вверх во время хода» (`AGENT_TEAM_SCROLLUP_BENCH=<файл>`, только в проверочном запуске; транскрипт
/// для дописывания — `AGENT_TEAM_SCROLLUP_FILE=<путь>`, копия в подставном каталоге Claude). Синтетического ввода нет:
/// стенд сдвигает окно прокрутки сам и перед каждым шагом сообщает о вводе владельца (`benchUserInput`), как колесо.
/// Приложение стенд не активирует: окно выводится вперёд без фокуса, ввод владельца в другие окна не перехватывается.
///
/// Следование может вернуться только в допуске у конца (`ThreadFollow.tolerance`), поэтому стенд проходит эту зону
/// много раз (`AGENT_TEAM_SCROLLUP_CYCLES`, 10; весь прогон с кадром укладывается в минуту ожидания сценария запуска):
/// - лента — в конец (через цикл — сначала к началу ленты, чтобы строки между началом и концом снова стали оценочными);
/// - к последней записи дописывается продолжение с тем же `message.id`, 0,6 с идёт ход и лента следует за ним (окно
///   ввода прошлого шага, 0,4 с, за это время кончается);
/// - шаги вверх по `AGENT_TEAM_SCROLLUP_STEP` pt (по умолчанию пиксель экрана) каждые `AGENT_TEAM_SCROLLUP_STEP_MS`
///   (16) мс, пока лента не выйдет из допуска. Пока идут шаги, ход молчит: рост ниже окна выносит ленту из допуска
///   за одну запись (следование уже снято, лента стоит), и зона пролетала бы непроверенной. Рост и сдвиг начала окна
///   во время шагов — тогда уточнение высот ленивой лентой: то, что проверяет стенд.
/// Ход: каждые `AGENT_TEAM_SCROLLUP_WRITE_MS` (300) мс две записи разной высоты. После циклов — 2 с покоя, ход идёт.
///
/// Итог (строка «ИТОГ: …»; сценарий запуска переводит её в код возврата):
/// - «НЕ ПРОШЁЛ» — следование вернулось над концом или лента ехала к концу без шага вниз;
/// - «НЕ ПРОВЕРЕНО» — в допуске не было ни роста, ни сдвига начала окна не стендом: проверять было нечего;
/// - «следование цело, гипотеза 6 не проверена» — рост в допуске был, а сдвига начала окна не стендом (компенсации
///   уточнения высот выше окна) не было: рост ниже окна даёт сам ход;
/// - «прошёл» — компенсация в допуске была, и следование не вернулось.
/// Живую прокрутку AppKit (ползунок, жест трекпада) стенд не воспроизводит: её уведомления идут только от настоящего жеста.
@MainActor
enum ScrollUpBench {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard AppDefaults.isProbeRun(CommandLine.arguments), let path = env["AGENT_TEAM_SCROLLUP_BENCH"] else { return }
        var lines: [String] = []
        func finish() { try? lines.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8) }
        try? await Task.sleep(nanoseconds: 15_000_000_000)

        // Окно — впереди, без активации приложения: перекрытое окно ленты ставится в конец сразу, и замер был бы не тот.
        func window() -> NSWindow? { NSApp.windows.first { $0.title == "agent-team" } }
        func windowVisible() -> Bool { window().map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false }
        for _ in 0..<5 where !windowVisible() {
            window()?.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard windowVisible() else { lines.append("СТЕНД НЕ ШЁЛ: окно не видно и без активации вперёд не вышло"); finish(); return }

        let keyPart = env["AGENT_TEAM_SCROLLUP_KEY"] ?? "|~chat"
        guard let (key, scroller) = FeedScroller.rememberedByKey.first(where: { k, s in
            k.contains(keyPart) && s.scroll?.window?.isVisible == true
        }), let scroll = scroller.scroll, let doc = scroll.documentView else {
            lines.append("СТЕНД НЕ ШЁЛ: на экране нет ленты с ключом «\(keyPart)»; ленты: "
                         + FeedScroller.rememberedByKey.keys.sorted().joined(separator: " "))
            finish(); return
        }
        guard let file = env["AGENT_TEAM_SCROLLUP_FILE"], FileManager.default.isWritableFile(atPath: file) else {
            lines.append("СТЕНД НЕ ШЁЛ: нет транскрипта для дописывания (AGENT_TEAM_SCROLLUP_FILE)"); finish(); return
        }
        let clip = scroll.contentView
        let pixel = 1 / max(scroll.window?.backingScaleFactor ?? 2, 1)
        let step = CGFloat(Double(env["AGENT_TEAM_SCROLLUP_STEP"] ?? "") ?? Double(pixel))
        let stepMs = UInt64(env["AGENT_TEAM_SCROLLUP_STEP_MS"].flatMap(UInt64.init) ?? 16)
        let cycles = Int(env["AGENT_TEAM_SCROLLUP_CYCLES"] ?? "") ?? 10
        let writeMs = UInt64(env["AGENT_TEAM_SCROLLUP_WRITE_MS"].flatMap(UInt64.init) ?? 300)
        let end = scroller.endInset + pixel / 2
        let tolerance = ThreadFollow.tolerance
        func fromEnd() -> CGFloat { doc.frame.height - clip.bounds.maxY }
        func setOrigin(_ y: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scroll.reflectScrolledClipView(clip)
        }
        lines.append(String(format: "лента %@; пиксель %.1f pt, шаг %.1f pt каждые %d мс, циклов %d; конец — до %.2f pt, допуск — до %.0f pt",
                            key, pixel, step, stepMs, cycles, end, tolerance))

        // Ход: две записи разной высоты за раз (как вызов инструмента и результат). Последний `message.id` — для
        // продолжения той же записи.
        final class Writer {
            var written = 0
            /// Ход молчит (идут шаги вверх).
            var paused = false
            var lastMessage = ""
            let iso: ISO8601DateFormatter = {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return f
            }()
            func record(message: String, text: String) -> String {
                let id = UUID().uuidString
                return #"{"type":"assistant","uuid":"\#(id)","timestamp":"\#(iso.string(from: Date()))","message":{"id":"\#(message)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n"
            }
            func append(_ chunk: String, to file: String) {
                guard let h = FileHandle(forWritingAtPath: file) else { return }
                h.seekToEndOfFile()
                h.write(Data(chunk.utf8))
                h.closeFile()
            }
        }
        let w = Writer()
        let writer = Task { @MainActor in
            while !Task.isCancelled {
                if w.paused { try? await Task.sleep(nanoseconds: 50_000_000); continue }
                var chunk = ""
                for k in 0..<2 {
                    w.written += 1
                    w.lastMessage = "m-" + UUID().uuidString
                    let paragraphs = Array(repeating: "Абзац записи, чтобы строка была повыше и уточняла высоту.", count: 1 + (w.written + k) % 4)
                    chunk += w.record(message: w.lastMessage, text: "Запись стенда \(w.written) во время хода.\\n\\n" + paragraphs.joined(separator: "\\n\\n"))
                }
                w.append(chunk, to: file)
                try? await Task.sleep(nanoseconds: writeMs * 1_000_000)
            }
        }
        defer { writer.cancel() }
        func continueLast() {
            w.append(w.record(message: w.lastMessage, text: "Продолжение той же записи: ответ дописывается, запись растёт.\\n\\nЕщё абзац продолжения."), to: file)
        }

        var refollowed = 0, pulledBack = 0, foreignAll = 0, foreignInZone = 0, growthInZone = 0, zoneSteps = 0, continuations = 0
        var notAtEnd = 0
        var foreign: [String] = []
        var trace: [String] = []
        let t0 = Date()
        func note(_ s: String) { if trace.count < 150 { trace.append(String(format: "+%.3f ", Date().timeIntervalSince(t0)) + s) } }
        for cycle in 0..<cycles {
            // Окно ввода прошлого шага (0,4 с) кончается: иначе переход стенда к началу и к концу лента принимала бы за
            // шаг владельца и снимала следование.
            try? await Task.sleep(nanoseconds: 500_000_000)
            if cycle % 2 == 1 {
                setOrigin(0)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            setOrigin(doc.frame.height - clip.bounds.height - scroller.endInset)
            scroller.follow.jumpedToEnd()
            w.paused = false
            continueLast()
            continuations += 1
            try? await Task.sleep(nanoseconds: 600_000_000)
            // Цикл начинается у конца: иначе шаги в допуск не попадают, и проверять в нём нечего.
            note(String(format: "цикл %d: перед шагами %.1f pt от конца, следует %@, высота %.0f", cycle, fromEnd(),
                        scroller.follow.follows ? "да" : "нет", doc.frame.height))
            if fromEnd() > tolerance { notAtEnd += 1 }
            w.paused = true
            // Записи, начатые до паузы, читатель транскрипта доносит с задержкой: шаги — после того, как они разложены.
            try? await Task.sleep(nanoseconds: 700_000_000)
            if fromEnd() > tolerance { note(String(format: "цикл %d: после паузы хода %.1f pt от конца", cycle, fromEnd())) }
            // Шаги вверх до выхода из допуска. После шага и ожидания кадра сравнивается: начало окна — с тем, где его
            // поставил шаг (разница — сдвиг не стендом: раскладка, компенсация, доводка к концу), высота документа — с той,
            // что была сразу после шага (рост). Зона — по расстоянию сразу после шага: рост ниже окна выносит ленту из
            // допуска одним кадром, и по расстоянию после роста он в зону не попал бы.
            var previousD = fromEnd()
            var n = 0
            while fromEnd() <= tolerance + 2, n < 400 {
                NotificationCenter.default.post(name: .benchUserInput, object: nil)
                setOrigin(clip.bounds.origin.y - step)
                let o = clip.bounds.origin.y, h = doc.frame.height, d = fromEnd()
                n += 1
                try? await Task.sleep(nanoseconds: stepMs * 1_000_000)
                let o2 = clip.bounds.origin.y, h2 = doc.frame.height, nd = fromEnd()
                let inZone = d > end && d <= tolerance
                if inZone { zoneSteps += 1 }
                if abs(o2 - o) > 0.25 {
                    foreignAll += 1
                    if inZone { foreignInZone += 1 }
                    if foreign.count < 40 {
                        foreign.append(String(format: "цикл %d, шаг %d, %.1f pt от конца: начало окна %.1f → %.1f (%+.1f), высота %.0f → %.0f",
                                              cycle, n, d, o, o2, o2 - o, h, h2))
                    }
                }
                if abs(h2 - h) > 0.25 {
                    if inZone { growthInZone += 1 }
                    note(String(format: "цикл %d, шаг %d: рост %+.1f pt при %.1f pt от конца, начало окна %+.1f", cycle, n, h2 - h, d, o2 - o))
                }
                if nd < previousD - 0.5 { pulledBack += 1; note(String(format: "цикл %d: к концу без шага вниз %.1f → %.1f pt", cycle, previousD, nd)) }
                if scroller.follow.follows, nd > end { refollowed += 1; note(String(format: "цикл %d: следует над концом, %.1f pt", cycle, nd)) }
                previousD = nd
            }
            note(String(format: "цикл %d: вышел после %d шагов: %.1f pt от конца, начало окна %.1f, высота окна %.1f, документа %.0f",
                        cycle, n, fromEnd(), clip.bounds.origin.y, clip.bounds.height, doc.frame.height))
            if scroller.follow.follows { refollowed += 1; note(String(format: "цикл %d: вышел из допуска, а следует, %.1f pt", cycle, fromEnd())) }
        }
        lines.append(String(format: "циклов %d за %.1f с; начато не у конца %d; шагов в допуске %d; продолжений записи %d",
                            cycles, Date().timeIntervalSince(t0), notAtEnd, zoneSteps, continuations))

        // Покой: записи идут, лента стоит.
        w.paused = false
        let restFrom = fromEnd()
        var restMin = restFrom
        let t2 = Date()
        while Date().timeIntervalSince(t2) < 2 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            restMin = min(restMin, fromEnd())
            if scroller.follow.follows, fromEnd() > end { refollowed += 1; note(String(format: "покой: следует над концом, %.1f pt", fromEnd())) }
        }
        if restMin < restFrom - 0.5 { pulledBack += 1; note(String(format: "покой: к концу %.1f → %.1f pt", restFrom, restMin)) }
        lines.append(String(format: "покой 2 с: от конца %.1f → %.1f pt (ближе всего %.1f), следует %@, «Новые ↓» %@",
                            restFrom, fromEnd(), restMin, scroller.follow.follows ? "да" : "нет", scroller.follow.unseen ? "есть" : "нет"))
        lines.append("записей дописано: \(w.written)")
        lines.append("ростов в допуске: \(growthInZone)")
        lines.append("сдвигов начала окна не стендом: \(foreignAll), из них в допуске: \(foreignInZone)")
        lines.append(contentsOf: foreign)
        lines.append("следование вернулось над концом: \(refollowed)")
        lines.append("лента ехала к концу без шага вниз: \(pulledBack)")
        lines.append(foreignInZone > 0
                     ? "компенсация выше окна в допуске: была, \(foreignInZone) раз — вопрос ревью проверен"
                     : "компенсация выше окна в допуске: не случилась — вопрос ревью этим прогоном не проверен")
        let verdict: String
        if refollowed > 0 || pulledBack > 0 || scroller.follow.follows { verdict = "ИТОГ: НЕ ПРОШЁЛ" }
        else if foreignInZone > 0 { verdict = "ИТОГ: прошёл" }
        else if growthInZone > 0 { verdict = "ИТОГ: следование цело, гипотеза 6 не проверена — компенсации выше окна в допуске не было" }
        else { verdict = "ИТОГ: НЕ ПРОВЕРЕНО — в допуске не было ни роста, ни сдвига начала окна" }
        lines.append(verdict)
        lines.append("== ход")
        lines.append(contentsOf: trace)
        finish()
    }
}
