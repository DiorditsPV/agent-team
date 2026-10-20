import AgentTeamCore
import AppKit
import SwiftUI

/// Поле ввода сообщения менеджеру: Enter отправляет, Shift+Enter переносит строку. Растёт по тексту до `maxLines`
/// строк, дальше прокручивается. Многострочный текст остаётся в черновике с переносами.
/// Клавиши, которые поле отдаёт хозяину раньше своей обработки: список подсказок и история ввода.
enum ComposerKey { case up, down, tab, enter, escape }

struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont
    var lineHeight: CGFloat
    var maxLines = 8
    var onSubmit: () -> Void
    /// Esc в пустом поле: true — нажатие обработано (ушло в панель), иначе оно идёт дальше по цепочке.
    var onEscape: () -> Bool = { false }
    /// Картинки из буфера обмена или перетаскивания, уже сохранённые файлами вложений.
    var onImages: ([URL]) -> Void = { _ in }
    /// Текст и положение курсора после правки или сдвига курсора владельцем (не после программной замены текста).
    var onEdit: (String, Int) -> Void = { _, _ in }
    /// Клавиша до обработки полем: `true` — хозяин её съел. Esc в пустом поле хозяин не берёт.
    var onKey: (ComposerKey) -> Bool = { _ in false }
    /// Куда поставить курсор после программной замены текста (подстановка из списка, запись истории).
    @Binding var cursorRequest: Int?

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        /// Идёт программная замена текста: подсказки на неё не реагируют.
        var applying = false
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            parent.recalculate(tv)
            if !applying { parent.onEdit(tv.string, tv.selectedRange().location) }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !applying, let tv = notification.object as? NSTextView else { return }
            parent.onEdit(tv.string, tv.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertTab(_:)): return parent.onKey(.tab)
            case #selector(NSResponder.cancelOperation(_:)):
                // Список подсказок берёт Esc первым; иначе в пустом поле Esc прерывает ход менеджера.
                if parent.onKey(.escape) { return true }
                return textView.string.isEmpty && parent.onEscape()
            case #selector(NSResponder.insertNewline(_:)):
                if flags.contains(.shift) || flags.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)       // перенос строки
                } else if !parent.onKey(.enter) {
                    parent.onSubmit()
                }
                return true
            default: return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerTextView()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        tv.onImages = { urls in context.coordinator.parent.onImages(urls) }
        tv.delegate = context.coordinator
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.insertionPointColor = NSColor(C.accent)
        apply(tv)
        tv.string = text
        DispatchQueue.main.async { recalculate(tv) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! ComposerTextView
        // Идёт незавершённый набор: ни текст, ни шрифт, ни курсор не трогаются, иначе набор сбросится. Запрос курсора
        // ждёт следующего обновления после конца набора.
        guard !tv.hasMarkedText() else { return }
        apply(tv)
        if tv.string != text {            // очистка после отправки, черновик другого проекта, подстановка из списка
            context.coordinator.applying = true
            tv.syncText(text)
            context.coordinator.applying = false
        }
        if let c = cursorRequest {
            context.coordinator.applying = true
            tv.setSelectedRange(NSRange(location: min(c, (tv.string as NSString).length), length: 0))
            context.coordinator.applying = false
            DispatchQueue.main.async { cursorRequest = nil }
        }
        DispatchQueue.main.async { recalculate(tv) }
    }

    private func apply(_ tv: NSTextView) {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineHeight
        para.maximumLineHeight = lineHeight
        tv.font = font
        tv.textColor = NSColor(C.ink)
        // Выделение — из токенов чата: системный цвет мог сливаться с подложкой поля в светлых и тёмных темах чата.
        let sel = ChatThemeStore.shared.theme.selectionStyle
        tv.selectedTextAttributes = [.backgroundColor: NSColor(Color(hex: sel.background)), .foregroundColor: NSColor(Color(hex: sel.text))]
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: font, .foregroundColor: NSColor(C.ink), .paragraphStyle: para]
    }

    /// Высота по числу строк: от одной до maxLines.
    fileprivate func recalculate(_ tv: NSTextView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let lines = max(1, min(CGFloat(maxLines), (used / lineHeight).rounded(.up)))
        let h = lines * lineHeight
        if abs(height - h) > 0.5 { DispatchQueue.main.async { height = h } }
    }
}
