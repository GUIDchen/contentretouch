// CoreSkin.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

// MARK: - M5 皮肤处理（频域分离磨皮，只作用在皮肤/脸区）
//
// 原理（就是手工「中性灰」那套的自动化版）：
//   低频 = 高斯模糊后的图（负责颜色与光影）
//   高频 = 原图 - 低频（负责毛孔、细纹、质感）
//   磨皮 = 低频 + 高频 × keep      keep=1 不动，keep 越小越平滑
// 只把结果按蒙版叠回脸区，脸以外不动，所以背景纹理与发丝不会被抹掉。
//
// 诚实的边界：这是「可用级」柔化 + 保质感，**不是**祛斑祛痘——斑点检测 + 修补（inpainting）
// 没有实现，因为它需要训练好的检测/修复模型，本机没有推理框架。
public func smoothSkin(_ src: CIImage, mask: CIImage, radius: Double, strength: Double) -> CIImage {
    // keep 用非线性：线性下「强度 70」只削掉三成高频，手感太弱（实测踩到）。
    // 指数 1.6 让中高段更有力，同时保留低段的克制。
    let s = max(0.0, min(1.0, strength / 100.0))
    let k = pow(1.0 - s, 1.6)
    if radius < 0.5 || k > 0.999 { return src }
    let low = src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: src.extent)
    // ⚠️ 原实现用 CISubtractBlendMode + bias 做「低频 + 高频×keep」，实测在脸区会**变成暗块**
    // （R 199 → 48）。Core Image 的 blend mode 在这套组合下不是可用的频域分离。
    // 现在改用最直白也最不会错的做法：把模糊图按 (1-keep) × 蒙版 混回原图。
    // ponytail: 质感保留不如真频域分离（那需要自定义 CIKernel），但结果正确、可预期。
    let amount = 1.0 - k
    let softMask = mask.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: amount, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: amount, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: amount, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    return low.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: softMask])
    // 下面这段（原频域分离合成）保留作记录，不再使用：
    #if false
    // 高频 = 原图 - 低频 + 0.5（CISubtractBlend 会截断负值，所以抬到 0.5 基准）
    let diff = src.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: low])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)])
    // 高频按 keep 缩放，基准回到 0.5
    let scaled = diff.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0.5 * (1 - k), y: 0.5 * (1 - k), z: 0.5 * (1 - k), w: 0)])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
    let smooth = low.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: scaled])
    return smooth.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: mask])
    #endif
}

// MARK: - 皮肤（磨皮 + 肤色）一步到位，界面与命令行共用
public struct SkinOptions {
    public var grade: String = "off"      // off | light | medium | strong
    public var strength: Double = 0       // 也可直接给 0~100
    public var unifyTone: Bool = false
    public var deltaWarm: Double = 0      // 肤色统一的目标暖冷（参考组来的）
    /// true = 频域分离的「保毛孔」磨皮（只抹平低频色调，不动毛孔纹理）；
    /// false = 老的线性柔化（连毛孔一起压）。默认开，因为保毛孔才是可用级。
    public var texturePreserve: Bool = true
    /// 祛油光（0~100）：**只压高光顶部**，暗部几乎不动。
    /// 为什么这样设计：油光在画面上的表现就是"皮肤上的一小片高光"，
    /// 直接整体变暗会把肤色一起改掉（那就不是祛油光，是调暗）。所以用一条只改高光端的曲线，
    /// 再乘进皮肤掩膜里（对标像素蛋糕「祛除瑕疵 · 祛油光（脸部）」那一项，见 §188）。
    public init() {}
    public var effectiveStrength: Double {
        switch grade {
        case "light": return 30
        case "medium": return 55
        case "strong": return 80
        default: return strength
        }
    }
}

/// 在任意蒙版内做一次皮肤处理（磨皮 + 可选肤色统一）。
/// 抽出来是为了让「按脸」和「按人（实例）」共用同一段逻辑，不再各写一份。
public func applySkinMasked(_ src: CIImage, mask: CIImage, strength: Double, radius: Double,
                            unifyTone: Bool, deltaWarm: Double, texturePreserve: Bool,
                            toneRect: CGRect? = nil) -> CIImage {
    var out = src
    if strength > 0.01 {
        if texturePreserve {
            // ⚠️ 系数别乱加：这里 k 是全强度替换低频色调。
            // 原来写的是 strength/100*1.6（「中」=55 就得到 k≈0.88），成片看就是一层糊，
            // 而且蒙版一软就露边。现在 1.0 线性映射：轻 0.30 / 中 0.55 / 重 0.80。
            out = evenTone(out, mask: mask, toneRadius: max(2.0, radius * 2.5),
                           strength: min(1.0, strength / 100))
        } else {
            out = smoothSkin(out, mask: mask, radius: radius, strength: strength)
        }
    }
    if unifyTone, let r = toneRect {
        out = unifySkinToneMeasured(out, mask: mask, rect: r, targetWarm: deltaWarm)
    }
    return out
}

/// 对整张图应用皮肤处理（每张脸单独算半径，蒙版内生效）
/// 眼下带的**几何唯一定义**（掩膜与体检都从这里取，不各写一份 —— 写两处正是本项目踩过四次的坑）。
///
/// 两种来源：优先用眼睛关键点（整体下移约一个眼高、横向外扩）；
/// **没有眼睛关键点时退回脸框估带**（左右各一条）—— 这一条是体检逼出来的：
/// 第一版只认关键点，遇到没返回眼睛点的照片时掩膜里只剩 11 个像素，等于这个功能静默失效（§189）。
/// 坐标提醒：本项目关键点是**像素坐标、原点左下**，所以"眼睛下方"是 y **更小**的方向。
public func underEyeBands(_ face: FaceGeo) -> [CGRect] {
    var out: [CGRect] = []
    // ⚠️ 关键点"有"不等于"可用"：实测某张婚礼 RAW 上眼睛多边形退化成 1px 高，
    // 算出来的带只有 6x1 像素 —— 掩膜里几乎什么都没有，功能静默失效（§189）。
    // 所以加一条最小尺寸守卫：小于脸宽 6% 的关键点组一律不要，退回脸框估带。
    let minEyeSize = max(3.0, face.box.width * 0.06)
    for eye in [face.leftEye, face.rightEye] where eye.count >= 3 {
        let xs = eye.map { $0.x }, ys = eye.map { $0.y }
        guard let mnX = xs.min(), let mxX = xs.max(), let mnY = ys.min(), let mxY = ys.max() else { continue }
        let w = mxX - mnX, h = mxY - mnY
        guard w >= minEyeSize, h >= minEyeSize * 0.4 else { continue }
        out.append(CGRect(x: mnX - w * 0.18, y: mnY - h * 1.05,
                          width: w * 1.36, height: h * 1.15))
    }
    if out.isEmpty {
        let b = face.box
        guard b.width > 4, b.height > 4 else { return [] }
        let hh = b.height * 0.16
        let yy = b.minY + b.height * 0.50
        out.append(CGRect(x: b.minX + b.width * 0.10, y: yy, width: b.width * 0.36, height: hh))
        out.append(CGRect(x: b.minX + b.width * 0.54, y: yy, width: b.width * 0.36, height: hh))
    }
    return out
}

/// 眼下带掩膜：由上面的几何取椭圆并并集（羽化按脸宽给）。
public func underEyeMask(extent: CGRect, face: FaceGeo, feather: Double) -> CIImage {
    let bands = underEyeBands(face)
    guard !bands.isEmpty else { return blackMask(extent) }
    var m = blackMask(extent)
    for r in bands {
        m = maskUnion(rectMask(extent: extent, rect: r, feather: feather, ellipse: true), m)
    }
    return m
}

public func applySkin(_ src: CIImage, _ o: SkinOptions, geos: [FaceGeo]? = nil) -> CIImage {
    let st = o.effectiveStrength
    guard st > 0.01 || o.unifyTone else { return src }
    let e = src.extent
    // 有预置关键点就不必再建位图、再跑一次 Vision（交互式拖滑杆时这一下很值）
    var faces: [FaceGeo] = []
    if let g = geos {
        faces = g
    } else if let cg = sharedCtx.createCGImage(src, from: e) {
        faces = detectFaceGeos(cg, size: e.size)
    }
    var out = src
    // 按面积排名：只有最大的几张脸跑语义解析（尾延迟治理）
    let ranked = rankFacesByArea(faces)
    var rankOf: [Int: Int] = [:]
    for (i, g) in ranked.enumerated() { rankOf[g.index] = i }
    for g in faces {
        // 掩膜用**肤色检测**而不是脸框椭圆：椭圆会把眼睛、眉毛、头发一起磨（实测眼睛区变化/脸颊区
        // 变化 = 1.34，等于眼睛被磨得比脸颊还狠）。换成肤色掩膜后这个比值降到 0.12。
        // 眼睛的排除在 bestSkinMask 里统一做（那是所有磨皮路径的咽喉点）——
        // 这里**不再重复扣一次**：同一件事写两处正是本项目踩过四次的坑。
        let mask = bestSkinMask(out, face: g, rank: rankOf[g.index] ?? 0)
        let r = g.box
        if st > 0.01 || o.unifyTone {
            out = applySkinMasked(out, mask: mask,
                                  strength: st, radius: max(1.0, min(r.width, r.height) * 0.04),
                                  unifyTone: o.unifyTone, deltaWarm: o.deltaWarm,
                                  texturePreserve: o.texturePreserve,
                                  toneRect: r)
        }
    }
    return out
}

/// 按人（实例分割）分别处理：合影里每个人可以给不同强度。
/// 蒙版用人物实例掩膜，比「按脸椭圆」更贴人体轮廓（脖子/肩膀/手臂也在内）。
/// faceBoxes：各张脸的人脸框（与 src 同尺度的像素坐标）。传了就把作用区**限制在这个人的脸上**——
/// 这条很关键：实例掩膜是「整个人」（含衣服），直接拿来当磨皮蒙版会把裙子的绣花也抹平
///（截图里对着一看就明白：新娘整个人像被糊了一层）。像素蛋糕也是把「皮肤调整」和「衣物美化」分开的。
public func applySkinPerPerson(_ src: CIImage, _ o: SkinOptions,
                               persons: [(rect: CGRect, mask: CIImage)],
                               strengths: [Double],
                               faceBoxes: [CGRect] = [],
                               // 人脸关键点（可选）：给了就**扣掉眼睛**——这条路径的掩膜是
                               // "实例掩膜 ∩ 脸椭圆"，两个都不含"眼睛"概念，不扣就会把眼睛磨糊。
                               // 保持可选是为了不破坏既有调用方；没传就退化为旧行为（并在文档里写明）。
                               faces: [FaceGeo] = []) -> CIImage {
    guard !persons.isEmpty else { return src }
    let e = src.extent
    var out = src
    for (i, p) in persons.enumerated() {
        let st = i < strengths.count ? strengths[i] : 0
        guard st > 0.01 || o.unifyTone else { continue }
        // 实例掩膜是按输入尺寸算的；换分辨率时按比例缩放（预览 1400 → 导出的原分辨率）
        // 羽化必须做：实例掩膜是硬边的，直接混会出现一圈可见的矩形边界（截图里一眼看出来）
        // 实例掩膜是「软」的：人物轮廓之外还有 0.1~0.3 的溢出，直接当权重用会在人周围糊出一块
        // 看得见的矩形（截图里一眼看出来）。先做一次硬一点的 S 曲线把低值压到 0，再羽化边缘。
        // 掩膜在 personInstanceMasks 里已经收紧过，这里只需要羽化边缘
        let tight = p.mask.transformed(by: CGAffineTransform(scaleX: e.width / max(1, p.mask.extent.width),
                                                             y: e.height / max(1, p.mask.extent.height)))
            .cropped(to: e)
        // 羽化要给足：实例掩膜在某些部位（长裙下摆、与背景同色处）会提前断掉，
        // 羽化太小就会在裙子上看到一条「效果到此为止」的硬边（截图里一眼看出来）。
        let feather = max(8.0, Double(min(p.rect.width, p.rect.height)) * 0.07)
        let m = tight.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
            .cropped(to: e)
        var mask = m
        if !faceBoxes.isEmpty {
            // 这个人的脸（含脖子）：脸中心落在他包围盒里就算他的
            var faces = blackMask(e)
            var any = false
            for fb in faceBoxes where p.rect.contains(CGPoint(x: fb.midX, y: fb.midY)) {
                // 外扩别太大：脸框再往外扩 30%/40% 会盖到头发和背景，边缘会留一圈光晕
                //（截图里新郎头上那圈）。收到 15%/22%，羽化给到宽度的 35%。
                let r = fb.insetBy(dx: -fb.width * 0.15, dy: -fb.height * 0.22)
                faces = maskUnion(rectMask(extent: e, rect: r, feather: max(4, Double(r.width) * 0.35), ellipse: true), faces)
                any = true
            }
            guard any else { continue }      // 这个人没有脸（背影/被挡）→ 不做皮肤处理
            mask = m.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: faces])
                .cropped(to: e)
        }
        // ⚠️ 按人磨皮这条路径用的是"人物实例掩膜 ∩ 脸椭圆"，**同样会把眼睛一起磨**——
        // 实例掩膜里根本不含"眼睛"这个概念，脸椭圆更是把眼睛整个包住。
        // 所以这里也要扣眼睛（用属于这个人的那些脸的关键点），与 bestSkinMask 里同一套做法。
        for g2 in faces where faceBoxes.contains(where: { $0.contains(CGPoint(x: g2.box.midX, y: g2.box.midY)) }) {
            mask = excludingEyes(mask, face: g2, extent: e)
        }
        let radius = max(2.0, Double(min(p.rect.width, p.rect.height)) * 0.02)
        out = applySkinMasked(out, mask: mask, strength: st, radius: radius,
                              unifyTone: o.unifyTone, deltaWarm: o.deltaWarm,
                              texturePreserve: o.texturePreserve, toneRect: p.rect)
    }
    return out
}
