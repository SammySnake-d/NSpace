import Foundation
import CoreGraphics

// IconThumb 胶囊唯一对外契约面（Axiom 3）：文件 URL + 尺寸 → CGImage 缩略图（纯派生缓存）。
// 契约只出 CGImage（Sendable），不出 NSImage：装饰层跨并发安全传递，且不把 AppKit 拖进引擎。

public protocol IconThumbnailing: Sendable {
    /// 生成 url 的缩略图（QuickLook）。失败一律返回 nil（BG-7：装饰失败不伤主链）。
    /// - Parameter size: 目标点尺寸（正方形上界）；内部按 scale=2 生成像素，故像素宽高 ≤ size*2。
    /// 命中 LRU 缓存直接返回；可随调用方 Task 取消（取消返回 nil）。
    func thumbnail(for url: URL, size: CGFloat) async -> CGImage?
}
