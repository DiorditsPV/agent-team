import Foundation
import Observation

/// Какую тему выбрал владелец для чата менеджера: «как окно» или любая тема из набора, независимо от окна и терминала.
public enum ChatThemeChoice {
    /// Чат оформлен темой окна.
    public static let window = "window"

    public static func isValid(_ id: String) -> Bool { id == window || WindowThemeChoice.isValid(id) }

    /// Токены чата: при «как окно» — токены окна, у которых основной текст, акцент и цвета ролей подтянуты до порога; иначе токены выбранной темы, у которых
    /// весь текст не ниже 4,5:1 на фоне, поверхности и подложке чата. Чат использует только свои токены,
    /// поэтому гарантия верна в любой паре «окно + чат».
    public static func theme(choice: String, window windowTheme: WindowTheme) -> WindowTheme {
        guard choice != window, isValid(choice) else { return readable(windowTheme, subdued: false) }
        return readable(WindowThemeChoice.theme(id: choice), subdued: true)
    }

    /// `subdued` — подтянуть и приглушённые ступени текста (dim, faint). У темы окна они остаются как есть:\n    /// это служебные подписи с мягким контрастом, но основной текст, акцент и цвета ролей читаются всегда.
    static func readable(_ t: WindowTheme, subdued: Bool) -> WindowTheme {
        var out = t
        let grounds = [t.bg, t.surface, t.well]
        func fix(_ c: UInt32) -> UInt32 {
            var v = c
            for _ in 0..<2 { for g in grounds { v = Contrast.ensure(v, on: g) } }
            return v
        }
        out.ink = fix(t.ink)
        out.muted = fix(t.muted)
        if subdued {
            out.dim = fix(t.dim)
            out.faint = fix(t.faint)
        }
        out.accent = fix(t.accent)
        out.amber = fix(t.amber)
        out.cyan = fix(t.cyan)
        out.violet = fix(t.violet)
        out.rose = fix(t.rose)
        out.periwinkle = fix(t.periwinkle)
        return out
    }
}

/// Текущая тема чата менеджера. Токены чата читают её отсюда, SwiftUI перерисовывает чат при смене.
@Observable
public final class ChatThemeStore: @unchecked Sendable {
    public static let shared = ChatThemeStore()
    public var theme = WindowTheme.appearance
    private init() {}
}

/// Оформление области агента (вкладки «Диалог» и «Вывод», панели «Команды»): тема терминала, а не окна.
public enum AgentAreaTheme {
    /// Токены области: «по умолчанию» — токены приложения, остальные — из палитры темы терминала; основной
    /// текст, акцент и цвета ролей не ниже 4,5:1 на фоне и поверхности, у выбранной темы — и приглушённые ступени.
    public static func theme(terminalThemeID id: String) -> WindowTheme {
        id == TermPalettes.defaultID
            ? ChatThemeChoice.readable(.appearance, subdued: false)
            : ChatThemeChoice.readable(.from(TermPalettes.palette(id: id)), subdued: true)
    }
}

/// Текущая тема области агента. Токены области читают её отсюда, SwiftUI перерисовывает экраны при смене.
@Observable
public final class AgentAreaStore: @unchecked Sendable {
    public static let shared = AgentAreaStore()
    public var theme = WindowTheme.appearance
    private init() {}
}
