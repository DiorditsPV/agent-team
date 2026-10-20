import Foundation

/// Короткое имя модели для строки состояния: «Opus 5.5», «Sonnet 5.5», «Haiku 4.5».
public enum ModelName {
    static let families = ["opus", "sonnet", "haiku", "fable"]

    /// Имя по id модели из транскрипта (`claude-opus-5-5`, `claude-haiku-4-5-20251001`, `claude-opus-5-5[1m]`)
    /// или по полю model роли (`opus`). Неизвестный id возвращается как есть, без префикса `claude-`.
    /// `nil` — модели нет: пусто, `inherit` и `default` роли, служебная `<synthetic>`.
    public static func short(_ id: String) -> String? {
        let raw = id.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || ["inherit", "default", "<synthetic>"].contains(raw.lowercased()) { return nil }
        let bare = raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
        var s = bare.lowercased()
        // Окно контекста (`[1m]`) и дата выпуска в имя не входят.
        if let r = s.range(of: #"\[[^\]]*\]$"#, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        let parts = s.split(separator: "-").map(String.init)
        guard let i = parts.firstIndex(where: families.contains) else { return bare }
        // Новые id — семейство, потом версия (`opus-5-5`); старые — версия, потом семейство (`3-5-sonnet`).
        let version = i == 0 ? Array(parts.dropFirst()) : Array(parts[..<i])
        guard (i == 0 || i == parts.count - 1), version.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return bare }
        let family = parts[i].prefix(1).uppercased() + parts[i].dropFirst()
        return version.isEmpty ? family : family + " " + version.joined(separator: ".")
    }

    /// Модель, выбранная командой `/model`: вывод «Set model to `Sonnet 5.5` and saved as your default…» в транскрипте.
    /// Возвращает показанное Claude Code имя без пояснений в скобках («Opus 5.5 (1M context) (default)» → «Opus 5.5»).
    /// «Kept model as …» модель не меняет — `nil`.
    public static func fromModelCommand(_ text: String) -> String? {
        guard let r = text.range(of: "Set model to ") else { return nil }
        var s = String(text[r.upperBound...])
        s = s.replacingOccurrences(of: #"\x{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        for stop in [" and saved", "</local-command-stdout>", "\n"] {
            if let e = s.range(of: stop) { s = String(s[..<e.lowerBound]) }
        }
        s = s.replacingOccurrences(of: "`", with: "")
        // Пояснений в скобках бывает несколько: «Opus 5.5 (1M context) (default)».
        while let p = s.range(of: #"\s*\([^)]*\)\s*$"#, options: .regularExpression) { s.removeSubrange(p) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        // Вместо имени может прийти id (`claude-sonnet-5-5`) — он приводится к тому же виду.
        return s.contains(" ") ? s : (short(s) ?? s)
    }
}
