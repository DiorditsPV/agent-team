import AppKit

/// Поле ввода, принимающее картинки: ⌘V с картинкой в буфере (снимок экрана, файл из Finder) и перетаскивание файлов.
/// Текст в буфере по-прежнему вставляется как текст.
public final class ComposerTextView: NSTextView {
    public var onImages: ([URL]) -> Void = { _ in }

    /// Картинки буфера: файлы картинок, иначе — данные картинки, если рядом нет текста.
    public static func images(from pb: NSPasteboard, preferData: Bool) -> [URL] {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let fromFiles = files.filter(Attachments.isImageFile).compactMap { Attachments.add(file: $0) }
        if !fromFiles.isEmpty { return fromFiles }
        guard files.isEmpty, preferData, pb.string(forType: .string) == nil,
              let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
              let url = Attachments.add(imageData: data) else { return [] }
        return [url]
    }

    public static func carriesImage(_ pb: NSPasteboard) -> Bool {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if files.contains(where: Attachments.isImageFile) { return true }
        return files.isEmpty && (pb.canReadObject(forClasses: [NSImage.self], options: nil))
    }

    /// Текст из привязки ставится в поле, только пока не идёт незавершённый набор (мёртвая клавиша Option+e,
    /// метод ввода с композицией): его символ ещё не в привязке, и замена строки стирала бы его вместе с курсором.
    /// `false` — поле занято набором и текст не тронут; привязка догонит поле, когда набор завершится.
    @discardableResult
    public func syncText(_ text: String) -> Bool {
        guard !hasMarkedText() else { return false }
        if string != text { string = text }
        return true
    }

    /// Буфер для вставки; в тестах подменяется, чтобы не трогать буфер владельца.
    public var pasteboard: NSPasteboard = .general

    public override func paste(_ sender: Any?) {
        let urls = Self.images(from: pasteboard, preferData: true)
        if urls.isEmpty { super.paste(sender) } else { onImages(urls) }
    }

    /// Пункт «Вставить» (⌘V) NSTextView включает только если в буфере есть читаемый им тип. У снимка экрана
    /// (⌘⌃⇧4) в буфере одна картинка, и без этого ⌘V молча не срабатывал: пункт меню был недоступен.
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) {
            if Self.carriesImage(pasteboard) { return true }
            // Текст NSTextView проверяет по общему буферу. Подменённый буфер (тесты) проверяется сам: иначе проверка
            // зависела бы от того, что лежит в буфере владельца.
            if pasteboard !== NSPasteboard.general { return isEditable && pasteboard.canReadObject(forClasses: [NSString.self], options: nil) }
        }
        return super.validateUserInterfaceItem(item)
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.carriesImage(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.carriesImage(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.images(from: sender.draggingPasteboard, preferData: true)
        if urls.isEmpty { return super.performDragOperation(sender) }
        onImages(urls)
        return true
    }
}
