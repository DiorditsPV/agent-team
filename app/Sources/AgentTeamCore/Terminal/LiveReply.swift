import Foundation

/// Ответ менеджера, который он пишет прямо сейчас: Claude Code записывает текстовый блок в транскрипт только
/// целиком, а на экране панели текст растёт по мере генерации. Замер на ходе менеджера: блок в 4500 знаков
/// виден в панели за 13 с до записи в транскрипт. Текст берётся с экрана и в ленте идёт черновиком «пишет».
public struct LiveReply: Equatable, Sendable {
    /// Текст с убранными переносами по ширине панели: абзацы разделены пустой строкой.
    public var text: String
    /// Начало ответа уже ушло за верхний край экрана (альтернативный экран без истории): виден только хвост.
    public var startCut: Bool

    public init(text: String, startCut: Bool) {
        self.text = text
        self.startCut = startCut
    }

    /// Текущий текстовый блок с экрана панели или nil: блока нет, после него был вызов инструмента (значит, он уже в
    /// транскрипте), или экран занят вопросом о праве.
    /// `toolColors` — цвета кружка идущего инструмента (`ScreenMarks.steadyBullets`): строка инструмента («⏺ Advising
    /// using …», «⏺ Mid tool run…») не ответ — что делает менеджер, показывает строка хода.
    public static func extract(_ raw: [StyledLine], toolColors: Set<TermColor> = []) -> LiveReply? {
        let content = PaneTail.content(raw)
        // Диалог внизу экрана (вопрос о праве, форма AskUserQuestion) — не ответ менеджера. Поле ввода с «❯» обрезает
        // PaneTail.content по последней такой строке, поэтому диалог ищется и по целому экрану.
        guard !PaneTail.asksPermission(content.map(\.plain)), !PaneTail.asksPermission(raw.map(\.plain)),
              !AskForm.isOpen(raw), PermissionPrompt.from(raw) == nil else { return nil }
        let kept = content.filter { !PaneDigest.isNoise($0.plain) }
        func boundary(_ p: String) -> Bool {
            PaneDigest.isBullet(p) || PaneDigest.isAction(p) || PaneDigest.isResult(p)
                || p.trimmingCharacters(in: .whitespaces).hasPrefix("❯")
        }
        var lines: [String] = []
        var cut = false
        if let start = kept.indices.reversed().first(where: { boundary(kept[$0].plain) }) {
            let head = kept[start].plain
            // Последняя граница — не текст (вызов инструмента, результат, строка владельца): текущего блока нет.
            guard PaneDigest.isBullet(head), !PaneDigest.isAction(head),
                  !ScreenMarks.isToolBullet(kept[start], toolColors: toolColors) else { return nil }
            lines.append(String(head.drop { $0 == " " }.dropFirst().drop { $0 == " " }))
            for l in kept[(start + 1)...] {
                if PaneDigest.isSpinner(l.plain) { break }
                lines.append(l.plain)
            }
        } else {
            // Границ нет: ответ длиннее экрана, его начало и вызовы до него прокручены.
            let body = kept.filter { !$0.isBlank }
            guard body.count >= 15 else { return nil }
            cut = true
            for l in kept {
                if PaneDigest.isSpinner(l.plain) { break }
                lines.append(l.plain)
            }
        }
        let text = unwrap(lines)
        return text.isEmpty ? nil : LiveReply(text: text, startCut: cut)
    }

    /// Строки панели → текст: отступ в два пробела снимается, строки одного абзаца склеиваются пробелом,
    /// пункты списков и строки таблиц остаются отдельными.
    static func unwrap(_ rows: [String]) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: "\n")) }
            current = []
        }
        var prevWasBlock = false
        for raw in rows {
            var line = raw
            if line.hasPrefix("  ") { line.removeFirst(2) }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); prevWasBlock = false; continue }
            let structural = t.range(of: #"^([-•*]|\d+[.)])\s"#, options: .regularExpression) != nil
                || t.hasPrefix("#") || t.hasPrefix("│") || t.hasPrefix("┌") || t.hasPrefix("├") || t.hasPrefix("└")
                || t.hasPrefix("|") || line.hasPrefix(" ")
            if structural || prevWasBlock || current.isEmpty {
                current.append(t)
            } else {
                current[current.count - 1] += " " + t
            }
            prevWasBlock = t.hasPrefix("│") || t.hasPrefix("┌") || t.hasPrefix("├") || t.hasPrefix("└")
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    /// Экран показывает конец ответа, когда тот длиннее панели: новый хвост пристыковывается к уже накопленному
    /// тексту по своему началу, и черновик остаётся целым, пока он растёт. Нет общего места — берётся один хвост.
    public static func merged(previous: LiveReply?, new: LiveReply?) -> LiveReply? {
        guard let new else { return nil }
        guard new.startCut, let prev = previous else { return new }
        let head = String(new.text.prefix(40))
        guard let r = prev.text.range(of: head, options: .backwards) else { return new }
        return LiveReply(text: String(prev.text[..<r.lowerBound]) + new.text, startCut: prev.startCut)
    }

    static func normalize(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// Черновик для ленты: менеджер в ходе, и этот текст ещё не записан в транскрипт. Блок, который уже лежит
    /// в последних ответах ленты (экран ещё показывает его), черновиком не считается.
    public static func draft(lines: [StyledLine], chat: [ChatEntry], busy: Bool) -> LiveReply? {
        draft(busy ? extract(lines) : nil, chat: chat, busy: busy)
    }

    /// То же по уже разобранному ответу экрана (`PaneOutput.reply`).
    public static func draft(_ reply: LiveReply?, chat: [ChatEntry], busy: Bool) -> LiveReply? {
        guard busy, let r = reply else { return nil }
        return isWritten(r, in: chat) ? nil : r
    }

    /// Текст черновика уже лежит среди последних ответов ленты.
    public static func isWritten(_ r: LiveReply, in chat: [ChatEntry]) -> Bool { isWritten(r, keys: writtenKeys(chat)) }

    /// Сколько черновик держится в ленте после того, как экран его больше не показывает, а лента ещё не получила блок.
    public static let holdAfterScreen: TimeInterval = 6

    /// Черновик, который лента показывает в этом кадре. С экрана текст уходит раньше, чем блок доходит до ленты: вызов
    /// инструмента или конец хода стирают его с экрана, а читатель транскрипта получает блок позже. Если убрать черновик
    /// сразу, лента на этот промежуток укорачивается, а затем снова растёт — текст прыгает вниз и вверх, у читающего
    /// остаётся провал. Поэтому ушедший с экрана черновик (`held`) стоит, пока его блок не появится в той же ленте, что
    /// на экране (`feed`): замена происходит в одном кадре. Сверка с той же лентой, а не с хвостом чата, исключает и кадр,
    /// где блок и черновик видны вместе.
    public static func shown(screen: LiveReply?, held: LiveReply?, feed: [ChatEntry]) -> LiveReply? {
        guard let d = screen ?? held else { return nil }
        return isWritten(d, in: feed) ? nil : d
    }
}
