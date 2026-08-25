#!/usr/bin/env swift
// 图标生成器（M20 定稿「N」）：CoreGraphics 离屏渲染 1024px PNG（无需窗口服务器/Xcode）
// 设计：石墨玻璃深底 + 青→蓝渐变几何 N——两根竖条 = 双窗格，斜杠 = 分割线（用户 2026-08-26 拍板）
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
func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

// macOS 图标网格：1024 画布中图形占约 824，四周留白
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(rounded(plate, 184))
ctx.clip()

// 底：石墨玻璃（近黑带蓝倾向），上亮下暗
let bg = CGGradient(colorsSpace: cs, colors: [
    rgba(0.10, 0.11, 0.14, 1), rgba(0.045, 0.05, 0.07, 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.minY), options: [])

// N：两竖条 + 斜杠并成一条路径一次渐变填充（绕向与 CGPath(roundedRect:) 一致，
// 避免 nonzero 环绕抵消出洞；一次填充无接缝、无叠影）
let inset = plate.insetBy(dx: 190, dy: 190)
let barW = inset.width * 0.26
let n = CGMutablePath()
n.addPath(rounded(CGRect(x: inset.minX, y: inset.minY, width: barW, height: inset.height), barW / 2))
n.addPath(rounded(CGRect(x: inset.maxX - barW, y: inset.minY, width: barW, height: inset.height), barW / 2))
let t: CGFloat = barW * 0.92
n.move(to: CGPoint(x: inset.minX + barW * 0.35 + t, y: inset.maxY - barW * 0.5))
n.addLine(to: CGPoint(x: inset.minX + barW * 0.35, y: inset.maxY - barW * 0.5))
n.addLine(to: CGPoint(x: inset.maxX - barW * 0.35 - t, y: inset.minY + barW * 0.5))
n.addLine(to: CGPoint(x: inset.maxX - barW * 0.35, y: inset.minY + barW * 0.5))
n.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: rgba(0.1, 0.55, 1, 0.5))
ctx.addPath(n)
ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [
    rgba(0.42, 0.83, 1.00, 1), rgba(0.04, 0.52, 1.00, 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: inset.midX, y: inset.maxY),
                       end: CGPoint(x: inset.midX, y: inset.minY), options: [])
ctx.restoreGState()

// 顶部玻璃高光（单一光源自上而下）
let sheen = CGGradient(colorsSpace: cs, colors: [rgba(1, 1, 1, 0.08), rgba(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: plate.midX, y: plate.maxY),
                       end: CGPoint(x: plate.midX, y: plate.maxY - 280), options: [])

ctx.restoreGState()
let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG 写入失败") }
print("已生成 \(out)")
