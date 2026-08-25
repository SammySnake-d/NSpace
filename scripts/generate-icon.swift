#!/usr/bin/env swift
// 一次性图标生成器：CoreGraphics 离屏渲染 1024px PNG（无需窗口服务器/Xcode）
// 用法: swift scripts/generate-icon.swift Support/icon_1024.png
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Support/icon_1024.png"
let S: CGFloat = 1024

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rounded(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

// macOS 图标网格：1024 画布中图形占约 824，四周留白
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(rounded(plate, 184))
ctx.clip()

// 背景：深蓝 → 紫渐变
let grad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.13, green: 0.16, blue: 0.38, alpha: 1),
    CGColor(red: 0.36, green: 0.20, blue: 0.62, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: plate.minX, y: plate.maxY),
                       end: CGPoint(x: plate.maxX, y: plate.minY), options: [])

// 双窗格玻璃拟物：左侧栏 + 两个主窗格
func pane(_ rect: CGRect, alpha: CGFloat) {
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    ctx.addPath(rounded(rect, 36))
    ctx.fillPath()
}
let inset = plate.insetBy(dx: 96, dy: 128)
let gap: CGFloat = 28
let sidebarW = inset.width * 0.24
let paneW = (inset.width - sidebarW - 2 * gap) / 2
pane(CGRect(x: inset.minX, y: inset.minY, width: sidebarW, height: inset.height), alpha: 0.32)
pane(CGRect(x: inset.minX + sidebarW + gap, y: inset.minY, width: paneW, height: inset.height), alpha: 0.92)
pane(CGRect(x: inset.minX + sidebarW + gap + paneW + gap, y: inset.minY, width: paneW, height: inset.height), alpha: 0.62)

// 侧栏书签点 + 窗格文件行（示意肌理）
ctx.setFillColor(CGColor(red: 0.36, green: 0.20, blue: 0.62, alpha: 0.55))
for i in 0..<4 {
    let y = inset.maxY - 90 - CGFloat(i) * 86
    ctx.addPath(rounded(CGRect(x: inset.minX + 28, y: y, width: sidebarW - 56, height: 34), 17))
    ctx.fillPath()
}
for (px, alpha) in [(inset.minX + sidebarW + gap, 0.5), (inset.minX + sidebarW + gap + paneW + gap, 0.35)] {
    ctx.setFillColor(CGColor(red: 0.13, green: 0.16, blue: 0.38, alpha: alpha))
    for i in 0..<5 {
        let y = inset.maxY - 84 - CGFloat(i) * 96
        ctx.addPath(rounded(CGRect(x: px + 32, y: y, width: paneW - 64, height: 30), 15))
        ctx.fillPath()
    }
}

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG 写入失败") }
print("已生成 \(out)")
