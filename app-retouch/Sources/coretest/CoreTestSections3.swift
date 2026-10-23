// CoreTestSections3.swift：coretest 的第 17~24 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections3() {
/// 色调均匀度：区域内低频（大半径模糊）的稳健标准差 = (p90-p10)/2.56。
/// 量的是**整张脸**（不是小方块）：小区域的边界效应会把任何度量都搅浑。


if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let geos = detectFaceGeos(cg, size: img.extent.size)
    if let g = geos.first {
        let e = img.extent
        let face = g.box
        // 测点必须落在**真皮肤**上：脸框里还有眼睛/眉毛/头发，它们的高频不受磨皮影响，
        // 用整个脸框当分母会把「只磨皮肤」的改进稀释掉（换成肤色掩膜后这里从 46% 变成 85% 就是被稀释的）。
        // 做法：沿脸的中轴采样若干点，取肤色掩膜值最高的那个当测点。
        // 探针要用**实际被 applySkin 使用的那张掩膜**（bestSkinMask：解析优先、肤色兜底），
        // 否则会挑到一个「解析掩膜判定不是皮肤」的点，两个版本都测不出变化
        let skinProbe = bestSkinMask(img, face: g)
        var best = (CGPoint(x: face.midX, y: face.midY), -1.0)
        for fy in stride(from: 0.15, through: 0.60, by: 0.05) {
            for fx in [0.30, 0.5, 0.70] {
                let pt = CGPoint(x: face.minX + face.width * fx, y: face.minY + face.height * fy)
                let v = maskValue(skinProbe, at: pt)
                if v > best.1 { best = (pt, v) }
            }
        }
        let inner = CGRect(x: best.0.x - face.width * 0.10, y: best.0.y - face.height * 0.08,
                           width: face.width * 0.20, height: face.height * 0.16)
        print("  测点 (皮肤掩膜值 " + fmt(best.1, 2) + ")：" + String(Int(best.0.x)) + "," + String(Int(best.0.y)))
        let baseDetail = detailP95(img, region: inner, radius: 2)
        let baseTone = toneSpread(img, region: face, radius: 30)
        var keep = SkinOptions(); keep.grade = "strong"; keep.texturePreserve = true
        var blur = SkinOptions(); blur.grade = "strong"; blur.texturePreserve = false
        let a = applySkin(img, keep), b = applySkin(img, blur)
        let aD = detailP95(a, region: inner, radius: 2), bD = detailP95(b, region: inner, radius: 2)
        let aT = toneSpread(a, region: face, radius: 30), bT = toneSpread(b, region: face, radius: 30)
        print("  脸内细节量(p95)：原图 " + fmt(baseDetail, 2) + "｜保毛孔 " + fmt(aD, 2) + "｜线性柔化 " + fmt(bD, 2))
        print("  测点区平均变化：保毛孔 " + fmt(diffMap(img, a).avg(in: inner), 5)
              + "｜线性柔化 " + fmt(diffMap(img, b).avg(in: inner), 5)
              + "｜全图 " + fmt(diffMap(img, b).total, 5))
        _ = toneSpread
        print("  脸内色调离散：  原图 " + fmt(baseTone, 2) + "｜保毛孔 " + fmt(aT, 2) + "｜线性柔化 " + fmt(bT, 2))
        // 判据用「相对关系」而不是绝对阈值：细节量 p95 在 0~255 上量化得很粗（4 / 3 / 2 这种整数），
        // 卡「必须保留 85%」会随取样点抖动
        check("保毛孔磨皮｜纹理保留更好", aD > bD * 1.3 && aD <= baseDetail,
              "保毛孔保留 " + fmt(aD / max(baseDetail, 0.001) * 100, 0) + "% 细节，线性柔化保留 " + fmt(bD / max(baseDetail, 0.001) * 100, 0) + "%")
        check("保毛孔磨皮｜色调确实被抹匀", aT < baseTone,
              "色调离散 " + fmt(baseTone, 2) + " → " + fmt(aT, 2))
        check("保毛孔磨皮｜不越界", diffMap(img, a).avg(in: CGRect(x: 0, y: 0, width: e.width, height: max(1, face.minY - face.height * 1.1)))
              < diffMap(img, a).avg(in: face) * 0.5,
              "脸区变化密度 " + fmt(diffMap(img, a).avg(in: face), 6) + " vs 脸区之外 " + fmt(diffMap(img, a).avg(in: CGRect(x: 0, y: 0, width: e.width, height: max(1, face.minY - face.height * 1.1))), 6))
        // 肤色统一：测出来的暖冷应该更接近目标
        let rect = face
        let before = measure(img.cropped(to: rect), work: 128).warmHi
        var uni = SkinOptions(); uni.unifyTone = true; uni.deltaWarm = before + 12
        let c = applySkin(img, uni)
        let after = measure(c.cropped(to: rect), work: 128).warmHi
        check("肤色统一朝目标靠拢", abs(after - (before + 12)) < abs(before - (before + 12)),
              "脸区暖冷 " + fmt(before, 2) + " → " + fmt(after, 2) + "（目标 " + fmt(before + 12, 2) + "）")
    }
}


head("6c. 手部 / 脚部（区域柔化）")
if let img = loadFixture(handImg, maxDim: 1000), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let rects = footRects(cg, extent: img.extent)
    let out = smoothFeet(img, strength: 70)
    check("脚部美化接口可用", renderable(out), "脚部区域 " + String(rects.count) + " 块（该素材人体姿态脚踝检出 " + String(rects.count) + "，为 0 时原图返回）")
}

// MARK: - 6d. 导出设置（格式 / 长边 / 位深 / 水印 / 重命名）


head("6d. 导出设置")
do {
    let tmp = "/tmp/probe/export"
    try? FileManager.default.removeItem(atPath: tmp)
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    check("重命名模板", exportName("{date}_{name}_{seq}", source: "/a/DSC001.jpg", index: 7).hasSuffix("DSC001_007"),
          exportName("{date}_{name}_{seq}", source: "/a/DSC001.jpg", index: 7))
    guard let img = loadFixture(bigFace, maxDim: 900) else { exit(1) }
    func size(_ p: String) -> (Int, Int, Int) {
        guard let s2 = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let im = CGImageSourceCreateImageAtIndex(s2, 0, nil) else { return (0, 0, 0) }
        return (im.width, im.height, im.bitsPerComponent)
    }
    var js = ExportSettings()
    js.maxLongEdge = 600
    let jp = tmp + "/a.jpg"
    let okJ = exportImage(img, to: URL(fileURLWithPath: jp), js)
    let (jw, jh, _) = size(jp)
    check("JPEG 导出 + 长边缩放", okJ && max(jw, jh) == 600, "输出 " + String(jw) + "x" + String(jh) + "（要求长边 600）")

    var ts = ExportSettings(); ts.format = "tiff"; ts.bitDepth = 16
    let tp = tmp + "/a.tif"
    let okT = exportImage(img, to: URL(fileURLWithPath: tp), ts)
    let (tw, th, tb) = size(tp)
    check("16bit TIFF 导出", okT && tb == 16, "输出 " + String(tw) + "x" + String(th) + "，位深 " + String(tb) + "（要求 16）")

    var ps = ExportSettings(); ps.format = "png"
    let pp = tmp + "/a.png"
    check("PNG 导出", exportImage(img, to: URL(fileURLWithPath: pp), ps),
          (try? FileManager.default.attributesOfItem(atPath: pp)[.size] as? Int).map { String($0) + " 字节" } ?? "无")

    var ws = ExportSettings()
    ws.watermarkText = "ContentRetouch {name}"
    let wp = tmp + "/wm.jpg"
    let okW = exportImage(applyWatermark(img, ws, sourceName: "x"), to: URL(fileURLWithPath: wp), ws)
    let (ww, wh, _) = size(wp)
    check("水印导出", okW && ww > 0, "输出 " + String(ww) + "x" + String(wh))

    // LOGO（图片）水印：合成一张带透明通道的 PNG，贴上去后必须能在右下角看到
    let logoPath = "/tmp/probe/logo_test.png"
    do {
        let W = 160, H = 60
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
        ctx.clear(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 15, width: 120, height: 30))
        if let cg2 = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: logoPath) as CFURL,
                                                      "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg2, nil)
            CGImageDestinationFinalize(dest)
        }
    }
    var ls = ExportSettings()
    ls.watermarkImagePath = logoPath
    ls.watermarkImageScale = 0.2
    let withLogo = applyWatermark(img, ls, sourceName: "x")
    let lm = diffMap(img, withLogo)
    let lc = lm.centroid
    // 默认位置是右下角：质心应该落在「右半边 + 下半边」
    let logoOK = lm.maxValue > 0.05 && lc.x > img.extent.width * 0.5 && lc.y < img.extent.height * 0.5
    check("LOGO 图片水印", FileManager.default.fileExists(atPath: logoPath) && logoOK,
          String(format: "变化质心 (%.0f,%.0f)（右下角区域），峰值 %.3f", lc.x, lc.y, lm.maxValue))

    // 「配了 LOGO 但用不了」必须能被**说出口**，而不是静默不打水印（§177）。
    // 三态都要验：正常 → nil（不该误报）；文件不存在 → 有话说；没配水印 → nil（不该误报）。
    var lsBad = ExportSettings()
    lsBad.watermarkImagePath = "/tmp/definitely_no_such_logo_zzz.png"
    let tBad = watermarkTrouble(lsBad)
    let tGood = watermarkTrouble(ls)
    let tNone = watermarkTrouble(ExportSettings())
    check("水印配了但用不了会说出口（且不误报）",
          tBad != nil && tGood == nil && tNone == nil,
          "文件不存在 → " + (tBad == nil ? "**没说话（错）**" : "有提示 ✓")
          + "｜正常 LOGO → " + (tGood == nil ? "nil ✓" : "**误报（错）**")
          + "｜没配水印 → " + (tNone == nil ? "nil ✓" : "**误报（错）**"))

    // 水印落点：和没水印的对比，变化必须集中在右下角
    let noW = ExportSettings()
    let base = applyWatermark(img, noW, sourceName: "x")
    let withW = applyWatermark(img, ws, sourceName: "x")
    let m = diffMap(base, withW)
    let e = base.extent
    let c = m.centroid
    let inCorner = c.x > e.width * 0.4 && c.y < e.height * 0.5
    check("水印落点在右下角", m.maxValue > 0.05 && inCorner,
          "变化质心(" + String(Int(c.x)) + "," + String(Int(c.y)) + ") 图 " + String(Int(e.width)) + "x" + String(Int(e.height)) + "，峰值 " + fmt(m.maxValue, 3))

    // 色彩空间：DisplayP3 导出必须真的标上 P3
    var p3 = ExportSettings(); p3.colorSpace = "DisplayP3"
    let p3p = tmp + "/p3.jpg"
    _ = exportImage(img, to: URL(fileURLWithPath: p3p), p3)
    var p3name = "无"
    if let src2 = CGImageSourceCreateWithURL(URL(fileURLWithPath: p3p) as CFURL, nil),
       let im = CGImageSourceCreateImageAtIndex(src2, 0, nil), let cs = im.colorSpace {
        p3name = String(describing: cs.name ?? "?" as CFString)
    }
    check("DisplayP3 色彩空间", p3name.contains("P3"), "导出色彩空间 " + p3name)

    // 批量导出 + 并行与串行的结果一致性
    let files = [bigFace].compactMap { n -> String? in
        for d in libDirs { let q = root + "/" + d + "/" + n; if FileManager.default.fileExists(atPath: q) { return q } }
        return nil
    }
    if !files.isEmpty {
        let t0 = Date()
        let r1 = exportBatch(files: files, outDir: tmp + "/b1", js, makeImage: { loadImage($0, maxDim: 0) }, workers: 1)
        let d1 = Date().timeIntervalSince(t0)
        let r2 = exportBatch(files: files, outDir: tmp + "/b2", js, makeImage: { loadImage($0, maxDim: 0) }, workers: 4)
        check("批量导出（串行/并行都成）", r1.written == files.count && r2.written == files.count,
              "串行 " + String(r1.written) + " 张 " + fmt(d1, 2) + " s｜并行 4 " + String(r2.written) + " 张 " + fmt(r2.seconds, 2) + " s")
    }
}

// MARK: - 6e1. 镜头校正（畸变 / 暗角 / 色差）与透视校正
//
// 判据都是「造一个人为畸变 → 校正 → 看量化指标是否回落」，
// 而不是「跑通了没报错」这种不算验证的验证。


head("6e1. 镜头校正与透视校正")
do {
    let W = 400, H = 400
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
    func gridImage(_ step: Int, vertical: Bool) -> CIImage {
        var img = CIImage(color: .black).cropped(to: canvas)
        for p in stride(from: step, to: (vertical ? W : H), by: step) {
            let r = vertical ? CGRect(x: CGFloat(p), y: 0, width: 2, height: CGFloat(H))
                             : CGRect(x: 0, y: CGFloat(p), width: CGFloat(W), height: 2)
            img = CIImage(color: .white).cropped(to: r).composited(over: img)
        }
        return img
    }
    /// 沿一条扫描线找亮线起点的位置
    func lineStarts(_ img: CIImage, _ at: CGFloat, vertical: Bool) -> [Int] {
        let n = vertical ? W : H
        var buf = [UInt8](repeating: 0, count: n * 4)
        let rect = vertical ? CGRect(x: 0, y: at, width: CGFloat(W), height: 1)
                            : CGRect(x: at, y: 0, width: 1, height: CGFloat(H))
        sharedCtx.render(img, toBitmap: &buf, rowBytes: vertical ? W * 4 : 4, bounds: rect, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var out: [Int] = []
        var inLine = false
        for i in 0..<n {
            let v = Double(buf[i * 4])
            if v > 160 && !inLine { inLine = true; out.append(i) }
            if v <= 160 { inLine = false }
        }
        return out
    }
    func spacingStd(_ pos: [Int]) -> Double {
        guard pos.count >= 3 else { return 999 }
        var gaps: [Double] = []
        for i in 1..<pos.count { gaps.append(Double(pos[i] - pos[i - 1])) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        return (gaps.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gaps.count)).squareRoot()
    }
    func meanLuma(_ img: CIImage, _ r: CGRect) -> Double {
        var buf = [UInt8](repeating: 0, count: Int(r.width) * Int(r.height) * 4)
        sharedCtx.render(img, toBitmap: &buf, rowBytes: Int(r.width) * 4, bounds: r, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var t = 0.0
        for i in 0..<(Int(r.width) * Int(r.height)) { t += Double(buf[i * 4]) }
        return t / Double(Int(r.width) * Int(r.height))
    }

    // 1) 畸变：人为桶形 → 校正后线距应该变均匀
    let gv = gridImage(40, vertical: true)
    let barrel = gv.applyingFilter("CIPinchDistortion", parameters: [
        kCIInputCenterKey: CIVector(x: 200, y: 200), kCIInputRadiusKey: 220.0, kCIInputScaleKey: -0.6])
    let distortedStd = spacingStd(lineStarts(barrel, 200, vertical: true))
    let fixedStd = spacingStd(lineStarts(correctLensDistortion(barrel, amount: 60), 200, vertical: true))
    check("镜头畸变校正", distortedStd > 5 && fixedStd < distortedStd * 0.4,
          "线距标准差 " + fmt(distortedStd, 2) + " → " + fmt(fixedStd, 2) + "（原图 0.00）")

    // 2) 暗角：人为压暗四角 → 校正后角/中差应显著变小
    let flat = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: canvas)
    let vig = vignette(flat, amount: 80)
    let corner0 = meanLuma(vig, CGRect(x: 10, y: 10, width: 40, height: 40))
    let center = meanLuma(vig, CGRect(x: 180, y: 180, width: 40, height: 40))
    let fixedVig = correctVignetting(vig, amount: 80)
    let corner1 = meanLuma(fixedVig, CGRect(x: 10, y: 10, width: 40, height: 40))
    check("镜头暗角校正", (center - corner0) > 15 && (center - corner1) < (center - corner0) * 0.3,
          "角/中差 " + fmt(center - corner0, 1) + " → " + fmt(center - corner1, 1))

    // 3) 色差：人为把 R/B 反向缩放 → 校正后边缘的 R-B 差应回落
    let edge = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: CGFloat(H)))
        .composited(over: CIImage(color: .black).cropped(to: canvas))
    func chan(_ i: CIImage, _ r: Double, _ g: Double, _ b: Double) -> CIImage {
        i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
    func scaleAbout(_ i: CIImage, _ sc: Double) -> CIImage {
        let t = CGAffineTransform(translationX: 200, y: 200).scaledBy(x: CGFloat(sc), y: CGFloat(sc)).translatedBy(x: -200, y: -200)
        return i.transformed(by: t).cropped(to: canvas)
    }
    let ca = scaleAbout(chan(edge, 1, 0, 0), 1.02)
        .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: chan(edge, 0, 1, 0)])
        .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaleAbout(chan(edge, 0, 0, 1), 0.98)])
        .cropped(to: canvas)
    func fringe(_ img: CIImage) -> Double {
        var buf = [UInt8](repeating: 0, count: W * 4)
        sharedCtx.render(img, toBitmap: &buf, rowBytes: W * 4, bounds: CGRect(x: 0, y: 200, width: CGFloat(W), height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var t = 0.0
        for i in 0..<W { t += abs(Double(buf[i * 4]) - Double(buf[i * 4 + 2])) }
        return t / Double(W)
    }
    let f0 = fringe(ca), f1 = fringe(correctChromaticAberration(ca, amount: 100))
    check("横向色差校正", f0 > 1.0 && f1 < f0 * 0.5,
          "边缘 R-B 平均差 " + fmt(f0, 3) + " → " + fmt(f1, 3) + "（理想 0.000）")

    // 4) 透视：人为垂直梯形 → 上下竖线错位应回落
    let g = gridImage(40, vertical: true)
    func keystoneMisalign(_ img: CIImage) -> Double {
        let top = lineStarts(img, 370, vertical: true), bot = lineStarts(img, 30, vertical: true)
        let n = min(top.count, bot.count)
        guard n >= 3 else { return 999 }
        var t = 0.0
        for i in 0..<n { t += abs(Double(top[i] - bot[i])) }
        return t / Double(n)
    }
    let key = perspectiveCorrect(g, horizontal: 0, vertical: -70)
    let m0 = keystoneMisalign(key), m1 = keystoneMisalign(perspectiveCorrect(key, horizontal: 0, vertical: 70))
    check("透视（垂直梯形）校正", m0 > 3 && m1 < m0 * 0.3,
          "上下竖线错位 " + fmt(m0, 1) + " px → " + fmt(m1, 1) + " px（原图 0.0）")
}

// MARK: - 6e2. 手动液化（向前变形 / 旋转 / 冻结 / 重建）


head("6e2. 手动液化完整工具集")
do {
    let W = 300, H = 300
    let bar = CGRect(x: 140, y: 0, width: 20, height: CGFloat(H))
    let base = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85))
        .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    let img = CIImage(color: .black).cropped(to: bar).composited(over: base)
    func boundaryX(_ im: CIImage, _ y: CGFloat) -> Int {
        var buf = [UInt8](repeating: 0, count: W * 4)
        sharedCtx.render(im, toBitmap: &buf, rowBytes: W * 4,
                         bounds: CGRect(x: 0, y: y, width: CGFloat(W), height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for x in 0..<W { if buf[x * 4] < 128 { return x } }
        return W
    }
    let center = CGPoint(x: 150, y: 150)
    let before = boundaryX(img, 150)
    let pushed = applyLiquify(img, strokes: [WarpStroke(mode: .push, center: center, radius: 50,
                                                        delta: CGPoint(x: 14, y: 0))])
    let after = boundaryX(pushed, 150)
    let far = boundaryX(pushed, 20)
    let m = diffMap(img, pushed)
    check("向前变形：方向与落点", after > before + 4 && far == before && hypot(m.centroid.x - center.x, m.centroid.y - center.y) < 25,
          "竖条边界 " + String(before) + " → " + String(after) + "（变形区外仍 " + String(far) + "），变化质心距笔刷 "
          + fmt(hypot(m.centroid.x - center.x, m.centroid.y - center.y), 1) + " px")

    let frozen = applyLiquify(img, strokes: [WarpStroke(mode: .push, center: center, radius: 50,
                                                        delta: CGPoint(x: 14, y: 0))],
                              freeze: [WarpStroke(mode: .freeze, center: center, radius: 55)])
    check("冻结区被锁住", diffMap(img, frozen).maxValue < 0.02,
          "冻结半径 55 覆盖整个笔刷后，最大变化 " + fmt(diffMap(img, frozen).maxValue, 4))

    let twirled = applyLiquify(img, strokes: [WarpStroke(mode: .twirl, center: center, radius: 50, strength: 1.0)])
    let tm = diffMap(img, twirled)
    check("旋转：落点在笔刷处", tm.maxValue > 0.05 && hypot(tm.centroid.x - center.x, tm.centroid.y - center.y) < 30,
          "峰值 " + fmt(tm.maxValue, 3) + " 质心距笔刷 " + fmt(hypot(tm.centroid.x - center.x, tm.centroid.y - center.y), 1) + " px")

    // 左推：把笔画方向的左侧当位移方向（竖条应该往左走）
    let leftPushed = applyLiquify(img, strokes: [WarpStroke(mode: .pushLeft, center: center, radius: 50,
                                                            delta: CGPoint(x: 0, y: 12), strength: 1.0)])
    let afterLeft = boundaryX(leftPushed, 150)
    check("左推：方向正确", afterLeft < before - 3,
          "竖条左边界 " + String(before) + " → " + String(afterLeft) + "（期望更左）")

    // 平滑：笔刷区内的高频细节应该被压掉，区外不动
    var noisy = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        .cropped(to: CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)))
    for i in stride(from: 10, to: W, by: 7) {
        noisy = CIImage(color: .white).cropped(to: CGRect(x: CGFloat(i), y: 0, width: 1, height: CGFloat(H)))
            .composited(over: noisy)
    }
    let smoothed = applyLiquify(noisy, strokes: [WarpStroke(mode: .smooth, center: center, radius: 45,
                                                            strength: 1.0)])
    let sm = diffMap(noisy, smoothed)
    let inBrush = sm.avg(in: CGRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80))
    let outBrush = sm.avg(in: CGRect(x: 10, y: 10, width: 60, height: 60))
    check("平滑：只抹平笔刷区", inBrush > 0.02 && outBrush < 0.001,
          "笔刷区内变化密度 " + fmt(inBrush, 4) + " vs 笔刷区外 " + fmt(outBrush, 5))

    // 重建：界面上的「重建一笔 / 重建一半」就是把笔画列表截短再重放（无状态、可预期）
    let twoStrokes = [WarpStroke(mode: .push, center: center, radius: 50, delta: CGPoint(x: 14, y: 0)),
                      WarpStroke(mode: .push, center: CGPoint(x: 150, y: 160), radius: 50, delta: CGPoint(x: 14, y: 0))]
    let full = applyLiquify(img, strokes: twoStrokes)
    let half = applyLiquify(img, strokes: Array(twoStrokes.prefix(1)))
    let none = applyLiquify(img, strokes: [])
    let dFull = diffMap(img, full).total, dHalf = diffMap(img, half).total, dNone = diffMap(img, none).total
    check("重建：截短笔画＝逐步回退", dFull > dHalf && dHalf > 0 && dNone < 1e-9,
          "两笔变化 " + fmt(dFull, 5) + " > 一笔 " + fmt(dHalf, 5) + " > 全清 " + fmt(dNone, 5))
}

// MARK: - 6e. 后调色补充（锐化/降噪/暗角/颗粒/补光/背景虚化/边缘优化）


head("6e. 后调色补充工具")
if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let e = img.extent
    let face = detectFaceGeos(cg, size: e.size).first?.box ?? CGRect(x: e.width * 0.2, y: e.height * 0.2, width: e.width * 0.5, height: e.height * 0.5)
    let cases: [(String, (CIImage) -> CIImage, Double)] = [
        ("锐化", { sharpen($0, amount: 80) }, 0.01),
        ("降噪", { denoise($0, amount: 80) }, 0.001),
        ("暗角", { vignette($0, amount: 80) }, 0.02),
        ("颗粒", { grain($0, amount: 80) }, 0.005),
        ("补光", { addLight($0, strength: 80, at: CGPoint(x: e.midX, y: e.minY + e.height * 0.68), radiusRatio: 0.75) }, 0.01)
    ]
    for (name, f, peak) in cases {
        let m = diffMap(img, f(img))
        check(name + "有效果且能出图", m.maxValue > peak && renderable(f(img)),
              "峰值 " + fmt(m.maxValue, 4) + " 全图均值 " + fmt(m.total, 6))
    }
    // 背景虚化：背景必须变、主体必须几乎不动
    if foregroundMask(img) != nil {
        let out = backgroundBlur(img, radius: 24, strength: 80)
        let m = diffMap(img, out)
        let inFace = m.avg(in: face.insetBy(dx: face.width * 0.2, dy: face.height * 0.2))
        let far = CGRect(x: 0, y: 0, width: e.width, height: max(1, face.minY - face.height))
        let inFar = m.avg(in: far)
        check("背景虚化：背景变、主体不动", inFar > inFace * 3 && m.maxValue > 0.02,
              "脸区变化密度 " + fmt(inFace, 6) + " vs 远处背景 " + fmt(inFar, 6) + "（" + fmt(inFar / max(inFace, 1e-9), 1) + " 倍）")
    }
}

// MARK: - 6f. 系统 AI 能力面：显著性 / 场景识别 / 智能裁剪 / 人物实例


head("6f. 显著性 / 场景识别 / 智能裁剪 / 人物实例")
do {
    guard let wImg = loadFixture(wedding, maxDim: 900),
          let wCG = sharedCtx.createCGImage(wImg, from: wImg.extent) else { exit(1) }
    let size = wImg.extent.size
    let faces = detectFaceGeos(wCG, size: size)

    // 1) 显著性：主体框应当把人都装进去，且不是整幅
    if let sal = detectSaliency(wCG) {
        let box = sal.subject
        let allIn = faces.allSatisfy { box.contains(CGPoint(x: $0.box.midX / size.width, y: $0.box.midY / size.height)) }
        check("显著性主体框", box.width > 0.2 && box.width < 0.99 && allIn,
              String(format: "主体框 x%.2f y%.2f w%.2f h%.2f 置信度 %.2f，%d 张脸全在框内：%@",
                     box.minX, box.minY, box.width, box.height, sal.confidence, faces.count, allIn ? "是" : "否"))
    } else { check("显著性主体框", false, "API 不可用") }

    // 2) 场景识别
    let sceneCases: [(String, String, String)] = [("婚礼双人", wedding, "婚礼"), ("大脸人像", bigFace, "人像")]
    for (label, rel, expect) in sceneCases {
        guard let img = loadFixture(rel, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let info = classifyScene(cg)
        let ok = info.category.contains(expect) || (expect == "人像" && info.category == "多人合影")
        check("场景识别 " + label, ok,
              "判为「" + info.category + "」（期望含「" + expect + "」）｜脸 " + String(info.faces)
              + " 人 " + String(info.people) + " 动物 " + String(info.animals)
              + " ｜标签 " + info.labels.prefix(4).map { $0.0 }.joined(separator: "/")
              + " ｜依据 " + info.reasons.joined(separator: "；"))
    }
    if let petImg = loadFixture(animalImg, maxDim: 900), let petCG = sharedCtx.createCGImage(petImg, from: petImg.extent) {
        let info = classifyScene(petCG)
        check("场景识别 宠物照", info.category == "宠物",
              "判为「" + info.category + "」｜动物 " + String(info.animals) + "｜依据 " + info.reasons.joined(separator: "；"))
    }

    // 3) 场景 → 推荐参数
    let humanScene = classifyScene(wCG)
    let sug = suggestParams(for: humanScene)
    let sugScenic = suggestParams(for: SceneInfo(category: "风光/场景"))
    check("场景推荐参数", sug.portrait.anyEnabled && sug.extras.count > 0 && !sugScenic.portrait.anyEnabled,
          humanScene.category + "：人像参数生效 " + String(sug.portrait.anyEnabled)
          + "、影调 " + String(sug.extras.count) + " 项；风光类人像参数为空 " + String(!sugScenic.portrait.anyEnabled))

    // 4) 智能裁剪：合成判据（主体在 0.72/0.72，裁完应落在三分线且完整）
    let canvasSize = CGSize(width: 1000, height: 1000)
    let subject = CGRect(x: 0.66, y: 0.66, width: 0.12, height: 0.12)
    let rect = smartCropRect(imageSize: canvasSize, aspect: 1.0, subject: subject, placement: "thirds")
    let nx = (Double(subject.midX) * 1000 - Double(rect.minX)) / Double(rect.width)
    let ny = (Double(subject.midY) * 1000 - Double(rect.minY)) / Double(rect.height)
    let inside = rect.contains(CGRect(x: subject.minX * 1000, y: subject.minY * 1000,
                                      width: subject.width * 1000, height: subject.height * 1000))
    check("智能裁剪（三分法落点）", inside && abs(nx - 2.0 / 3.0) < 0.12 && abs(ny - 2.0 / 3.0) < 0.12,
          String(format: "裁剪框 %dx%d，主体落在框内 (%d%%, %d%%)（目标 67%%, 67%%）",
                 Int(rect.width), Int(rect.height), Int(nx * 100), Int(ny * 100)))
    let rectC = smartCropRect(imageSize: canvasSize, aspect: 16.0 / 9.0, subject: subject, placement: "center")
    // 注意：subject 是归一化坐标，裁剪框是像素坐标 —— 两边别混（第一版就混了，判定全错）
    let subjectPx = CGRect(x: subject.minX * 1000, y: subject.minY * 1000,
                           width: subject.width * 1000, height: subject.height * 1000)
    check("智能裁剪（比例与居中）", abs(Double(rectC.width / rectC.height) - 16.0 / 9.0) < 0.02 && rectC.contains(subjectPx),
          String(format: "16:9 裁剪框 %dx%d，宽高比 %.3f",
                 Int(rectC.width), Int(rectC.height), Double(rectC.width / rectC.height)))

    // 4b) 非方形画布：归一化 w/h 不是同一个单位，比例必须按像素算（这条正是第一次漏掉的情形）
    let tall = CGSize(width: 1080, height: 1620)
    let tallSubject = CGRect(x: 0.10, y: 0.29, width: 0.79, height: 0.69)
    let sq = smartCropRect(imageSize: tall, aspect: 1.0, subject: tallSubject, placement: "center")
    let wide = smartCropRect(imageSize: tall, aspect: 16.0 / 9.0, subject: tallSubject, placement: "center")
    check("智能裁剪（竖幅上要 1:1）", abs(Double(sq.width - sq.height)) < 2 && sq.width <= 1080.5 && sq.height <= 1620.5,
          String(format: "1080x1620 上裁出 %dx%d（宽高差 %.1f）", Int(sq.width), Int(sq.height), Double(sq.width - sq.height)))
    check("智能裁剪（竖幅上要 16:9）", abs(Double(wide.width / wide.height) - 16.0 / 9.0) < 0.02,
          String(format: "裁出 %dx%d，宽高比 %.3f（目标 1.778）", Int(wide.width), Int(wide.height), Double(wide.width / wide.height)))

    // 4c) 肩线倾角：真人图应该给一个角度；人为旋转后角度应随之变化
    if let tilt = shoulderTilt(wCG, extent: wImg.extent) {
        let rotated = wImg.transformed(by: CGAffineTransform(rotationAngle: 8 * .pi / 180))
        let rCG = sharedCtx.createCGImage(rotated, from: rotated.extent)
        let tilt2 = rCG.flatMap { shoulderTilt($0, extent: rotated.extent) }
        check("肩线倾角测量", abs(tilt) < 45 && tilt2 != nil && abs((tilt2! - tilt) - 8) < 6,
              String(format: "原图 %.1f°，整体旋转 8° 后 %.1f°（期望相差约 8°）", tilt, tilt2 ?? 0))
    } else {
        check("肩线倾角测量", false, "这张图没检出双肩")
    }

    // 4d) 按人分别处理：同图给两个人不同磨皮强度，各自区域变化应该差开
    do {
        let persons2 = personInstanceMasks(wImg)
        if persons2.count >= 2 {
            var o = SkinOptions(); o.grade = "strong"; o.texturePreserve = true
            let out = applySkinPerPerson(wImg, o, persons: persons2, strengths: [90, 10])
            let dm = diffMap(wImg, out)
            let a = dm.avg(in: persons2[0].rect.insetBy(dx: persons2[0].rect.width * 0.2, dy: persons2[0].rect.height * 0.2))
            let b = dm.avg(in: persons2[1].rect.insetBy(dx: persons2[1].rect.width * 0.2, dy: persons2[1].rect.height * 0.2))
            check("按人分别处理（强度可不同）", renderable(out) && a > b * 1.5,
                  String(format: "强 90 的人区变化 %.5f vs 弱 10 的人区 %.5f（%.1f 倍）", a, b, a / max(b, 1e-9)))
            // 有脸门控时：变化必须只在脸上，不能糊到衣服（实例掩膜是「整个人」）
            let gated = applySkinPerPerson(wImg, o, persons: persons2, strengths: [90, 10],
                                           faceBoxes: faces.map { $0.box })
            let gm = diffMap(wImg, gated)
            var faceSum = 0.0
            for f in faces { faceSum += gm.avg(in: f.box.insetBy(dx: -10, dy: -10)) }
            let faceAvg = faceSum / Double(max(1, faces.count))
            // 衣服区：取第一个人包围盒的下半部分，避开脸
            let r0 = persons2[0].rect
            let cloth = CGRect(x: r0.minX, y: r0.minY, width: r0.width, height: r0.height * 0.35)
            let clothAvg = gm.avg(in: cloth)
            check("按人磨皮只作用在脸上", faceAvg > clothAvg * 3 && gm.maxValue > 0.01,
                  String(format: "脸区变化 %.5f vs 衣服区 %.5f（%.1f 倍）", faceAvg, clothAvg, faceAvg / max(clothAvg, 1e-9)))
        } else {
            check("按人分别处理（强度可不同）", false, "没分出两个人")
        }
    }

    // 5) 人物实例：婚礼双人应分出 2 个实例，互不重叠、左右分明
    let persons = personInstanceMasks(wImg)
    if persons.count >= 2 {
        // 用 maskCoverage（内部会把掩膜缩到小图再采样）：直接 render 小尺寸只会采到原图左下角
        let ma = maskCoverage(persons[0].mask, in: wImg.extent)
        let mb = maskCoverage(persons[1].mask, in: wImg.extent)
        let overlap = persons[0].mask.applyingFilter("CIMultiplyBlendMode",
                                                     parameters: [kCIInputBackgroundImageKey: persons[1].mask])
        let mo = maskCoverage(overlap, in: wImg.extent)
        let ca = centroidOfBright(persons[0].mask, in: wImg.extent)
        let cb = centroidOfBright(persons[1].mask, in: wImg.extent)
        let ra = persons[0].rect, rb = persons[1].rect
        let notFullImage = ra.width < wImg.extent.width * 0.95 && rb.width < wImg.extent.width * 0.95
        check("实例包围盒不是整幅图", notFullImage && ra.width > 10 && rb.width > 10,
              String(format: "人1 框 %.0fx%.0f、人2 框 %.0fx%.0f（图 %.0fx%.0f）",
                     ra.width, ra.height, rb.width, rb.height, wImg.extent.width, wImg.extent.height))
        check("人物实例分割（多人）", ma > 0.01 && mb > 0.01 && mo < min(ma, mb) * 0.35 && ca.x < cb.x,
              String(format: "分出 %d 个实例；覆盖率 %.1f%% / %.1f%%，重叠 %.2f%%；左右重心 x %.0f vs %.0f",
                     persons.count, ma * 100, mb * 100, mo * 100, ca.x, cb.x))
    } else {
        check("人物实例分割（多人）", false, "只分出 " + String(persons.count) + " 个实例")
    }
}

// MARK: - 6g. 自动/智能这一层（白平衡 / 边缘感知锐化 / 高光恢复 / 补光方向）

// MARK: - 6i. 透明素材：水印 LOGO 的 alpha 不能被丢掉
//
// 为什么单列：水印是已发布的功能，而 LOGO 最常见的格式就是**透明背景 PNG**。
// 给照片用的读图路（loadImage）位图信息是 noneSkipLast（没有 alpha），
// 拿它读 LOGO 会把透明像素当成"不透明的黑"—— 实测导出后水印区平均亮度 0.013（全黑）。
head("6i. 透明素材（水印 LOGO 的 alpha）")
do {
    let dir = NSTemporaryDirectory() + "cr_alpha_" + String(ProcessInfo.processInfo.processIdentifier)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/logo.png"
    var made = false
    // 200x200 全透明，中间 100x100 不透明红方块
    if let cs = CGColorSpace(name: CGColorSpace.sRGB),
       let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.clear(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        if let cg = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            made = CGImageDestinationFinalize(dest)
        }
    }
    if made, let img = loadImageWithAlpha(path) {
        // 取两个点：透明角（应 alpha≈0）与红方块中心（应 alpha≈255）
        func alphaAt(_ x: CGFloat, _ y: CGFloat) -> Int {
            var buf = [UInt8](repeating: 0, count: 4)
            sharedCtx.render(img, toBitmap: &buf, rowBytes: 4,
                             bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return Int(buf[3])
        }
        let aCorner = alphaAt(5, 5), aCenter = alphaAt(100, 100)
        check("透明 LOGO 的 alpha 被保留（透明角 0、方块中心不透明）",
              aCorner < 16 && aCenter > 240,
              "角 alpha=" + String(aCorner) + "（应≈0）｜ 中心 alpha=" + String(aCenter) + "（应≈255）")
    } else {
        check("透明 LOGO 的 alpha 被保留（透明角 0、方块中心不透明）", false, "夹具没造出来或读不回来")
    }
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - 6h2. 16 位精度：16bit TIFF/PNG 进来不能被悄悄压成 8bit
//
// 为什么单列：界面文案写着「16bit AI Raw 引擎」，导出也提供 8/16 位 TIFF/PNG。
// 但**导入**这条路如果写死 8 位 CGContext，16 位源片一进来就被压成 256 级 ——
// 用户"导进 16bit、导出 16bit"，中间少掉的精度是看不见的（渐变上会变成可见的台阶）。
head("6h2. 16 位精度（16bit TIFF 进来不能掉成 8bit）")
do {
    let dir = NSTemporaryDirectory() + "cr_16bit_" + String(ProcessInfo.processInfo.processIdentifier)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/grad16.tif"
    var made = false
    // 造一张 16 位灰阶渐变：横向 0→65535，纵向不变（8 位量化后只剩 ≤256 级）
    let gw = 512, gh = 16
    var px = [UInt16](repeating: 0, count: gw * gh)
    for x in 0..<gw {
        let v = UInt16(Double(x) / Double(gw - 1) * 65535.0)
        for y in 0..<gh { px[y * gw + x] = v }
    }
    if let cs = CGColorSpace(name: CGColorSpace.linearGray),
       let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 2) as CFData),
       let cg = CGImage(width: gw, height: gh, bitsPerComponent: 16, bitsPerPixel: 16,
                        bytesPerRow: gw * 2, space: cs,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                  "public.tiff" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, cg, nil)
        made = CGImageDestinationFinalize(dest)
    }
    if made, let img = loadImage(path) {
        // 数不同取值：真 16 位应当有几百到上千个不同值；被压成 8 位就只剩 ≤256
        let w = max(1, Int(img.extent.width)), h = max(1, Int(img.extent.height))
        var raw = [UInt16](repeating: 0, count: w * h)
        let fmt: CIFormat = .R16
        // ⚠️ 渲染到**线性空间**再数：sRGB 的传递函数在高光端会压掉若干级（实测同一张图在 sRGB 下
        // 只有 272 个不同值，在线性下有 500+），拿它当判据会把"其实没丢"误判成"丢了"。
        // 线性空间对传递函数不敏感：8 位必然 ≤256 个不同值，16 位能到 500 左右 —— 判据才干净。
        sharedCtx.render(img, toBitmap: &raw, rowBytes: w * 2,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: fmt,
                         colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var seen = Set<UInt16>()
        for v in raw { seen.insert(v) }
        // 判据取 256 这条线。数字是**逐段实测**的（§179 把 §174 挂着的那个"还差一半"查清了）：
        //   源位图直接读                        ：512 个   ← 夹具没问题
        //   画进 sRGB **8 位**上下文（旧行为）    ：183 个   ← 就是"被压成 8 位"的样子
        //   画进 sRGB **16 位**上下文（现在的代码）：429 个   ← 剩下的差额是 sRGB 传递函数在高光端
        //                                              本来就压级，**不是丢精度**
        //   本用例再经一次 CIContext 渲染         ：272 个   ← 又多一次色彩空间往返
        // 所以这条守的是"不能又掉回 8 位"（>256），而不是"必须等于 512"——
        // 后者本来就不是这条链路能达到的数（见账本 §174.3 与 §179）。
        check("16bit TIFF 读进来没有掉回 8 位（不同取值 >256）",
              seen.count > 256,
              "不同取值 " + String(seen.count) + " 个（8 位会是 183 上下；本链路在「读图」这一步实测 429，"
              + "再经一次 CIContext 渲染到本用例是 272 —— 判据只守「不许掉回 256 以下」）")
    } else {
        check("16bit TIFF 读进来仍是 16 位（不是被压成 8 位）", false, "夹具没造出来或读不回来")
    }
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - 6h. EXIF 方向：手机竖拍照片必须摆正
//
// 为什么单列一节：`CGImageSourceCreateImageAtIndex` **不会**应用 EXIF 方向，而本仓库另外两条读图路
// （缩略图条、导出小图）都带了 kCGImageSourceCreateThumbnailWithTransform —— 于是"缩略图是正的、
// 预览与导出却是躺倒的"。2026-09-26 实测过：400x200 + 方向 6 的图，导出仍是 400x200 且方向写成 1，
// 等于把手机竖拍的照片永久转躺。手机照片里方向 3/6/8 极常见，所以这条要一直守着。
head("6h. EXIF 方向（手机竖拍照片必须摆正）")
do {
    // 造夹具：400x200 的像素 + 方向标记 6（顺时针 90°，应显示成 200x400）
    let dir = NSTemporaryDirectory() + "cr_orient_" + String(ProcessInfo.processInfo.processIdentifier)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/rot6.jpg"
    let pw = 400, ph = 200
    var made = false
    if let cs = CGColorSpace(name: CGColorSpace.sRGB),
       let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
        ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        if let cg = ctx.makeImage(),
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
            made = CGImageDestinationFinalize(dest)
        }
    }
    if made, let img = loadImage(path) {
        let e = img.extent
        check("EXIF 方向 6 的图读进来是摆正的",
              Int(e.width) == ph && Int(e.height) == pw,
              "读到 " + String(Int(e.width)) + "x" + String(Int(e.height))
              + "（期望 " + String(ph) + "x" + String(pw) + "；方向没应用就会读成 "
              + String(pw) + "x" + String(ph) + "）")
    } else {
        check("EXIF 方向 6 的图读进来是摆正的", false, "夹具没造出来或读不回来")
    }
    try? FileManager.default.removeItem(atPath: dir)
}

}
