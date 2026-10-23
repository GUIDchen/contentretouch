// Audits.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 96 宽缩图的像素缓冲：整幅平均对**局部**改动几乎不动，缩图逐像素比才看得见（第 140 节）。
    /// 掩膜降采样的**视觉等价性检查**：同一组参数、只在"掩膜在多大分辨率上算"这一项上不同（cap=0 是旧行为），
/// 画面差多少。用来证明 §169 那个提速没有改画面 —— 门里的判据是"最大差 ≤2 级"。
/// 触发：CR_MASKREDUCE=1（配合 CR_IMPORT；--zoom=400 能看到降采样真正生效的那一档）。
func auditMaskReduce() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard let img = workImage() else { emit("MASKREDUCE 没有工作图（先 CR_IMPORT 一张）"); return }
    // 512px：auditSmall 那种 96px 会把局部的掩膜差异摊平，判不出"最大差"（这是判据，不是缩略图）
    let w = 512
    func sample(_ ci: CIImage) -> [UInt8] {
        let e = ci.extent
        let h = max(1, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let sx = CGFloat(w) / max(1, e.width)
        let scaled = ci.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    let saved = skinMaskWorkMax
    autoSkinAmount = 80
    skinMaskWorkMax = 0                       // 旧行为：掩膜按全分辨率算
    let a = sample(renderPipeline(img, geos: cachedGeos))
    skinMaskWorkMax = saved                   // 新行为：降采样算、再放大回去
    let b = sample(renderPipeline(img, geos: cachedGeos))
    autoSkinAmount = 0
    var mx = 0, sum = 0.0
    let n = min(a.count, b.count) / 4
    for i in 0..<n {
        var d = 0
        for c in 0..<3 { d = max(d, abs(Int(a[i * 4 + c]) - Int(b[i * 4 + c]))) }
        if d > mx { mx = d }
        sum += Double(d)
    }
    emit(String(format: "MASKREDUCE-SUM cap=%.0f maxdiff=%d meandiff=%.3f samples=%d",
                saved, mx, sum / Double(max(1, n)), n))
}

/// **祛油光**体检：验证它的**定义性质** —— "只压高光顶，不动暗部"。
///
/// 为什么不能只验"画面变了"：整体变暗也能让画面变 ✗ —— 那就不是祛油光而是调暗。
/// 所以这里分开量"暗部像素"与"亮部像素"的平均变化：亮部必须明显变暗、暗部必须几乎不动。
/// 触发：CR_SHINEAUDIT=1（配合 CR_IMPORT）。
func auditShine() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard let img = workImage() else { emit("SHINEAUDIT 没有工作图（先 CR_IMPORT 一张）"); return }
    func sample() -> [UInt8] {
        let w = 200
        let e = img.extent
        let h = max(1, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let sx = CGFloat(w) / max(1, e.width)
        let scaled = renderPipeline(img, geos: cachedGeos)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    // ⚠️ 量**肖像面板**那条（`portrait.shine`），不是皮肤面板那条（`skinShine`）——
    // §203.3 发现：判据 F 一直守的是皮肤面板那份实现，而用户拖的滑杆在按部位面板上，
    // 两条是同一功能的两份实现。判据要钉在**真正生效**的那条上，否则它绿着也不能说明产品是对的。
    // （皮肤那条留着不动：它是 §188 加的，要不要收成一条是独立的一件事，先量再动。）
    portrait.shine = 0
    let base = sample()
    portrait.shine = 100
    let after = sample()
    portrait.shine = 0
    // 按**基线的亮度**分组：暗部（<0.35）、中间（0.35~0.7）、亮部（>0.7）
    var darkB = 0.0, darkN = 0.0, hiB = 0.0, hiN = 0.0, hiPeak = 0.0
    for i in 0..<(min(base.count, after.count) / 4) {
        let r = Double(base[i * 4]) / 255, g = Double(base[i * 4 + 1]) / 255, b = Double(base[i * 4 + 2]) / 255
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let r2 = Double(after[i * 4]) / 255, g2 = Double(after[i * 4 + 1]) / 255, b2 = Double(after[i * 4 + 2]) / 255
        let lum2 = 0.2126 * r2 + 0.7152 * g2 + 0.0722 * b2
        let d = (lum - lum2) * 255   // 正 = 变暗
        if lum < 0.35 { darkB += d; darkN += 1 }
        else if lum > 0.70 {
            hiB += d; hiN += 1
            // 亮部的**峰值**：这一版实现用 level 掩膜只碰最亮那一小片，平均值天然被稀释
            //（实测峰值 23 级、亮部平均 1.79）—— "作用处有多强"要看峰值，"别处没动"才看均值（§204）
            if d > hiPeak { hiPeak = d }
        }
    }
    let dAvg = darkN > 0 ? darkB / darkN : 0
    let hAvg = hiN > 0 ? hiB / hiN : 0
    emit(String(format: "SHINEAUDIT 祛油光=100：暗部(亮度<0.35)平均变化 %.2f 级 ｜ 亮部(>0.70)平均变化 %.2f 级", dAvg, hAvg))
    emit(String(format: "SHINEAUDIT brightpeak=%.1f", hiPeak))
    // ⚠️ 参数表必须与格式符**逐一对齐**：加了 brightpeak 却忘了补参数时，
    // 值会整体错位（实测 brightpeak 报成像素数 15005），而判据照样"绿" —— 这正是本项目
    // 反复记的那种假绿。所以把每个数都按名字排好，顺序错了也能一眼看出来。
    emit(String(format: "SHINEAUDIT-SUM dark=%.2f bright=%.2f brightpeak=%.1f pixels_dark=%.0f pixels_bright=%.0f",
                dAvg, hAvg, hiPeak, darkN, hiN))
    emit("SHINEAUDIT 完")
}

/// **祛黑眼圈**体检：验证"只动眼下那条带"。
/// 判据：眼下带里必须**变亮**；脸以外的地方必须**几乎不动**（不然就是整脸提亮，不是祛黑眼圈）。
/// 触发：CR_DCAUDIT=1（配合 CR_IMPORT）。
func auditDarkCircle() {
    guard let img = workImage(), let g = cachedGeos.max(by: { $0.box.width < $1.box.width }) else {
        FileHandle.standardError.write(("DCAUDIT 没有工作图或没检出脸\n").data(using: .utf8)!); return
    }
    let w = 200
    let e = img.extent
    let sx = CGFloat(w) / max(1, e.width)
    let h = max(1, Int(round(Double(e.height) * Double(sx))))
    func sample() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let scaled = renderPipeline(img, geos: cachedGeos)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    // 对照实验：把"被开的那个参数"换成另一个（CR_DCAUDIT_CTRL=eyebag）。
    // 为什么需要：基线样本里 anyEnabled=false 会让管线**直接返回**，而任何一个人像功能一开，
    // 图就要走一次工作空间平移往返 = 整幅重采样。不设对照就会把"重采样"误判成"掩膜漏出"（§189）
    let ctrl = ProcessInfo.processInfo.environment["CR_DCAUDIT_CTRL"] ?? ""
    func setKnob(_ v: Double) {
        if ctrl == "eyebag" { portrait.eyebag = v } else { portrait.darkCircle = v }
    }
    setKnob(0)
    let base = sample()
    setKnob(100)
    let after = sample()
    setKnob(0)
    // 眼下带矩形（与 underEyeMask 同一套几何，缩放到本渲染尺寸）
    // **与掩膜用同一个几何函数**（写两处就会出现"体检量的是 A、产品改的是 B"）
    let bands = underEyeBands(g).map {
        CGRect(x: $0.minX * sx, y: $0.minY * sx, width: $0.width * sx, height: $0.height * sx)
    }
    // "带外"必须排除**所有**脸框：管线对每张脸都做眼下带，只排最大那张会把第二张脸的
    // 合法改动算成"漏到脸外"（实测正是这样：带外总量 ≈ 12400 级 ≈ 48px × 259）
    let faceRects = cachedGeos.map {
        CGRect(x: $0.box.minX * sx, y: $0.box.minY * sx, width: $0.box.width * sx, height: $0.box.height * sx)
    }
    func pixLum(_ b: [UInt8], _ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return (0.2126 * Double(b[i]) + 0.7152 * Double(b[i + 1]) + 0.0722 * Double(b[i + 2])) / 255
    }
    // 掩膜探针：带里到底有没有掩膜？（"效果=0"必须先分清是掩膜空，还是混合没发生）
    var mMaskPeak = 0.0, mMaskHit = 0, mMaskBandPeak = 0.0
    do {
        var mbuf = [UInt8](repeating: 0, count: w * h * 4)
        let fm = underEyeMask(extent: e, face: g, feather: max(2, g.box.width * 0.02))
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(fm, toBitmap: &mbuf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for y in 0..<h { for x in 0..<w {
            let v = Double(mbuf[(y * w + x) * 4]) / 255
            if v > mMaskPeak { mMaskPeak = v }
            if v > 0.02 { mMaskHit += 1 }
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))   // 位图第 0 行 = 图像顶部
            if v > mMaskBandPeak, bands.contains(where: { $0.contains(p) }) { mMaskBandPeak = v }
        } }
    }
    var inB = 0.0, inN = 0.0, outB = 0.0, outN = 0.0
    var leakN = 0, leakD = 0.0, leakX = 0, leakY = 0, inMax = -999.0
    var lx0 = w, lx1 = 0, ly0 = h, ly1 = 0
    for y in 0..<h { for x in 0..<w {
        let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))   // 位图第 0 行 = 图像顶部
        let inBand = bands.contains { $0.contains(p) }
        let inFace = faceRects.contains { $0.contains(p) }
        // 符号口径：after − base，正 = 带内**变亮**。早先写成 base − after 却把注释写成"正 = 变亮"，
        // 量出来的正负正好是反的 —— 差点据此判成"功能没生效"（§189）
        let d = (pixLum(after, x, y) - pixLum(base, x, y)) * 255
        if inBand { inB += d; inN += 1; if d > inMax { inMax = d } } else if !inFace {
            outB += d; outN += 1
            // 定位漏出：漏出是**局部**（几个像素上百级）还是**全局舍入**（全图每像素零点几级）？
            if abs(d) >= 3 {
                leakN += 1
                if x < lx0 { lx0 = x }; if x > lx1 { lx1 = x }
                if y < ly0 { ly0 = y }; if y > ly1 { ly1 = y }
                if abs(d) > abs(leakD) { leakD = d; leakX = x; leakY = y }
            }
        }
    } }
    let inAvg = inN > 0 ? inB / inN : 0
    let outAvg = outN > 0 ? outB / outN : 0
    FileHandle.standardError.write(String(format: "DCAUDIT 祛黑眼圈=100：眼下带平均变亮 %+.2f 级（峰值 %+.1f）｜ 脸以外平均变化 %+.2f 级 ｜ 脸 %d 张 ｜ 脸外 ≥3 级的像素 %d 个（最大 %+.1f 级 @%d,%d）\n", inAvg, inMax, outAvg, cachedGeos.count, leakN, leakD, leakX, leakY).data(using: .utf8)!)
    FileHandle.standardError.write(String(format: "DCAUDIT 漏出外接框 x[%d,%d] y[%d,%d]（渲染尺度）｜ 脸框 %@ ｜ 带 %@\n",
        lx0, lx1, ly0, ly1,
        faceRects.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: " "),
        bands.map { String(format: "%.0f,%.0f %.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) }.joined(separator: " ")).data(using: .utf8)!)
    FileHandle.standardError.write(String(format: "DCAUDIT-SUM band=%.2f outside=%.2f px_band=%.0f px_out=%.0f bandmax=%.1f maskband=%.2f maskpx=%d leakpx=%d leakmax=%.1f\n", inAvg, outAvg, inN, outN, inMax, mMaskBandPeak, mMaskHit, leakN, leakD).data(using: .utf8)!)
    FileHandle.standardError.write(("DCAUDIT 完\n").data(using: .utf8)!)
}

/// **特征掩膜覆盖率**诊断（§214）：唇色/牙齿/眼睛这些"薄曲线关键点 + 解析掩膜"的项，
// 效果弱到底是"掩膜没覆盖到"还是别的。调用的是**产品同一条入口** `bestFeatureMask` ——
// 不另写一份算法（写两处会出现"体检量的是 A、产品改的是 B"，§189 踩过）。
/// 触发：CR_MCAUDIT=1（配合 CR_IMPORT）。
func auditMaskCover() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    // ⚠️ 遍历**所有脸**（§236）：原来只取最大那张，而逐项体检的区域是所有脸的并集 ——
    // §232 据此推断"婚礼 RAW 上那 7 级来自第二张脸"，但那只是推理。多脸照片上两者口径必须对齐，
    // 否则同一个疑问会以"探针说 0%、体检说 7 级"的形式反复出现。
    guard let img = workImage(), !cachedGeos.isEmpty else {
        emit("MCAUDIT 没有工作图或没检出脸"); return
    }
    emit(String(format: "MCAUDIT 共 %d 张脸", cachedGeos.count))
    for (fi, face) in cachedGeos.enumerated() { auditMaskCoverOne(img, face: face, tag: "脸\(fi + 1)") }
    emit("MCAUDIT 完")
}

/// 单张脸的掩膜覆盖/取值诊断（由 auditMaskCover 对每张脸调用）。
func auditMaskCoverOne(_ img: CIImage, face g: FaceGeo, tag: String) {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    let e = img.extent
    /// 掩膜在矩形内的覆盖率（>0.02 记作覆盖）
    func coverage(_ m: CIImage, in r: CGRect, extent: CGRect) -> Double {
        let w = max(1, Int(extent.width)), h = max(1, Int(extent.height))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(m, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var inB = 0, hit = 0
        for y in 0..<h { for x in 0..<w {
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))
            guard r.contains(p) else { continue }
            inB += 1
            if Double(buf[(y * w + x) * 4]) / 255 > 0.02 { hit += 1 }
        } }
        return inB > 0 ? 100.0 * Double(hit) / Double(inB) : 0
    }
    func cover(_ label: String, _ polys: [[CGPoint]], _ classes: Set<Int>) {
        guard polys.first?.count ?? 0 >= 3 else { emit("MCAUDIT " + label + "：关键点不足 3 个"); return }
        var r = CGRect.null
        for p in polys { for q in p { r = r.union(CGRect(x: q.x, y: q.y, width: 0, height: 0)) } }
        let fallback = featureMask(extent: e, polygons: polys,
                                   feather: max(0.8, min(r.width, r.height) * 0.2))
        // ⚠️ 两份掩膜都要量（§215）：上一轮只量了 `bestFeatureMask` 的结果，得到"眼睛覆盖 0%"，
        // 但逐项体检里眼睛却量到 7 级（非 0）—— 两者必有一个不是我以为的那样。
        // 最可能的分歧：解析掩膜为空 ⇒ 产品在别处退回兜底（多边形 ∪ 包围盒椭圆），而我量的是解析结果。
        // 所以这里把**解析掩膜**与**兜底掩膜**的覆盖率并排打出来，用数据判断走的是哪条。
        let parsed = parsedMaskForFace(img, face: g, classes: classes, feather: max(0.8, min(r.width, r.height) * 0.2))
        let fbCover = coverage(fallback, in: r, extent: e)
        let pCover = parsed.map { coverage($0, in: r, extent: e) } ?? -1
        // 相对脸框的比例（§222）：给"眼睛/牙齿退化成一条线时按脸框估区"提供数据，
        // 而不是凭感觉写 0.20/0.22 这种常数（牙齿那两个常数就是这么来的，这里补上它的实测依据）
        let fb0 = g.box
        emit(String(format: "MCAUDIT %@ 相对脸框：中心 x %+.2f y %+.2f ｜ 宽 %.2f 高 %.2f（脸 %.0fx%.0f）",
                    label, (r.midX - fb0.midX) / max(1, fb0.width), (r.midY - fb0.midY) / max(1, fb0.height),
                    r.width / max(1, fb0.width), r.height / max(1, fb0.height), fb0.width, fb0.height))
        emit(String(format: "MCAUDIT %@ 关键点 %d 组 ｜ 包围盒 %.0fx%.0f ｜ 兜底掩膜覆盖 %.0f%% ｜ 解析掩膜覆盖 %@",
                    label, polys.count, r.width, r.height, fbCover,
                    pCover < 0 ? "无（拿不到解析掩膜）" : String(format: "%.0f%%", pCover)))
        // 仍然按产品入口算一遍（保留上一轮的口径，便于对比）
        let m = bestFeatureMask(img, face: g, classes: classes) { fallback }
        let cg = sharedCtx.createCGImage(m, from: e.integral)
        let w = max(1, Int(e.width)), h = max(1, Int(e.height))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        if let cg { sharedCtx.render(CIImage(cgImage: cg), toBitmap: &buf, rowBytes: w * 4,
                                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        var inB = 0, hit = 0
        for y in 0..<h { for x in 0..<w {
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))
            guard r.contains(p) else { continue }
            inB += 1
            if Double(buf[(y * w + x) * 4]) / 255 > 0.02 { hit += 1 }
        } }
        emit(String(format: "MCAUDIT %@ · 产品入口(bestFeatureMask)覆盖率 %d/%d = %.0f%%",
                    label, hit, inB, inB > 0 ? 100.0 * Double(hit) / Double(inB) : 0))
    }
    // 掩膜的**取值分布**（§225）：覆盖率是"多少像素被碰到"，而效果大小看的是"碰到多少" ——
    // §224 用算术反解出唇掩膜峰值只有 0.07 量级，这里直接把分布量出来验证。
    do {
        let lb = g.bbox(g.outerLips)
        if !lb.isNull, min(lb.width, lb.height) >= 3 {
            let m = bestFeatureMask(img, face: g, classes: FaceClass.lipClasses) {
                featureMask(extent: e, polygons: [g.outerLips],
                            feather: max(0.8, min(lb.width, lb.height) * 0.18))
            }
            let w = max(1, Int(e.width)), h = max(1, Int(e.height))
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            sharedCtx.render(m, toBitmap: &buf, rowBytes: w * 4,
                             bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var vals: [Double] = []
            for y in 0..<h { for x in 0..<w {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))
                if lb.contains(p) { vals.append(Double(buf[(y * w + x) * 4]) / 255) }
            } }
            vals.sort()
            let n = vals.count
            let mean = n > 0 ? vals.reduce(0, +) / Double(n) : 0
            emit(String(format: "MCAUDIT 唇掩膜取值：n=%d 均值 %.3f ｜ p50 %.3f ｜ p90 %.3f ｜ 峰值 %.3f",
                        n, mean, n > 0 ? vals[n / 2] : 0, n > 0 ? vals[min(n - 1, n * 9 / 10)] : 0, vals.last ?? 0))
        }
    }
    // 耳朵/鼻子：模型一直在输出 7/8(耳)、10(鼻) 两类，但**没有任何地方使用它们** ——
    // 这两项现在走 Vision 关键点多边形（会退化）。并排量覆盖率，先看接上解析类能换来什么（§237）。
    // 耳：Vision 没有耳部关键点，产品用的是「脸框两侧竖长椭圆」近似（CoreParts.swift 的 case .ears）。
    // 上一轮我拿 faceContour（整脸轮廓）当分母 ⇒ 量的其实是脸，结论无效。
    // 这里改用**与产品同一套竖带几何**当分母，再问：解析类 7/8 在这两条带子里覆盖多少？
    // （这才是「耳朵要不要接解析类」的决策数据）
    do {
        let w = g.box.width * 0.20, h = g.box.height * 0.55
        let left = CGRect(x: g.box.minX - w * 0.15, y: g.box.midY - h * 0.2, width: w, height: h)
        let right = CGRect(x: g.box.maxX - w * 0.85, y: g.box.midY - h * 0.2, width: w, height: h)
        if let em = parsedMaskForFace(img, face: g, classes: FaceClass.earClasses, feather: 2) {
            let cl = coverage(em, in: left, extent: e)
            let cr = coverage(em, in: right, extent: e)
            emit(String(format: "MCAUDIT %@ 耳带(产品同几何) 解析7/8覆盖：左带 %.0f%% 右带 %.0f%% ｜ 带面积 %.0fx%.0f",
                        tag, cl, cr, w, h))
        } else {
            emit("MCAUDIT " + tag + " 耳带：拿不到解析掩膜（无耳类输出）")
        }
        // 换一个更直接的分母：不问「带子里有多少耳」，而问「耳类像素有多少、在哪」（§243）。
        // 若耳类面积合理 ⇒ 可直接用它替代产品那套竖椭圆近似（那是真收益）；若 ≈0 ⇒ 模型不输出耳朵，此路不通。
        if let em2 = parsedMaskForFace(img, face: g, classes: FaceClass.earClasses, feather: 2) {
            let w2 = max(1, Int(e.width)), h2 = max(1, Int(e.height))
            var b2 = [UInt8](repeating: 0, count: w2 * h2 * 4)
            sharedCtx.render(em2, toBitmap: &b2, rowBytes: w2 * 4,
                             bounds: CGRect(x: 0, y: 0, width: w2, height: h2), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var n2 = 0, sx2 = 0.0, sy2 = 0.0, lf = 0, rt = 0
            for y in 0..<h2 { for x in 0..<w2 {
                if Double(b2[(y * w2 + x) * 4]) / 255 > 0.02 {
                    n2 += 1
                    let px = Double(x) + 0.5, py = Double(h2) - (Double(y) + 0.5)
                    sx2 += px; sy2 += py
                    if px < Double(g.box.midX) { lf += 1 } else { rt += 1 }
                }
            } }
            if n2 > 0 {
                emit(String(format: "MCAUDIT %@ 耳类面积：命中 %d px（工作图共 %d）｜质心相对脸框 x %+.2f y %+.2f ｜ 左/右 %d/%d",
                            tag, n2, w2 * h2,
                            (sx2 / Double(n2) - Double(g.box.midX)) / Double(max(1, g.box.width)),
                            (sy2 / Double(n2) - Double(g.box.midY)) / Double(max(1, g.box.height)), lf, rt))
            } else {
                emit("MCAUDIT " + tag + " 耳类面积：全图 0 命中（模型在这张图上没输出耳朵）")
            }
        }
        // 逐类直方图（§243）：把 0~18 每一类的面积与质心都打出来 —— 既验证 README 的类别表，
        // 也回答「耳类索引到底是不是 7/8」（前一版三张脸都只有右侧有 7/8，非常可疑）。
        // 用的是产品自己的 maskFromLabels 映射，不另写一份坐标换算。
        for k in 0...18 {
            guard let km = parsedMaskForFace(img, face: g, classes: [k], feather: 2) else { continue }
            let wk = max(1, Int(e.width)), hk = max(1, Int(e.height))
            var bk = [UInt8](repeating: 0, count: wk * hk * 4)
            sharedCtx.render(km, toBitmap: &bk, rowBytes: wk * 4,
                             bounds: CGRect(x: 0, y: 0, width: wk, height: hk), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var nk = 0, sxk = 0.0, syk = 0.0
            for y in 0..<hk { for x in 0..<wk where Double(bk[(y * wk + x) * 4]) / 255 > 0.02 {
                nk += 1
                sxk += Double(x) + 0.5
                syk += Double(hk) - (Double(y) + 0.5)
            } }
            if nk > 300 {
                emit(String(format: "MCAUDIT %@ 类%02d：%6d px ｜ 质心相对脸框 x %+.2f y %+.2f",
                            tag, k, nk,
                            (sxk / Double(nk) - Double(g.box.midX)) / Double(max(1, g.box.width)),
                            (syk / Double(nk) - Double(g.box.midY)) / Double(max(1, g.box.height))))
            }
        }
    }
    cover("\(tag) 鼻", [g.nose], [10])
    cover("\(tag) 唇", [g.outerLips], FaceClass.lipClasses)
    cover("\(tag) 齿", [g.innerLips], FaceClass.mouthClasses)
    cover("\(tag) 眼", [g.leftEye, g.rightEye], FaceClass.eyeClasses)
}

/// **导出偏色**二分探针：把"源文件 → 导入 → 管线 → 导出"这条链上每一段的**绝对亮度**打出来。
///
/// 为什么要有它：§193 发现无编辑导出的成片明显偏暗偏色（webp 源 0.504 → 0.079、RAW 0.413 → 0.149），
/// 而现有 17 个门一个都没抓到（它们全是"导出 vs 导出"或"渲染 vs 渲染"，全局色调偏移天然隐形）。
/// 定位的第一步不是读管线代码，而是**先量三个点**，把搜索空间一刀切开：
///   ① 源文件解码后   ② 导入后的工作图   ③ 管线输出（全参数 0）
/// ①→② 掉 → 导入/解码；②→③ 掉 → 管线；③ 正常但导出偏色 → 写入。
/// 触发：CR_COLAUDIT=1（配合 CR_IMPORT）。
func auditColorChain() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    func means(_ i: CIImage, _ tag: String) {
        let w = 256
        let e = i.extent
        guard e.width > 1, e.height > 1 else { emit("COLAUDIT " + tag + "：extent 异常"); return }
        let k = CGFloat(w) / e.width
        let h = max(1, Int(round(Double(e.height) * Double(k))))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let small = i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var r = 0.0, g = 0.0, b = 0.0
        for i2 in stride(from: 0, to: w * h, by: 1) {
            r += Double(buf[i2 * 4]); g += Double(buf[i2 * 4 + 1]); b += Double(buf[i2 * 4 + 2])
        }
        let n = Double(max(1, w * h)) * 255
        emit(String(format: "COLAUDIT %@ 均值 R=%.3f G=%.3f B=%.3f（%dx%d）", tag, r / n, g / n, b / n, w, h))
    }
    if let u = srcURL, let decoded = loadAnyImage(u.path, maxDim: 0) {
        means(decoded, "① 源文件解码")
    } else {
        emit("COLAUDIT ① 源文件解码：拿不到 srcURL 或解码失败")
    }
    guard let img = workImage() else { emit("COLAUDIT 没有工作图"); emit("COLAUDIT 完"); return }
    means(img, "② 导入后的工作图")
    means(renderPipeline(img, geos: cachedGeos), "③ 管线输出(预览尺度)")
    // ④ 导出走的是**全分辨率**（长边 >1600 ⇒ 会启用"掩膜降采样"那条支路）。
    // 预览与导出在这一步分道扬镳，所以必须单独量一次 —— 这一条就是冲着 §193 的偏色去的。
    if let u = srcURL, let full = loadAnyImage(u.path, maxDim: 0) {
        means(full, "④ 源文件全分辨率解码")
        means(renderPipeline(full, geos: detectFaceGeos(
            sharedCtx.createCGImage(full, from: full.extent) ?? CIImage().cgImage!,
            size: full.extent.size)), "⑤ 管线输出(全分辨率)")
    }
    // ⑥ 拿一张**已确认正常**的输入（全分辨率管线输出）直接调 exportImage，
    // 把"渲染"与"写入"两件事彻底分开：这一步要是也黑，问题就 100% 在 exportImage 里。
    if let u = srcURL, let full = loadAnyImage(u.path, maxDim: 0) {
        var es = ExportSettings()
        es.format = "png"
        let good = renderPipeline(full, geos: cachedGeos)
        let outURL = URL(fileURLWithPath: "/tmp/colaudit_export.png")
        try? FileManager.default.removeItem(at: outURL)
        let okw = exportImage(good, to: outURL, es, sourceURL: u)
        if okw, let back = loadAnyImage(outURL.path, maxDim: 0) {
            means(back, "⑥ exportImage 写出的文件再读回")
        } else {
            emit("COLAUDIT ⑥ exportImage 写入失败")
        }
    }
    // ⑦ 复刻**导出路径的配方**：本图自适应曝光 + closedLoop（3 轮朝 currentStyle.target 收敛）
    if let u = srcURL, let full = loadAnyImage(u.path, maxDim: 0) {
        var c = pipelineConfigNow()
        c.faces = []; c.cachedGeos = []; c.perFace = [:]; c.personSkin = []
        let s0 = measure(full)
        let over = max(0, s0.p50 - 120)
        c.params.gamma = max(1.0, c.params.gamma - over * 0.001)
        c.params.brightness = max(0, 5 - over * 0.10)
        emit(String(format: "COLAUDIT ⑦ 本图 p50=%.1f ｜ over=%.1f ｜ 起始 brightness=%.2f gamma=%.3f ｜ currentStyle.target p50=%.1f",
                    s0.p50, over, c.params.brightness, c.params.gamma, currentStyle.target.p50))
        let (bp, _, _, _) = closedLoop(full, base: c.params, target: currentStyle.target, iterations: 3)
        emit(String(format: "COLAUDIT ⑦ closedLoop 之后 brightness=%.2f gamma=%.3f contrast=%.3f",
                    bp.brightness, bp.gamma, bp.contrast))
        c.params = bp
        means(renderPipeline(full, geos: nil, cfg: c), "⑦ 导出配方输出")
    }
    emit("COLAUDIT 完")
}

/// **祛鼻孔瑕疵**诊断：为什么满档只改 3 级？
///
/// 怀疑点：这一项复用斑点检测器（`removeBlemishes`），而它的检测半径是 `鼻宽×0.06`（实测约 2px），
/// 高斯模糊会把**鼻孔本身**一起模糊掉 ⇒ 残差 ≈ 0 ⇒ 这种"大而暗"的目标天然检不出来。
/// 所以这里做一个**半径扫描**：同一个鼻孔区，换几个检测半径，看斑点掩膜到底有没有反应。
/// 只用掩膜、不跑整条管线，所以很快。
/// 触发：CR_NOAUDIT=1（配合 CR_IMPORT）。
func auditNostril() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard let img = workImage(), let g = cachedGeos.max(by: { $0.box.width < $1.box.width }), g.nose.count >= 3 else {
        emit("NOAUDIT 没有工作图或鼻子关键点不足"); return
    }
    let w = 240
    let e = img.extent
    let sx = CGFloat(w) / max(1, e.width)
    let h = max(1, Int(round(Double(e.height) * Double(sx))))
    let nb = g.bbox(g.nose)
    let sc = CGAffineTransform(scaleX: sx, y: sx)
    let small = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: sc)
    let nbs = CGRect(x: (nb.minX - e.minX) * sx, y: (nb.minY - e.minY) * sx,
                     width: nb.width * sx, height: nb.height * sx)
    let rect = CGRect(x: nbs.minX, y: nbs.minY, width: nbs.width, height: nbs.height * 0.6)
    let fb = g.box
    emit(String(format: "NOAUDIT 鼻子 %.0fx%.0f ｜ 脸框 %.0fx%.0f ｜ 鼻宽/脸宽 %.2f ｜ 鼻高/脸高 %.2f ｜ 鼻孔区 %.0fx%.0f ｜ 工作图 %.0fx%.0f",
                nb.width, nb.height, fb.width, fb.height,
                nb.width / max(1, fb.width), nb.height / max(1, fb.height),
                rect.width, rect.height, e.width, e.height))
    func stat(_ m: CIImage, _ r: CGRect) -> (Double, Double, Int) {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(m, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var peak = 0.0, sum = 0.0
        var n = 0
        for y in 0..<h { for x in 0..<w {
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))
            guard r.contains(p) else { continue }
            let v = Double(buf[(y * w + x) * 4]) / 255
            sum += v; n += 1
            if v > peak { peak = v }
        } }
        return (peak, n > 0 ? sum / Double(n) : 0, n)
    }
    let nostrilMask = rectMask(extent: small.extent, rect: rect, feather: max(2, rect.width * 0.15), ellipse: true)
    let (mpk, mav, mn) = stat(nostrilMask, rect)
    emit(String(format: "NOAUDIT 鼻孔掩膜：区内 %d px ｜ 峰值 %.2f 均值 %.2f", mn, mpk, mav))
    // 二维扫描：检测半径 × 阈值 → 斑点掩膜在鼻孔区里的响应
    // 为什么要扫：产品当前用"半径 = 鼻宽×0.06"（实测 2.0~2.6px）与阈值 0.09，
    // 而鼻孔的像素尺度是"鼻子本身"，不是鼻子上的小点 —— 半径低于目标尺度时残差 ≈ 0。
    let radii = [max(2.0, nb.width * 0.06), nb.width * 0.15, nb.width * 0.25, nb.width * 0.40]
    let ths = [0.09, 0.05, 0.03]
    for rr in radii {
        var row = ""
        for th in ths {
            let (_, spot) = removeBlemishesWithMask(small, skinMask: nostrilMask, threshold: th,
                                                    detectRadius: max(1, rr * sx),
                                                    fixRadius: max(4, nb.width * 0.18 * sx), strength: 1.0)
            let (pk, _, _) = stat(spot, rect)
            row += String(format: " 阈值%.2f→峰值%.2f", th, pk)
        }
        emit(String(format: "NOAUDIT 半径 %.1f px：%@", rr, row))
    }
    emit("NOAUDIT 完")
}

/// **祛瑕疵 10 项**逐项体检：每一项都必须"只在它该管的那块地方改画面"。
///
/// 为什么需要：这 10 项**早就都在**（§189.8，证据是 9.10.48 就有的 23 个 pSlider + 各自实现分支），
/// 但没有任何一条判据量过"它们各自改在哪"。一个"接线正确、几何落空"的功能（关键点退化时就会这样，
/// §189 的祛黑眼圈正是如此）在"画面变了没有"这个口径下完全看不出来 —— 它变了，只是变在了别处。
///
/// 判据（门里用的是前两条）：① 每项都得真的改画面（总改动为 0 = 空转）；
/// ② **区内峰值 ≥5 级** —— 满档还改不到 5 级，就是"滑杆在、功能看不见"（修复前的祛鼻孔瑕疵正是 3 级）。
/// 另外两条只报告不判：**区外峰值**与**区内占比**会被图形底噪污染（见文件里那段说明，§191 实测过：
/// 底噪能到 42~179 级、占上万像素，比很多功能本身还猛，加 3×3 邻域过滤又会把"改动像素很少"的项误判成空转）。
/// 期望区域按各项自己的实现取（脸框 / 眼下带 / 唇 / 鼻 / 下巴下方 / 下半脸），并对**所有脸**取并集 ——
/// 只算最大那张脸会把第二张脸的合法改动算成"改到区外"（§189 踩过一次）。
/// 触发：CR_BIAUDIT=1（配合 CR_IMPORT）。
func auditBlemishItems() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard let img = workImage(), !cachedGeos.isEmpty else {
        emit("BIAUDIT 没有工作图或没检出脸"); return
    }
    let w = 240
    let e = img.extent
    let sx = CGFloat(w) / max(1, e.width)
    let h = max(1, Int(round(Double(e.height) * Double(sx))))
    func sample() -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let scaled = renderPipeline(img, geos: cachedGeos)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    /// 各项"该管的那块地方"：按实现取，不是想当然
    func expected(_ name: String, _ g: FaceGeo) -> [CGRect] {
        let b = g.box
        switch name {
        case "祛黑眼圈":
            return underEyeBands(g)
        case "祛眼袋":   // 比黑眼圈更深（实现里 depth = 0.22×脸高）
            return underEyeBands(g).map {
                CGRect(x: $0.minX, y: $0.minY - b.height * 0.10,
                       width: $0.width, height: $0.height + b.height * 0.20)
            }
        case "祛鼻孔瑕疵":
            let nb = g.bbox(g.nose)
            return nb.isNull ? [] : [nb.insetBy(dx: -nb.width * 0.3, dy: -nb.height * 0.3)]
        case "唇纹修整":
            let lb = g.bbox(g.outerLips)
            return lb.isNull ? [] : [lb.insetBy(dx: -lb.width * 0.3, dy: -lb.height * 0.3)]
        case "祛双下巴":   // 实现：脸框中线 ± 0.45 宽，下巴下方 0.34 高起、0.40 高
            return [CGRect(x: b.midX - b.width * 0.45, y: b.minY - b.height * 0.34,
                           width: b.width * 0.9, height: b.height * 0.40)]
        case "牙齿":
            // ⚠️ 必须与产品同构（§221）：产品在内唇包围盒退化时改用**按脸框估的口腔区**，
            // 体检要是还按那条线算"期望区域"，就会把改动判成"跑到区域外"（实测占比掉到 14%）——
            // 这正是本项目反复踩的"写两处"（§189 的眼下带、§204 的 F 判据都是同一个坑）。
            let tb = g.bbox(g.innerLips)
            if tb.isNull || min(tb.width, tb.height) < max(3.0, g.box.width * 0.06) {
                // 与产品同值（§222 已按实测收紧到 0.18/0.10）—— 两处必须一起改，
                // 否则体检会把正确的改动判成"跑到区域外"（这次就是这么发现同步漏了的）
                return [CGRect(x: g.box.midX - g.box.width * 0.09,
                               y: g.box.minY + g.box.height * 0.18,
                               width: g.box.width * 0.18, height: g.box.height * 0.10)]
            }
            return [tb.insetBy(dx: -tb.width * 0.3, dy: -tb.height * 0.3)]
        case "眼睛":
            let eb = g.bbox(g.leftEye).union(g.bbox(g.rightEye))
            // 与产品同构（§222）：关键点退化时产品改用"按脸框估的整条眼带"，体检也得用同一条
            if eb.isNull || min(eb.width, eb.height) < max(3.0, g.box.width * 0.06) {
                return [CGRect(x: g.box.midX - g.box.width * 0.28,
                               y: g.box.midY + g.box.height * 0.22 - g.box.height * 0.07,
                               width: g.box.width * 0.56, height: g.box.height * 0.14)]
            }
            return [eb.insetBy(dx: -eb.width * 0.3, dy: -eb.height * 0.3)]
        case "唇色":
            let lb2 = g.bbox(g.outerLips)
            return lb2.isNull ? [] : [lb2.insetBy(dx: -lb2.width * 0.3, dy: -lb2.height * 0.3)]
        case "下颌线增强":  // 实现：整宽，下半张脸（0.52 高）
            return [CGRect(x: b.minX, y: b.minY - b.height * 0.08,
                           width: b.width, height: b.height * 0.52)]
        default:          // 瑕疵类：以皮肤掩膜为界，掩膜在脸框内
            return [b]
        }
    }
    // 两组分开：上面 11 项进判据；颜色 4 项先**只报告** —— 它们各自的强弱需要先量出来
    //（牙齿在 coretest 的人像自检里只有 3 级，很可能与 §191 的鼻孔瑕疵同病，但得先量再定）。
    let items: [(String, WritableKeyPath<PortraitOptions, Double>)] = [
        ("面部祛瑕疵", \.faceBlemish), ("祛斑祛痘", \.spotBlemish), ("祛痣", \.mole),
        ("祛油光", \.shine), ("祛汗孔", \.sweat), ("祛黑眼圈", \.darkCircle),
        ("祛眼袋", \.eyebag), ("祛鼻孔瑕疵", \.nostril), ("唇纹修整", \.lipLine),
        ("祛双下巴", \.doubleChin), ("下颌线增强", \.jawLine),
    ]
    let colorItems: [(String, WritableKeyPath<PortraitOptions, Double>)] = [
        ("牙齿", \.teeth), ("眼睛", \.eyes), ("唇色", \.lipColor), ("腮红", \.blush),
    ]
    // 期望区域（缩放到本渲染尺寸）：所有脸的并集
    var regionsScaled: [String: [CGRect]] = [:]
    for (name, _) in items + colorItems {
        regionsScaled[name] = cachedGeos.flatMap { expected(name, $0) }.map {
            CGRect(x: $0.minX * sx, y: $0.minY * sx, width: $0.width * sx, height: $0.height * sx)
        }
    }
    func pixLum(_ b: [UInt8], _ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return (0.2126 * Double(b[i]) + 0.7152 * Double(b[i + 1]) + 0.0722 * Double(b[i + 2])) / 255
    }
    // ⚠️ 基线**不能**用"全部为 0"那张图：全 0 时 applyPortrait 直接 return，
    // 一开任何一项，图就要多走一条滤镜链，于是**整幅图**出现 2~60 级的底噪（实测区外 13k~21k 像素、
    // 边缘最大 61 级 —— 与 §189.5 同源）。拿它当基线，11 项会有 11 项被判"改到区外"。
    // 所以每项用**自己**的小值当对照，而且这个值必须清掉实现里**最深的那道闸门**：
    // adjustInMask 是 `guard k > 0.001`、reduceShine 是 `guard strength > 0.01`（都是 值/100），
    // 所以低于 1.0 的对照值会让某些项"看着开了、其实原样返回" —— 图形结构跟满档不一样，
    // 底噪抵消不掉。实测：0.02 时 11 项有 7 项仍报"改到区外"；0.5 时降到 2 项；**2.0 时全清**。
    // 取 2.0（效果只有满档的 1/50）之后，相减剩下的才是"这一项真正改了哪儿"。
    var lines: [String] = []
    var dead = 0, badPeak = 0, badShare = 0, weak = 0
    for (name, kp) in items + colorItems {
        portrait[keyPath: kp] = 2.0
        let base = sample()
        portrait[keyPath: kp] = 100
        let after = sample()
        portrait[keyPath: kp] = 0
        let regs = regionsScaled[name] ?? []
        // 作用域像素数（§211）：把"这张照片里没有可改的目标"与"功能坏了"分开 ——
        // 牙齿/唇色在婚礼 RAW 上实测 0/3 级（那张照片嘴闭着），在门夹具上是 11/9 级。
        // 没有这个前置量时，判据会把"照片里没有"当成"功能坏了"（假红），而假红会被当噪音忽略。
        // 它同时是"高光恢复在没有过曝像素时必然为 0"那条老经验的通用化（那边打印的是过曝像素占比）。
        // 作用域内**基线的亮度均值**（§213）：乘性调色（唇色 R×1.32…）的效果正比于像素亮度，
        // 所以"这一项在某张图上只有 3 级"到底是"照片暗"还是"功能弱"，靠这一个数就能分开。
        var regionN = 0
        var regionLum = 0.0
        for y in 0..<h { for x in 0..<w {
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))
            if regs.contains(where: { $0.contains(p) }) {
                regionN += 1
                regionLum += pixLum(base, x, y)
            }
        } }
        let regionLumAvg = regionN > 0 ? regionLum / Double(regionN) : 0
        var pxIn = 0, pxOut = 0, peak = 0.0, peakOut = 0.0, sum = 0.0
        for y in 0..<h { for x in 0..<w {
            let d = abs(pixLum(after, x, y) - pixLum(base, x, y)) * 255
            guard d >= 2 else { continue }          // <2 级是图形管线底噪（§189.5）
            sum += d
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(h) - (CGFloat(y) + 0.5))   // 位图第 0 行 = 顶部
            if regs.contains(where: { $0.contains(p) }) {
                pxIn += 1; if d > peak { peak = d }
            } else {
                pxOut += 1; if d > peakOut { peakOut = d }
            }
        } }
        let share = (pxIn + pxOut) > 0 ? 100.0 * Double(pxIn) / Double(pxIn + pxOut) : 0
        if sum < 1 { dead += 1 }
        // §209：颜色四项（牙齿/眼睛/唇色/腮红）**也纳入判据**了。
        // 第 3 轮把它们做成"只报告"是因为当时没有任何实测值 —— 先量、量出来都在 9~15 级、
        // 没有一项低于可见阈值，那就没有理由把它们留在判据之外（报告项没人看）。
        if peak < 5 { weak += 1 }   // 区内峰值 <5 级 = 满档也看不见
        if peakOut >= peak { badPeak += 1 }
        if share < 60 { badShare += 1 }    // 只报告：底噪会让这条在部分项上失真（见文件头说明）
        // ⚠️ **必须同时给出"在工作图上的像素数"**（§228）：诊断在 240px 缩略图上渲染，
        // 而工作图是 934~2160px。一个 32x15 px 的嘴唇在诊断尺度上只剩 8x4 —— 读数是"6 px 改动、
        // 峰值 3 级"，看着像功能坏了，其实是抽样摊平（§227 用六轮才查清这件事）。
        // 有了这一列，"3 级"一眼就能被认成"小目标在当前尺度下的读数"。
        let fullN = Double(regionN) / Double(max(1e-9, sx * sx))
        lines.append(String(format: "%@ 峰值 %.0f 级 ｜ 作用域 %d px（工作图 %.0f px，区内亮度 %.2f）｜ 区内 %d / 区外 %d px ｜ 占比 %.0f%% ｜ 区外最大 %.0f 级",
                            name, peak, regionN, fullN, regionLumAvg, pxIn, pxOut, share, peakOut))
    }
    for l in lines { emit("BIAUDIT " + l) }
    emit(String(format: "BIAUDIT-SUM items=%d dead=%d weak=%d badpeak=%d badshare=%d wx%d", items.count, dead, weak, badPeak, badShare, w))
    emit(String(format: "BIAUDIT-COLOR items=%d（已并入判据 H，与祛瑕 11 项同口径）", colorItems.count))
    emit("BIAUDIT 完")
}

/// **笔触的按图隔离**体检：手动笔触在"切走再切回"之后必须还在，而且**不能串到别的图上**。
///
/// 为什么单列：多图切换门里那条"不同图应 >3"比的是**两张不同的照片** ——
/// 两张不同的照片本来就该不一样，所以它**抓不到"笔触串图"**（§185.3）。
/// 而 `currentEditState()` 只存参数类状态（params/portrait/extras…）、**不含笔触**（Presets.swift:192），
/// 所以"笔触算哪张图的"这件事必须单独量。
/// 触发：CR_STROKEAUDIT=1（配合 CR_IMPORT="A,B"）。
func auditStrokePerImage() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard strip.count >= 2 else { emit("STROKEAUDIT 需要两张图（用 CR_IMPORT=\"A,B\"）"); return }
    let a = strip[0], b = strip[1]
    func peak(_ x: [UInt8]?, _ y: [UInt8]?) -> Double {
        guard let a0 = x, let b0 = y else { return -1 }
        var p = 0.0
        for i in 0..<(min(a0.count, b0.count) / 4) {
            p = max(p, max(abs(Double(a0[i * 4]) - Double(b0[i * 4])),
                           max(abs(Double(a0[i * 4 + 1]) - Double(b0[i * 4 + 1])),
                               abs(Double(a0[i * 4 + 2]) - Double(b0[i * 4 + 2])))))
        }
        return p
    }
    func snap() -> [UInt8]? { outImage.flatMap { auditSmall($0) } }
    switchToImage(a)
    let cleanA = snap()
    // 在 A 上下一笔（祛痘）：半径/强度给足，保证量得出来
    spotActive = true
    spotPoints = [CGPoint(x: 0.5, y: 0.45)]
    spotRadius = 60
    spotStrength = 90
    refresh()
    let editedA = snap()
    let editPeak = peak(cleanA, editedA)
    switchToImage(b)
    let cleanB = snap()
    let leak = peak(cleanB, snap())
    switchToImage(a)
    let backA = snap()
    let sameBack = peak(editedA, backA)
    emit(String(format: "STROKEAUDIT A 上那一笔：%.0f（应 >=3，说明确实改了画面）", editPeak))
    emit(String(format: "STROKEAUDIT 切到 B 后：与 B 干净态 峰值 %.0f（应 <=1；大了说明 A 的笔触串过来了）", leak))
    emit(String(format: "STROKEAUDIT 切回 A 后：与切走前 峰值 %.0f（应 <=1；大了说明笔触丢了）", sameBack))
    emit(String(format: "STROKEAUDIT-SUM edit=%.0f leak=%.0f back=%.0f", editPeak, leak, sameBack))
    emit("STROKEAUDIT 完")
}

/// **同步到选中图片**体检：把当前这套调整批量套到选中的几张上。
///
/// 为什么单列这一节：这是个实打实的功能（界面上叫「同步到选中图片」），
/// 但它**此前没有任何门覆盖** —— `tools/dist` 与 coretest 里都搜不到它（§178）。
/// 判据：选中的 N 张都要产出文件、且画面**确实变了**（不然"同步了个空气"也能算通过）。
/// 触发：CR_SYNCAUDIT=1（配合 CR_IMPORT 一张：缩略图条按该图所在目录载入）。
func auditSyncToSelected() {
    func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
    guard let cur = srcURL else { emit("SYNCAUDIT 没有工作图（先 CR_IMPORT 一张）"); return }
    // 单张导入**不会**填缩略图条（那是"导入文件夹"那条路做的）——
    // 体检自己把同目录的图装进来，模拟"用户导入了一个文件夹"的状态（否则这条永远测不了）。
    if strip.count < 2 {
        // 注意判据是"少于 2 张"而不是"空"：单张导入会把 strip 设成**只含当前这张**（实测踩到，
        // 用 isEmpty 判断时这条体检永远报"目标只有 0 张"，看着像功能坏了）
        let dir = cur.deletingLastPathComponent()
        strip = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        stripDir = dir
    }
    let others = strip.filter { $0 != cur }
    guard others.count >= 2 else {
        emit("SYNCAUDIT 可同步的目标只有 " + String(others.count) + " 张（需要 >=2）—— 先把夹具目录准备好"); return
    }
    let pick = Array(others.prefix(2))
    // 用一个**显著**的参数：暗角 80 —— 只要真套上了，画面必然变
    vignetteAmount = 80
    selectedStrip = Set(pick)
    let before = pick.map { loadAnyImage($0.path, maxDim: 500) }
    let outDir = pick[0].deletingLastPathComponent().appendingPathComponent("synced")
    try? FileManager.default.removeItem(atPath: outDir.path)
    emit("SYNCAUDIT 选中 " + String(pick.count) + " 张：" + pick.map { $0.lastPathComponent }.joined(separator: ","))
    applyToSelected()
    func waitDone(_ tries: Int) {
        if busy && tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waitDone(tries - 1) }
            return
        }
        var changed = 0, missing = 0
        for (i, u) in pick.enumerated() {
            let out = outDir.appendingPathComponent(
                exportName(export.nameTemplate, source: u.path, index: export.startIndex) + "." + export.fileExtension)
            guard let a = before[i], let b = loadAnyImage(out.path, maxDim: 500) else { missing += 1; continue }
            let (bufA, bufB) = (auditSmallCI(a), auditSmallCI(b))
            var peak = 0.0
            if let x = bufA, let y = bufB {
                for k in 0..<(min(x.count, y.count) / 4) {
                    peak = max(peak, max(abs(Double(x[k * 4]) - Double(y[k * 4])),
                                         max(abs(Double(x[k * 4 + 1]) - Double(y[k * 4 + 1])),
                                             abs(Double(x[k * 4 + 2]) - Double(y[k * 4 + 2])))))
                }
            }
            if peak > 2 { changed += 1 }
        }
        emit(String(format: "SYNCAUDIT-SUM picked=%d changed=%d missing=%d", pick.count, changed, missing))
        emit("SYNCAUDIT 完")
    }
    waitDone(120)
}

func auditSmall(_ n: NSImage) -> [UInt8]? {
        guard let cg = n.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let W = 96, H = max(1, Int(Double(W) * ci.extent.height / max(1, ci.extent.width)))
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        let sx = CGFloat(W) / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: W * 4,
                         bounds: CGRect(x: 0, y: 0, width: W, height: H),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }

    /// **撤销/重做体检**：这是用户的安全网，以前没有任何自动验证。
    /// 判据：撤销一次必须回到上一步的画面（而不是"画面没动"），
    ///       连续撤销到底必须回到**最初的原图**（导入状态也必须在历史里）。
    /// 触发：CR_UNDOAUDIT=1（配合 CR_IMPORT）。
    func auditUndoRedo() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil, let s0 = outImage, let b0 = auditSmall(s0) else {
            emit("UNDOAUDIT 没有工作图（先 CR_IMPORT 一张）"); return
        }
        func peak(_ a0: [UInt8]?, _ b: NSImage?) -> Double {
            guard let a0 = a0, let b = b, let b0 = auditSmall(b) else { return -1 }
            var p = 0.0
            for i in 0..<(min(a0.count, b0.count) / 4) {
                p = max(p, max(abs(Double(a0[i * 4]) - Double(b0[i * 4])),
                               max(abs(Double(a0[i * 4 + 1]) - Double(b0[i * 4 + 1])),
                                   abs(Double(a0[i * 4 + 2]) - Double(b0[i * 4 + 2])))))
            }
            return p
        }
        // 走**真实的笔流程**：起笔 → 拖动中重渲（增量路径）→ 收笔（批量定稿）。
        // 直接 refresh() + pushHistory() 会绕过收笔那一步，量不出"预览 ≠ 导出"这类问题。
        func edit(_ label: String, _ pts: [CGPoint]) {
            beginStrokeHistory(label)
            spotActive = true; spotPoints = pts
            refresh()
            endStrokeHistory()
        }
        emit(String(format: "UNDOAUDIT 历史初态：条数 %d ｜ 游标 %d", history.count, historyCursor))
        edit("自检-编辑1", [CGPoint(x: 0.42, y: 0.45)])
        let e1 = outImage.flatMap { auditSmall($0) }
        emit(String(format: "UNDOAUDIT 编辑1 后：条数 %d ｜ 游标 %d ｜ vs 初始 峰值 %.0f", history.count, historyCursor, peak(b0, outImage)))
        edit("自检-编辑2", [CGPoint(x: 0.42, y: 0.45), CGPoint(x: 0.52, y: 0.55)])
        let e2 = outImage.flatMap { auditSmall($0) }
        emit(String(format: "UNDOAUDIT 编辑2 后：条数 %d ｜ 游标 %d ｜ vs 编辑1 峰值 %.0f", history.count, historyCursor, peak(e1, outImage)))

        undo()
        emit(String(format: "UNDOAUDIT 撤销1 次后：游标 %d ｜ vs 编辑2 峰值 %.0f ｜ vs 编辑1 峰值 %.0f ｜ vs 初始 峰值 %.0f",
                    historyCursor, peak(e2, outImage), peak(e1, outImage), peak(b0, outImage)))
        undo()
        emit(String(format: "UNDOAUDIT 撤销2 次后：游标 %d ｜ vs 编辑1 峰值 %.0f ｜ vs 初始 峰值 %.0f",
                    historyCursor, peak(e1, outImage), peak(b0, outImage)))
        undo()
        emit(String(format: "UNDOAUDIT 撤销3 次后：游标 %d ｜ vs 初始 峰值 %.0f", historyCursor, peak(b0, outImage)))
        redo()
        emit(String(format: "UNDOAUDIT 重做1 次后：游标 %d ｜ vs 编辑1 峰值 %.0f ｜ vs 初始 峰值 %.0f",
                    historyCursor, peak(e1, outImage), peak(b0, outImage)))
        redo()
        emit(String(format: "UNDOAUDIT 重做2 次后：游标 %d ｜ vs 编辑2 峰值 %.0f（应≈0；不为 0 说明同一状态两次渲染不一致）",
                    historyCursor, peak(e2, outImage)))
        emit("UNDOAUDIT 完")
    }

    /// 把 CIImage 渲染成 256 宽的小缓冲（给"变化落在哪个区域"这类判据用）。
    /// ⚠️ 用 96 宽踩过坑：小脸的眼睛掩膜在 96 网格上覆盖率显示 **0.00%**，但画面确实变了 ——
    /// 那是采样分辨率极限，不是"掩膜是空的"。覆盖率的判据必须在够细的网格上量。
    func auditSmallCI(_ img: CIImage) -> [UInt8]? {
        let ci = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        let W = 256, H = max(1, Int(Double(W) * ci.extent.height / max(1, ci.extent.width)))
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        let sx = CGFloat(W) / max(1, ci.extent.width)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sx))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: W * 4,
                         bounds: CGRect(x: 0, y: 0, width: W, height: H),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }

    /// 当前进程的常驻内存（MB）。稳定性体检用：长时间跑会不会一路涨上去。
    /// （`mach_task_basic_info` 的 resident_size：Mac 上就等于活动监视器里的"内存"）
    func auditRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), q, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    /// **稳定性体检**：连续换图 N 轮 + 每轮套预设/撤销/重渲，看**常驻内存会不会一路涨**、会不会崩。
    /// 为什么需要它：桌面应用最怕"开了两小时越来越卡/突然崩"，而这类问题在功能测试里完全看不到。
    /// 触发：CR_STRESSAUDIT=1（配合 CR_IMPORT="a.jpg,b.jpg,…" 多张）。
    func auditStress() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil else { emit("STRESSAUDIT 没有工作图（先 CR_IMPORT）"); return }
        guard strip.count >= 2 else { emit("STRESSAUDIT 只导入了 \(strip.count) 张，至少 2 张才能换图压测"); return }
        // 按动作拆开量：只有知道"是哪一步在涨"，才好修。
        // CR_STRESS_MODE=switch（只换图）| refresh（只重渲）| preset（只套预设+撤销）| all（默认，全上）
        let mode = ProcessInfo.processInfo.environment["CR_STRESS_MODE"] ?? "all"
        let start = auditRSSMB()
        emit(String(format: "STRESSAUDIT 起始常驻 %.0f MB ｜ 条带 %d 张 ｜ 预设 %d 条 ｜ 模式 %@",
                    start, strip.count, styles.count, mode))
        let rounds = Int(ProcessInfo.processInfo.environment["CR_STRESS_ROUNDS"] ?? "20") ?? 20
        var peak = start
        var times: [Double] = []
        for i in 1...rounds {
            // ⚠️ 每轮必须有 autoreleasepool：真实使用里每次交互是**一个 runloop 迭代**，
            // 池会在迭代结束时排空；而体检是**一次主线程调用里连跑 20~60 轮** ——
            // 不套池的话所有 autoreleased 的 CGImage/NSImage 都堆到循环结束，
            // 实测"每轮 +11 MB、60 轮涨到 892 MB"，看着像内存泄漏，其实是**测试自己没排池**。
            var dtms = 0.0
            autoreleasepool {
                let t0 = Date()
                if mode == "switch" || mode == "all" { switchToImage(strip[i % strip.count]) }
                if mode == "preset" || mode == "all" {
                    if !styles.isEmpty { applyPreset(styles[i % styles.count]) }
                    undo()
                }
                refresh()
                // 首帧出图：用户点下一张之后**真正要等的那一段**（切图 + 管线 + 出图）。
                // 只量内存是不够的 —— 内存平台化不代表"点一下不卡"（§196 起把这一条纳入判据）。
                if let ci = workImage() {
                    let out = renderPipeline(ci, geos: cachedGeos)
                    _ = sharedCtx.createCGImage(out, from: out.extent.integral)
                }
                dtms = Date().timeIntervalSince(t0) * 1000
            }
            times.append(dtms)
            // ⚠️ **必须每轮让出一次 runloop**（默认开，CR_STRESS_YIELD=0 可关掉做对照）。
            // 真实使用里每次交互都回到 runloop，SwiftUI 的视图更新会被处理、图片随之释放；
            // 而体检如果连着写 @State，这些更新会排队积压 ——
            // 实测：不让出时"每轮 +12.6 MB、40 轮涨到 666 MB"，看着像内存泄漏；
            // 让出之后**完全平台化**（189 → 202 → 201 MB）。那 20 分钟的排查差点让我去改产品代码。
            if ProcessInfo.processInfo.environment["CR_STRESS_YIELD"] != "0" {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            let now = auditRSSMB()
            peak = max(peak, now)
            if i % 5 == 0 || i == rounds {
                emit(String(format: "STRESSAUDIT 第 %2d 轮：常驻 %.0f MB（峰值 %.0f）", i, now, peak))
            }
        }
        // 清一次缓存再看：切回第一张 + 重渲
        switchToImage(strip[0]); refresh()
        let end = auditRSSMB()
        emit(String(format: "STRESSAUDIT 结束常驻 %.0f MB ｜ 峰值 %.0f MB ｜ 漂移 %+.0f MB（%+.0f%%）",
                    end, peak, end - start, start > 0 ? (end - start) / start * 100 : 0))
        let st = times.sorted()
        let med = st.isEmpty ? 0 : st[st.count / 2]
        let p95 = st.isEmpty ? 0 : st[min(st.count - 1, Int(Double(st.count) * 0.95))]
        emit(String(format: "STRESSAUDIT 切图+首帧耗时：中位 %.0f ms ｜ p95 %.0f ms ｜ 最快 %.0f ｜ 最慢 %.0f",
                    med, p95, st.first ?? 0, st.last ?? 0))
        emit(String(format: "STRESSAUDIT-SUM rounds=%d start=%.0f peak=%.0f end=%.0f drift=%.0f switch_median=%.0f switch_p95=%.0f",
                    rounds, start, peak, end, end - start, med, p95))
        emit("STRESSAUDIT 完")
    }

    /// 逐类 A/B 评测用（§259）：把**当前**人脸解析模型的标签图存成 PGM（0~18 灰度），
    /// 便于和外部候选模型（Python/onnxruntime）逐类比对。触发：CR_DUMPLABELS=/path.pgm（配合 CR_IMPORT）。
    func dumpLabelMap(_ path: String) {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard let img = workImage() else { emit("DUMPLABELS 没有工作图（先 CR_IMPORT）"); return }
        // §266：评测必须**复刻产品的输入口径**。产品是「按脸取 1.7 倍正方形裁剪 → 解析该裁剪」
        //（parsedMaskForFace: side = max(脸宽,脸高) * (1 + 0.35*2)）。
        // 我上一轮解析整图 ⇒ 尺度差好几倍，测的是产品根本不走的那条路（§265）。
        // CR_DUMPCROP=1 时改用同样的裁剪，并把该裁剪导出成 PPM（512x512），供 Python 侧用**同一输入**跑候选。
        var src = img
        if ProcessInfo.processInfo.environment["CR_DUMPCROP"] == "1",
           let g = cachedGeos.max(by: { $0.box.width < $1.box.width }) {
            let side = max(g.box.width, g.box.height) * 1.7
            let crop = CGRect(x: g.box.midX - side / 2, y: g.box.midY - side / 2, width: side, height: side)
                .intersection(img.extent)
            if crop.width > 24 {
                src = img.cropped(to: crop)
                emit(String(format: "DUMPLABELS 人脸裁剪 %.0fx%.0f（脸 %.0f）", crop.width, crop.height, g.box.width))
                let S = 512
                // ⚠️ 必须先把裁剪**平移到原点**再缩放：cropped(to:) 保留裁剪的 extent 起点（crop.origin），
                // 而 render(bounds: 0,0,S,S) 是按 [0,0] 取的 ⇒ 直接渲染会得到一张**全黑图**
                //（这一轮就栽在这：候选在裁剪 PPM 上全部输出「背景」，我一度误判成上下翻转 ✗）。
                let scaled = src.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .transformed(by: CGAffineTransform(scaleX: CGFloat(S) / max(1, crop.width),
                                                      y: CGFloat(S) / max(1, crop.height)))
                var buf = [UInt8](repeating: 0, count: S * S * 4)
                sharedCtx.render(scaled, toBitmap: &buf, rowBytes: S * 4,
                                 bounds: CGRect(x: 0, y: 0, width: S, height: S), format: .RGBA8,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                var ppm = Data("P6\n\(S) \(S)\n255\n".utf8)
                for i in 0..<(S * S) { ppm.append(contentsOf: [buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2]]) }
                try? ppm.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".pgm", with: ".ppm")))
            }
        }
        guard let cg = sharedCtx.createCGImage(src, from: src.extent) else { emit("DUMPLABELS 建图失败"); return }
        guard let r = FaceParser.shared.parse(cg) else { emit("DUMPLABELS 解析失败"); return }
        let side = max(1, Int(Double(r.labels.count).squareRoot().rounded()))
        var out = Data("P5\n\(side) \(side)\n255\n".utf8)
        out.append(contentsOf: r.labels.prefix(side * side))
        do {
            try out.write(to: URL(fileURLWithPath: path))
            emit("DUMPLABELS 已写 \(path) \(side)x\(side)")
        } catch { emit("DUMPLABELS 写失败：\(error)") }
        emit("DUMPLABELS 完")
    }
    /// 四肢选型探针（§255，③ 用）：把「现有关键点掩膜」与「Vision 人体分割」放在同一张图上量。
    /// 目的：回答「换个来源能不能提升覆盖率」—— 尤其在**关节掩膜为空**的图上，人像掩膜还有没有。
    /// 只报告不判据（选型数据，不是门）。触发：CR_LIMBSEG=1（配合 CR_IMPORT）。
    func auditLimbSeg() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard let img = workImage() else { emit("LIMBSEG 没有工作图（先 CR_IMPORT）"); return }
        let geos = cachedGeos
        let e = img.extent
        // 这个小文件里 coverage 是别处的私有函数，探针自己数（与 MCAUDIT 同一套：缩到 256 宽渲染取值）
        // ⚠️ 别叫 pct：核心层 Auto2/CoreIO 里已有同名函数，重复实现审计会把它当「界面又写了一份核心逻辑」
        //（§256：误报，但正解是改名而不是加白名单 —— 白名单会让这条检查永久变黄）
        func limbMaskPct(_ m: CIImage) -> Double {
            let w = 256
            let h = max(1, Int(Double(w) * e.height / max(1, e.width)))
            let small = m.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / max(1, e.width),
                                                           y: CGFloat(h) / max(1, e.height)))
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                             bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var n = 0
            for i in 0..<(w * h) where buf[i * 4] > 128 { n += 1 }
            return Double(n) / Double(w * h) * 100
        }
        var armsPct = 0.0, legsPct = 0.0
        if let am = partMask(img, part: .arms, geos: geos) { armsPct = limbMaskPct(am) }
        if let lm = partMask(img, part: .legs, geos: geos) { legsPct = limbMaskPct(lm) }
        let t0 = Date()
        let pm = personMask(img)
        let ms = Date().timeIntervalSince(t0) * 1000
        var personPct = -1.0
        var box = CGRect.zero
        if let pm = pm {
            personPct = limbMaskPct(pm)
            box = bboxOfBright(pm, in: e, threshold: 128)
        }
        emit(String(format: "LIMBSEG 脸%d ｜ 手臂 %.2f%% ｜ 腿 %.2f%% ｜ 人像掩膜 %.2f%%（盒 %.0fx%.0f）｜ 人像分割耗时 %.0f ms",
                    geos.count, armsPct, legsPct, personPct, box.width, box.height, ms))
        if armsPct < 0.01 && legsPct < 0.01 {
            emit(personPct > 0.5 ? "LIMBSEG 结论：关节掩膜为空但人像掩膜仍在 ⇒ 可用它兜底提升覆盖率"
                                 : "LIMBSEG 结论：关节与人像掩膜都为空 ⇒ 两者都失效（换来源也救不了）")
        }
        emit("LIMBSEG 完")
    }

    /// **按部位体检**：逐个部位（脸/眼/唇/鼻/耳/手臂/腿）拉一个强增量，看"画面变了没"以及    /// **变化是不是落在该部位的掩膜里**。coretest 只验过"笔触构造"，UI → 管线这一段没量过。
    /// 触发：CR_PARTAUDIT=1（配合 CR_IMPORT）。
    func auditParts() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil, let img = workImage() else { emit("PARTAUDIT 没有工作图（先 CR_IMPORT）"); return }
        let geos = cachedGeos
        var sum = "PARTAUDIT-SUM faces=" + String(geos.count)
        for part in BodyPart.allCases {
            partAdjusts = []; refresh()
            let before = outImage.flatMap { auditSmallCI(CIImage(cgImage: $0.cgImage(forProposedRect: nil, context: nil, hints: nil)!)) }
            var pa = PartAdjust(part: part.rawValue); pa.dBrightness = 40
            partAdjusts = [pa]; refresh()
            let after = outImage.flatMap { auditSmallCI(CIImage(cgImage: $0.cgImage(forProposedRect: nil, context: nil, hints: nil)!)) }
            var peak = 0.0, changed = 0, inside = 0, maskPct = 0.0, peakInMask = 0
            var centroidInMask = 0, maskSupport = 0       // 原来这里还有个 maskPixels：只写不读，2026-09-26 删
            if let a = before, let b = after, a.count == b.count {
                let mb = partMask(img, part: part, geos: geos).flatMap { auditSmallCI($0) }
                let n = a.count / 4
                var maskN = 0, peakIdx = 0
                var wx = 0.0, wy = 0.0, wsum = 0.0
                let W = 256
                for i in 0..<n {
                    let d = max(abs(Double(a[i * 4]) - Double(b[i * 4])),
                                max(abs(Double(a[i * 4 + 1]) - Double(b[i * 4 + 1])),
                                    abs(Double(a[i * 4 + 2]) - Double(b[i * 4 + 2]))))
                    if d > peak { peak = d; peakIdx = i }
                    // ⚠️ 两侧口径都要说清：
                    //   · "掩膜支撑区" 用 >8（掩膜的羽化带也算它的一部分）——拿它算"改动有没有漏到外面"
                    //   · "掩膜核心区" 用 >128 —— 拿它算覆盖与峰值定位
                    // 一开始只用 >128 算比例，脸上羽化带宽，比例只有 37%，看着像"改动漏出去了"，
                    // 其实是口径错（羽化本来就在掩膜里）。
                    let inCore = (mb.map { $0[i * 4] > 128 }) ?? false
                    let inSupport = (mb.map { $0[i * 4] > 8 }) ?? false
                    if inCore { maskN += 1 }
                    if inSupport { maskSupport += 1 }
                    if d >= 3 { changed += 1; if inSupport { inside += 1 } }
                    if d >= 3 { wx += Double(i % W) * d; wy += Double(i / W) * d; wsum += d }
                }
                maskPct = Double(maskN) / Double(max(1, n)) * 100
                _ = maskN
                // 变化最强的那个点、以及变化量的加权重心，是否落在掩膜里 ——
                // 这两条比"变了多少像素落在掩膜内"稳得多：羽化边缘在 96 宽缩图上本来就会被算到"外面"。
                // 峰值是否落在掩膜里，用**支撑区**（>8）判：小脸的"眼睛"掩膜核心可能不到一个采样点，
                // 用 >128 判会得出"没有掩膜"的假结论（全身照实测就是这种情况）。
                peakInMask = ((mb.map { $0[peakIdx * 4] > 8 }) ?? false) ? 1 : 0
                _ = centroidInMask
                if wsum > 0 {
                    let ci = Int(wy / wsum) * W + Int(wx / wsum)
                    centroidInMask = ((mb.map { $0[ci * 4] > 128 }) ?? false) ? 1 : 0
                }
            }
            let ratio = changed > 0 ? Double(inside) / Double(changed) * 100 : -1
            emit(String(format: "PARTAUDIT %@ 峰值 %3.0f ｜ 变了 %d 像素 ｜ 掩膜内(硬阈值) %.0f%% ｜ 掩膜覆盖 %.2f%% ｜ 峰值在掩膜内 %@ ｜ 重心在掩膜内 %@",
                        part.rawValue, peak, changed, ratio, maskPct,
                        peakInMask == 1 ? "是" : "否", centroidInMask == 1 ? "是" : "否"))
            // §250：耳朵补「掩膜是否在耳位」的字段 —— 面积/占比量不出位置（§243 那次改动门看不出差别）。
            // xo = 掩膜包围盒中线相对脸框中心的横向偏移（脸宽为单位）；sw = 掩膜宽度/脸宽。
            // 判据同 coretest §244：解析路径偏一侧（|xo| > 0.3）｜兜底路径跨两侧（sw > 0.8）。
            var posExtra = ""
            if part == .ears, let em = partMask(img, part: .ears, geos: geos) {
                let b = bboxOfBright(em, in: img.extent, threshold: 128)
                if let fb = geos.max(by: { $0.box.width < $1.box.width })?.box, fb.width > 1 {
                    posExtra = String(format: ":xo%+.2f:sw%.2f", (b.midX - fb.midX) / fb.width, b.width / fb.width)
                }
            }
            sum += String(format: " %@:p%.0f:s%d:r%.0f:pk%d",
                          part.rawValue, peak, maskSupport, ratio, peakInMask) + posExtra
        }
        partAdjusts = []; refresh()
        emit(sum)
        emit("PARTAUDIT 完")
    }

    /// **场景推荐体检**：`classifyScene` 认出来的类别 + `suggestParams` 是否真的落到了参数上。
    /// 为什么要有它：场景推荐是"智能"功能，可它以前没有任何检查 —— 分类器退化成"永远返回同一个类别"
    /// 或者建议没落到参数上，都不会有人发现。
    /// 触发：CR_SCENEAUDIT=1（配合 CR_IMPORT）。
    func auditSceneSuggest() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil, let img = workImage(), sharedCtx.createCGImage(img, from: img.extent) != nil else {
            emit("SCENEAUDIT 没有工作图（先 CR_IMPORT 一张）"); return
        }
        let before = outImage.flatMap { auditSmall($0) }
        runSceneSuggest()
        let after = outImage.flatMap { auditSmall($0) }
        var peak = 0.0
        if let a = before, let b = after {
            for i in 0..<(min(a.count, b.count) / 4) {
                peak = max(peak, max(abs(Double(a[i * 4]) - Double(b[i * 4])),
                                     max(abs(Double(a[i * 4 + 1]) - Double(b[i * 4 + 1])),
                                         abs(Double(a[i * 4 + 2]) - Double(b[i * 4 + 2])))))
            }
        }
        let info = sceneInfo ?? SceneInfo()
        emit("SCENEAUDIT 类别「" + info.category + "」｜ 脸 " + String(info.faces) + " ｜ 人 "
             + String(info.people) + " ｜ 动物 " + String(info.animals)
             + " ｜ 依据：" + info.reasons.joined(separator: "；"))
        emit(String(format: "SCENEAUDIT 建议落地：画面变化峰值 %.0f ｜ 张数 %d", peak, info.labels.count))
        emit("SCENEAUDIT-SUM cat=" + info.category + String(format: " faces=%d people=%d animals=%d peak=%.0f",
                                                             info.faces, info.people, info.animals, peak))
        emit("SCENEAUDIT 完")
    }

    /// **参考追色体检**：solveRef（把参考图折算成目标）→ applyRef（走界面同一条路）→ **独立量**"离参考近了没"。
    /// 为什么单独量：核心的 matchToReference 自己会返回 before/err，用它自己的数等于"自己给自己判卷"。
    /// 触发：CR_REFAUDIT=1（配合 CR_IMPORT 与 --reference=<图片路径，逗号分隔>）。
    func auditReference() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil, let img = workImage() else {
            emit("REFAUDIT 没有工作图（先 CR_IMPORT 一张）"); return
        }
        guard !refPaths.isEmpty else { emit("REFAUDIT 没设参考图（--reference=…）"); return }
        solveRef()
        // 把折算出来的目标打出来：闸门（白底文档/截图）为什么不触发，全靠这几个数说话
        if let tt = refTargetStats {
            emit(String(format: "REFAUDIT 目标 q5/q50/q95 = %.3f/%.3f/%.3f ｜ sat %.2f ｜ 暖冷 阴影%+.2f 高光%+.2f",
                        tt.q5, tt.q50, tt.q95, tt.sat, tt.warmSh, tt.warmHi))
        } else {
            emit("REFAUDIT 目标 = nil（被拒）｜ " + refInfo)
        }
        guard let t = refTargetStats else {
            // 拒绝也算一种结果：脚本按用例判定（白底文档/读不到的参考必须被拒）
            emit("REFAUDIT 参考被拒：" + refInfo)
            emit("REFAUDIT-SUM accepted=0 before=-1 after=-1")
            emit("REFAUDIT 完"); return
        }
        let before = measure(img).distance(to: t)
        let baseBuf = outImage.flatMap { auditSmall($0) }
        applyRef()                                  // 界面按「参考追色」按钮走的就是这条
        let after = measure(renderPipeline(img, geos: cachedGeos)).distance(to: t)
        let outBuf = outImage.flatMap { auditSmall($0) }
        var peak = 0.0
        if let a = baseBuf, let b = outBuf {
            for i in 0..<(min(a.count, b.count) / 4) {
                peak = max(peak, max(abs(Double(a[i * 4]) - Double(b[i * 4])),
                                     max(abs(Double(a[i * 4 + 1]) - Double(b[i * 4 + 1])),
                                         abs(Double(a[i * 4 + 2]) - Double(b[i * 4 + 2])))))
            }
        }
        emit(String(format: "REFAUDIT 追色：与参考的误差 %.4f → %.4f（应更小）｜ 画面变化峰值 %.0f ｜ 分区 %d",
                    before, after, peak, regionMatches.count))
        emit(String(format: "REFAUDIT-SUM accepted=1 before=%.4f after=%.4f peak=%.0f", before, after, peak))
        emit("REFAUDIT 完")
    }

    /// **一键智能体检**：智能裁剪 / 肩线校平 / 按人物裁剪。
    /// 这三个是"算出来的结果"，所以能用**人造真值**卡：
    ///   智能裁剪 3:4 → 裁剪框宽高比必须是 0.750；按人物裁剪同理；
    ///   肩线校平 → 应用的旋转必须等于"检出倾角的反向"（脚本再拿人造旋转图做差分验证）。
    /// 触发：CR_SMARTAUDIT=1（配合 CR_IMPORT）。
    func auditSmartActions() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil, let img = workImage(),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else {
            emit("SMARTAUDIT 没有工作图（先 CR_IMPORT 一张）"); return
        }
        let e = img.extent
        // ① 智能裁剪 3:4
        cropAspect = "3:4"
        runSmartCrop()
        let cr1 = cropRect ?? .zero            // cropRect 是可选：显式解包，别让类型推断去猜
        let cw = Double(cr1.width) * Double(e.width)
        let chh = Double(cr1.height) * Double(e.height)
        let cropAR = chh > 1 ? cw / chh : 0
        emit(String(format: "SMARTAUDIT 智能裁剪 3:4 → %.0fx%.0f 宽高比 %.3f（真值 0.750）", cw, chh, cropAR))

        // ② 肩线校平：先取核心函数的倾角当真值，再看应用了多少
        let tilt = shoulderTilt(cg, extent: e)
        levelShoulders()
        emit(String(format: "SMARTAUDIT 肩线校平：检出倾角 %@ → 应用 %+.2f°（应等于倾角的反向，且夹在 ±10°）",
                    tilt.map { String(format: "%+.2f°", $0) } ?? "没检出", rotateDeg))
        let tiltV = tilt ?? 0

        // ③ 按人物裁剪（要走人物实例分割，慢）
        detectPersons()
        let persons = personRects.count
        var personAR = 0.0
        if persons > 0 {
            cropToPerson(0)
            let cr2 = cropRect ?? .zero
            let pw = Double(cr2.width) * Double(e.width)
            let ph = Double(cr2.height) * Double(e.height)
            personAR = ph > 1 ? pw / ph : 0
            emit(String(format: "SMARTAUDIT 按人物裁剪：%d 人 → %.0fx%.0f 宽高比 %.3f（真值 0.750）",
                        persons, pw, ph, personAR))
        } else {
            emit("SMARTAUDIT 按人物裁剪：这张图没检出人物")
        }
        emit(String(format: "SMARTAUDIT-SUM cropAR=%.3f tilt=%.2f applied=%.2f persons=%d personAR=%.3f",
                    cropAR, tiltV, rotateDeg, persons, personAR))
        emit("SMARTAUDIT 完")
    }

    /// **预设体检**：套用 / 再点一次取消 / 切换 / 撤销后再套 —— 用户报过"再点一次仍没实现"，
    /// 四条路径的**中间状态**（appliedPresetKey / prePresetSnapshot）以前没人量过。
    /// 触发：CR_PRESETAUDIT=1（配合 CR_IMPORT）。
    func auditPresets() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil, let s0 = outImage, let a0 = auditSmall(s0) else {
            emit("PRESETAUDIT 没有工作图（先 CR_IMPORT 一张）"); return
        }
        guard styles.count >= 2 else { emit("PRESETAUDIT 预设不足 2 条（\(styles.count)）"); return }
        // ⚠️ 必须**每步先存缓冲、再两两比**：写成"拿当前画面比"会量到错的那一刻
        //（第一版就是这么错的：S3 的"Q 后 vs P"是在取消 Q 之后才比的，恒为 0；
        //  S4 的两条也都量成了同一时刻）—— 指标口径错了，门就会既假红又假绿。
        func peakBetween(_ a: [UInt8]?, _ b: [UInt8]?) -> Double {
            guard let a = a, let b = b else { return -1 }
            var p = 0.0
            for i in 0..<(min(a.count, b.count) / 4) {
                p = max(p, max(abs(Double(a[i * 4]) - Double(b[i * 4])),
                               max(abs(Double(a[i * 4 + 1]) - Double(b[i * 4 + 1])),
                                   abs(Double(a[i * 4 + 2]) - Double(b[i * 4 + 2])))))
            }
            return p
        }
        func grab() -> [UInt8]? { outImage.flatMap { auditSmall($0) } }
        let p = styles[0], q = styles[1]
        emit("PRESETAUDIT 预设：[0] \(p.name) ｜ [1] \(q.name) ｜ 叠加模式 \(applyMode)")

        // S1 套用 / S2 再点一次取消
        applyPreset(p); let bufP = grab()
        let keyAfterS1 = appliedPresetKey != nil
        applyPreset(p); let bufCancel = grab()
        let keyAfterS2 = appliedPresetKey != nil
        emit(String(format: "PRESETAUDIT S1 套用 P：vs 基线 峰值 %.0f（应 ≥3）｜ appliedKey 非空 %@",
                    peakBetween(a0, bufP), keyAfterS1 ? "是" : "否"))
        emit(String(format: "PRESETAUDIT S2 再点一次取消：vs 基线 峰值 %.0f（应 ≤1）｜ appliedKey 空 %@",
                    peakBetween(a0, bufCancel), keyAfterS2 ? "否" : "是"))

        // S4 套 P → 撤销 → 再套 P（此刻状态是"基线、无预设"，S2 刚清干净）
        // 撤销之后 appliedPresetKey 若还留着，第二次会被当成"取消" → 画面拍回陈旧快照 = 没反应
        applyPreset(p)
        undo(); let bufUndo = grab()
        applyPreset(p); let bufRe = grab()
        emit(String(format: "PRESETAUDIT S4 套P→撤销→再套P：撤销后 vs 基线 %.0f（应 ≤1）｜ 再套后 vs 基线 %.0f（应 ≥3 = 与 S1 一样生效）",
                    peakBetween(a0, bufUndo), peakBetween(a0, bufRe)))

        // S3 套 P → 套 Q → 取消 Q：取消应回到"套用 Q 之前"= P 的状态，而不是回到最初
        //（放在最后，因为它结束时画面停在 P 的样子）
        let bufP2 = bufRe
        applyPreset(q); let bufQ = grab()
        applyPreset(q); let bufCancelQ = grab()
        emit(String(format: "PRESETAUDIT S3 套P→套Q→取消Q：Q vs P %.0f（Q 应生效 ≥3）｜ 取消后 vs P %.0f（应 ≤1）｜ 取消后 vs 基线 %.0f（应 ≥3 = 还是带着 P）",
                    peakBetween(bufP2, bufQ), peakBetween(bufP2, bufCancelQ), peakBetween(a0, bufCancelQ)))
        emit(String(format: "PRESETAUDIT-SUM s1=%.0f s2=%.0f s4undo=%.0f s4re=%.0f s3q=%.0f s3cancel=%.0f s3base=%.0f",
                    peakBetween(a0, bufP), peakBetween(a0, bufCancel),
                    peakBetween(a0, bufUndo), peakBetween(a0, bufRe),
                    peakBetween(bufP2, bufQ), peakBetween(bufP2, bufCancelQ), peakBetween(a0, bufCancelQ)))
        emit("PRESETAUDIT 完")
    }

    /// **多图切换体检**：切来切去时，每张图自己的编辑还在不在（`editStates` 的记忆）。
    /// 这是数据完整性：用户在 A 图上修了半天，切到 B 看一眼再切回来，A 的编辑必须还在。
    /// 触发：CR_STRIPAUDIT=1（配合 CR_IMPORT="a.jpg,b.jpg" 两张）。
    func auditStripStates() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

        guard srcURL != nil, let s0 = outImage, let a0 = auditSmall(s0) else {
            emit("STRIPAUDIT 没有工作图（先 CR_IMPORT 两张）"); return
        }
        guard strip.count >= 2 else { emit("STRIPAUDIT 只导入了 \(strip.count) 张，切图体检需要 2 张"); return }
        func peak(_ a: [UInt8]?, _ b: NSImage?) -> Double {
            guard let a = a, let b = b, let b0 = auditSmall(b) else { return -1 }
            var p = 0.0
            for i in 0..<(min(a.count, b0.count) / 4) {
                p = max(p, max(abs(Double(a[i * 4]) - Double(b0[i * 4])),
                               max(abs(Double(a[i * 4 + 1]) - Double(b0[i * 4 + 1])),
                                   abs(Double(a[i * 4 + 2]) - Double(b0[i * 4 + 2])))))
            }
            return p
        }
        let uA = srcURL!, uB = strip[1]
        emit("STRIPAUDIT 开始：条带 \(strip.count) 张 ｜ 当前 \((uA.lastPathComponent))")

        // 在 A 上修一笔
        beginStrokeHistory("自检-A图编辑")
        spotActive = true; spotPoints = [CGPoint(x: 0.42, y: 0.45)]
        refresh()
        endStrokeHistory()
        let a1 = outImage.flatMap { auditSmall($0) }
        let editPeak = peak(a0, outImage)
        emit(String(format: "STRIPAUDIT A 图编辑后：vs A 原样 峰值 %.0f（应 ≥3）", editPeak))

        // 切到 B：必须是"干净"的，而且不能带着 A 的编辑
        // 记下切换**前**的条数：它必须是 2（"打开"这条基准 + 刚才那一笔）。
        // 少了这条判据，"切图重建历史"坏掉时会**假通过** —— 因为基准没入栈时条数恰好也是 1，
        // 而撤销又会因为 cursor>0 的守卫而拒绝（负向验证时踩到，第 143 节）。
        let histBefore = history.count
        switchToImage(uB)
        let b0 = outImage.flatMap { auditSmall($0) }
        let bHist = history.count
        let cross = peak(a1, outImage)
        emit(String(format: "STRIPAUDIT 切到 B：历史 \(bHist) 条 ｜ 与 A 编辑后 峰值 %.0f（不同图应 >3）｜ history[0]=\(history.first?.label ?? "-")",
                    cross))

        // 在 B 上按撤销：必须是"已经是最初的状态"，画面不许动
        let bBefore = outImage.flatMap { auditSmall($0) }
        undo()
        let undoPeak = peak(bBefore, outImage)
        emit(String(format: "STRIPAUDIT 在 B 上按撤销：与按前 峰值 %.0f（应 =0，不许把 A 的编辑套过来）｜ 状态：\(status)",
                    undoPeak))

        // 切回 A：编辑必须还在
        switchToImage(uA)
        let backPeak = peak(a1, outImage), rawPeak = peak(a0, outImage)
        emit(String(format: "STRIPAUDIT 切回 A：与 A 编辑后 峰值 %.0f（应 ≤1 = 编辑还在）｜ 与 A 原样 峰值 %.0f（应 ≥3 = 确实带着编辑）",
                    backPeak, rawPeak))
        _ = b0
        // 机器可读汇总行（ASCII）：脚本按它判据 —— 别再从中文行里抠数字，
        // awk 在多字节文本上按**字节**算偏移，中文单位会把"历史 1 条"读成 0（踩过）。
        emit(String(format: "STRIPAUDIT-SUM histBefore=%d hist=%d edit=%.0f cross=%.0f undo=%.0f back=%.0f raw=%.0f",
                    histBefore, bHist, editPeak, cross, undoPeak, backPeak, rawPeak))
        emit("STRIPAUDIT 完")
    }

    /// **交互工具体检**：把「工具 → 状态 → 渲染」这条链整条量一遍。
    ///
    /// 为什么单独做一份：coretest 验的是核心函数、体检表验的是**参数**，而
    /// 污点修复 / 修补 / 仿制 / 液化 / 裁剪 这些**交互工具**走的是
    /// 「simulateTool 改状态 → refresh 重渲」这条路 —— 以前只有人手点一次才知道通不通，
    /// 重构或改渲染管线时它们坏了没有任何门会响。
    /// 触发：CR_TOOLAUDIT=1（配合 CR_IMPORT）。
    func auditToolPipeline() {
        func emit(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
        guard srcURL != nil else { emit("TOOLAUDIT 没有工作图（先 CR_IMPORT 一张）"); return }
        // 缩到 96 宽逐像素比：整幅平均对**局部**改动几乎不动（CR_PUSH 自检踩过，量出过 0.000）
        func small(_ n: NSImage) -> [UInt8]? { auditSmall(n) }
        // 每个工具之前必须**清干净**：否则上一条笔触会留在"底图"里，量出来的是累加效果
        func clearTools() {
            spotActive = false; patchActive = false; cloneActive = false; brushActive = false; cropMode = false
            spotPoints = []; clonePoints = []; warpStrokes = []; cropApplied = false
        }
        for tool in ["spot", "patch", "clone", "liquify", "pinch", "crop"] {
            clearTools(); refresh()
            guard let b = outImage, let b0 = small(b) else { emit("TOOLAUDIT " + tool + " 取不到底图"); continue }
            simulateTool(tool)
            guard let a = outImage, let a0 = small(a) else { emit("TOOLAUDIT " + tool + " 取不到输出"); continue }
            var sum = 0.0, peak = 0.0
            // ⚠️ 遍历长度必须取**两者较小值**：裁剪会让输出图变小（1050x1400 → 526x700），
            // 按底图的像素数遍历会越界（这段体检自己踩过：卡在 diff 循环里没输出）。
            let px = min(b0.count, a0.count) / 4
            for i in 0..<px {
                let d = max(abs(Double(b0[i * 4]) - Double(a0[i * 4])),
                            max(abs(Double(b0[i * 4 + 1]) - Double(a0[i * 4 + 1])),
                                abs(Double(b0[i * 4 + 2]) - Double(a0[i * 4 + 2]))))
                sum += d; peak = max(peak, d)
            }
            // 落点要按**工具各自用的那个数组**数：修补读 patchPoints、仿制读 clonePoints
            //（混着数会把"写错了数组"这种 bug 掩盖掉 —— 第 140 节就是被这个坑绊出来的）
            let n: Int
            switch tool {
            case "liquify", "pinch": n = warpStrokes.count
            case "crop": n = cropApplied ? 1 : 0
            case "clone": n = clonePoints.count
            case "patch": n = patchPoints.count
            default: n = spotPoints.count
            }
            emit(String(format: "TOOLAUDIT %@ 均值 %.2f ｜ 峰值 %.0f ｜ 落点 %d",
                        tool, sum / Double(max(1, px)), peak, n))
        }
        clearTools(); refresh()
        emit("TOOLAUDIT 完")   // 收尾哨兵：脚本靠它判断"跑完了"，别拿"最后一行已经出现"当完成
    }
}
