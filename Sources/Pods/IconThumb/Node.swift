import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// 构造工厂 + 入口（Axiom 2：LRU 缓存为实例私有，非全局单例）。
/// NSCache 自身线程安全，其余无可变状态，故 @unchecked Sendable 成立。
public final class IconThumb: IconThumbnailing, @unchecked Sendable {
    private let cache = ThumbnailCache()
    private let scale: CGFloat = 2   // Retina 生成，契约文档承诺像素 ≤ size*scale

    public init() {}

    public func thumbnail(for url: URL, size: CGFloat) async -> CGImage? {
        if Task.isCancelled { return nil }

        // key 含 mtime：文件改动后旧缩略图自动失效（防陈旧），无需显式 invalidate。
        let key = cacheKey(url: url, size: size, scale: scale)
        if let hit = cache.image(forKey: key) { return hit }

        guard let image = await generateThumbnail(url: url, size: size, scale: scale) else {
            return nil
        }
        cache.store(image, forKey: key)
        return image
    }
}
