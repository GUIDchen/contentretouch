// CoreParts.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

// MARK: - ⑩ 部位识别与「按部位调参」
//
// 用户要的是：把人脸/眼睛/嘴唇/鼻子/耳朵/手臂/腿分别识别出来，然后**每一块单独调**。
//
// 实现口径（重要）：这**不是**语义分割，而是把已有的关键点拼成掩膜——
//   · 脸：Vision 的 faceContour 多边形（第 47 轮已经用它替代了椭圆，比椭圆贴 70%）；
//   · 眼/唇/鼻：对应关键点多边形；
//   · 耳：**没有耳部关键点**，用脸框两侧各一条竖长椭圆近似（如实标注为估的）；
//   · 手臂/腿：2D 人体姿态的 肩→肘→腕 / 髋→膝→踝 画成**粗折线**（半径按骨长比例）。
// 因此"部位调整"的精度上限就是关键点本身的精度：正脸、四肢张开时好；侧脸、遮挡、贴身时差。
public enum BodyPart: String, CaseIterable, Identifiable {
    case face = "脸", eyes = "眼睛", lips = "嘴唇", nose = "鼻子", ears = "耳朵", arms = "手臂", legs = "腿"
    public var id: String { rawValue }
}

/// 某一部位的掩膜（白=该部位）。返回 nil 表示这张图上这个部位不成立（没检出关键点）。
public func partMask(_ src: CIImage, part: BodyPart, geos: [FaceGeo]) -> CIImage? {
    let e = src.extent
    guard let g = geos.max(by: { $0.box.width < $1.box.width }) else {
        // 没有脸时只有四肢可能成立
        return (part == .arms || part == .legs) ? limbMask(src, legs: part == .legs) : nil
    }
    switch part {
    case .face:
        return contourFaceMask(extent: e, face: g)
    case .eyes:
        var polys: [[CGPoint]] = []
        if g.leftEye.count >= 3 { polys.append(g.leftEye) }
        if g.rightEye.count >= 3 { polys.append(g.rightEye) }
        guard !polys.isEmpty else { return nil }
        return polygonMask(extent: e, polygons: polys, feather: 1.5)
    case .lips:
        let polys = g.outerLips.count >= 3 ? [g.outerLips] : (g.innerLips.count >= 3 ? [g.innerLips] : [])
        guard !polys.isEmpty else { return nil }
        return polygonMask(extent: e, polygons: polys, feather: 2)
    case .nose:
        // §237：解析类 10「鼻」实测在**三张脸上都是 100% 覆盖**（门夹具脸1、RAW 脸1、RAW 脸2），
        // 而关键点多边形会退化（同牙齿/眼睛的病史）。与唇/齿/眼同构：解析优先、多边形兜底。
        if let pm = parsedMaskForFace(src, face: g, classes: FaceClass.noseClasses, feather: 2) { return pm }
        guard g.nose.count >= 3 else { return nil }
        return polygonMask(extent: e, polygons: [g.nose], feather: 2)
    case .ears:
        // §243：解析耳类 7/8 实测有 1300~1800 px 输出，质心落在**脸框外缘**（正是耳朵该在的位置），
        // 而下面那套「脸框两侧竖椭圆」近似会盖到脸颊与头发。改成解析优先、竖椭圆兜底（与鼻/唇/齿/眼同构）。
        // 守卫：在脸框外扩区域里覆盖率 > 0.003 才采用 —— 耳类天然小（常只露一只耳），阈值不能大；
        // 但完全没有耳类输出时必须退回竖椭圆（§215 的「空解析掩膜顶掉兜底」教训）。
        do {
            let outer = g.box.insetBy(dx: -g.box.width * 0.5, dy: -g.box.height * 0.25)
            if let em = parsedMaskForFace(src, face: g, classes: FaceClass.earClasses, feather: 2),
               maskCoverageSmall(em, in: outer) > 0.003 {
                return em
            }
        }
        // ⚠️ Vision 没有耳部关键点：用脸框两侧各一条竖长椭圆**近似**（如实标注）。
        let w = g.box.width * 0.20, h = g.box.height * 0.55
        let left = CGRect(x: g.box.minX - w * 0.15, y: g.box.midY - h * 0.2, width: w, height: h)
        let right = CGRect(x: g.box.maxX - w * 0.85, y: g.box.midY - h * 0.2, width: w, height: h)
        // 羽化别给太大：给到 0.4w 时只有中心一小条超过阈值，掩膜会变成"横着一条细线"
        //（coretest 第 31 段的包围盒量出来是 0.24×0.02，明显不对）
        return maskUnion(rectMask(extent: e, rect: left, feather: max(1.5, w * 0.15), ellipse: true),
                         rectMask(extent: e, rect: right, feather: max(1.5, w * 0.15), ellipse: true))
    case .arms:
        return limbMask(src, legs: false)
    case .legs:
        return limbMask(src, legs: true)
    }
}

/// 四肢掩膜：把关键点连成**粗折线**（肩→肘→腕 / 髋→膝→踝）。没有姿态关键点就返回 nil。
public func limbMask(_ src: CIImage, legs: Bool) -> CIImage? {
    guard let cg = sharedCtx.createCGImage(src, from: src.extent) else { return nil }
    let b = detectBodyPoints(cg, extent: src.extent)
    func seg(_ a: CGPoint?, _ m: CGPoint?, _ z: CGPoint?) -> [CGPoint] {
        var pts: [CGPoint] = []
        if let a { pts.append(a) }
        if let m { pts.append(m) }
        if let z { pts.append(z) }
        return pts.count >= 2 ? pts : []
    }
    var chains: [[CGPoint]] = []
    if legs {
        chains.append(seg(b.leftHip, b.leftKnee, b.leftAnkle))
        chains.append(seg(b.rightHip, b.rightKnee, b.rightAnkle))
    } else {
        chains.append(seg(b.leftShoulder, b.leftElbow, b.leftWrist))
        chains.append(seg(b.rightShoulder, b.rightElbow, b.rightWrist))
    }
    chains = chains.filter { !$0.isEmpty }
    guard !chains.isEmpty else { return nil }
    // 半径按骨长比例：太细盖不住肢体、太粗会糊到旁边（取最长一段的 18%）
    var boneLen = 0.0
    for c in chains { for i in 1..<c.count { boneLen = max(boneLen, hypot(c[i].x - c[i-1].x, c[i].y - c[i-1].y)) } }
    let r = max(6.0, boneLen * 0.18)
    let e = src.extent
    let W = Int(e.width), H = Int(e.height)
    guard W > 8, H > 8,
          let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 0, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setStrokeColor(gray: 1, alpha: 1)
    ctx.setLineWidth(r * 1.6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for c in chains {
        // 位图坐标原点在左下、与 CI 同向 → **不翻 y**（本项目的坐标口径）
        ctx.move(to: CGPoint(x: c[0].x - e.minX, y: c[0].y - e.minY))
        for p in c.dropFirst() { ctx.addLine(to: CGPoint(x: p.x - e.minX, y: p.y - e.minY)) }
        ctx.strokePath()
    }
    guard let out = ctx.makeImage() else { return nil }
    return CIImage(cgImage: out).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        .cropped(to: e)
}

/// 一个部位的调整（都是**增量**，与"范围选择"同一套心智：全局调完、局部加减一点）
public struct PartAdjust: Codable, Equatable {
    public var part: String
    public var dBrightness = 0.0
    public var dWarm = 0.0
    public var dSat = 0.0
    public var dSmooth = 0.0
    public init(part: String) { self.part = part }
    public var isEmpty: Bool {
        abs(dBrightness) < 0.01 && abs(dWarm) < 0.01 && abs(dSat) < 0.01 && abs(dSmooth) < 0.01
    }
}

/// 把「按部位」的增量逐个贴上去。与范围选择同一套做法：
/// 用"全局 + 该部位增量"渲染一版颜色，再按该部位的掩膜混回当前结果。
/// 柔化（dSmooth）在该部位的皮肤/毛发上做一次轻度柔化。
public func applyPartAdjustments(_ src: CIImage, _ parts: [PartAdjust], geos: [FaceGeo],
                                 base: Params) -> CIImage {
    var out = src
    for pa in parts where !pa.isEmpty {
        guard let part = BodyPart(rawValue: pa.part), let m = partMask(out, part: part, geos: geos) else { continue }
        var lp = base
        lp.brightness += pa.dBrightness
        lp.desat = max(0, lp.desat + pa.dSat)
        lp.cbSh[0] += pa.dWarm / 1.923
        lp.cbHi[0] += pa.dWarm / 1.923
        out = render(out, lp).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
        if abs(pa.dSmooth) > 0.01 {
            let r = max(1.0, min(out.extent.width, out.extent.height) * 0.004)
            let soft = evenTone(out, mask: m, toneRadius: r * 2.5,
                                strength: min(1.0, abs(pa.dSmooth) / 100))
            out = soft
        }
    }
    return out
}

// MARK: - ⑧⑨ 部位变形的**笔触构造**（纯函数：不碰 CI 上下文，便于单测/复现）
//
// 为什么把它单独抽出来：App 里那段形变逻辑"到底生成了什么笔触"没法单独看，
// 而 coretest 又调不到 App 的方法。抽成纯函数后，**App 与测试用同一份实现**，
// 这才可能把"笔触本身有问题"与"管线没接上"分开验证。
/// ⚠️ 坐标约定必须与笔刷一致（这一条踩过坑）：
///   · center = 归一化 (0~1)；radius = 百分比；delta = 归一化；
///   · 渲染管线里的 conv() 会把它们换算成像素：denorm(center)、radiusPx(radius)、delta*边长。
/// 我第一版这里直接塞了像素坐标（关键点本来就是像素），于是 conv() 又乘了一遍宽高——
/// 笔触中心飞到画面外，表现就是「笔触记上了、画面一点没变」（App 端自检峰值只有 1/255）。
public func partDeformStrokes(part: BodyPart, kind: String, amount: Double,
                              geos: [FaceGeo], body: BodyPoints, extent: CGRect) -> [WarpStroke] {
    guard amount > 0.01 else { return [] }
    var strokes: [WarpStroke] = []
    let strength = min(1.0, max(0.0, amount / 100))
    // 像素坐标 → 归一化（见上面的坐标约定）
    func norm(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / max(1, extent.width), y: p.y / max(1, extent.height))
    }
    // ── 五官：作用在关键点上 ──
    // 注意：必须按 part 限定。原来只要检到脸就无条件跑这一段，于是「腿·瘦」被当成了
    // 五官里不匹配 kind 的 default 分支（额头向上推）。coretest 第 33 段的证据：
    // 腿·拉长 / 腿·瘦 生出来的笔触完全一样，都是「向前变形 r3.9% d(0,11)」（就是额头那笔）。
    let faceParts: Set<BodyPart> = [.face, .eyes, .lips, .nose]
    if faceParts.contains(part), let g = geos.max(by: { $0.box.width < $1.box.width }) {
        func keyPoint() -> CGPoint? {
            switch kind {
            case "大眼": return g.leftEye.isEmpty ? nil : g.centroid(g.leftEye)
            case "瘦鼻": return g.nose.isEmpty ? nil : g.centroid(g.nose)
            case "唇形": return g.outerLips.isEmpty ? nil : g.centroid(g.outerLips)
            case "下巴": return CGPoint(x: g.box.midX, y: g.box.minY + g.box.height * 0.06)
            default: return CGPoint(x: g.box.midX, y: g.box.maxY - g.box.height * 0.08)
            }
        }
        if let p = keyPoint() {
            let facePct = Double(g.box.width) / Double(max(1, extent.width)) * 100
            let r = max(0.8, facePct * (kind == "唇形" ? 0.10 : 0.16))
            switch kind {
            case "大眼":
                strokes.append(WarpStroke(mode: .expand, center: norm(p), radius: r, strength: strength, density: 0.6))
                if !g.rightEye.isEmpty {
                    strokes.append(WarpStroke(mode: .expand, center: norm(g.centroid(g.rightEye)), radius: r,
                                              strength: strength, density: 0.6))
                }
            case "瘦鼻":
                strokes.append(WarpStroke(mode: .push, center: norm(p), radius: r * 0.9,
                                          delta: CGPoint(x: -0.012 * strength, y: 0),
                                          strength: strength, density: 0.6))
                strokes.append(WarpStroke(mode: .push, center: norm(p), radius: r * 0.9,
                                          delta: CGPoint(x: 0.012 * strength, y: 0),
                                          strength: strength, density: 0.6))
            case "唇形":
                strokes.append(WarpStroke(mode: .expand, center: norm(p), radius: r,
                                          strength: strength * 0.7, density: 0.6))
            case "下巴":
                strokes.append(WarpStroke(mode: .push, center: norm(p), radius: r,
                                          delta: CGPoint(x: 0, y: -0.02 * strength),
                                          strength: strength, density: 0.6))
            default:
                strokes.append(WarpStroke(mode: .push, center: norm(p), radius: r,
                                          delta: CGPoint(x: 0, y: 0.02 * strength),
                                          strength: strength, density: 0.6))
            }
        }
    }
    // ── 四肢：沿骨链作用 ──
    guard part == .arms || part == .legs else { return strokes }
    let isLeg = (part == .legs)
    let chains: [[CGPoint]] = isLeg
        ? [[body.leftHip, body.leftKnee, body.leftAnkle].compactMap { $0 },
           [body.rightHip, body.rightKnee, body.rightAnkle].compactMap { $0 }]
        : [[body.leftShoulder, body.leftElbow, body.leftWrist].compactMap { $0 },
           [body.rightShoulder, body.rightElbow, body.rightWrist].compactMap { $0 }]
    for c in chains where c.count >= 2 {
        let a0 = c.first!, a1 = c.last!
        let dx = Double(a1.x - a0.x), dy = Double(a1.y - a0.y)
        let len = max(1, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        // ⚠️ 半径按"骨长占画面高度的百分比 ×0.55"。若只检出一个关节、
        // 或骨长很小（小腿被裁掉一半），半径会小到 1px 级 —— 那基本等于没推。
        // 这里给一个**下限 2%**，避免"用力拖却没反应"。
        let r = max(2.0, len / Double(max(1, extent.height)) * 100 * 0.55)
        if kind == "拉长" {
            strokes.append(WarpStroke(mode: .push, center: norm(a0), radius: r,
                                      delta: CGPoint(x: -ux * 0.05 * strength, y: -uy * 0.05 * strength),
                                      strength: strength, density: 0.6))
            strokes.append(WarpStroke(mode: .push, center: norm(a1), radius: r,
                                      delta: CGPoint(x: ux * 0.05 * strength, y: uy * 0.05 * strength),
                                      strength: strength, density: 0.6))
        } else if kind == "瘦" {
            for p in c {
                strokes.append(WarpStroke(mode: .pinch, center: norm(p), radius: r,
                                          strength: strength, density: 0.6))
            }
        }
    }
    return strokes
}
