import CoreGraphics

/// Куда ставить окна проверочного запуска (стенд, снимок): не на основной экран владельца, где строка меню и его работа.
/// Окно остаётся видимым целиком, на заднем плане его не прячут: перекрытое окно ленты ведёт себя иначе, и замеры были бы не те.
public enum CheckPlacement {
    public struct Screen: Equatable, Sendable {
        public var frame: CGRect
        public var visibleFrame: CGRect
        public init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// Экран и рамка окна. `screens[0]` — основной (со строкой меню). Нет второго экрана — `nil`: окно остаётся как есть.
    /// Окно уже на неосновном экране остаётся на нём (повторный вывод не перебрасывает его на другой); иначе — на первом
    /// неосновном. Рамка не меняется, если окно целиком в видимой области экрана; иначе размер уменьшается до неё и
    /// окно сдвигается внутрь.
    public static func place(window: CGRect, screens: [Screen]) -> (screen: Int, frame: CGRect)? {
        guard screens.count > 1 else { return nil }
        let others = Array(screens.indices.dropFirst())
        let center = CGPoint(x: window.midX, y: window.midY)
        let index = others.first { screens[$0].frame.contains(center) } ?? others[0]
        let visible = screens[index].visibleFrame
        var f = window
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.origin.x, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.origin.y, visible.minY), visible.maxY - f.height)
        // Окно с основного экрана (центр вне неосновных): его позиция там ничего не значит — по центру нового экрана.
        if !others.contains(where: { screens[$0].frame.contains(center) }) {
            f.origin = CGPoint(x: visible.midX - f.width / 2, y: visible.midY - f.height / 2)
        }
        return (index, f)
    }
}
