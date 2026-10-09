// 抠图工具：把「带着背景的素材」清理成透明背景的主体。
//
// 针对这类素材的实际情况设计（会在输出的统计里体现）：
//   · 最外一圈是白框，往内一圈是"图标的圆角遮罩"被烘焙成的黑色阶梯像素 —— 那两层都是残留；
//   · 再往内是画面本身的背景（这里是浅蓝天空 + 棕色桌面）；
//   · 主体与背景之间还有一圈抗锯齿过渡像素（天空 #A9C9DE 与玻璃轮廓之间会混出 #8BA5B4）。
//
// 判据分两步：
//   1) 从四边做连通泛滥：只有「属于背景色族」且「与边缘连通」的像素才被清掉 ——
//      这一点很关键，玻璃内部的浅蓝（冰/玻璃体，如 #BCD3E1）颜色与天空接近，
//      但它不与边缘连通，所以会被保留。
//   2) 再吃掉一圈过渡像素：只有靠近天空/桌面色族的才吃，**不按黑色族判** ——
//      否则玻璃那道深色轮廓会被啃掉。
//
// 用法：swiftc -O packaging/cutout.swift -o /tmp/cutout
//       /tmp/cutout <输入.png> <输出.png> [预览底色]
// 输出：透明背景且裁到主体外接矩形的主图，以及一张放在对比底色上的预览图。

import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：cutout <输入.png> <输出.png> [预览色 R,G,B]")
    exit(64)
}
let inputPath = arguments[1]
let outputPath = arguments[2]

// 预览底色用洋红：任何残留的白/蓝/棕边缘在它上面都无所遁形
var previewColor = (r: 255, g: 0, b: 255)
if arguments.count >= 4 {
    let parts = arguments[3].split(separator: ",").compactMap { Int($0) }
    if parts.count == 3 { previewColor = (parts[0], parts[1], parts[2]) }
}

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: inputPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("读不到 \(inputPath)")
}

let width = image.width
let height = image.height
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { buffer in
    let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

func pixel(_ index: Int) -> (Int, Int, Int) {
    (Int(pixels[index * 4]), Int(pixels[index * 4 + 1]), Int(pixels[index * 4 + 2]))
}

// MARK: 背景色族

/// 纯白外侧
func isWhiteFamily(_ r: Int, _ g: Int, _ b: Int) -> Bool { r >= 244 && g >= 244 && b >= 244 }
/// 假遮罩的黑色阶梯
func isBlackFamily(_ r: Int, _ g: Int, _ b: Int) -> Bool { r <= 42 && g <= 42 && b <= 42 }
/// 浅蓝天空。区间特意收窄：玻璃体/冰的浅蓝约为 #BCD3E1，红分量 188 会被挡在外面，
/// 否则泛滥可能顺着颜色相近的像素漏进玻璃内部。
func isSkyFamily(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    r >= 150 && r <= 182 && g >= 185 && g <= 215 && b >= 205 && b <= 235
}
/// 棕色桌面
func isTableFamily(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    r >= 115 && r <= 175 && g >= 80 && g <= 130 && b >= 35 && b <= 100
}

func isBackgroundFamily(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    isWhiteFamily(r, g, b) || isBlackFamily(r, g, b) || isSkyFamily(r, g, b) || isTableFamily(r, g, b)
}

/// 只用于「吃过渡像素」：不含黑色族，避免啃掉主体轮廓
func isSoftBackgroundFamily(_ r: Int, _ g: Int, _ b: Int) -> Bool {
    isWhiteFamily(r, g, b) || isSkyFamily(r, g, b) || isTableFamily(r, g, b)
}

// MARK: 第一步：从四边连通泛滥

var isBackground = [Bool](repeating: false, count: width * height)
var stack: [Int] = []

func consider(_ index: Int) {
    guard !isBackground[index] else { return }
    let (r, g, b) = pixel(index)
    guard isBackgroundFamily(r, g, b) else { return }
    isBackground[index] = true
    stack.append(index)
}

for x in 0..<width {
    consider(x)                          // 第一行
    consider((height - 1) * width + x)   // 最后一行
}
for y in 0..<height {
    consider(y * width)
    consider(y * width + width - 1)
}

while let index = stack.popLast() {
    let x = index % width
    if x > 0 { consider(index - 1) }
    if x < width - 1 { consider(index + 1) }
    if index >= width { consider(index - width) }
    if index < width * (height - 1) { consider(index + width) }
}

let floodedCount = isBackground.filter { $0 }.count

// MARK: 第二步：吃掉一圈抗锯齿过渡像素（两轮，处理斜边）

var fringeCount = 0
for _ in 0..<2 {
    var toRemove: [Int] = []
    for index in 0..<(width * height) where !isBackground[index] {
        let x = index % width
        let hasBackgroundNeighbour =
            (x > 0 && isBackground[index - 1]) ||
            (x < width - 1 && isBackground[index + 1]) ||
            (index >= width && isBackground[index - width]) ||
            (index < width * (height - 1) && isBackground[index + width])
        guard hasBackgroundNeighbour else { continue }
        let (r, g, b) = pixel(index)
        if isSoftBackgroundFamily(r, g, b) { toRemove.append(index) }
    }
    if toRemove.isEmpty { break }
    for index in toRemove { isBackground[index] = true }
    fringeCount += toRemove.count
}

// MARK: 第三步：形态学开运算 —— 剪掉挂在主体上的细长残留
//
// 实测踩坑：天空与桌面交界的那条地平线只有 1–2px 厚，但它穿过杯身、与主体连通，
// 所以既能躲过色族泛滥，也能躲过连通域筛选（它和玻璃属于同一个连通域）。
//
// 解法是形态学的"开"：先腐蚀（8 邻域全为前景才保留），1–2px 厚的结构会被整条抹掉；
// 再把腐蚀后的核膨胀一圈，恢复主体轮廓。
//
// 这里踩过一个坑：一开始用的是"按重建的开运算"（腐蚀后沿原前景泛洪重建），
// 那是错的 —— 按重建的开运算按定义会保留整个连通分量，挂在杯子上的那条地平线
// 因为与杯子连通，会被原封不动地"接"回来（实测面积一字未变，就是最直接的证据）。
// 真正的开运算是腐蚀 + 膨胀，不回接：细线被腐蚀掉之后，膨胀也长不回来。

var eroded = [Bool](repeating: false, count: width * height)
for y in 1..<(height - 1) {
    for x in 1..<(width - 1) {
        let index = y * width + x
        guard !isBackground[index] else { continue }
        var allForeground = true
        for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
                if isBackground[(y + dy) * width + (x + dx)] { allForeground = false }
            }
        }
        if allForeground { eroded[index] = true }
    }
}

var opened = [Bool](repeating: false, count: width * height)
for y in 0..<height {
    for x in 0..<width {
        var touchesCore = eroded[y * width + x]
        if !touchesCore {
            outer: for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    if eroded[ny * width + nx] { touchesCore = true; break outer }
                }
            }
        }
        opened[y * width + x] = touchesCore
    }
}

var thinRemoved = 0
for index in 0..<(width * height) where !isBackground[index] && !opened[index] {
    isBackground[index] = true
    thinRemoved += 1
}
print(String(format: "开运算剪掉挂在主体上的细残留：%d 像素", thinRemoved))

// MARK: 第四步：连通域筛选 —— 只留主体，丢掉细环状残留
//
// 实测踩坑：泛滥之后剩下的不是玻璃，而是一圈**抗锯齿灰边**（假遮罩边界混出来的灰像素，
// 不属于任何色族，所以泛滥和过渡清除都碰不到它）。它绕着整张画布走一圈，
// 于是"前景外接矩形"变成 916×948 —— 看起来像没抠干净。
//
// 判据用形状而不是面积：残环的外接矩形很大但填充率极低（面积/外接矩形 < 0.01），
// 主体则接近 1。这样不必调阈值就能分开。

var component = [Int](repeating: -1, count: width * height)
var components: [(area: Int, minX: Int, minY: Int, maxX: Int, maxY: Int, sample: (Int, Int, Int))] = []

for start in 0..<(width * height) where !isBackground[start] && component[start] < 0 {
    let id = components.count
    var queue = [start]
    component[start] = id
    var area = 0
    var cMinX = width, cMaxX = -1, cMinY = height, cMaxY = -1
    var sampleIndex = start
    while let index = queue.popLast() {
        area += 1
        let x = index % width, y = index / width
        cMinX = min(cMinX, x); cMaxX = max(cMaxX, x)
        cMinY = min(cMinY, y); cMaxY = max(cMaxY, y)
        if area == area / 2 * 2 { sampleIndex = index }   // 随便取一个较早的像素当代表色
        if x > 0, !isBackground[index - 1], component[index - 1] < 0 {
            component[index - 1] = id; queue.append(index - 1)
        }
        if x < width - 1, !isBackground[index + 1], component[index + 1] < 0 {
            component[index + 1] = id; queue.append(index + 1)
        }
        if index >= width, !isBackground[index - width], component[index - width] < 0 {
            component[index - width] = id; queue.append(index - width)
        }
        if index < width * (height - 1), !isBackground[index + width], component[index + width] < 0 {
            component[index + width] = id; queue.append(index + width)
        }
    }
    components.append((area, cMinX, cMinY, cMaxX, cMaxY, pixel(sampleIndex)))
}

let ranked = components.enumerated().sorted { $0.element.area > $1.element.area }
guard let mainEntry = ranked.first else { fatalError("没有剩下任何前景像素") }
let (mainID, mainInfo) = mainEntry

// 判据：保留主体，以及**紧贴**主体的分量（真实距离 ≤ 12px）。
//
// 为什么不用"外接矩形相交"（我先试过，失败了）：残留是形状圆角上的黑块，它的外接矩形
// 又宽又长，主体矩形稍微外扩一点就与它相交 —— 于是判据把它当成"就近"保留了下来。
// 按真实距离则非常干净：勺子贴着杯口（0px），圆角残留离主体 80px 以上。
var distanceFromMain = [Int](repeating: -1, count: width * height)
var distanceQueue: [Int] = []
for index in 0..<(width * height) where component[index] == mainID {
    distanceFromMain[index] = 0
    distanceQueue.append(index)
}
var head = 0
while head < distanceQueue.count {
    let index = distanceQueue[head]
    head += 1
    let distance = distanceFromMain[index]
    if distance >= 12 { continue }
    let x = index % width, y = index / width
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
        let neighbour = ny * width + nx
        if distanceFromMain[neighbour] < 0 {
            distanceFromMain[neighbour] = distance + 1
            distanceQueue.append(neighbour)
        }
    }
}

var touchingIDs: Set<Int> = [mainID]
for index in 0..<(width * height) where component[index] >= 0 && component[index] != mainID {
    if distanceFromMain[index] >= 0 { touchingIDs.insert(component[index]) }
}

func keepComponent(_ info: (area: Int, minX: Int, minY: Int, maxX: Int, maxY: Int, sample: (Int, Int, Int)),
                   id: Int) -> Bool {
    info.area >= 100 && touchingIDs.contains(id)
}

let keepIDs = ranked.filter { keepComponent($0.element, id: $0.offset) }.map { $0.offset }

print("连通域（按面积排序，最多列 8 个；主体 id=\(mainID)，紧贴主体的分量 id=\(touchingIDs.sorted())）")
for (rank, entry) in ranked.prefix(8).enumerated() {
    let (id, info) = entry
    let boxArea = (info.maxX - info.minX + 1) * (info.maxY - info.minY + 1)
    let fill = Double(info.area) / Double(boxArea)
    print(String(format: "  #%d id=%d 面积 %7d 外接 %dx%d 填充率 %.3f 代表色 #%02X%02X%02X  %@",
                 rank + 1, id, info.area,
                 info.maxX - info.minX + 1, info.maxY - info.minY + 1, fill,
                 info.sample.0, info.sample.1, info.sample.2,
                 keepComponent(info, id: id) ? "保留" : "丢弃"))
}

for index in 0..<(width * height) where !isBackground[index] {
    if !keepIDs.contains(component[index]) { isBackground[index] = true }
}

// MARK: 空间分布图 —— 一眼看清残留落在哪
//
// 光看面积/外接矩形会误判（细环和 1px 横线都曾骗过我），所以直接把最终 mask 降采样成
// ASCII 打出来：. 是背景，█ 是前景。哪块残留落在哪个方位一目了然。
print("\n最终 mask 分布（. 背景 / █ 前景）：")
let mapColumns = 56
let mapRows = 28
for row in 0..<mapRows {
    var line = ""
    for column in 0..<mapColumns {
        let x0 = column * width / mapColumns, x1 = max(x0 + 1, (column + 1) * width / mapColumns)
        let y0 = row * height / mapRows, y1 = max(y0 + 1, (row + 1) * height / mapRows)
        var foreground = 0, sampled = 0
        for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 6)) {
            for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 6)) {
                sampled += 1
                if !isBackground[y * width + x] { foreground += 1 }
            }
        }
        line += Double(foreground) / Double(max(1, sampled)) > 0.12 ? "█" : "."
    }
    print("  " + line)
}

// MARK: 按前景外接矩形裁剪

var minX = width, maxX = -1, minY = height, maxY = -1
for y in 0..<height {
    for x in 0..<width where !isBackground[y * width + x] {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, maxY >= minY else { fatalError("没有剩下任何前景像素") }

let padding = 2
minX = max(0, minX - padding); maxX = min(width - 1, maxX + padding)
minY = max(0, minY - padding); maxY = min(height - 1, maxY + padding)
let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1

// MARK: 输出（直接按行优先构造，不经过 CTM，方向不会翻）

func write(_ buffer: [UInt8], _ w: Int, _ h: Int, to path: String) {
    let data = Data(buffer)
    guard let provider = CGDataProvider(data: data as CFData),
          let cgImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: w * 4, space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            "public.png" as CFString, 1, nil) else {
        fatalError("无法写出 \(path)")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("写入失败：\(path)") }
}

var cutout = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
var preview = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)

for y in 0..<cropHeight {
    for x in 0..<cropWidth {
        let sourceIndex = (y + minY) * width + (x + minX)
        let targetIndex = (y * cropWidth + x) * 4
        if isBackground[sourceIndex] {
            cutout[targetIndex] = 0; cutout[targetIndex + 1] = 0
            cutout[targetIndex + 2] = 0; cutout[targetIndex + 3] = 0
            preview[targetIndex] = UInt8(previewColor.r)
            preview[targetIndex + 1] = UInt8(previewColor.g)
            preview[targetIndex + 2] = UInt8(previewColor.b)
            preview[targetIndex + 3] = 255
        } else {
            for offset in 0..<3 { cutout[targetIndex + offset] = pixels[sourceIndex * 4 + offset] }
            cutout[targetIndex + 3] = 255
            // 预览：主体不透明地压在底色上，不需要混合
            for offset in 0..<3 { preview[targetIndex + offset] = pixels[sourceIndex * 4 + offset] }
            preview[targetIndex + 3] = 255
        }
    }
}

write(cutout, cropWidth, cropHeight, to: outputPath)
let previewPath = outputPath.replacingOccurrences(of: ".png", with: "-preview.png")
write(preview, cropWidth, cropHeight, to: previewPath)

let total = width * height
let finalForeground = (0..<(width * height)).reduce(into: 0) { count, index in
    if !isBackground[index] { count += 1 }
}
print("\n输入：\(width)x\(height)")
print(String(format: "连通泛滥清掉：%d 像素（%.1f%%）", floodedCount, Double(floodedCount) * 100 / Double(total)))
print(String(format: "过渡边缘再清：%d 像素（%.1f%%）", fringeCount, Double(fringeCount) * 100 / Double(total)))
print(String(format: "开运算再清：%d 像素（%.1f%%）", thinRemoved, Double(thinRemoved) * 100 / Double(total)))
print(String(format: "最终保留的主体：%d 像素（%.1f%%）", finalForeground, Double(finalForeground) * 100 / Double(total)))
print("主体外接矩形：x \(minX)…\(maxX)（宽 \(cropWidth)），y \(minY)…\(maxY)（高 \(cropHeight)）")
print("输出：\(outputPath)")
print("      \(previewPath)（放在 \(previewColor.r),\(previewColor.g),\(previewColor.b) 底色上，用来看残留）")
