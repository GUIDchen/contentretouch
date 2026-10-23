// FaceRetouch.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

public struct PortraitOptions: Codable {
    // 祛除瑕疵（照像素蛋糕的条目名，逐条对应）
    public var faceBlemish = 0.0     // 面部祛瑕疵
    public var spotBlemish = 0.0     // 祛斑祛痘
    public var mole = 0.0            // 祛痣
    public var shine = 0.0           // 祛油光（脸部）
    public var sweat = 0.0           // 祛汗孔（脸部）
    public var darkCircle = 0.0      // 祛黑眼圈
    public var eyebag = 0.0          // 祛眼袋
    public var nostril = 0.0         // 祛鼻孔瑕疵
    public var lipLine = 0.0         // 唇纹修整
    public var doubleChin = 0.0      // 祛双下巴
    public var jawLine = 0.0         // 下颌线增强
    // 牙齿 / 眼睛
    public var teeth = 0.0           // 牙齿美白
    public var eyes = 0.0            // 眼睛增强（黑白眼珠）
    // 妆容
    public var lipColor = 0.0
    public var blush = 0.0
    // 手脚
    public var hands = 0.0           // 手部美化（区域柔化 + 提亮）
    public var feet = 0.0            // 脚部美化（按脚踝定位，近似）
    // 创意（第三方模型）—— §413：一键上色（DDColor Tiny，可选下载）。
    // 说明：本轮只加字段（无副作用 ✓）；等 applyPortrait 的收尾处挂上调用并加滑块后再启用 ✓，
    // 这样可以避免出现「滑块在、管线不理会」的死控件 ✗。
    public var colorize = 0.0
    // 面部重塑
    public var faceSlim = 0.0        // 瘦脸
    public var eyeBig = 0.0          // 大眼
    public var noseSlim = 0.0        // 鼻翼收窄
    public var chinShape = 0.0       // 下巴
    public var forehead = 0.0        // 额头（饱满度，bump/pinch）
    /// 发际线：正 = 上移（额头变大），负 = 下移（额头变小）。
    /// 和 forehead 不是一回事：forehead 改额头的「饱满度」，这个改「发际线位置」。
    public var hairline = 0.0
    public init() {}

    public var anyColor: Bool {
        faceBlemish > 0.01 || spotBlemish > 0.01 || mole > 0.01 || shine > 0.01 || sweat > 0.01
            || darkCircle > 0.01 || eyebag > 0.01 || nostril > 0.01 || lipLine > 0.01
            || doubleChin > 0.01 || jawLine > 0.01 || teeth > 0.01 || eyes > 0.01
            || lipColor > 0.01 || blush > 0.01 || hands > 0.01 || feet > 0.01
    }
    public var anyWarp: Bool {
        faceSlim > 0.01 || eyeBig > 0.01 || noseSlim > 0.01 || chinShape > 0.01 || forehead > 0.01
        || abs(hairline) > 0.01
    }
    public var anyEnabled: Bool { anyColor || anyWarp }
}

/// 油光/汗孔：脸区内「高亮 + 低饱和」的像素压暗降饱和。
/// level 越高越只抓最亮的点（油光 0.82 / 汗孔 0.88）。
public func reduceShine(_ src: CIImage, skin: CIImage, strength: Double, level: Double = 0.82) -> CIImage {
    guard strength > 0.01 else { return src }
    let lum = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        // ⚠️ 这里 alpha 故意留 0（与 Auto.swift 里的写法相反），是**实测**出来的：
        // 这条链路后面接的是 CIMultiplyBlendMode(亮度 × 皮肤蒙版)，
        // 把 alpha 改成 1 之后祛油光/祛汗孔的效果直接没了（差异图全黑，峰值 0.0306 → 0.0227 且质心散开）。
        // 受控实验的另一面：蒙版 alpha=0 时 CIBlendWithMask 会当空蒙版（见 Auto.swift 里的注释），
        // 但 maskScaled() 会把 alpha 重新设成 1，所以这里能work。底层原因没查清，以实测为准。
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0)])
    // (亮度 - level) / (1 - level)，负值被 clamp 成 0
    let over = lum.applyingFilter("CIColorMatrix", parameters: [
        "inputBiasVector": CIVector(x: -level, y: -level, z: -level, w: 0)])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 / (1 - level), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 / (1 - level), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 / (1 - level), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    let mask = over.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: skin])
    // 幅度校准（§203）：原来满档只把亮部压暗 4.44 级（判据 F 实测），
    // 而同为"看得见"的祛斑祛痘峰值 80 级 —— 油光这一项满档偏弱。区域由上面的 level 掩膜锁死
    // （只碰比 level 更亮的那一小片），所以"加强"只会让它更像去反光，不会变成整体变暗 ——
    // 这一点由判据 F 每次预检守着（亮部要明显变暗、暗部必须几乎不动）。
    return adjustInMask(src, mask: mask, brightness: -0.09, saturation: -0.55, strength: strength)
}

/// 一次性应用全部人像功能：一次关键点检测，所有效果共用同一套几何
/// geos：可选的预置关键点（调用方缓存后传进来，避免一次刷新里重复跑 Vision）。
/// 传入时必须是**这张图**的关键点（像素坐标要跟 src0 同一尺度）。
public func applyPortrait(_ src0: CIImage, _ o: PortraitOptions, geos: [FaceGeo]? = nil) -> CIImage {
    guard o.anyEnabled else { return src0 }
    // 手部/脚部不依赖人脸关键点，先做（没人脸也能用）
    var src1 = src0
    if o.hands > 0.01 { src1 = smoothHands(src1, strength: o.hands) }
    if o.feet > 0.01 { src1 = smoothFeet(src1, strength: o.feet) }
    let origin = src1.extent.origin
    let work = src1.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    let e = work.extent
    let faces: [FaceGeo]
    if let g = geos {
        faces = g
    } else {
        guard let cg = sharedCtx.createCGImage(work, from: e) else { return src1 }
        faces = detectFaceGeos(cg, size: e.size)
    }
    // 没有人脸时，手脚的结果也要返回（早先这里直接 return src，会把手脚效果一起丢掉）
    guard !faces.isEmpty else {
        return src1.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).cropped(to: src0.extent)
    }
    var out = work

    // ── 1. 瑕疵类（颜色操作，先做，避免被后面的形变带偏）──
    // 尾延迟治理：只有最大的几张脸跑语义解析（实测 7 张脸的组要 962ms，约 137ms/脸）
    let rankedFaces = rankFacesByArea(faces)
    var faceRank: [Int: Int] = [:]
    for (i, g) in rankedFaces.enumerated() { faceRank[g.index] = i }
    // 皮肤掩膜**按需才算**：这一段是逐脸跑解析（实测约 137ms/脸），
    // 而它只服务于下面的瑕疵类；如果用户只调了瘦脸/大眼这类几何项，这张掩膜根本不会被读。
    // （体检时量出来的：只开「痣」和只开「脚部」，脸框内的改动量几乎一样 —— 顺着查到的。）
    let needSkinMask = o.faceBlemish > 0.01 || o.spotBlemish > 0.01 || o.mole > 0.01
        || o.shine > 0.01 || o.sweat > 0.01 || o.darkCircle > 0.01 || o.eyebag > 0.01 || o.nostril > 0.01
    let skinMasks: [CIImage] = needSkinMask ? faces.map { g -> CIImage in
        if (faceRank[g.index] ?? 0) < maxParsedFacesPerImage, parsingWorthwhile(g),
           let m = parsedMaskForFace(work, face: g, classes: FaceClass.skinClasses,
                                     feather: max(0.8, g.box.width * 0.004)) {
            return m
        }
        return faceSkinMask(work, g)
    } : []
    if o.faceBlemish > 0.01 || o.spotBlemish > 0.01 || o.mole > 0.01 {
        for (i, g) in faces.enumerated() {
            var m = skinMasks[i]
            if abs(g.box.width) < 1 { continue }
            let w = g.box.width          // box 已经是像素坐标，早先这里又乘了一次 e.width（错）
            if o.faceBlemish > 0.01 {
                m = skinMasks[i]
                out = removeBlemishes(out, skinMask: m, threshold: 0.05, detectRadius: max(2, w * 0.02),
                                      fixRadius: max(4, w * 0.06), strength: o.faceBlemish / 100)
            }
            if o.spotBlemish > 0.01 {
                out = removeBlemishes(out, skinMask: m, threshold: 0.055, detectRadius: max(2, w * 0.02),
                                      fixRadius: max(5, w * 0.07), strength: o.spotBlemish / 100)
            }
            if o.mole > 0.01 {
                // 痣：更深的暗块、更大的填充半径
                out = removeBlemishes(out, skinMask: m, threshold: 0.10, detectRadius: max(3, w * 0.03),
                                      fixRadius: max(7, w * 0.09), strength: o.mole / 100)
            }
        }
    }
    if o.shine > 0.01 || o.sweat > 0.01 {
        for m in skinMasks {
            if o.shine > 0.01 { out = reduceShine(out, skin: m, strength: o.shine / 100, level: 0.80) }
            if o.sweat > 0.01 { out = reduceShine(out, skin: m, strength: o.sweat / 100, level: 0.87) }
        }
    }
    for g in faces {
        // ── 2. 眼周：黑眼圈 / 眼袋 ──
        // 区域以「眼睛下缘 + 脸高的一个比例」定义（按眼部包围盒定义时，脸一大区域就太小、盖不住眼袋）
        if o.darkCircle > 0.01 || o.eyebag > 0.01 {
            let le = g.bbox(g.leftEye), re = g.bbox(g.rightEye)
            // 祛黑眼圈：几何走 underEyeBands（唯一定义，体检用同一个函数）—— 早先这里自己算一套，
            // 眼睛关键点退化时算出的带只剩几像素，功能静默失效、体检也量不到它（§189）
            if o.darkCircle > 0.01 {
                let m = underEyeMask(extent: e, face: g, feather: max(2, g.box.width * 0.02))
                // 提亮 + 压青紫（黑眼圈泛青紫，蓝通道偏重）
                out = adjustInMask(out, mask: m, brightness: 0.07, saturation: -0.10,
                                   warm: 4, blueReduce: 5, strength: o.darkCircle / 100)
            }
            for eye in [le, re] where eye.width > 2 {
                if o.eyebag > 0.01 {
                    let depth = 0.22 * g.box.height
                    let r = CGRect(x: eye.midX - eye.width * 1.0, y: eye.minY - depth,
                                   width: eye.width * 2.0, height: depth + eye.height * 0.4)
                    let m = rectMask(extent: e, rect: r, feather: max(3, r.height * 0.45), ellipse: true)
                    // 眼袋是低频阴影：更大羽化 + 提亮去阴影
                    out = adjustInMask(out, mask: m, brightness: 0.075, contrast: -0.08,
                                       strength: o.eyebag / 100)
                }
            }
        }
        // ── 3. 鼻子：鼻孔瑕疵 ──
        if o.nostril > 0.01, g.nose.count >= 3 {
            let nb = g.bbox(g.nose)
            let r = CGRect(x: nb.minX, y: nb.minY, width: nb.width, height: nb.height * 0.6)
            let m = rectMask(extent: e, rect: r, feather: max(2, r.width * 0.15), ellipse: true)
            out = removeBlemishes(out, skinMask: m, threshold: 0.09, detectRadius: max(2, nb.width * 0.06),
                                  fixRadius: max(4, nb.width * 0.18), strength: o.nostril / 100)
        }
        // ── 4. 唇：唇纹修整 / 唇色 ──
        if o.lipLine > 0.01, g.outerLips.count >= 3 {
            let lb = g.bbox(g.outerLips)
            // 用共享的 featureMask（多边形 ∪ 包围盒椭圆）：Vision 的唇部关键点也是**细曲线**，
            // 实测部分照片上多边形质心落在多边形之外（coretest 第 40 段），只靠多边形会让唇纹修整落空。
            let m = featureMask(extent: e, polygons: [g.outerLips],
                                feather: max(0.8, min(lb.width, lb.height) * 0.18))
            out = softenInMask(out, mask: m, radius: max(1.5, lb.height * 0.18), strength: o.lipLine / 100)
        }
        if o.lipColor > 0.01, g.outerLips.count >= 3 {
            let lb2 = g.bbox(g.outerLips)
            // 尺度探针（§227，CR_BIAUDIT=1 时打一行）：唇色分支用的 `work` 与关键点 `g` 是否同一尺度？
            // 体检的探针是在**全分辨率 img** 上自己调 bestFeatureMask，若这里 work 是降采样图，
            // 掩膜就会错位 —— 而"只改 6 px、且不在掩膜高处"（§226）正是错位的特征。
            if ProcessInfo.processInfo.environment["CR_BIAUDIT"] == "1" {
                FileHandle.standardError.write(String(format: "LIPTRACE work=%.0fx%.0f e=%.0fx%.0f 唇盒=%.0fx%.0f 脸盒=%.0fx%.0f 关键点样本=(%.0f,%.0f)\n",
                    work.extent.width, work.extent.height, e.width, e.height,
                    lb2.width, lb2.height, g.box.width, g.box.height,
                    g.outerLips.first?.x ?? -1, g.outerLips.first?.y ?? -1).data(using: .utf8)!)
            }
            // 解析优先：上下唇是语义分出来的，多边形只是圈个大概
            let m = bestFeatureMask(work, face: g, classes: FaceClass.lipClasses) {
                featureMask(extent: e, polygons: [g.outerLips],
                             feather: max(0.8, min(lb2.width, lb2.height) * 0.18))
            }
            let k = min(1.0, o.lipColor / 100)
            // 强度常数原来是 (R +0.20 / G −0.08 / B −0.12)，多图实测**最大峰值只有 6 级**（第 41 段），
            // 属于"拖满也几乎看不出来"。调到 (R +0.32 / G −0.12 / B −0.18)：同样是"自然唇色"的量级，
            // 但拉满时看得出来。
            let tinted = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + 0.32 * k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - 0.12 * k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.18 * k, w: 0)])
            out = tinted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
        }
        // ── 5. 腮红（脸颊近似：眼睛下方外侧）──
        if o.blush > 0.01 {
            let lc = g.centroid(g.leftEye), rc = g.centroid(g.rightEye)
            let drop = g.box.height * 0.30, out2 = g.box.width * 0.12
            for c in [CGPoint(x: lc.x - out2, y: lc.y - drop), CGPoint(x: rc.x + out2, y: rc.y - drop)] {
                let rr = g.box.width * 0.26
                let r = CGRect(x: c.x - rr, y: c.y - rr * 0.8, width: rr * 2, height: rr * 1.6)
                let m = rectMask(extent: e, rect: r, feather: max(3, rr * 0.45), ellipse: true)
                let k = min(1.0, o.blush / 100)
                // 同理（腮红原来最大峰值 6 级，拉满看不出来）：R +0.16→+0.26、B −0.06→−0.10
                let tint = out.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 + 0.26 * k, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 - 0.03 * k, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.10 * k, w: 0),
                    "inputBiasVector": CIVector(x: 0.06 * k, y: 0.006 * k, z: 0.012 * k, w: 0)])
                out = tint.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(m, 0.85)])
            }
        }
        // ── 6. 牙齿 / 眼睛 ──
        if o.teeth > 0.01, g.innerLips.count >= 3 {
            let tb = g.bbox(g.innerLips)
            // ⚠️ **关键点退化守卫**（§221，与 §189 眼下带同构）：内唇包围盒可能退化成一条线 ——
            // §214 实测婚礼 RAW 上是 13x1，掩膜只盖 ~11 px ⇒ 牙齿美白峰值恒为 0 级。
            // 阈值取"最小边 < 脸宽 6%"（与眼下带的 minEyeSize 同一个口径，也是实测出来的）。
            // 退化时退回**按脸框估的口腔区**，不再依赖那条线状关键点。
            let degenerate = min(tb.width, tb.height) < max(3.0, g.box.width * 0.06)
            let m: CIImage
            if degenerate {
                // 口腔区经验位置**按实测比例**（§222：跨三张脸量到齿包围盒 = 宽 0.10~0.18 脸宽、
                // 高 0.03~0.08 脸高、中心 y −0.17~−0.25）。第一版凭感觉写了 0.40/0.18，
                // 比真实嘴部宽一倍多 —— 而体检用的是同一个矩形，**自己量自己发现不了过宽**，
                // 是靠"关键点相对脸框比例"这份独立数据才看出来的。
                let mr = CGRect(x: g.box.midX - g.box.width * 0.09,
                                y: g.box.minY + g.box.height * 0.18,
                                width: g.box.width * 0.18, height: g.box.height * 0.10)
                m = rectMask(extent: e, rect: mr, feather: max(1, mr.height * 0.3), ellipse: true)
            } else {
                // 解析优先：口腔/牙齿是单独一类（11）。innerLips 多边形会把嘴唇内侧一圈也算进来。
                // 羽化随特征尺寸走：脸只有几十像素时，固定 2.5 px 羽化会把整块蒙版吃没（实测中心值只剩 0.29）
                m = bestFeatureMask(work, face: g, classes: FaceClass.mouthClasses) {
                    featureMask(extent: e, polygons: [g.innerLips],
                                 feather: max(0.8, min(tb.width, tb.height) * 0.25))
                }
            }
            // 美白：提亮 + 去饱和（黄） + 蓝通道抬一点去黄
            out = adjustInMask(out, mask: m, brightness: 0.05, saturation: -0.45, blueReduce: -6,
                               strength: o.teeth / 100)
        }
        if o.eyes > 0.01, g.leftEye.count >= 3 {
            let ebFull = g.bbox(g.leftEye).union(g.bbox(g.rightEye))
            // ⚠️ **关键点退化守卫**（§222，与 §221 牙齿同构）：眼关键点可能退化成一条线 ——
            // §214 实测婚礼 RAW 上是 76x3 ⇒ 掩膜覆盖 0%、这一项在那张照片上结构性失效。
            // 兜底区按实测比例（跨三张脸：眼包围盒 = 宽 0.43~0.64 脸宽、高 0.08~0.21 脸高、
            // 中心 y +0.17~+0.27）取"整条眼带"。
            if min(ebFull.width, ebFull.height) < max(3.0, g.box.width * 0.06) {
                let er = CGRect(x: g.box.midX - g.box.width * 0.28,
                                y: g.box.midY + g.box.height * 0.22 - g.box.height * 0.07,
                                width: g.box.width * 0.56, height: g.box.height * 0.14)
                let em = rectMask(extent: e, rect: er, feather: max(1, er.height * 0.3), ellipse: true)
                out = adjustInMask(out, mask: em, brightness: 0.03, saturation: -0.05, contrast: 0.18,
                                   strength: o.eyes / 100)
            } else {
            let eb = g.bbox(g.leftEye)
            // 解析优先：眼区（含眼白/瞳孔）是一类，眼睑和眉毛是别类，不会互相串
            // 同上：眼睛关键点是细曲线，只靠多边形会漏（第 40 段实测质心处 0.00），
            // 用 featureMask（多边形 ∪ 包围盒椭圆）保证眼白/瞳孔都被覆盖。
            let m = bestFeatureMask(work, face: g, classes: FaceClass.eyeClasses) {
                featureMask(extent: e, polygons: [g.leftEye, g.rightEye],
                            feather: max(0.8, min(eb.width, eb.height) * 0.25))
            }
            // 黑白眼珠：加对比（瞳孔更实）+ 轻微提亮（眼白更亮）
            out = adjustInMask(out, mask: m, brightness: 0.03, saturation: -0.05, contrast: 0.18,
                               strength: o.eyes / 100)
            }
        }
        // ── 7. 双下巴：下巴下方的阴影提亮 + 轻微上收 ──
        if o.doubleChin > 0.01 {
            let r = CGRect(x: g.box.midX - g.box.width * 0.45,
                           y: g.box.minY - g.box.height * 0.34,
                           width: g.box.width * 0.9, height: g.box.height * 0.40)
            let m = rectMask(extent: e, rect: r, feather: max(3, r.height * 0.4), ellipse: true)
            // 幅度校准（§202）：0.055 在同族里明显偏弱 —— 逐项体检实测满档峰值
            // 双下巴 12~17 级 vs 眼袋 16~19、黑眼圈 18~22（都是"局部提亮去阴影"这一族）。
            // 拉到 0.10 之后落到同族水平，滑杆满档才真的"看得见"。
            out = adjustInMask(out, mask: m, brightness: 0.10, contrast: -0.07,
                               strength: o.doubleChin / 100)
        }
        // ── 8. 下颌线增强：下半张脸内做局部对比 + 锐化 ──
        if o.jawLine > 0.01 {
            let r = CGRect(x: g.box.minX, y: g.box.minY - g.box.height * 0.08,
                           width: g.box.width, height: g.box.height * 0.52)
            let m = rectMask(extent: e, rect: r, feather: max(3, r.height * 0.3), ellipse: true)
            let k = o.jawLine / 100
            let edged = out.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: max(2.0, g.box.width * 0.02),
                kCIInputIntensityKey: 0.6 * k])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: Float(1 + 0.06 * k)])
            out = edged.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(m, 1)])
        }
    }

    // ── 9. 面部重塑（形变放最后，几何基于原始关键点）──
    if o.anyWarp {
        var strokes: [LiquifyStroke] = []
        var pushStrokes: [WarpStroke] = []
        var zone = blackMask(e)
        for g in faces {
            let box = g.box
            // 形变只允许发生在脸框外扩 1.5 倍以内，背景不许被推动
            let zr = CGRect(x: box.midX - box.width * 0.85, y: box.midY - box.height * 0.85,
                            width: box.width * 1.7, height: box.height * 1.7)
            zone = maskUnion(rectMask(extent: e, rect: zr, feather: max(4, box.width * 0.15)), zone)
            // 3D 姿态感知（2.5D 近似）：瘦脸与鼻翼收窄都是**横向**推挤。脸一旦转过去，
            // 关键点在画面里被透视压缩，同样的横向位移会把脸推歪（侧脸被推成"歪嘴"）。
            // 按 |cos(yaw)| 折算：正脸照做，接近 90° 侧脸只做 45%。
            // ⚠️ 诚实边界：本机没有 3DMM，这**不是**真正的三维塑形，只是用姿态角给二维形变打折。
            let poseK = max(0.45, abs(cos(Double(g.yaw))))
            if o.faceSlim > 0.01 {
                // 左右颊各一个收缩点（与「收腰」同一套 Bump/Pinch 机制）
                let cy = box.minY + box.height * 0.42
                let r = box.width * 0.42
                strokes.append(LiquifyStroke(center: CGPoint(x: box.minX + box.width * 0.10, y: cy),
                                             radius: Double(r), strength: -o.faceSlim / 100 * 0.9 * poseK))
                strokes.append(LiquifyStroke(center: CGPoint(x: box.maxX - box.width * 0.10, y: cy),
                                             radius: Double(r), strength: -o.faceSlim / 100 * 0.9 * poseK))
            }
            if o.eyeBig > 0.01 {
                for eye in [g.bbox(g.leftEye), g.bbox(g.rightEye)] where eye.width > 2 {
                    strokes.append(LiquifyStroke(center: CGPoint(x: eye.midX, y: eye.midY),
                                                 radius: Double(eye.width * 2.4),
                                                 strength: o.eyeBig / 100 * 0.55))
                }
            }
            if o.noseSlim > 0.01, g.nose.count >= 3 {
                let nb = g.bbox(g.nose)
                strokes.append(LiquifyStroke(center: CGPoint(x: nb.minX, y: nb.midY),
                                             radius: Double(nb.width * 0.8), strength: -o.noseSlim / 100 * 0.7 * poseK))
                strokes.append(LiquifyStroke(center: CGPoint(x: nb.maxX, y: nb.midY),
                                             radius: Double(nb.width * 0.8), strength: -o.noseSlim / 100 * 0.7 * poseK))
            }
            if o.chinShape > 0.01 {
                let c = CGPoint(x: box.midX, y: box.minY + box.height * 0.06)
                strokes.append(LiquifyStroke(center: c, radius: Double(box.width * 0.5),
                                             strength: o.chinShape / 100 * 0.45))
            }
            if o.forehead > 0.01 {
                let c = CGPoint(x: box.midX, y: box.minY + box.height * 0.90)
                strokes.append(LiquifyStroke(center: c, radius: Double(box.width * 0.5),
                                             strength: o.forehead / 100 * 0.40))
            }
            // 发际线：整块竖向位移（不是 bump/pinch）——bump 只会把额头「撑圆」，
            // 改不了发际线的位置。这里用方向性位移把额头上缘整体推上/推下。
            if abs(o.hairline) > 0.01 {
                // 位移中心优先用「量出来的发际线」；量不到（没模型/头发太小）再退回脸框 84%
                let measured = hairlineY(work, face: g)
                let c = CGPoint(x: box.midX, y: measured ?? (box.minY + box.height * 0.84))
                pushStrokes.append(WarpStroke(
                    mode: .push, center: c, radius: Double(box.width * 0.62),
                    delta: CGPoint(x: 0, y: Double(box.height) * 0.11 * (o.hairline / 100)),
                    strength: 1.0))
            }
        }
        if !strokes.isEmpty {
            let warped = liquify(out, strokes: strokes)
            // 形变结果只落在 zone 内，出了脸区一律回退原图
            out = warped.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: zone])
        }
        if !pushStrokes.isEmpty {
            let warped = applyLiquify(out, strokes: pushStrokes)
            out = warped.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: zone])
        }
    }
    // §414：一键上色（第三方模型 DDColor，可选下载）—— 放在收尾之前，作用于整图 ✓。
    // §432（方向 5 第一步的修复）：**低饱和掩膜**。
    //   §431 实测：对本来有色的图，上色把色度从 56.71 改写成 43.88（差 -12.84）⇒ 会给彩色照片掉色 ✗。
    //   因此只在**低饱和处**采用上色结果，保留原有彩色 ✓：
    //     掩膜 = 反相(原图色度的亮度) ⇒ 低饱和处亮(=1) ⇒ 那里才用上色结果 ✓。
    //   模型未装 / 跑不动 ⇒ colorize 返回 nil ⇒ 这一支不生效（画面不变，功能不消失 ✓）。
    if o.colorize > 0.001, let colored = Colorizer.shared.colorize(out) {
        let k = max(0.0, min(1.0, o.colorize / 100.0))
        let gray = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        let chroma = out.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: gray])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 4.0])
        let lowSat = chroma.applyingFilter("CIColorInvert")
        let mixed = colored.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: lowSat])
        out = out.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: mixed, kCIInputTimeKey: k])
    }
    // 裁回整数 extent：Core Image 的 createCGImage 不接受非整数 extent（实测会直接失败）
    return out.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
        .cropped(to: src0.extent)
}

/// 保毛孔的色调均匀化：只动低频，高频纹理一点不碰
public func evenTone(_ src: CIImage, mask: CIImage, toneRadius: Double, strength: Double) -> CIImage {
    let k = max(0.0, min(1.0, strength))
    guard k > 0.001, toneRadius > 0.4 else { return src }
    let e = src.extent
    let low = src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: toneRadius]).cropped(to: e)
    let low2 = src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: toneRadius * 4]).cropped(to: e)
    guard let kernel = toneKernel,
          let out = kernel.apply(extent: e, arguments: [src, low, low2, k]) else {
        // 回落：线性混模糊图（会连毛孔一起压，属于降级路径）
        return softenInMask(src, mask: mask, radius: toneRadius, strength: k * 0.56)
    }
    return out.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: mask])
}

/// 肤色统一（真做）：先测出这块皮肤当前的暖冷，再朝参考组的目标暖冷平移。
/// 之前那版只是把参考值当代理量直接推，方向对但幅度凭经验；现在改成**先测后推**。
public func unifySkinToneMeasured(_ src: CIImage, mask: CIImage, rect: CGRect,
                                  targetWarm: Double, feather: Double = 0) -> CIImage {
    let r = rect.intersection(src.extent)
    guard r.width > 4, r.height > 4 else { return src }
    let cur = measure(src.cropped(to: r), work: 128)
    let delta = targetWarm - cur.warmHi
    if abs(delta) < 0.8 { return src }              // 已经一致就别动（避免无谓改动）
    let shift = max(-14.0, min(14.0, delta))
    var out = src
    let tinted = out.applyingFilter("CIColorMatrix", parameters: [
        "inputBiasVector": CIVector(x: shift / 255.0, y: 0, z: -shift / 255.0, w: 0)])
    out = tinted.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
    return out
}

/// 给一组矩形区域做柔化（手、脚、宠物、唇纹共用）。区域由调用方给，避免各写一份蒙版代码。
public func softenRects(_ src: CIImage, rects: [CGRect], strength: Double,
                        blurRadius: Double = 6, brighten: Double = 0.03) -> CIImage {
    let e = src.extent
    var mask = blackMask(e)
    for r0 in rects {
        let r = r0.intersection(e)
        guard r.width > 4, r.height > 4 else { continue }
        let feather = max(3.0, min(r.width, r.height) * 0.25)
        let patch = CIImage(color: .white).cropped(to: r)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: e)
        // 用已验证写法：白块 SourceOver 到黑底（加法合成会得到空蒙版）
        mask = patch.composited(over: mask)
    }
    return softenInMask(src, mask: mask, radius: blurRadius, strength: strength / 100, brighten: brighten)
}

/// 脚部美化：人体姿态只给到脚踝，所以区域取「脚踝下方一块」——如实标注为近似。
public func footRects(_ cg: CGImage, extent: CGRect) -> [CGRect] {
    let req = VNDetectHumanBodyPoseRequest()
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil,
          let obs = (req.results ?? []).first else { return [] }
    func pt(_ n: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
        guard let p = try? obs.recognizedPoint(n), p.confidence > 0.2 else { return nil }
        return CGPoint(x: p.location.x * extent.width, y: p.location.y * extent.height)
    }
    var out: [CGRect] = []
    for a in [pt(.leftAnkle), pt(.rightAnkle)] {
        guard let a = a else { continue }
        let s = extent.height * 0.06          // 脚的大致尺度：按图高取一块
        out.append(CGRect(x: a.x - s * 0.7, y: a.y - s, width: s * 1.4, height: s * 1.3))
    }
    return out
}

public func smoothFeet(_ src: CIImage, strength: Double = 60) -> CIImage {
    guard strength > 0.01, let cg = sharedCtx.createCGImage(src, from: src.extent) else { return src }
    let rects = footRects(cg, extent: src.extent)
    guard !rects.isEmpty else { return src }
    return softenRects(src, rects: rects, strength: strength, blurRadius: 5, brighten: 0.02)
}
