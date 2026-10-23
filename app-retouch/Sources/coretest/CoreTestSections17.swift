// CoreTestSections17.swift：大面积修补 —— 分块样例补洞 vs 取样复制兜底（第 126 节）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections17() {
// MARK: - 53. 大面积修补：分块样例补洞
head("53. 大面积修补：分块样例补洞 vs 取样复制")
do {
    if let full = loadFixture(bigFace, maxDim: 1400) {
        let fe = full.extent
        // 500x500 的洞（约占图面 8~17%，取决于夹具尺寸）：超过样例补洞单次的 6% 上限
        let side = min(500.0, min(fe.width, fe.height) * 0.45)
        let hole = CGRect(x: fe.midX - side / 2, y: fe.minY + fe.height * 0.30, width: side, height: side)
        let truth = full.cropped(to: hole)
        func avgColor(_ img: CIImage) -> CIColor {
            let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: img])!
            var px = [UInt8](repeating: 0, count: 4)
            sharedCtx.render(f.outputImage!, toBitmap: &px, rowBytes: 4,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return CIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255)
        }
        let damaged = CIImage(color: avgColor(truth)).cropped(to: hole).composited(over: full)
        func rmse(_ img: CIImage) -> Double {
            let t = truth.transformed(by: CGAffineTransform(translationX: -hole.minX, y: -hole.minY))
            let d = img.cropped(to: hole).transformed(by: CGAffineTransform(translationX: -hole.minX, y: -hole.minY))
                .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: t])
            let n = 48
            var buf = [UInt8](repeating: 0, count: n * n * 4)
            let sc = Double(n) / Double(hole.width)
            sharedCtx.render(d.transformed(by: CGAffineTransform(scaleX: sc, y: sc)), toBitmap: &buf,
                             rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var s = 0.0
            for i in 0..<(n * n) { s += Double(buf[i * 4]) }
            return s / Double(n * n)
        }
        // 落点：铺满这个洞的网格（半径 40 → 总面积超过 5% 图面，会触发分块）
        let radius = 60.0
        // ⚠️ 必须**密集铺满**：上一版半径 40、间距 105px，圆与圆之间有空隙，
        // 等于只补了 25 个小圆、整块洞没盖住 —— 量出来的误差跟"没补"一样（140.6 vs 140.6）。
        var pts: [CGPoint] = []
        let step = radius * 1.3
        var yy = hole.minY + step / 2
        while yy < hole.maxY { var xx = hole.minX + step / 2
            while xx < hole.maxX { pts.append(CGPoint(x: xx, y: yy)); xx += step }
            yy += step }
        let area = Double(pts.count) * Double.pi * radius * radius
        let frac = area / Double(fe.width * fe.height)
        let t0 = Date()
        let tiled = healSpots(damaged, points: pts, radius: radius, strength: 1.0, feather: 0.4)
        let dt = Date().timeIntervalSince(t0)
        let cloneOnly = cloneAligned(damaged, points: pts,
                                     offsets: Array(repeating: CGPoint(x: -radius * 2, y: 0), count: pts.count),
                                     radius: radius, feather: 0.4, opacity: 1.0)
        // 对照：**绕过上限**整块跑一次样例补洞（看"最好能到什么程度"）——
        // 若它也很差，说明问题在这个用例而不是分块本身。
        var fullExErr = 999.0
        if let m = strokeMask(extent: fe, points: pts, radius: radius),
           let r = inpaintExemplar(damaged, mask: m, roi: strokeBounds(pts, radius: radius, extent: fe)) {
            fullExErr = rmse(r.image)
        }
        let damagedErr = rmse(damaged), tiledErr = rmse(tiled), cloneErr = rmse(cloneOnly)
        print(String(format: "  [实测] 洞 %.0fx%.0f（%.1f%% 图面，%d 个落点 r=%.0f）：挖掉后 %.1f ｜ 取样复制 %.1f ｜ 分块样例 %.1f（%.1f s）｜ 整块样例（绕过上限）%.1f",
                     side, side, frac * 100, pts.count, radius, damagedErr, cloneErr, tiledErr, dt, fullExErr))
        // ⚠️ **不判定优劣**：这个用例的真值跨了人脸/头发，本来就不可重建，区分不了两种补法
        // （§47 那种"可重复纹理"的用例里样例补洞能到 6.6）。这里只把数字留档，
        // 要下结论得先造一个"大面积且可重建"的用例 —— 第 126 节记了这件事。
        skip("大面积：记录在案（不判优劣，缺可重建的大面积用例）",
              String(format: "分块 %.1f ｜ 取样复制 %.1f ｜ 整块样例(绕过上限) %@ ｜ 挖掉后 %.1f",
                     tiledErr, cloneErr, fullExErr > 900 ? "nil（正确拒绝超限）" : String(format: "%.1f", fullExErr), damagedErr))
    } else { print("  （夹具不可用，跳过）") }
}
}
