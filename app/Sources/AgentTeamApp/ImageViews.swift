import AgentTeamCore
import AppKit
import SwiftUI

/// Миниатюры уменьшаются один раз и держатся в кеше: лента перерисовывается часто, а картинки в транскрипте — сотни килобайт base64.
@MainActor
enum ThumbCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    /// Уменьшенная картинка вне главного потока.
    static func load(key: String, side: CGFloat, url: URL?, base64: String?) async -> NSImage? {
        if let hit = image(key) { return hit }
        let px = Int(side * 2)
        let cg: CGImage? = await Task.detached(priority: .userInitiated) {
            if let url { return Attachments.thumbnail(url: url, maxPixel: px) }
            if let b = base64, let d = Data(base64Encoded: b) { return Attachments.thumbnail(data: d, maxPixel: px) }
            return nil
        }.value
        guard let cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}

/// Миниатюра картинки: файл вложения или base64 из транскрипта. Нажатие раскрывает картинку.
struct ImageThumb: View {
    var key: String
    var url: URL?
    var base64: String?
    var side: CGFloat = 96
    var app: AppModel
    var onRemove: (() -> Void)?
    @State private var image: NSImage?

    var body: some View {
        Button {
            app.viewedImage = ViewedImage(id: key, url: url, base64: base64)
        } label: {
            ZStack {
                C.bg
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.system(size: 16)).foregroundStyle(C.faint)
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .overlay(Rectangle().stroke(C.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Раскрыть картинку")
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(C.ink)
                        .frame(width: 18, height: 18).background(C.surface.opacity(0.92))
                        .overlay(Rectangle().stroke(C.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Убрать картинку")
                .padding(3)
            }
        }
        .task(id: key) {
            if let hit = ThumbCache.image(key) { image = hit; return }
            image = await ThumbCache.load(key: key, side: side, url: url, base64: base64)
        }
    }
}

/// Раскрытая картинка на всё окно; Esc или нажатие закрывает.
struct ImageViewer: View {
    var item: ViewedImage
    var close: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82).onTapGesture(perform: close)
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .padding(40)
                    .shadow(color: .black.opacity(0.4), radius: 24)
                    .onTapGesture(perform: close)
            } else {
                ProgressView().controlSize(.small)
            }
            Button(action: close) {
                HStack(spacing: 6) {
                    Text("Закрыть").font(T.text(12))
                    Text("Esc").font(T.mono(11)).foregroundStyle(T.dim)
                }
                .foregroundStyle(T.ink).padding(.horizontal, 12).padding(.vertical, 7)
                .background(T.surface).overlay(Rectangle().stroke(T.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(20)
        }
        .task(id: item.id) {
            let source = item
            image = await Task.detached(priority: .userInitiated) { source.data.flatMap { NSImage(data: $0) } }.value
        }
    }
}
