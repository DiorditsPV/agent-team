import Foundation

/// Картинка для раскрытия на всё окно: файл вложения или base64 из транскрипта.
public struct ViewedImage: Equatable, Identifiable, Sendable {
    public var id: String
    public var url: URL?
    public var base64: String?

    public init(id: String, url: URL? = nil, base64: String? = nil) {
        self.id = id
        self.url = url
        self.base64 = base64
    }

    public var data: Data? {
        if let url, let d = try? Data(contentsOf: url) { return d }
        return base64.flatMap { Data(base64Encoded: $0) }
    }
}
