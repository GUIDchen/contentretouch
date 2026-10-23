// CoreBody.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

// MARK: - 全身美型（近似：人体姿态关键点 + 分段液化）
//
// 做法：VNDetectHumanBodyPoseRequest 拿肩/髋关键点 → 在「腰」（肩髋中点）做收缩、在肩点做膨胀，
// 复用已有的 liquify（Bump/Pinch）。注意 Vision 的人体姿态坐标是**图像归一化、原点左下**，
// 与 Core Image 同向，所以 y 不翻转（与面部关键点不同——那套是相对人脸框的，必须翻转）。
// ⚠️ 边界：没有形体模型，只能做「大致收腰/宽肩」这种粗调整，达不到像素蛋糕的塑形水准。
public struct BodyPoints {
    public var leftShoulder: CGPoint?
    public var rightShoulder: CGPoint?
    public var leftHip: CGPoint?
    public var rightHip: CGPoint?
    public var neck: CGPoint?
    public var root: CGPoint?
    // ⑩ 四肢
    public var leftElbow: CGPoint?
    public var rightElbow: CGPoint?
    public var leftWrist: CGPoint?
    public var rightWrist: CGPoint?
    public var leftKnee: CGPoint?
    public var rightKnee: CGPoint?
    public var leftAnkle: CGPoint?
    public var rightAnkle: CGPoint?
    public init() {}
}

public func detectBodyPoints(_ cg: CGImage, extent: CGRect) -> BodyPoints {
    let req = VNDetectHumanBodyPoseRequest()
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil,
          let obs = (req.results ?? []).first else { return BodyPoints() }
    func pt(_ name: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
        guard let p = try? obs.recognizedPoint(name), p.confidence > 0.1 else { return nil }
        // ⚠️ 必须加上 extent 的**原点**（第 114 节）：归一化坐标是相对这张位图的，
        // 而调用方给的 extent 常常是管线中段的图（原点不为 0）。原来只乘宽高，
        // 于是关键点整体偏移 —— 表现就是"直接调 reshapeBody 有效果、走管线却完全没有"（峰值 58 vs 0）。
        return CGPoint(x: extent.minX + p.location.x * extent.width,
                       y: extent.minY + p.location.y * extent.height)
    }
    var b = BodyPoints()
    b.leftShoulder = pt(.leftShoulder); b.rightShoulder = pt(.rightShoulder)
    b.leftHip = pt(.leftHip); b.rightHip = pt(.rightHip)
    b.neck = pt(.neck); b.root = pt(.root)
    // ⑩ 四肢要用：肘/腕/膝/踝（Vision 的 2D 人体姿态本来就有这些关节，之前只取了 4 个点）
    b.leftElbow = pt(.leftElbow); b.rightElbow = pt(.rightElbow)
    b.leftWrist = pt(.leftWrist); b.rightWrist = pt(.rightWrist)
    b.leftKnee = pt(.leftKnee); b.rightKnee = pt(.rightKnee)
    b.leftAnkle = pt(.leftAnkle); b.rightAnkle = pt(.rightAnkle)
    return b
}

public func reshapeBody(_ src: CIImage, slimWaist: Double = 0, wideShoulders: Double = 0) -> CIImage {
    guard slimWaist > 0.01 || wideShoulders > 0.01 else { return src }
    guard let cg = sharedCtx.createCGImage(src, from: src.extent) else { return src }
    let b = detectBodyPoints(cg, extent: src.extent)
    if ProcessInfo.processInfo.environment["CR_AUDIT"] == "1" {
        FileHandle.standardError.write(String(format: "BODYDBG reshapeBody 进来了：extent %.0f,%.0f %.0fx%.0f ｜ 肩(%.0f,%.0f)(%.0f,%.0f) ｜ 收腰 %.0f 宽肩 %.0f\n",
            src.extent.minX, src.extent.minY, src.extent.width, src.extent.height,
            b.leftShoulder?.x ?? -1, b.leftShoulder?.y ?? -1, b.rightShoulder?.x ?? -1, b.rightShoulder?.y ?? -1,
            slimWaist, wideShoulders).data(using: .utf8)!)
    }
    var strokes: [LiquifyStroke] = []
    if slimWaist > 0.01, let ls = b.leftShoulder, let lh = b.leftHip,
       let rs = b.rightShoulder, let rh = b.rightHip {
        let lw = CGPoint(x: (ls.x + lh.x) / 2, y: (ls.y + lh.y) / 2)
        let rw = CGPoint(x: (rs.x + rh.x) / 2, y: (rs.y + rh.y) / 2)
        // 半径从 0.45 收到 0.18：Core Image 失真滤镜的 radius 不是硬边界而是「最强处」，
        // 实测 0.45 时整张图都被推（腰外 49.2 vs 腰内 50.5，等于全图变形）。
        let r = abs(ls.x - rs.x) * 0.18
        strokes.append(LiquifyStroke(center: lw, radius: r, strength: -slimWaist / 100))
        strokes.append(LiquifyStroke(center: rw, radius: r, strength: -slimWaist / 100))
    }
    if wideShoulders > 0.01, let ls = b.leftShoulder, let rs = b.rightShoulder {
        let r = abs(ls.x - rs.x) * 0.16
        strokes.append(LiquifyStroke(center: ls, radius: r, strength: wideShoulders / 100))
        strokes.append(LiquifyStroke(center: rs, radius: r, strength: wideShoulders / 100))
    }
    let warped = liquify(src, strokes: strokes)
    // 再用羽化蒙版把影响区锁死在腰部附近：无论滤镜尾巴多长，出了蒙版就回到原图。
    // 蒙版直接复用面部的羽化椭圆（faceMask），把「腰部」当成一张脸来框。
    guard let ls = b.leftShoulder, let rs = b.rightShoulder,
          let lh = b.leftHip, let rh = b.rightHip else { return warped }
    let e = src.extent
    // 蒙版改成「以两个腰部笔刷点为中心的两个椭圆」——与笔刷共用同一组坐标，不可能错位。
    // 之前用「四个关节的平均点」当中心，实测被一个异常髋关节把中心拉偏约 1300 px，
    // 结果蒙版盖在图别处、腰部反而被回退成原图（腰部内变化 43.5 → 0.009）。
    // 顺带加关键点合理性校验：肩必须在髋上方、躯干高度占图高 10%~90%，否则不处理。
    let shoulderY = (ls.y + rs.y) / 2, hipY = (lh.y + rh.y) / 2
    guard shoulderY > hipY, abs(shoulderY - hipY) > e.height * 0.1,
          abs(shoulderY - hipY) < e.height * 0.9 else { return warped }
    let W = Int(e.width), H = Int(e.height)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return warped }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    // ⚠️ **蒙版必须按"实际写进去的那些笔刷"来画**（第 114 节修的真 bug）：
    // 原来这里写死成"腰部左右两个椭圆"，而「宽肩」的笔刷点在**肩部** ——
    // 结果肩部形变出了蒙版，被整块退回原图，`宽肩` 实测**完全没有效果（0.00）**，
    // 而体检却因为"检出关节 10/12"看着一切正常。现在直接遍历 strokes，
    // 蒙版与笔刷共用同一组坐标，收腰/宽肩（以及以后任何新增的身体笔刷）都不可能再错位。
    for s in strokes {
        let rr = Double(s.radius) * 1.2
        // 位图蒙版不需要翻 y（coretest 探针 D 实测：脸框当多边形画，脸框处均值 0.986 不翻 / 0.000 翻）。
        ctx.fillEllipse(in: CGRect(x: s.center.x - rr, y: s.center.y - rr, width: rr * 2, height: rr * 2))
    }
    guard let maskCG = ctx.makeImage() else { return warped }
    let mask = CIImage(cgImage: maskCG)
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: abs(ls.x - rs.x) * 0.05])
        .cropped(to: e)
    let masked = warped.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: mask])
    if ProcessInfo.processInfo.environment["CR_AUDIT"] == "1" {
        // 逐步量：笔画 → 形变 → 蒙版 → 混合，看是哪一步把效果吃掉的
        func smallPeak(_ a: CIImage, _ b2: CIImage) -> Double {
            let W2 = 120, H2 = max(1, Int(Double(W2) * e.height / max(1, e.width)))
            func buf(_ i: CIImage) -> [UInt8] {
                var o = [UInt8](repeating: 0, count: W2 * H2 * 4)
                let sc = i.cropped(to: e).transformed(by: CGAffineTransform(scaleX: CGFloat(W2) / e.width,
                                                                           y: CGFloat(H2) / e.height))
                sharedCtx.render(sc, toBitmap: &o, rowBytes: W2 * 4,
                                 bounds: CGRect(x: 0, y: 0, width: W2, height: H2),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return o
            }
            let x = buf(a), y = buf(b2)
            var mx = 0.0
            for i in 0..<(W2 * H2) { mx = max(mx, abs(Double(x[i * 4]) - Double(y[i * 4]))) }
            return mx
        }
        var maskCover = 0.0
        if let m = maskCG as CGImage? {
            let W3 = m.width, H3 = m.height
            var mb = [UInt8](repeating: 0, count: W3 * H3 * 4)
            sharedCtx.render(CIImage(cgImage: m), toBitmap: &mb, rowBytes: W3 * 4,
                             bounds: CGRect(x: 0, y: 0, width: W3, height: H3),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var c = 0
            for i in 0..<(W3 * H3) where mb[i * 4] > 128 { c += 1 }
            maskCover = Double(c) / Double(W3 * H3)
        }
        FileHandle.standardError.write(String(format: "BODYDBG 笔画 %d ｜ 蒙版覆盖 %.2f%% ｜ 形变差 %.1f ｜ 混合后差 %.1f\n",
            strokes.count, maskCover * 100, smallPeak(src, warped), smallPeak(src, masked)).data(using: .utf8)!)
    }
    return masked
}

// MARK: - 衣物平整（近似：衣物区域高频压制）
//
// 没有衣物分割模型，所以用「人像蒙版 − 脸部蒙版 − 过亮像素（白纱/背景）」粗略定位衣物，
// 在区域内做高频压制（与背景纯化同一套 flatten 机制）。
// ⚠️ 边界：这是**粗定位**——深色衣服、袖子、披肩能盖住，裸露皮肤与白纱边容易被漏掉或误伤。
//    面板里明写「受限可用」，不吹成「衣物美化」。
public func smoothClothes(_ src: CIImage, strength: Double = 60, flattenRadius: Double = 28) -> CIImage {
    guard strength > 0.01 else { return src }
    // 解析优先：衣服是语义类别（16）。原来的做法是「人像掩膜 − 人脸椭圆 − 高光」，
    // 那套要靠减法去猜，白纱、露出的手臂、背景都会糊进来。
    //
    // ⚠️ 但**要加覆盖率的闸门**：这个模型是在人像数据集上训的，对真实婚礼图会整片误判
    //（实测 wedding_01：整幅 46% 被分成「帽子」类 18、衣服类只有 0.4%）。
    // 覆盖太少说明解析在这张图上不成立，那就老实退回原来的减法方案。
    if let cloth = parsedMaskFromImage(src, classes: FaceClass.clothClasses, feather: 6) {
        let cov = maskCoverage(cloth, in: src.extent, threshold: 128)
        if cov > 0.02 && cov < 0.70 {
            return smoothClothesMasked(src, mask: cloth, strength: strength, flattenRadius: flattenRadius)
        }
    }
    guard let person = personMask(src) else { return src }
    // ── 没有解析模型时的兜底：人像掩膜 − 人脸椭圆 − 高光 ──
    let e = src.extent
    // 1) 减掉**皮肤**（不只是脸）：原来只减脸椭圆，实测人像掩膜的 **93%~97% 都被当成衣服**——
    //    也就是说露出的手臂、脖子、肩膀全被当成衣服去"平整"，皮肤会变成塑料感
    //    （coretest 第 25 段量出来的）。现在优先减肤色掩膜，脸椭圆只当兜底。
    var mask = person
    if let cg = sharedCtx.createCGImage(src, from: e) {
        let geos = detectFaceGeos(cg, size: e.size)
        if geos.count == 1, let sk = skinMaskForFace(src, face: geos[0]) as CIImage? {
            mask = mask.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: sk.applyingFilter("CIColorInvert")])
        } else if geos.count > 1 {
            let sk = skinMaskForFaces(src, geos: geos)
            mask = mask.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: sk.applyingFilter("CIColorInvert")])
        } else {
            // 没检出脸 → 退回原来的脸椭圆（至少别把脸糊掉）
            for fa in detectFaceInfos(cg) {
                let face = faceMask(extent: e, face: fa, feather: 0.6)
                mask = mask.applyingFilter("CIMultiplyBlendMode", parameters: [
                    kCIInputBackgroundImageKey: face.applyingFilter("CIColorInvert")])
            }
        }
    }
    // 1.5) 再减掉**头发**：解析模型本来就有 hair 类（我们身上已经带着 FaceParsing.mlmodel），
    //      之前没用上。头发被当成"衣服"去压高频，会让发丝变塑料 —— 减掉即可，不需要新模型。
    //      （这是审阅里"衣物需要分割模型"的一条低成本替代：用已有模型能覆盖的部分先做掉。）
    if let hair = parsedMaskFromImage(src, classes: FaceClass.hairClasses, feather: 6) {
        let hairCov = maskCoverage(hair, in: e, threshold: 128)
        if hairCov > 0.002 && hairCov < 0.5 {     // 解析明显不成立时不要乱减
            mask = mask.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: hair.applyingFilter("CIColorInvert")])
        }
    }
    // 2) 减掉高亮区（白纱/背景残留）
    let lum = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: -0.82, y: -0.82, z: -0.82, w: 0)])   // 高于 0.82 的亮度压成 0
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1.6, y: 1.6, z: 1.6, w: 0)])            // 放大成可用蒙版
    mask = mask.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: lum])
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10])
        .cropped(to: e)
        // 关键：羽化会把蒙版扩散到人像边界之外（实测外溢 0.10→0.14），
        // 模糊之后再乘一次人像蒙版把它夹回人像内部，外溢即归零。
        .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: person])
    return smoothClothesMasked(src, mask: mask, strength: strength, flattenRadius: flattenRadius)
}

/// 衣物美化的公共后半段：给一张衣物蒙版，做区域内高频压制
public func smoothClothesMasked(_ src: CIImage, mask inputMask: CIImage, strength: Double,
                                flattenRadius: Double) -> CIImage {
    let e = src.extent
    let mask = inputMask.cropped(to: e)
    // 3) 区域内高频压制（与背景纯化同机制）
    let k = max(0.0, min(1.0, strength / 100.0))
    let soft = mask.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    let low = fastBlur(src, radius: flattenRadius)
    return low.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: soft])
}

// MARK: - 手部美化（近似：手部关键点 → 区域蒙版 → 磨皮 + 提亮）
//
// Vision 的 VNDetectHumanHandPoseRequest 每只手给 21 个关键点（本机实测可用）。
// 取所有点的包围框 → 用 **Core Image 原生蒙版**（CIImage(color:).cropped + 高斯羽化）
// 生成区域蒙版——不碰 CGBitmapContext，所以不存在 y 镜像问题（踩过那个坑）。
// ⚠️ 边界：这是「手部区域柔化 + 提亮」，不是像素蛋糕那种手部塑形（指节拉长/去皱分级）。
public struct HandInfo {
    public var rect: CGRect          // 图像坐标（CI 同向）
    public var points: Int
    public var maxConfidence: Float
}

public func detectHandInfos(_ cg: CGImage, extent: CGRect) -> [HandInfo] {
    let req = VNDetectHumanHandPoseRequest()
    req.maximumHandCount = 4
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil else { return [] }
    var out: [HandInfo] = []
    for h in (req.results ?? []) {
        guard let pts = try? h.recognizedPoints(.all) else { continue }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var n = 0
        var maxC: Float = 0
        for (_, p) in pts where p.confidence > 0.2 {
            let x = p.location.x * extent.width, y = p.location.y * extent.height
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            n += 1; maxC = max(maxC, p.confidence)
        }
        guard n >= 5, maxX > minX else { continue }
        // 稍微外扩，把手掌边缘也包进去
        let pad = max(maxX - minX, maxY - minY) * 0.18
        out.append(HandInfo(rect: CGRect(x: minX - pad, y: minY - pad,
                                         width: (maxX - minX) + pad * 2,
                                         height: (maxY - minY) + pad * 2),
                            points: n, maxConfidence: maxC))
    }
    return out
}

/// 手部蒙版：把 21 个关键点连成**手掌轮廓多边形**，而不是用它们的包围框。
///
/// 为什么值得升级：包围框是矩形的，手腕、袖口、旁边的背景都会被框进去一起柔化
///（实测可见：手旁边 30 px 的背景被一并磨了）。多边形跟着手的形状走，越界量能降一个数量级。
/// 凸包用「按角度排序 + Graham 扫描」自己算，几十个点，不值得引依赖。
public func handPolygons(_ cg: CGImage, extent: CGRect) -> [CIImage] {
    let req = VNDetectHumanHandPoseRequest()
    req.maximumHandCount = 4
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil else { return [] }
    var hulls: [[CGPoint]] = []
    for h in (req.results ?? []) {
        guard let pts = try? h.recognizedPoints(.all) else { continue }
        var ps: [CGPoint] = []
        for (_, p) in pts where p.confidence > 0.2 {
            ps.append(CGPoint(x: p.location.x * extent.width, y: p.location.y * extent.height))
        }
        guard ps.count >= 5, let hull = convexHull(ps) else { continue }
        hulls.append(hull)
    }
    guard !hulls.isEmpty else { return [] }
    return rasterize(hulls, extent: extent)
}

public func smoothHands(_ src: CIImage, strength: Double = 60) -> CIImage {
    guard strength > 0.01, let cg = sharedCtx.createCGImage(src, from: src.extent) else { return src }
    // 优先用 21 点轮廓（贴合手的形状）；拿不到轮廓再退回包围框
    let polys = handPolygons(cg, extent: src.extent)
    if let first = polys.first {
        var mask = first
        for m in polys.dropFirst() { mask = maskUnion(mask, m) }
        return softenInMask(src, mask: mask, radius: 6, strength: strength / 100, brighten: 0.04)
    }
    let hands = detectHandInfos(cg, extent: src.extent)
    guard !hands.isEmpty else { return src }
    return softenRects(src, rects: hands.map { $0.rect }, strength: strength,
                       blurRadius: 6, brighten: 0.04)
}
