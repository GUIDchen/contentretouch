// RetouchCore：把 M2/M4a 的逻辑收成一个库，命令行与图形界面共用
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO
import UniformTypeIdentifiers

public let cbGain = 26.0

// MARK: - 统计


// 色彩管理（复查第 4 条）：全部读图都走 loadImage()，测量与写盘都固定 sRGB。
// 之前直接用 CIImage(contentsOf:) 让 Core Image 自己猜，结果恒等渲染比原图亮 13 级（双重伽马）。
// ⚠️ 这里**不留** `cacheIntermediates: false`：§195 试过并**量到它是负收益**，已撤回。
// 探针（Sources/probe）显示关缓存能让"重复渲染同一套参数"的漂移从 +29MB 降到 0，
// 但真实用法不是重复渲染同一套参数：
//   · 预览中位延迟 9.8 ms → **26.6 ms**（直方图那一段 1.14 → 11.7 ms）
//   · 4 张 40MP 批量导出峰值 RSS 1389~1507 MB → **1683 MB**（没降反升）
// 结论：本应用的渲染图是"改一次参数就换一套"，中间缓存不是浪费而是被真正复用的。
public let sharedCtx = CIContext(options: [.useSoftwareRenderer: false,
                                          .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])





// MARK: - 参数与出图




// MARK: - 风格与参考库


















































/// 把若干多边形光栅化成一个灰度蒙版（白=保留）。
/// 每个手单独一张更简单，但一张图跑一次光栅化更省：24MP 也才 24 MB（灰度 1 字节/像素），用完即释放。
func rasterize(_ hulls: [[CGPoint]], extent: CGRect) -> [CIImage] {
    let W = Int(extent.width.rounded()), H = Int(extent.height.rounded())
    guard W > 8, H > 8,
          let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(gray: 1, alpha: 1)
    for hull in hulls {
        // 关键点连出来的轮廓比手掌**小一圈**（点在关节内侧），所以按质心放大 12%，
        // 否则指尖和掌缘磨不到，看上去像「中间一块被磨平了」
        let cx = hull.reduce(0) { $0 + $1.x } / CGFloat(hull.count)
        let cy = hull.reduce(0) { $0 + $1.y } / CGFloat(hull.count)
        let path = CGMutablePath()
        func grow(_ p: CGPoint) -> CGPoint { CGPoint(x: cx + (p.x - cx) * 1.12, y: cy + (p.y - cy) * 1.12) }
        path.move(to: grow(hull[0]))
        for p in hull.dropFirst() { path.addLine(to: grow(p)) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
    guard let out = ctx.makeImage() else { return [] }
    // 光栅图坐标原点在左下、与 CI 同向，所以**不需要翻 y**（本项目的坐标口径文档里有这条）
    return [CIImage(cgImage: out).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        .cropped(to: extent)]
}

/// 凸包（Graham 扫描），输入输出都是图像坐标
func convexHull(_ src: [CGPoint]) -> [CGPoint]? {
    guard src.count >= 3 else { return nil }
    let pts = src.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [CGPoint] = []
    for p in pts {
        while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    var upper: [CGPoint] = []
    for p in pts.reversed() {
        while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    lower.removeLast(); upper.removeLast()
    let hull = lower + upper
    return hull.count >= 3 ? hull : nil
}










// MARK: - 写盘








