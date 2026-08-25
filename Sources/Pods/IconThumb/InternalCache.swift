import Foundation
import CoreGraphics

// 私有关注点：LRU 缓存（NSCache 包装）+ 防陈旧缓存键。

/// NSCache 只收 class；CGImage 是 struct 语义的 CF 类型，用引用盒子承载。
final class ThumbnailBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// LRU 缩略图缓存：countLimit=512（滚动列表可见窗口的数倍，足够复用又受控）。
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSString, ThumbnailBox>()

    init() {
        cache.countLimit = 512
    }

    func image(forKey key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func store(_ image: CGImage, forKey key: String) {
        cache.setObject(ThumbnailBox(image), forKey: key as NSString)
    }
}

/// 缓存键 = 路径 + 尺寸 + scale + mtime：mtime 变化即换键，旧图自然被 LRU 淘汰（防陈旧）。
func cacheKey(url: URL, size: CGFloat, scale: CGFloat) -> String {
    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate?.timeIntervalSince1970 ?? 0
    return "\(url.path)|\(Int(size))|\(Int(scale))|\(mtime)"
}
