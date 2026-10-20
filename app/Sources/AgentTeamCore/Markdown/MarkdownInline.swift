import Foundation

/// Инлайн-разметка строки блока: `код`, **жирный**, *курсив*, ~~зачёркнутый~~, ссылки.
/// Разбирает парсер Foundation; голые адреса `https://…` и `www.…` он не связывает — их помечает детектор ссылок.
public enum MDInline {
    public static func attributed(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        autolink(&a)
        return a
    }

    nonisolated(unsafe) private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func autolink(_ a: inout AttributedString) {
        guard let detector else { return }
        let plain = String(a.characters)
        guard plain.contains("://") || plain.contains("www.") else { return }
        let ns = plain as NSString
        for m in detector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
            let found = ns.substring(with: m.range)
            // Только явные адреса: «AgentTeam.app» или «README.md» — имена файлов, а не ссылки.
            guard found.contains("://") || found.lowercased().hasPrefix("www."), let url = m.url,
                  let range = Range(m.range, in: a) else { continue }
            let busy = a[range].runs.contains { $0.link != nil || ($0.inlinePresentationIntent?.contains(.code) ?? false) }
            if !busy { a[range].link = url }
        }
    }
}
