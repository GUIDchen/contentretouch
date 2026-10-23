// CoreTestSections14.swift：coretest 的第 105~107 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections14() {
head("47. 大面积兜底（自然纹理，非周期条纹）")
do {
    // 用真实照片的**纹理区**做真值：把一块挖掉，再用三种补法还原，比洞内平均误差。
    // 注意：libDirs 里只有 douyin / bilibili / 小红书 三个目录，用它里面的真实照片；
    // 洞落在人像片的中下段（衣物/桌面这类有纹理的地方），避开纯色背景。
    if let full = loadFixture(bigFace, maxDim: 1400) {
        let fe = full.extent
        // 找一个有纹理、没有大面积纯色的区域（人像片的中部偏下：桌面/衣物褶皱）
        let hole = CGRect(x: fe.midX - 90, y: fe.minY + fe.height * 0.18, width: 180, height: 180)
        let truth = full.cropped(to: hole)
        // "挖掉"：把洞内替换成该区域的**均值色**（等价于物体被移除后留下的一块），这是修补工具要面对的输入
        func avgColor(_ img: CIImage) -> CIColor {
            let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: img])!
            var px = [UInt8](repeating: 0, count: 4)
            sharedCtx.render(f.outputImage!, toBitmap: &px, rowBytes: 4,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return CIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                           blue: CGFloat(px[2]) / 255)
        }
        let flat = CIImage(color: avgColor(truth)).cropped(to: hole)
        let damaged = flat.composited(over: full)
        func rmse(_ img: CIImage) -> Double {
            let d = img.cropped(to: hole).transformed(by: CGAffineTransform(translationX: -hole.minX, y: -hole.minY))
                .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: truth.transformed(by: CGAffineTransform(translationX: -hole.minX, y: -hole.minY))])
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
        let center = CGPoint(x: hole.midX, y: hole.midY)
        let radius = Double(hole.width) / 2
        let damagedErr = rmse(damaged)
        // 模糊填（就在用例里搭一个，避免为测试去改产品 API）：
        // 大半径高斯糊一块，再按羽化后的圆蒙版贴回去
        let maskHard = CIImage(color: .white).cropped(to: hole)
        let maskSoft = CIImage(color: .black).cropped(to: fe)
            .composited(over: maskHard)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.12])
            .cropped(to: fe)
        let blurred = damaged.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 0.5])
        let blurFill = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: damaged, kCIInputMaskImageKey: maskSoft])
        let blurErr = rmse(blurFill)
        let cloneErr = rmse(cloneAligned(damaged, points: [center],
                                         offsets: [CGPoint(x: -radius * 2, y: 0)],
                                         radius: radius, feather: 0.3, opacity: 1.0))
        let exErr = inpaintExemplar(damaged,
                                    mask: CIImage(color: .white).cropped(to: hole))
            .map { rmse($0.image) } ?? 999
        print(String(format: "  [实测] 180x180 洞（%.1f%% 图面）：挖掉后 %.1f ｜ 模糊填 %.1f ｜ 取样复制 %.1f ｜ 样例补洞 %.1f",
                     hole.width * hole.height / (fe.width * fe.height) * 100, damagedErr, blurErr, cloneErr, exErr))
        check("大面积：三种补法都不比\"不补\"更差",
              blurErr <= damagedErr + 2 && cloneErr <= damagedErr + 2,
              String(format: "挖掉 %.1f ｜ 模糊填 %.1f ｜ 取样复制 %.1f", damagedErr, blurErr, cloneErr))
    } else { print("  （夹具不可用，跳过）") }
}

// MARK: - 48. 身体塑形（收腰/宽肩）：笔刷点、蒙版、画面变化逐层量

head("48. 身体塑形：逐层定位（体检说宽肩 均值0.01/峰值0）")
do {
    // ⚠️ 夹具必须是**有身体的**整幅照：bigFace 是脸部特写，本来就检不到关节（第一版就栽在这）。
    // 婚礼照在 2604_wedding 下，loadFixture 的回落分支（root + 相对路径）能取到。
    if let img = loadFixture("2604_wedding/00_RAW_readonly/wedding_01.jpg", maxDim: 900),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let b = detectBodyPoints(cg, extent: e)
        let names: [(String, CGPoint?)] = [("左肩", b.leftShoulder), ("右肩", b.rightShoulder),
                                           ("左髋", b.leftHip), ("右髋", b.rightHip),
                                           ("左肘", b.leftElbow), ("右肘", b.rightElbow),
                                           ("左腕", b.leftWrist), ("右腕", b.rightWrist)]
        let present = names.filter { $0.1 != nil }.map { $0.0 }.joined(separator: ",")
        print("  [实测] 检出关节：" + (present.isEmpty ? "无" : present))
        // ⚠️ 别用 diffMap 判这里的强弱：它是降采样签名（96px 级），28px 半径的局部变形会被缩没，
        // 上一版就是因此得出"liquify 是空转"的错误结论。这里按**全分辨率逐像素**量峰值。
        func peakVs(_ a: CIImage, _ b2: CIImage, box: CGRect? = nil) -> Double {
            let r = box ?? e
            let n = Int(r.width), m = Int(r.height)
            func buf(_ i: CIImage) -> [UInt8] {
                var o = [UInt8](repeating: 0, count: n * m * 4)
                let c = i.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
                sharedCtx.render(c, toBitmap: &o, rowBytes: n * 4,
                                 bounds: CGRect(x: 0, y: 0, width: n, height: m),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return o
            }
            let x = buf(a), y = buf(b2)
            var mx = 0.0
            for i in 0..<(n * m) {
                for ch in 0..<3 { mx = max(mx, abs(Double(x[i * 4 + ch]) - Double(y[i * 4 + ch]))) }
            }
            return mx
        }
        if let ls = b.leftShoulder, let rs = b.rightShoulder {
            print(String(format: "  [实测] 肩宽 %.0f px｜肩线 y=%.0f（图高 %.0f，y 向上）",
                         abs(ls.x - rs.x), (ls.y + rs.y) / 2, e.height))
            let r = abs(ls.x - rs.x) * 0.16
            print(String(format: "  [实测] 宽肩笔刷：半径 %.0f px，强度 0.8", r))
            // 直接用同一组笔画做一次 liquefy，看单步有没有效果
            let strokes = [LiquifyStroke(center: ls, radius: r, strength: 0.8),
                           LiquifyStroke(center: rs, radius: r, strength: 0.8)]
            let warped = liquify(img, strokes: strokes)
            let p0 = peakVs(img, warped)
            print(String(format: "  [实测] 只做 liquify（全分辨率峰值）：%.0f 级", p0))
            check("宽肩：笔画本身有效果（liquify 这一步不是空转）", p0 > 10,
                  String(format: "全分辨率峰值 %.0f 级", p0))
            // 再走完整 reshapeBody（含蒙版）
            let full = reshapeBody(img, slimWaist: 0, wideShoulders: 80)
            let p1 = peakVs(img, full)
            // 肩部那一小块 vs 图另一侧（远离肩）：形变应该集中在肩附近
            let nearBox = CGRect(x: min(ls.x, rs.x) - 60, y: min(ls.y, rs.y) - 60, width: 240, height: 200)
            let farBox = CGRect(x: e.minX + 10, y: e.minY + 10, width: 200, height: 200)
            let pNear = peakVs(img, full, box: nearBox)
            let pFar = peakVs(img, full, box: farBox)
            print(String(format: "  [实测] reshapeBody(宽肩 80)：全图峰值 %.0f ｜ 肩附近 %.0f ｜ 远处角落 %.0f",
                         p1, pNear, pFar))
            check("宽肩：完整路径能改变肩部（蒙版没把肩部退回原图）", pNear > 10,
                  String(format: "肩附近峰值 %.0f 级（远处角落 %.0f，说明作用范围是局部的）", pNear, pFar))
        } else {
            check("宽肩：这张夹具检出了双肩", false, "没检出肩——该用例换夹具" )
        }
    } else { print("  （夹具不可用，跳过）") }
}

// MARK: - 49. CIBumpDistortion 的 scale 到底要多大（宽肩为 0 的直接嫌疑）

head("49. CIBumpDistortion 的 scale 语义")
do {
    if let img = loadFixture("2604_wedding/00_RAW_readonly/wedding_01.jpg", maxDim: 900) {
        let e = img.extent
        let c = CGPoint(x: e.midX, y: e.midY)
        for scale in [0.4, 5.0, 50.0, 200.0] {
            let out = img.applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: c.x, y: c.y),
                kCIInputRadiusKey: 28.0, kCIInputScaleKey: scale])
            let m = diffMap(img, out)
            print(String(format: "  [实测] CIBumpDistortion scale=%.1f radius=28：峰值 %.0f", scale, m.maxValue))
        }
        // 对照：手动液化用的 warp 内核那套（WarpStroke + 内核）
        let ws = [WarpStroke(mode: .expand, center: c, radius: 28, strength: 0.8, density: 0.6)]
        let k = applyLiquify(img, strokes: ws)
        let mk = diffMap(img, k)
        print(String(format: "  [实测] warp 内核路径（同参数）：峰值 %.0f", mk.maxValue))
    } else { print("  （夹具不可用，跳过）") }
}
print("")
print("通过 " + String(nPass) + " 项，未通过 " + String(nFail) + " 项")
}
