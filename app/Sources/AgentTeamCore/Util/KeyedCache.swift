import Foundation

/// Кеш одного значения по ключу: `value(key:build:)` пересчитывает значение, только когда ключ сменился.
/// Для тяжёлых производных от записей (группировка ленты), которые не должны пересчитываться при каждой перерисовке вида.
public final class KeyedCache<Value> {
    private var key: String?
    private var cached: Value?
    /// Сколько раз значение пересчитывалось.
    public private(set) var rebuilds = 0

    public init() {}

    public func value(key: String, build: () -> Value) -> Value {
        if key == self.key, let cached { return cached }
        let v = build()
        self.key = key
        cached = v
        rebuilds += 1
        return v
    }
}
