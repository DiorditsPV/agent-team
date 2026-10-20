import AgentTeamCore
import SwiftUI

/// Прокрутка к строке через `ScrollViewProxy`; к концу — с короткой анимацией.
struct ProxyRows: FeedRows {
    let proxy: ScrollViewProxy
    func scrollTo(_ id: String, anchorY: CGFloat, animated: Bool) {
        let anchor = UnitPoint(x: 0, y: anchorY)
        if animated { withAnimation(.easeOut(duration: FeedScroller.animationTime)) { proxy.scrollTo(id, anchor: anchor) } } else { proxy.scrollTo(id, anchor: anchor) }
    }
}

/// Вызовы из видов — с `ScrollViewProxy`.
extension FeedScroller {
    @discardableResult
    func restore(proxy: ScrollViewProxy, ids: [String]) -> Bool { restore(rows: ProxyRows(proxy: proxy), ids: ids) }
    func grew(proxy: ScrollViewProxy, bottomID: String, model: EarlierPages?, firstID: String?) {
        grew(rows: ProxyRows(proxy: proxy), bottomID: bottomID, model: model, firstID: firstID)
    }
    func arrived(proxy: ScrollViewProxy, bottomID: String, model: EarlierPages? = nil) {
        arrived(rows: ProxyRows(proxy: proxy), bottomID: bottomID, model: model)
    }
    func jumpToEnd(proxy: ScrollViewProxy, bottomID: String) { jumpToEnd(rows: ProxyRows(proxy: proxy), bottomID: bottomID) }
    func appeared(proxy: ScrollViewProxy, ids: [String], bottomID: String, toEndOtherwise: Bool) {
        appeared(rows: ProxyRows(proxy: proxy), ids: ids, bottomID: bottomID, toEndOtherwise: toEndOtherwise)
    }
    func pendingChanged(from old: Int, to new: Int, proxy: ScrollViewProxy, bottomID: String) {
        pendingChanged(from: old, to: new, rows: ProxyRows(proxy: proxy), bottomID: bottomID)
    }
    func ownMessageSent(proxy: ScrollViewProxy, bottomID: String) { ownMessageSent(rows: ProxyRows(proxy: proxy), bottomID: bottomID) }
    func pagePrepended(proxy: ScrollViewProxy, bottomID: String, model: EarlierPages, ids: [String]) {
        pagePrepended(rows: ProxyRows(proxy: proxy), bottomID: bottomID, model: model, ids: ids)
    }
}

/// Строка ленты сообщает прокрутке своё место в окне и уход из ленивой ленты. У каждого экземпляра строки свой
/// номер: строка старого вида с тем же id, уходя, не стирает место строки нового.
struct FeedRowPosition: ViewModifier {
    let id: String
    let scroller: FeedScroller
    let space: String
    var onGone: () -> Void = {}
    @State private var instance = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(space)).minY } action: { y in
                scroller.rowMoved(id, y: y, view: instance)
            }
            .onDisappear { scroller.rowGone(id, view: instance); onGone() }
    }
}

