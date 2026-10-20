import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Картинки для сообщения менеджеру. Claude Code превращает вставленный путь к файлу картинки во вложение
/// («[Image #N]»), поэтому приложение кладёт картинку файлом в кеш приложения (вне репозиториев) и вставляет путь.
public enum Attachments {
    /// Форматы, которые Claude Code принимает файлом как есть; остальные переводятся в PNG.
    static let passthrough: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    public static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.agent-team.app").appendingPathComponent("attachments")
    }

    private static func newURL(ext: String, in dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString.lowercased() + "." + ext)
    }

    /// Файл картинки (перетаскивание, копирование в Finder). Путь без пробелов: его вставляют в строку ввода.
    public static func add(file: URL, in dir: URL = directory) -> URL? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let ext = file.pathExtension.lowercased()
        if passthrough.contains(ext) {
            let dest = newURL(ext: ext, in: dir)
            do { try FileManager.default.copyItem(at: file, to: dest); return dest } catch { return nil }
        }
        return writePNG(source: src, in: dir)
    }

    /// Картинка из буфера обмена (снимок экрана): TIFF или PNG.
    public static func add(imageData: Data, in dir: URL = directory) -> URL? {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        return writePNG(source: src, in: dir)
    }

    private static func writePNG(source: CGImageSource, in dir: URL) -> URL? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let dest = newURL(ext: "png", in: dir)
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, nil)
        return CGImageDestinationFinalize(out) ? dest : nil
    }

    /// Уменьшенная копия для миниатюры: самая длинная сторона не больше `maxPixel`.
    public static func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(source: src, maxPixel: maxPixel)
    }

    public static func thumbnail(data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source: src, maxPixel: maxPixel)
    }

    private static func thumbnail(source: CGImageSource, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// Файлы старше суток удаляются при запуске: вставленный путь Claude Code читает сразу.
    public static func purge(olderThan age: TimeInterval = 86_400, in dir: URL = directory) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for f in files {
            let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(d) > age { try? fm.removeItem(at: f) }
        }
    }

    public static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }
}
