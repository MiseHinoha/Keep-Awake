// KeepAwake 应用图标的渲染来源：暖/冷底色圆角底板 + 像素风主体（冰咖啡）。
//
// 为什么底板用代码画：它是纯几何（圆角方块 + 渐变），改色只动两个数值。
// 为什么主体是图片：那幅像素画是本项目自带的素材，用 packaging/cutout.swift 抠出透明背景后
// 存在 packaging/glass-subject.png。**缩放必须用最近邻** —— 双线性会把像素画的边缘糊掉，
// 那是像素素材的底线。
//
// 用法：swiftc -O -parse-as-library packaging/draw-icon.swift -o /tmp/draw-icon
//       /tmp/draw-icon <输出.png> [cold]      # 不给 cold 就是暖色底板
// 之后：sh scripts/make-icon.sh <输出.png>
//
// 注意 -parse-as-library 不能省：文件里有 @main，编译器会把同文件的顶层代码当成
// 非法的顶层代码，只有加了它才会把这里当作库模块来编译。
//
// 画的时候用左上角为原点（CoreGraphics 默认原点在左下），这样坐标可以直接按设计稿读。
//
// 历史：早先的主体是矢量画的热咖啡杯（带热气 / 茶碟 / 投影），后来换成这幅像素风冰咖啡。

import CoreGraphics
import Foundation
import ImageIO

private let canvas = 1024.0

private func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// MARK: 底板配色
//
// 暖色沿用这个 app 原本的品牌色；冷色是为了配冰咖啡而加的备选。

private struct PlateColors {
    var top: CGColor
    var bottom: CGColor
    var glow: CGColor

    static let warm = PlateColors(top: rgb(248, 190, 112),
                                  bottom: rgb(196, 92, 36),
                                  glow: rgb(255, 246, 230, 0.40))
    static let cold = PlateColors(top: rgb(214, 233, 241),
                                  bottom: rgb(74, 124, 158),
                                  glow: rgb(255, 255, 255, 0.34))
    /// 深色：浅色的玻璃杯体与深色咖啡在深底上都最跳，也是 macOS 图标里最常见的一种处理
    static let dark = PlateColors(top: rgb(78, 90, 104),
                                  bottom: rgb(24, 30, 38),
                                  glow: rgb(255, 255, 255, 0.16))
}

// MARK: 读取主体

/// 主体图片的路径：与可执行文件无关，固定取仓库里的 packaging/glass-subject.png。
/// 也支持用环境变量 KA_SUBJECT 覆盖，方便临时换素材比较。
private func loadSubject() -> CGImage? {
    let override = ProcessInfo.processInfo.environment["KA_SUBJECT"]
    let path = override ?? "packaging/glass-subject.png"
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
        return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

/// 横向锚点：取主体**下半部**（杯身所在）不透明像素的水平中心。
///
/// 为什么不能直接按整张图居中：右上那把勺子会把外接矩形整体拉宽，
/// 按它居中的话杯身会明显偏左 —— 第一版就是这个毛病。
private func subjectAnchor(_ image: CGImage) -> Double {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    var minX = width, maxX = -1
    for y in (height / 2)..<height {          // 行序从上到下，所以后半段就是下半部
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 {
            minX = min(minX, x)
            maxX = max(maxX, x)
        }
    }
    guard maxX >= minX else { return Double(width) / 2 }
    return Double(minX + maxX) / 2
}

// MARK: 绘制

private func drawIcon(to outputPath: String, colors: PlateColors) {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                              bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("无法创建绘图上下文")
    }
    ctx.translateBy(x: 0, y: CGFloat(canvas))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)

    // ── 底板：macOS 应用图标网格，824×824 居中、圆角 185
    let inset = 100.0
    let plate = CGPath(roundedRect: CGRect(x: inset, y: inset,
                                           width: canvas - inset * 2, height: canvas - inset * 2),
                       cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let background = CGGradient(colorsSpace: colorSpace,
                                colors: [colors.top, colors.bottom] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background,
                           start: CGPoint(x: 0, y: inset),
                           end: CGPoint(x: 0, y: canvas - inset),
                           options: [])
    // 主体背后一团光：纯渐变会很平，主体浮不起来
    let glow = CGGradient(colorsSpace: colorSpace,
                          colors: [colors.glow, (colors.glow.copy(alpha: 0) ?? colors.glow)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 540), endRadius: 470,
                           options: [])
    ctx.restoreGState()

    // ── 主体：等比缩放到指定高度后居中
    guard let subject = loadSubject() else {
        fatalError("读不到主体图（packaging/glass-subject.png，可用 KA_SUBJECT 覆盖）")
    }
    let subjectHeight = 620.0
    let scale = subjectHeight / Double(subject.height)
    let drawWidth = Double(subject.width) * scale
    let drawHeight = Double(subject.height) * scale
    let anchor = subjectAnchor(subject) * scale

    // 这里再翻一次抵消上面的翻转：否则图像会上下颠倒。
    // 抵消之后 CTM 回到常规的「左下原点」，而垂直居中在两种坐标系下是一样的。
    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(canvas))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .none          // 像素画必须最近邻
    ctx.draw(subject, in: CGRect(x: canvas / 2 - anchor, y: (canvas - drawHeight) / 2,
                                 width: drawWidth, height: drawHeight))
    ctx.restoreGState()

    // ── 生成 PNG
    guard let image = ctx.makeImage() else { fatalError("渲染失败") }
    let url = URL(fileURLWithPath: outputPath)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("无法写入 \(outputPath)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("写入失败：\(outputPath)") }
    print("已生成：\(outputPath)")
}

@main
enum DrawIcon {
    static func main() {
        let arguments = CommandLine.arguments
        let target = arguments.count > 1 ? arguments[1] : "AppIcon-source.png"
        let colors: PlateColors
        if arguments.contains("cold") {
            colors = .cold
        } else if arguments.contains("dark") {
            colors = .dark
        } else {
            colors = .warm
        }
        drawIcon(to: target, colors: colors)
    }
}
