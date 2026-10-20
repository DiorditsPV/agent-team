import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import AgentTeamCore

/// Картинки в сообщениях: разбор блоков `type:image` транскрипта и файлы вложений для вставки пути.
final class ImageAttachmentTests: XCTestCase {
    private var dirs: [URL] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-img-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d
    }

    /// Однотонная картинка нужного формата.
    private func imageData(type: UTType, width: Int = 40, height: Int = 20) throws -> Data {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func line(_ content: String, extra: String = "") -> Substring {
        Substring(#"{"type":"user","uuid":"u1","timestamp":"2026-10-17T06:12:34.161Z","message":{"role":"user","content":\#(content)}\#(extra)}"#)
    }

    func testOwnerMessageWithImagesKeepsThemAndDropsMarker() throws {
        let png = try imageData(type: .png).base64EncodedString()
        var p = TranscriptParser()
        p.feed(lines: [line(#"[{"type":"text","text":"[Image #1]\nЧто тут не так?"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}]"#)])
        let e = try XCTUnwrap(p.entries.last)
        XCTAssertEqual(e.kind, .owner("Что тут не так?"))
        XCTAssertEqual(e.images.count, 1)
        XCTAssertEqual(e.images.first?.mediaType, "image/png")
        XCTAssertEqual(e.images.first?.base64, png)
        XCTAssertNotNil(Attachments.thumbnail(data: try XCTUnwrap(e.images.first?.data), maxPixel: 16))
    }

    /// Сообщение из одних картинок остаётся в ленте, а не отбрасывается как пустое.
    func testImageOnlyMessageIsKept() throws {
        let png = try imageData(type: .png).base64EncodedString()
        var p = TranscriptParser()
        p.feed(lines: [line(#"[{"type":"text","text":"[Image #1] [Image #2]"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"\#(png)"}}]"#)])
        let e = try XCTUnwrap(p.entries.last)
        XCTAssertEqual(e.kind, .owner(""))
        XCTAssertEqual(e.images.map(\.mediaType), ["image/png", "image/jpeg"])
        XCTAssertEqual(Set(e.images.map(\.id)).count, 2)
    }

    /// Картинки результатов инструментов — не сообщение владельца.
    func testToolResultImagesAreIgnored() {
        var p = TranscriptParser()
        p.feed(lines: [line(#"[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}]"#)])
        XCTAssertTrue(p.entries.isEmpty)
    }

    func testTextOnlyMessageHasNoImages() {
        var p = TranscriptParser()
        p.feed(lines: [line(#""просто текст [Image #1] в середине""#)])
        XCTAssertEqual(p.entries.last?.kind, .owner("просто текст [Image #1] в середине"))
        XCTAssertEqual(p.entries.last?.images.count, 0)
    }

    func testBufferImageBecomesPNGFileWithoutSpaces() throws {
        let dir = tempDir().appendingPathComponent("cache dir")
        let tiff = try imageData(type: .tiff)
        let url = try XCTUnwrap(Attachments.add(imageData: tiff, in: dir))
        XCTAssertEqual(url.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(url.lastPathComponent.contains(" "))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.png.identifier)
    }

    func testFileIsCopiedUnderNeutralNameAndOtherFormatsBecomePNG() throws {
        let src = tempDir()
        let dir = tempDir()
        let jpg = src.appendingPathComponent("Снимок экрана 1.jpg")
        try imageData(type: .jpeg).write(to: jpg)
        let copy = try XCTUnwrap(Attachments.add(file: jpg, in: dir))
        XCTAssertEqual(copy.pathExtension, "jpg")
        XCTAssertFalse(copy.path.contains(" "))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: jpg))

        let bmp = src.appendingPathComponent("a.bmp")
        try imageData(type: .bmp).write(to: bmp)
        XCTAssertEqual(Attachments.add(file: bmp, in: dir)?.pathExtension, "png")

        let notImage = src.appendingPathComponent("a.txt")
        try "не картинка".write(to: notImage, atomically: true, encoding: .utf8)
        XCTAssertNil(Attachments.add(file: notImage, in: dir))
        XCTAssertFalse(Attachments.isImageFile(notImage))
        XCTAssertTrue(Attachments.isImageFile(jpg))
    }

    func testThumbnailIsDownscaled() throws {
        let src = tempDir().appendingPathComponent("big.png")
        try imageData(type: .png, width: 800, height: 400).write(to: src)
        let t = try XCTUnwrap(Attachments.thumbnail(url: src, maxPixel: 100))
        XCTAssertEqual(max(t.width, t.height), 100)
    }

    func testPurgeRemovesOnlyOldFiles() throws {
        let dir = tempDir()
        let old = dir.appendingPathComponent("old.png"), fresh = dir.appendingPathComponent("fresh.png")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        Attachments.purge(in: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }
}
