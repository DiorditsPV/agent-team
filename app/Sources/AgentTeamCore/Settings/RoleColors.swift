import Foundation

/// Цвета ролей, различимые с первого взгляда. Токены темы (cyan, violet, periwinkle, rose, amber) несут и другие
/// обязанности — ссылки, статус «ждёт» — и не меняются; меняется только их копия для ролей: цвет, слишком близкий
/// к другому цвету ролей или к акценту менеджера, поворачивается по оттенку при той же светлоте (контраст к фону тот же).
public enum RoleColors {
    /// Наименьшее ΔE00 между любыми двумя цветами ролей и акцентом менеджера. До разведения худшая пара была 10,3–10,4
    /// (cyan и periwinkle в Nord, violet и periwinkle в оформлении приложения) — её владелец и видел как один цвет.
    /// 15 достижимо во всех темах окна, чата и области агента поворотом оттенка; порог выше требует поворотов почти
    /// на 180° и даёт мутные цвета, а выигрыш по худшей паре — меньше двух единиц.
    public static let minDelta = 15.0

    /// Цвета ролей в порядке токенов. Акцент не двигается; цвет ролей в конфликте двигается по очереди periwinkle,
    /// violet, cyan, rose, amber. Цвета без конфликта остаются как в теме.
    /// `ground` — фон темы: по нему сторона, в которую округление не снижает контраст.
    public static func palette(accent: UInt32, roles: [UInt32], ground: UInt32) -> [UInt32] {
        let key = [ground, accent] + roles
        if let hit = lock.withLock({ cache[key] }) { return hit }
        let out = spread(accent: accent, roles: roles, ground: ground, minDelta: minDelta)
        lock.withLock { cache[key] = out }
        return out
    }

    nonisolated(unsafe) private static var cache: [[UInt32]: [UInt32]] = [:]
    private static let lock = NSLock()

    /// Порядок, в котором цвета ролей можно двигать (индексы в `roles`: cyan, violet, periwinkle, rose, amber).
    /// Копия amber двигается последней: у неё тот же цвет, что у статуса «ждёт», но в Solarized Light она сливается
    /// с акцентом, а сдвинуть акцент нельзя.
    static let movable = [2, 1, 0, 3, 4]

    static func spread(accent: UInt32, roles: [UInt32], ground: UInt32, minDelta: Double) -> [UInt32] {
        let dark = Contrast.luminance(ground) < 0.18
        var c = roles
        func nearest(_ x: UInt32, except i: Int) -> Double {
            ([accent] + c.enumerated().filter { $0.offset != i }.map(\.element)).map { ColorDifference.deltaE(x, $0) }.min() ?? .infinity
        }
        for _ in 0..<3 {
            var changed = false
            for i in movable where i < c.count && nearest(c[i], except: i) < minDelta {
                // Цвет уходит туда, где до ближайшего соседа дальше всего: наименьший допустимый угол оставлял его
                // у самой границы порога, рядом с теми же соседями. При равенстве — меньший поворот.
                var best = (c[i], nearest(c[i], except: i))
                for d in stride(from: 5.0, through: 180, by: 5) {
                    for sign in [1.0, -1.0] {
                        let cand = ColorDifference.rotatedHue(roles[i], by: sign * d, darkGround: dark)
                        let n = nearest(cand, except: i)
                        if n > best.1 + 0.5 { best = (cand, n) }
                    }
                }
                if best.0 != c[i] { c[i] = best.0; changed = true }
            }
            if !changed { break }
        }
        return c
    }
}
