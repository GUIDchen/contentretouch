// CoreTestSections18.swift：大面积补洞的"可重建"用例（第 129 节）。
// 上一轮（§53）用的人像区域跨了人脸/头发，真值本来就不可重建 → 区分不了补法。
// 这一节先**自动找一块重复纹理**（与自身平移副本最接近的窗口），在它上面挖大洞再比。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections18() {
head("54. 大面积补洞：先在可重建区域上造用例")
do {
    let names = ["0001_7676844130508479842_01.webp", "0001_7676844130508479842_05.webp",
                 "0001_7673816620465215714_01.webp", bigFace]
    var best: (Double, String, CGRect, CIImage)? = nil
    for name in names {
        guard let img = loadFixture(name, maxDim: 1200) else { continue }
        let e = img.extent
        let side = min(320.0, min(e.width, e.height) * 0.3)
        // 逐窗口量"自相似度"：窗口与它向右/向下平移半个窗口后的平均差（越小越重复）
        var yy = e.minY + side
        while yy + side < e.maxY {
            var xx = e.minX + side
            while xx + side < e.maxX {
                let box = CGRect(x: xx, y: yy, width: side, height: side)
                let win = img.cropped(to: box)
                let dx = win.transformed(by: CGAffineTransform(translationX: -side * 0.5, y: 0)).cropped(to: box)
                let d = win.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: dx])
                let n = 24
                var buf = [UInt8](repeating: 0, count: n * n * 4)
                let sc = Double(n) / side
                sharedCtx.render(d.transformed(by: CGAffineTransform(scaleX: sc, y: sc)), toBitmap: &buf,
                                 rowBytes: n * 4, bounds: CGRect(x: 0, y: 0, width: n, height: n),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                var s = 0.0
                for i in 0..<(n * n) { s += Double(buf[i * 4]) }
                let score = s / Double(n * n)
                if best == nil || score < best!.0 { best = (score, name, box, img) }
                xx += side * 0.7
            }
            yy += side * 0.7
        }
    }
    guard let (score, name, hole, img) = best else { print("  （没找到可用夹具）"); return }
    let side = hole.width
    print(String(format: "  [实测] 选中 \(name) 的 %.0fx%.0f 区域（自相似差 %.1f，越小越像重复纹理）", side, side, score))
    let truth = img.cropped(to: hole)
    func avgColor(_ i: CIImage) -> CIColor {
        let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: i])!
        var px = [UInt8](repeating: 0, count: 4)
        sharedCtx.render(f.outputImage!, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return CIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255)
    }
    let damaged = CIImage(color: avgColor(truth)).cropped(to: hole).composited(over: img)
    func rmse(_ i: CIImage) -> Double {
        let t = truth.transformed(by: CGAffineTransform(translationX: -hole.minX, y: -hole.minY))
        let d = i.cropped(to: hole).transformed(by: CGAffineTransform(translationX: -hole.minX, y: -hole.minY))
            .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: t])
        let n = 40
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        let sc = Double(n) / hole.width
        sharedCtx.render(d.transformed(by: CGAffineTransform(scaleX: sc, y: sc)), toBitmap: &buf, rowBytes: n * 4,
                         bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var s = 0.0
        for i in 0..<(n * n) { s += Double(buf[i * 4]) }
        return s / Double(n * n)
    }
    let radius = Double(side) * 0.22
    var pts: [CGPoint] = []
    let step = radius * 1.5
    var yy = hole.minY + step * 0.6
    while yy < hole.maxY { var xx = hole.minX + step * 0.6
        while xx < hole.maxX { pts.append(CGPoint(x: xx, y: yy)); xx += step }
        yy += step }
    let frac = Double(pts.count) * Double.pi * radius * radius / Double(img.extent.width * img.extent.height)
    let cloneOnly = cloneAligned(damaged, points: pts,
                                 offsets: Array(repeating: CGPoint(x: -radius * 2, y: 0), count: pts.count),
                                 radius: radius, feather: 0.35, opacity: 1.0)
    let healed = healSpots(damaged, points: pts, radius: radius, strength: 1.0, feather: 0.35)
    // 诊断：直接调样例补洞，看它被什么拒绝（洞占比？ROI？）
    if let m = strokeMask(extent: img.extent, points: pts, radius: radius) {
        var mp = 0
        let W = Int(img.extent.width), H = Int(img.extent.height)
        var mb = [UInt8](repeating: 0, count: W * H * 4)
        sharedCtx.render(m, toBitmap: &mb, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for i in 0..<(W * H) where mb[i * 4] > 128 { mp += 1 }
        let roi = strokeBounds(pts, radius: radius, extent: img.extent)
        if let r = inpaintExemplar(damaged, mask: m, roi: roi) {
            print(String(format: "  [实测] 直接调样例补洞：成功（填充 %d px、%.0f ms）误差 %.1f ｜ 掩膜 %d px（%.2f%%）｜ ROI %.0fx%.0f",
                         r.stats.filled, r.stats.millis, rmse(r.image), mp, Double(mp) / Double(W * H) * 100, roi.width, roi.height))
        } else {
            print(String(format: "  [实测] 直接调样例补洞：**返回 nil** ｜ 掩膜 %d px（占图面 %.2f%%，上限 6%%）｜ ROI %.0fx%.0f（上限 4096）",
                         mp, Double(mp) / Double(W * H) * 100, roi.width, roi.height))
        }
    }
    print(String(format: "  [实测] 洞 %.0fx%.0f（占图面 %.1f%%，%d 个落点 r=%.0f）：挖掉后 %.1f ｜ 取样复制 %.1f ｜ healSpots %.1f",
                 side, side, frac * 100, pts.count, radius, rmse(damaged), rmse(cloneOnly), rmse(healed)))
    // 这条断言**护住当前决定**：大面积走取样复制（第 129 节实测 36.5），
    // 若有人再加回"分块样例补洞"，它会变成 44.6 → 这里直接红。
    check("大面积兜底：取样复制不差于（分块）样例补洞", rmse(healed) <= rmse(cloneOnly) * 1.05,
          String(format: "healSpots %.1f ｜ 取样复制 %.1f（差值 >5%% 说明补法变差了）", rmse(healed), rmse(cloneOnly)))
}
}
