import Foundation
import CoreGraphics
import QuickLookThumbnailing

// 私有关注点：QLThumbnailGenerator 桥接。

/// 生成缩略图；任何失败（不支持类型/文件不存在/超时/取消）都返回 nil，不抛错。
/// 取消协作式：入口查 Task.isCancelled，且系统 async 生成 API 自身响应任务取消而抛错（被 try? 吞成 nil）。
func generateThumbnail(url: URL, size: CGFloat, scale: CGFloat) async -> CGImage? {
    if Task.isCancelled { return nil }

    let request = QLThumbnailGenerator.Request(
        fileAt: url,
        size: CGSize(width: size, height: size),
        scale: scale,
        representationTypes: .thumbnail)

    let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
    return rep?.cgImage
}
