import AppKit
import XCTest
@testable import AgentTeamCore

/// Путь вставки картинки через NSPasteboard: ⌘V включён и срабатывает для буфера с одной картинкой
/// (снимок экрана), для файла из Finder и не мешает обычному тексту. Буфер владельца не трогается.
@MainActor
final class ComposerPasteTests: XCTestCase {
    private var paths: [URL] = []

    override func tearDown() async throws {
        for u in paths { try? FileManager.default.removeItem(at: u) }
        paths = []
    }

    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("agtest-\(UUID().uuidString.prefix(8))"))
    }

    private func pngData() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    private func view(_ pb: NSPasteboard) -> (ComposerTextView, Box) {
        let tv = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        tv.isRichText = false
        tv.pasteboard = pb
        let box = Box()
        tv.onImages = { box.urls += $0 }
        return (tv, box)
    }

    final class Box { var urls: [URL] = [] }

    private let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

    /// Снимок экрана: в буфере только public.png. Обычный NSTextView считает пункт «Вставить» недоступным.
    func testScreenshotOnlyPasteboardEnablesAndRunsPaste() throws {
        let pb = pasteboard()
        pb.clearContents()
        pb.setData(try pngData(), forType: .png)
        let (tv, box) = view(pb)
        XCTAssertTrue(tv.validateUserInterfaceItem(pasteItem), "⌘V доступен для буфера с картинкой")
        tv.paste(nil)
        let url = try XCTUnwrap(box.urls.first)
        paths.append(url)
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTiffPasteboardWorksToo() throws {
        let pb = pasteboard()
        pb.clearContents()
        let tiff = try XCTUnwrap(NSImage(data: try pngData())?.tiffRepresentation)
        pb.setData(tiff, forType: .tiff)
        let (tv, box) = view(pb)
        XCTAssertTrue(tv.validateUserInterfaceItem(pasteItem))
        tv.paste(nil)
        paths += box.urls
        XCTAssertEqual(box.urls.count, 1)
    }

    /// Файл, скопированный в Finder: в буфере URL файла.
    func testFinderFileCopyPastesAsAttachment() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-\(UUID().uuidString.prefix(8)).png")
        try pngData().write(to: file)
        paths.append(file)
        let pb = pasteboard()
        pb.clearContents()
        pb.writeObjects([file as NSURL])
        let (tv, box) = view(pb)
        XCTAssertTrue(tv.validateUserInterfaceItem(pasteItem))
        tv.paste(nil)
        paths += box.urls
        let url = try XCTUnwrap(box.urls.first)
        XCTAssertNotEqual(url, file, "вложение — копия в кеше приложения")
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: file))
    }

    /// Текст в буфере вставляется как текст, вложений нет.
    func testTextPasteboardStaysText() throws {
        let pb = pasteboard()
        pb.clearContents()
        pb.setString("обычный текст", forType: .string)
        let (tv, box) = view(pb)
        XCTAssertTrue(tv.validateUserInterfaceItem(pasteItem))
        XCTAssertTrue(ComposerTextView.images(from: pb, preferData: true).isEmpty)
        tv.paste(nil)
        XCTAssertTrue(box.urls.isEmpty)
    }

    /// Перетаскивание файла и превью скриншота читают тот же буфер (`images(from:)`), но с другим источником.
    func testDragPasteboardsCarryImages() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-\(UUID().uuidString.prefix(8)).png")
        try pngData().write(to: file)
        paths.append(file)
        let drag = pasteboard()
        drag.clearContents()
        drag.writeObjects([file as NSURL])
        XCTAssertTrue(ComposerTextView.carriesImage(drag))
        let got = ComposerTextView.images(from: drag, preferData: true)
        paths += got
        XCTAssertEqual(got.count, 1)

        let preview = pasteboard()
        preview.clearContents()
        preview.setData(try pngData(), forType: .png)
        XCTAssertTrue(ComposerTextView.carriesImage(preview))

        let notImage = pasteboard()
        notImage.clearContents()
        notImage.setString("слово", forType: .string)
        XCTAssertFalse(ComposerTextView.carriesImage(notImage))
        let tv = ComposerTextView(frame: .zero)
        XCTAssertTrue(tv.acceptableDragTypes.contains(.fileURL) && tv.acceptableDragTypes.contains(.png) && tv.acceptableDragTypes.contains(.tiff))
    }
}
