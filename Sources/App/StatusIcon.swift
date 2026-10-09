// 顶栏图标怎么画 —— 单独成文件，是为了让排查工具（scripts/status-icon-probe.swift）
// 能跟 App 编译同一份代码来量位置，而不是各写一遍。
//
// 为什么不是「一行 SF Symbol 名」就完事：
// SF Symbol 给出来的是一张「按字体度量对齐」的图，两个符号各给一张不同宽高的
// （实测：cup.and.saucer.fill 是 20x15、moon.zzz 是 15x17）。而顶栏按钮的宽和高
// 都是按这张图算出来的 —— 于是两个状态的图标尺寸不一样（按钮 36x28 / 32x30）、
// 位置也各偏一点（偏高 1.0 / 2.0 点），切换时肉眼能看到图标上下错、左右跳。
// 统一画进同一张固定画布、居中放：两态尺寸一致（都量到 36x28 的项目、墨迹中心偏差
// 0.2 点 = 0.4 个物理像素），切换时图标不再上下错、左右跳。

import AppKit

enum StatusIcon {
    /// 两态共用的画布尺寸：宽 20 = 最宽的那个符号（咖啡杯）的自然宽度，
    /// 高 28 = 原来「用 SF Symbol 原图」时那个项目的按钮高度（杯子那版 36x28）。
    /// 为什么高度要特意对上按钮：普通图片做按钮时，**按钮高度 = 图片高度**（实测 24 以下是 22 的下限），
    /// 而按钮会决定点得中的范围和悬停高亮的大小 —— 取 28 就跟改动前一样，
    /// 不会让顶栏项目比以前矮一截。图片是透明的，画布高一点不会让图标变大。
    static let canvas = NSSize(width: 20, height: 28)

    /// 画布内整体上移多少点（正 = 往上；AppKit 坐标原点在左下）。
    /// 数字是量出来的，不是猜的：跑 `sh scripts/status-icon-probe.sh`，它会把墨迹中心
    /// 跟顶栏项目窗口的正中对比，目标是偏差 0 点。实测：0 和 +0.5 都只差 0.2 点
    /// （0.4 个物理像素，量不出区别），取 +0.5 是因为那样符号画在整点上 ——
    /// 万一接的是 1x 显示器，整点落位不会糊。
    static let verticalNudge: CGFloat = 0.5

    static func make(symbol: String, description: String) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else {
            return nil
        }
        glyph.isTemplate = true
        // 不四舍五入到整点：画布高与符号高奇偶不同，精确的居中是 .5 点——
        // 在 2x 屏上 .5 点正好落在一个像素上（清晰），而取整反而会引入 0.5 点的偏心。
        let origin = NSPoint(
            x: (canvas.width - glyph.size.width) / 2,
            y: (canvas.height - glyph.size.height) / 2 + verticalNudge)

        // 用 drawingHandler 而不是先把图标画进一张位图：handler 在真正绘制时才展开，
        // 按当时的倍率画，矢量符号到 Retina 上才不会糊；画进位图就等于固定在 1x 了。
        let image = NSImage(size: canvas, flipped: false) { rect in
            glyph.draw(at: NSPoint(x: rect.minX + origin.x, y: rect.minY + origin.y),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }
}
