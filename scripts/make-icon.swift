// 生成 App 图标：把 design/icon-source.png（图像模型生成的原图）放进 macOS 标准图标网格。
//
// 原图自带的底板尺寸和圆角都不标准，所以这里重画底板（824×824、圆角 185、阴影），
// 渐变色从原图底板取样；再把原图按它自己的底板边界对齐缩放进来，用标准圆角裁切。
//
// 用法：swift scripts/make-icon.swift [原图] [输出目录]
// 默认原图 design/icon-source.png，输出到 AppIcon.appiconset，文件名与 Contents.json 对应。

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let sourcePath = args.count > 1 ? args[1] : "design/icon-source.png"
let outDir = args.count > 2 ? args[2] : "Sources/MMApp/Resources/Assets.xcassets/AppIcon.appiconset"

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - 读原图，找底板边界和底色

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let source = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { fail("读不了原图：\(sourcePath)") }

let sw = source.width, sh = source.height
var pixels = [UInt8](repeating: 0, count: sw * sh * 4)
pixels.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: sw, height: sh))
}
// 内存第 0 行是图像顶部
func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * sw + x) * 4 + 3] }
func color(_ x: Int, _ y: Int) -> CGColor {
    let i = (y * sw + x) * 4
    let a = max(CGFloat(pixels[i + 3]), 1)
    return CGColor(srgbRed: CGFloat(pixels[i]) / a, green: CGFloat(pixels[i + 1]) / a, blue: CGFloat(pixels[i + 2]) / a, alpha: 1)
}

// 沿中线找不透明区域的边界，即原图底板的上下左右
let midX = sw / 2, midY = sh / 2
guard let left = (0..<sw).first(where: { alpha($0, midY) > 128 }),
      let right = (0..<sw).last(where: { alpha($0, midY) > 128 }),
      let top = (0..<sh).first(where: { alpha(midX, $0) > 128 }),
      let bottom = (0..<sh).last(where: { alpha(midX, $0) > 128 })
else { fail("原图里没有找到不透明的底板") }
let sourceTile = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
let topColor = color(midX, top + 10)
let bottomColor = color(midX, bottom - 10)
print("原图底板：\(sourceTile)")

// MARK: - 合成

/// 在 1024×1024、y 轴向下的坐标系里画图标。
func draw(_ ctx: CGContext, pixels: Int) {
    let k = CGFloat(pixels) / 1024
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // 底板与阴影（阴影参数不受 CTM 影响：按像素缩放，且 y 轴向上）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(bottomColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [topColor, bottomColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])

    // 原图按宽度等比缩放，使它的底板左右边对齐标准底板，垂直方向居中
    let scale = tile.width / sourceTile.width
    let drawn = CGRect(x: tile.minX - sourceTile.minX * scale,
                       y: tile.midY - sourceTile.midY * scale,
                       width: CGFloat(sw) * scale, height: CGFloat(sh) * scale)
    // 当前坐标系 y 向下，CGImage 按 y 向上绘制，局部再翻转一次
    ctx.translateBy(x: 0, y: drawn.maxY)
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: drawn.minX, y: 0, width: drawn.width, height: drawn.height))
    ctx.restoreGState()
}

func render(pixels: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }
    ctx.interpolationQuality = .high
    let scale = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    draw(ctx, pixels: pixels)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "icon", code: 2) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 3) }
}

let outputs: [(String, Int)] = [16, 32, 128, 256, 512].flatMap { pt in
    [("icon_\(pt)x\(pt).png", pt), ("icon_\(pt)x\(pt)@2x.png", pt * 2)]
}
for (name, pixels) in outputs {
    try render(pixels: pixels, to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("\(name)  \(pixels)×\(pixels)")
}
