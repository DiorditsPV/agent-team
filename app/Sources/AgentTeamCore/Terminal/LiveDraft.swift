import Foundation
import Observation

/// Черновик ответа менеджера, который показывает лента («пишет…»): экран панели, накопленное за верхний край
/// и ушедшее с экрана до прихода блока в ленту (`LiveReply.shown`).
///
/// Считается здесь, а не в теле чата: экран меняется на каждом захвате панели, а ход идёт минутами. Тело чата
/// черновик не читает и на захват не пересчитывается — его читает только хвост ленты. Сверка с лентой идёт по
/// заранее нормализованным последним ответам, а не заново на каждый захват.
@MainActor
@Observable
public final class LiveDraft {
    /// Накопленное: экран плюс прокрученное за верхний край; ушедшее с экрана держится, пока блок не придёт в ленту,
    /// но не дольше `LiveReply.holdAfterScreen`. Сверки с лентой здесь нет — её делает `shown(feed:key:)` в кадре ленты.
    public private(set) var held: LiveReply? {
        didSet { if (held != nil) != active { active = held != nil } }
    }
    /// Черновик есть (текст его может меняться): меняется только при появлении и уходе, поэтому его можно читать в теле
    /// чата, не подписываясь на каждый захват панели.
    public private(set) var active = false

    /// Ответ с экрана панели (`PaneOutput.reply`), пока менеджер в ходе; nil — экрана нет или он без ответа.
    @ObservationIgnored public var screen: LiveReply? {
        didSet { if screen != oldValue { screenChanged() } }
    }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var written: [String] = []
    @ObservationIgnored private var feedKey: String?

    /// Текст черновика вырос (лента идёт за ним).
    @ObservationIgnored public var onGrew: () -> Void = {}
    /// Отложить на `delay` секунд (тесты подменяют).
    @ObservationIgnored public var after: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
    }

    public init() {}

    /// Черновик в кадре ленты из `entries`: блок, уже лежащий в этой ленте, черновиком не показывается, и замена идёт
    /// в одном кадре — без кадра, где видны оба, и без кадра, где нет ни одного. `key` — ревизия ленты: последние ответы
    /// для сверки нормализуются один раз на ревизию, а не на каждый захват панели.
    public func shown(feed entries: [ChatEntry], key: String) -> LiveReply? {
        guard let held else { return nil }
        if key != feedKey {
            feedKey = key
            written = LiveReply.writtenKeys(entries)
        }
        return LiveReply.isWritten(held, keys: written) ? nil : held
    }

    private func screenChanged() {
        generation += 1
        if let screen {
            let before = held?.text.count
            held = LiveReply.merged(previous: held, new: screen)
            if held?.text.count != before { onGrew() }
        } else if held != nil {
            // Экран черновик больше не показывает: он стоит в ленте, пока туда не придёт его блок, но не дольше срока —
            // прерванный ход блока не запишет.
            let g = generation
            after(LiveReply.holdAfterScreen) { [weak self] in
                guard let self, self.generation == g else { return }
                self.held = nil
            }
        }
    }
}

extension LiveReply {
    /// Последние ответы ленты в виде для сверки (`isWritten`): нормализованы и без разметки, считаются один раз
    /// на ревизию ленты.
    public static func writtenKeys(_ chat: [ChatEntry]) -> [String] {
        chat.suffix(8).compactMap { e -> String? in
            if case let .reply(t) = e.kind { return flat(normalize(t)) }
            return nil
        }
    }

    /// Текст черновика уже лежит среди ответов `keys` (`writtenKeys`).
    public static func isWritten(_ r: LiveReply, keys: [String]) -> Bool {
        let key = String(normalize(r.text).prefix(60))
        guard key.count >= 8 else { return false }
        let k = String(flat(key).prefix(40))
        return keys.contains { $0.contains(k) }
    }

    /// Разметка в транскрипте (жирный, код) отличается от экрана: сравниваем по буквам и цифрам.
    static func flat(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
