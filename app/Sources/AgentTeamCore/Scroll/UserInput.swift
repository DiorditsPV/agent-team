import AppKit
import Foundation

/// Время последнего ввода владельца в любую ленту (колесо, перетаскивание, клавиши навигации): прочие механизмы (закрепление
/// строки при подгрузке сверху) не спорят с владельцем, пока он листает сам.
public enum UserInputClock {
    nonisolated(unsafe) public static var last = Date.distantPast
    /// Сколько лент сейчас в живой прокрутке AppKit (ползунок в руке, жест трекпада) и когда она последний раз двигала
    /// ленту. Ползунок AppKit ведёт своим циклом событий, и монитор ввода видит только нажатие.
    nonisolated(unsafe) public static var liveScrolls = 0
    nonisolated(unsafe) public static var liveMoved = Date.distantPast
    /// Сколько секунд назад владелец листал. Пока идёт живая прокрутка, — 0: владелец листает сейчас (живая прокрутка
    /// без сдвигов дольше `ThreadFollow.liveScrollStale` не считается).
    public static func sinceLast() -> TimeInterval {
        if liveScrolls > 0, Date().timeIntervalSince(liveMoved) < ThreadFollow.liveScrollStale { return 0 }
        return Date().timeIntervalSince(last)
    }
}

public extension Notification.Name {
    /// Стенд замера сообщает, что «владелец» только что прокрутил ленту (настоящего события колеса у стенда нет).
    static let benchUserInput = Notification.Name("AgentTeamBenchUserInput")
}

/// Один монитор ввода владельца на приложение: колесо и тачпад (с инерцией), нажатие и перетаскивание мыши, клавиши
/// навигации. Событие отмечается у тех лент, над которыми оно произошло (клавиши — у лент окна, если фокус не в поле
/// ввода). Монитор на каждую ленту при кешированных проектах прогонял каждое событие через десятки замыканий.
/// Лента, которая принимает ввод владельца (в приложении — проба прокрутки ленты).
@MainActor
public protocol UserInputTarget: AnyObject {
    var scroll: NSScrollView? { get }
    /// Ввод владельца над лентой. `scrolling` — ввод, который ленту листает (`UserInputMonitor.scrolls`); щелчок — нет.
    func markUserInput(scrolling: Bool)
}

@MainActor
public final class UserInputMonitor {
    public static let shared = UserInputMonitor()
    /// Листает ли ленту ввод этого вида: колесо и трекпад (с инерцией), перетаскивание (выделение с автопрокруткой),
    /// клавиши навигации. Щелчок — нет, и на полосе прокрутки тоже: ползунок покрыт живой прокруткой AppKit
    /// (`ScrollProbe`), а щелчок в ленте (выделить текст, раскрыть блок, вернуться в приложение) не должен откладывать
    /// следование за концом и постановку пачки в конец.
    public static func scrolls(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .scrollWheel, .leftMouseDragged, .keyDown: return true
        default: return false
        }
    }

    private final class Entry { weak var probe: UserInputTarget?; init(_ p: UserInputTarget) { probe = p } }
    private var entries: [Entry] = []
    private var monitor: Any?
    private var benchObserver: NSObjectProtocol?
    private static let navKeys: Set<UInt16> = [123, 124, 125, 126, 115, 116, 119, 121, 49]      // стрелки, Home, PgUp, End, PgDn, пробел

    public func register(_ p: UserInputTarget) {
        entries.removeAll { $0.probe == nil || $0.probe === p }
        entries.append(Entry(p))
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]) { event in
            MainActor.assumeIsolated { UserInputMonitor.shared.handle(event) }
            return event
        }
        // Замер (`AGENT_TEAM_READ_BENCH`): стенд прокручивает программно и сообщает об этом как о вводе владельца.
        benchObserver = NotificationCenter.default.addObserver(forName: .benchUserInput, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UserInputMonitor.shared.entries.forEach { $0.probe?.markUserInput(scrolling: true) } }
        }
    }

    public func unregister(_ p: UserInputTarget) {
        entries.removeAll { $0.probe == nil || $0.probe === p }
        guard entries.isEmpty else { return }
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let o = benchObserver { NotificationCenter.default.removeObserver(o); benchObserver = nil }
    }

    private func handle(_ event: NSEvent) {
        for e in entries {
            guard let p = e.probe, let scroll = p.scroll, event.window === scroll.window else { continue }
            switch event.type {
            case .keyDown:
                if Self.navKeys.contains(event.keyCode), !(scroll.window?.firstResponder is NSText) { p.markUserInput(scrolling: true) }
            default:
                if scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) { p.markUserInput(scrolling: Self.scrolls(event.type)) }
            }
        }
    }
}
