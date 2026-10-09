// 量顶栏图标落在哪：拿真实的 NSStatusItem 建一遍，把按钮渲染出来，
// 数出「墨迹」（不透明像素）的范围，再换算到屏幕上跟菜单栏条带的正中比。
//
// 由 scripts/status-icon-probe.sh 负责编译（要和 Sources/App/StatusIcon.swift 一起编译，
// 这样量的是 App 真正在用的那份画法，不是另写一份）。
//
// 输出两种方案的数据：
//   原图 —— 直接用 SF Symbol 的图（改成固定画布之前的样子）
//   画布 —— StatusIcon.make 画出来的固定画布图
// 目标：两个状态图标尺寸一致，墨迹中心落在条带正中（偏差 ≤ 0.5 点 = 1 个物理像素）。
//
// 精度的边界：这里量的是「墨迹包围盒」的中心，最小刻度是 1 物理像素（0.5 点）；
// 别把它当亚像素测量看 —— 0.5 点的读数就是「已经压到一像素以内」的意思。
import AppKit
import Foundation

let outDir = "/tmp/keepawake-status-icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct InkBox {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var isEmpty: Bool { maxX < minX || maxY < minY }
}

struct Measurement {
    var buttonW: CGFloat
    var buttonH: CGFloat
    var inkW: CGFloat            // 点
    var inkH: CGFloat            // 点
    var inkMidXInButton: CGFloat
    var fromTop: CGFloat         // 墨迹中心距屏幕顶部的点数
    var stripHeight: CGFloat     // 顶栏项目窗口的高度 = 该对齐的那条带子
    var thickness: CGFloat       // NSStatusBar.system.thickness（仅供参考，见下）
    var deviation: CGFloat { fromTop - stripHeight / 2 }   // 正 = 比条带正中低
}

/// 在**像素**层面找墨迹范围（阈值取得低一点，把抗锯齿的边缘也算进去，
/// 让包围盒稳定到 1 像素），同时按「点」打印 ASCII，方便肉眼核对。
func scan(_ rep: NSBitmapImageRep, pointsWide: Int, pointsHigh: Int, drawASCII: Bool, tag: String) -> InkBox {
    var box = InkBox(minX: rep.pixelsWide, minY: rep.pixelsHigh, maxX: -1, maxY: -1)
    var lines: [String] = []
    for py in 0..<pointsHigh {
        var line = ""
        for px in 0..<pointsWide {
            let x0 = px * rep.pixelsWide / max(1, pointsWide)
            let x1 = max(x0 + 1, (px + 1) * rep.pixelsWide / max(1, pointsWide))
            let y0 = py * rep.pixelsHigh / max(1, pointsHigh)
            let y1 = max(y0 + 1, (py + 1) * rep.pixelsHigh / max(1, pointsHigh))
            var hit = false
            for y in y0..<min(y1, rep.pixelsHigh) {
                for x in x0..<min(x1, rep.pixelsWide) {
                    guard (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 else { continue }
                    hit = true
                    box.minX = min(box.minX, x)
                    box.maxX = max(box.maxX, x)
                    box.minY = min(box.minY, y)
                    box.maxY = max(box.maxY, y)
                }
            }
            line += hit ? "#" : "."
        }
        lines.append(line)
    }
    if drawASCII {
        print("  " + tag + "（" + String(pointsWide) + "x" + String(pointsHigh) + " 点，y 从上往下）")
        print("  +" + String(repeating: "-", count: pointsWide) + "+")
        for line in lines {
            print("  |" + line + "|")
        }
        print("  +" + String(repeating: "-", count: pointsWide) + "+")
    }
    return box
}

/// 建一个真实的顶栏项目量一次 → 量完立刻撤掉（不在顶栏留东西）。
func measure(_ image: NSImage?, on: Bool, tag: String, drawASCII: Bool) -> Measurement {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let thickness = NSStatusBar.system.thickness
    guard let button = item.button else {
        return Measurement(buttonW: 0, buttonH: 0, inkW: 0, inkH: 0, inkMidXInButton: 0,
                           fromTop: 0, stripHeight: 0, thickness: thickness)
    }
    button.image = image
    button.title = ""
    button.imagePosition = .imageOnly
    button.contentTintColor = on ? .systemOrange : nil
    button.toolTip = "status-icon-probe"
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))

    let bounds = button.bounds
    var box = InkBox(minX: 0, minY: 0, maxX: -1, maxY: -1)
    if let rep = button.bitmapImageRepForCachingDisplay(in: bounds) {
        button.cacheDisplay(in: bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outDir + "/" + tag + ".png"))
        }
        box = scan(rep, pointsWide: Int(bounds.width.rounded()), pointsHigh: Int(bounds.height.rounded()),
                   drawASCII: drawASCII, tag: tag)
    }
    // 墨迹中心 → 窗口坐标 → 屏幕（自上而下）坐标，跟菜单栏条带正中比。
    let backing = button.window?.backingScaleFactor ?? 1
    let buttonInWindow = button.convert(bounds, to: nil)
    let windowInScreen = button.window?.frame ?? .zero
    let screenHeight = button.window?.screen?.frame.height ?? 0
    let inkMidYPixelsFromButtonTop = (CGFloat(box.minY) + CGFloat(box.maxY + 1)) / 2
    let inkMidYInButton = bounds.height - inkMidYPixelsFromButtonTop / backing
    let inkMidXPixelsFromButtonLeft = (CGFloat(box.minX) + CGFloat(box.maxX + 1)) / 2
    let fromTop = screenHeight - (windowInScreen.origin.y + buttonInWindow.origin.y + inkMidYInButton)
    return Measurement(buttonW: bounds.width, buttonH: bounds.height,
                       inkW: CGFloat(box.maxX - box.minX + 1) / backing,
                       inkH: CGFloat(box.maxY - box.minY + 1) / backing,
                       inkMidXInButton: inkMidXPixelsFromButtonLeft / backing,
                       fromTop: fromTop, stripHeight: windowInScreen.height, thickness: thickness)
}

func report(_ label: String, _ symbol: String, _ on: Bool, _ image: NSImage?, drawASCII: Bool = false) -> Measurement {
    let result = measure(image, on: on, tag: label + "-" + (on ? "on" : "off"), drawASCII: drawASCII)
    print("")
    print("— " + label + " —— " + (on ? "开" : "关") + "（" + symbol + "）")
    print("  按钮 " + String(format: "%.0fx%.0f", result.buttonW, result.buttonH)
          + "  墨迹 " + String(format: "%.1fx%.1f", result.inkW, result.inkH) + " 点"
          + "  墨迹中心在按钮内 x=" + String(format: "%.1f", result.inkMidXInButton)
          + "（按钮正中 " + String(format: "%.1f", result.buttonW / 2) + "）")
    print("  墨迹中心距屏幕顶 " + String(format: "%.1f", result.fromTop) + " 点"
          + "（项目窗口 " + String(format: "%.0f", result.stripHeight) + " 点高，正中 " + String(format: "%.1f", result.stripHeight / 2) + "）"
          + " → 偏差 " + String(format: "%+.1f", result.deviation) + " 点（正=偏低）")
    return result
}

final class Probe: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let cases: [(symbol: String, on: Bool)] = [("cup.and.saucer.fill", true), ("moon.zzz", false)]
        print("NSStatusBar.system.thickness = " + String(format: "%.1f", NSStatusBar.system.thickness)
              + " 点（这个 API 报的是经典菜单栏高度；带刘海的本机项目窗口实际 34 点高 —— 对齐看项目窗口）")

        print("")
        print("=== 方案一：直接用 SF Symbol 原图（改成固定画布之前的样子）===")
        for item in cases {
            let raw = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            raw?.isTemplate = true
            _ = report("原图", item.symbol, item.on, raw)
        }

        print("")
        print("=== 方案二：StatusIcon.make 画的固定画布 ===")
        var deviations: [CGFloat] = []
        for item in cases {
            let image = StatusIcon.make(symbol: item.symbol, description: "合盖保活：" + (item.on ? "已开启" : "已关闭"))
            deviations.append(report("画布", item.symbol, item.on, image, drawASCII: true).deviation)
        }

        print("")
        let worst = deviations.map { abs($0) }.max() ?? 99
        if worst <= 0.5 {
            print("✓ 两个状态的图标尺寸一致、都落在条带正中（最大偏差 " + String(format: "%.1f", worst) + " 点，不到 1 个物理像素）")
        } else {
            let suggestion = -((deviations.first ?? 0) + (deviations.last ?? 0)) / 2
            print("✗ 最大偏差 " + String(format: "%.1f", worst) + " 点；把 Sources/App/StatusIcon.swift 的 verticalNudge "
                  + "从 " + String(format: "%+.1f", StatusIcon.verticalNudge) + " 改成 "
                  + String(format: "%+.1f", (StatusIcon.verticalNudge + suggestion).rounded())
                  + " 后重跑（正 = 往上）")
        }
        print("PNG 存在 " + outDir)
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
let probe = Probe()
application.delegate = probe
application.setActivationPolicy(.accessory)
application.run()
