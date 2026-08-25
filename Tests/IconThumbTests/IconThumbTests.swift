import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import IconThumb

/// 黑盒验收：只经 Contract 公开面 + 真实临时 PNG（用 ImageIO 生成，不碰 AppKit/NSImage）。
@Suite struct IconThumbTests {

    /// 用 CoreGraphics + ImageIO 落一张纯色 PNG，返回其 URL。
    private func makePNG(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nspace-it-\(UUID().uuidString).png")
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    @Test func generatesThumbnailWithinRequestedPixelBounds() async throws {
        let png = try makePNG(width: 512, height: 512)
        defer { try? FileManager.default.removeItem(at: png) }

        let size: CGFloat = 128
        let scale: CGFloat = 2
        let thumb = await IconThumb().thumbnail(for: png, size: size)

        let image = try #require(thumb, "真实 PNG 应能生成缩略图")
        #expect(image.width > 0 && image.height > 0)
        #expect(image.width <= Int(size * scale))
        #expect(image.height <= Int(size * scale))
    }

    @Test func returnsNilForMissingFile() async {
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).png")
        let thumb = await IconThumb().thumbnail(for: bogus, size: 128)
        #expect(thumb == nil)
    }

    @Test func secondRequestReturnsCachedImage() async throws {
        let png = try makePNG(width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: png) }

        let icon = IconThumb()
        let first = await icon.thumbnail(for: png, size: 96)
        let second = await icon.thumbnail(for: png, size: 96)
        #expect(first != nil)
        // 命中缓存应返回同一 CGImage 实例（引用相等）
        #expect(first === second)
    }
}
