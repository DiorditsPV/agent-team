import Foundation

/// Сдвиг содержимого окна между двумя кадрами — по самим пикселям, а не по местам строк, которые сообщает ленивая
/// лента (их записи бывают устаревшими). Стенды сравнивают кадр окна ленты до подгрузки и после неё.
///
/// Кадр — подпись строк пикселей: на каждую строку пикселей `width` значений яркости. Сдвиг `d` значит, что
/// содержимое уехало вниз на `d` строк пикселей: строка `i` нового кадра — строка `i - d` старого.
public struct ContentShift: Equatable, Sendable {
    /// Сдвиг в строках пикселей; nil — совпадения нет (содержимое ушло дальше окна или сменилось).
    public var pixels: Int?
    /// Средняя разница яркости на лучшем сдвиге (0…255).
    public var error: Double

    /// Строки старого кадра, по которым ищется совпадение, — средняя часть окна (края закрывают затемнение у верха и
    /// кнопки); строки без рисунка (фон между блоками) не годятся — на них совпадает любой сдвиг.
    public static func measure(before: [[Float]], after: [[Float]], margin: Double = 0.15, maxError: Double = 3) -> ContentShift {
        let n = min(before.count, after.count)
        guard n > 8, let width = before.first?.count, width > 0 else { return ContentShift(pixels: nil, error: .infinity) }
        let lo = Int(Double(n) * margin), hi = Int(Double(n) * (1 - margin))
        let sample = (lo..<hi).filter { i in
            let row = before[i]
            let mean = row.reduce(0, +) / Float(width)
            return row.reduce(0) { $0 + abs($1 - mean) } / Float(width) > 2
        }
        guard sample.count >= 8 else { return ContentShift(pixels: nil, error: .infinity) }

        func cost(_ d: Int, stride: Int) -> Double? {
            var sum: Float = 0
            var count = 0
            var k = 0
            while k < sample.count {
                let i = sample[k] + d
                if i >= 0, i < n {
                    let a = before[sample[k]], b = after[i]
                    var s: Float = 0
                    for c in 0..<width { s += abs(a[c] - b[c]) }
                    sum += s
                    count += width
                }
                k += stride
            }
            // Перекрытие меньше трети пробы — совпадение не засчитывается.
            guard count * 3 >= (sample.count / stride) * width else { return nil }
            return Double(sum) / Double(count)
        }

        var best: (d: Int, e: Double)?
        for d in -n...n {
            guard let e = cost(d, stride: 4) else { continue }
            if best == nil || e < best!.e { best = (d, e) }
        }
        guard let coarse = best else { return ContentShift(pixels: nil, error: .infinity) }
        best = nil
        for d in (coarse.d - 6)...(coarse.d + 6) {
            guard let e = cost(d, stride: 1) else { continue }
            if best == nil || e < best!.e { best = (d, e) }
        }
        guard let fine = best else { return ContentShift(pixels: nil, error: .infinity) }
        return ContentShift(pixels: fine.e <= maxError ? fine.d : nil, error: fine.e)
    }
}
