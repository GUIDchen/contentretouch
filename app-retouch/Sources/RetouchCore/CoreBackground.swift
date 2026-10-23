// CoreBackground.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

// MARK: - 挑图（近似打分，供命令行与界面共用）
public struct ImageScore {
    public var file: String
    public var sharpness: Double
    public var faceQuality: Double
    public var faces: Int
    public var flags: [String]
    public var total: Double
    public var eyeOpenness: Double = 0      // 最大一张脸的睁眼度（眼高/眼宽，闭眼时变小）
    public var composition: Double = 0      // 构图分（0~1，越接近三分线越高）
    // —— 本轮新增 ——
    public var smile: Double = 0            // 笑容强度（嘴张开度 × 嘴宽/脸宽）
    public var headYaw: Double = 0          // 头部偏转（度，0=正脸；取绝对值最大的那张脸）
    public var closedEyes: Int = 0          // 判定为闭眼的脸数（只数够大、且判定得出来的脸）
    public var judgedFaces: Int = 0         // 参与闭眼判定的脸数（够大且可测）
    // —— 前沿：Apple 学习模型的美学评分（macOS 15+）——
    public var aesthetic: Double = 0        // 0~1，越大越好看；0 且 utility=false 表示没跑（不是低分）
    public var aestheticOK: Bool = false
    public var isUtility: Bool = false      // 截图/文档/翻拍，不是要交付的照片
}

/// 挑图打分。
///
/// ⚠️ `maxDim` 不是可有可无的参数：早先这里写的是 `loadAnyImage(path)`（= **全分辨率**），
/// 于是每张 24MP 的片子都要解一遍完整位图（约 96 MB），再把它送进 Vision 跑人脸/显著性/美学分。
/// 挑图一次要过几千上万张，表现就是「内存长时间一两 G 上下、机器发烫发卡」。
/// 打分要的是**画面内容**，不是像素级细节——降到 1600px 判据完全够用，内存与耗时降一个量级。
public func scoreImage(_ path: String, maxDim: Int = 1600) -> ImageScore? {
    guard let ci = loadAnyImage(path, maxDim: maxDim),
          let cg = sharedCtx.createCGImage(ci, from: ci.extent) else { return nil }
    let size = ci.extent.size
    let s = measure(ci)
    let blur = ci.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0]).cropped(to: ci.extent)
    let diff = ci.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blur])
    // 差分图的 p50 几乎恒为 0，必须用高位分位才反映细节量（实测踩过这个坑）
    let sharp = measure(diff).p95
    let geos = detectFaceGeos(cg, size: size)
    let faces = geos.count
    let fq = geos.map { Double($0.quality) }.max() ?? 0

    // 睁眼度：脸越小越不可靠，所以只对够大的脸判定（脸宽 ≥ 图宽 6%）
    func aspect(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var r = CGRect.null
        for p in pts { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        return r.width > 0.5 ? Double(r.height / r.width) : 0
    }
    func bboxOfPts(_ pts: [CGPoint]) -> CGRect {
        guard pts.count >= 3 else { return .null }
        var r = CGRect.null
        for p in pts { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        return r
    }
    // 笑容：内唇高 / 外唇高（闭嘴时约 0.1~0.2，张嘴笑时 0.4+）。实测：三张素材里
    // 张嘴那张 0.55、另外两张 0.18 / 0.10，区分度够。
    var smile = 0.0
    if let big = geos.max(by: { $0.box.width < $1.box.width }), big.box.width >= size.width * 0.08 {
        let outer = bboxOfPts(big.outerLips), inner = bboxOfPts(big.innerLips)
        if outer.height > 0.5 { smile = min(1.0, Double(inner.height / outer.height)) }
    }
    // 头部姿态：Vision 直接给 yaw/roll（弧度），比自己从关键点推可靠
    var yawMax = 0.0
    for g in geos { yawMax = max(yawMax, abs(g.yaw), abs(g.roll)) }
    // 多人时逐脸判闭眼：只数「够大且测得出来」的脸，测不出来的不算数（避免小脸假报警）
    var closedEyes = 0, judgedFaces = 0
    for g in geos where g.box.width >= size.width * 0.08 {
        let vals = [aspect(g.leftEye), aspect(g.rightEye)].filter { $0 > 0 && $0 <= 0.9 }
        guard !vals.isEmpty else { continue }
        judgedFaces += 1
        if vals.reduce(0, +) / Double(vals.count) < 0.22 { closedEyes += 1 }
    }

    var eyeOpen = 0.0
    if let big = geos.max(by: { $0.box.width < $1.box.width }), big.box.width >= size.width * 0.08 {
        let a = aspect(big.leftEye), b = aspect(big.rightEye)
        let vals = [a, b].filter { $0 > 0 }
        if !vals.isEmpty {
            let v = vals.reduce(0, +) / Double(vals.count)
            // 正脸睁眼约 0.3~0.6；侧脸时这组关键点会几乎垂直（实测最大到 6.1），
            // 那种情况不是闭眼，是测不了——直接记 0 表示「不判定」，避免假报警。
            eyeOpen = v > 0.9 ? 0 : v
        }
    }

    // 构图：主体用**显著性**定位（没脸的风光照也能判），退化时才用最大脸、最后才用画面中心
    var comp = 0.5
    let subj: CGPoint
    if let sal = detectSaliency(cg), sal.subject.width > 0.05 {
        subj = CGPoint(x: sal.subject.midX, y: sal.subject.midY)
    } else if let big = geos.max(by: { $0.box.width < $1.box.width }) {
        subj = CGPoint(x: big.box.midX / size.width, y: big.box.midY / size.height)
    } else {
        subj = CGPoint(x: 0.5, y: 0.5)
    }
    let thirds = [1.0 / 3, 2.0 / 3]
    var best = 1.0
    for tx in thirds { for ty in thirds {
        best = min(best, hypot(Double(subj.x - tx), Double(subj.y - ty)))
    } }
    // 三分法 与 中心构图 都算好构图（人像中心构图很常见，只按三分线判会把它们全误报）
    let thirdScore = max(0, 1 - best / 0.30)
    let centerScore = max(0, 1 - hypot(Double(subj.x - 0.5), Double(subj.y - 0.5)) / 0.22) * 0.9
    comp = max(thirdScore, centerScore)
    // 主体贴边/被切掉要扣分
    var cut = false
    if let big = geos.max(by: { $0.box.width < $1.box.width }) {
        let b = big.box
        if b.minX < 2 || b.minY < 2 || b.maxX > size.width - 2 || b.maxY > size.height - 2 { cut = true }
    }

    // 前沿：学习模型的美学分 + 「是不是截图/文档」
    let aes = aestheticScore(cg)
    let dark = max(0, (20 - s.p5) / 20)
    let bright = max(0, (s.p99 - 245) / 10)
    var flags: [String] = []
    if faces == 0 { flags.append("无人脸") }
    if sharp < 6 { flags.append("可能模糊") }
    if fq > 0 && fq < 0.25 { flags.append("人脸质量低") }
    if eyeOpen > 0 && eyeOpen < 0.22 { flags.append("疑似闭眼") }
    if closedEyes > 0 { flags.append("有 \(closedEyes) 张脸闭眼") }
    if yawMax > 0.6 { flags.append("侧脸/扭头 \(Int(yawMax * 180 / .pi))°") }
    if comp < 0.25 { flags.append("构图偏离三分线") }
    if cut { flags.append("主体贴边") }
    if dark > 0.5 { flags.append("欠曝") }
    if bright > 0.5 { flags.append("过曝") }
    if aes.ok && aes.isUtility { flags.append("截图/文档（不是照片）") }
    let total = sharp * 3 + fq * 40 + Double(faces) * 2 - dark * 20 - bright * 20
        + comp * 10 - (eyeOpen > 0 && eyeOpen < 0.22 ? 15 : 0) - (cut ? 8 : 0)
        + smile * 8                                  // 笑容加分（挑图时笑脸优先）
        - Double(closedEyes) * 12                    // 每有一张脸闭眼扣 12
        - (yawMax > 0.6 ? 5 : 0)                     // 扭头超过 34° 扣 5
        + (aes.ok ? aes.overall * 25 : 0)            // 学习模型的美学分（跑不了就不加不减）
        - (aes.ok && aes.isUtility ? 30 : 0)         // 截图/文档直接压到底
    var out = ImageScore(file: URL(fileURLWithPath: path).lastPathComponent, sharpness: sharp,
                         faceQuality: fq, faces: faces, flags: flags, total: total)
    out.eyeOpenness = eyeOpen
    out.composition = comp
    out.smile = smile
    out.headYaw = yawMax * 180 / .pi
    out.closedEyes = closedEyes
    out.judgedFaces = judgedFaces
    out.aesthetic = aes.overall
    out.aestheticOK = aes.ok
    out.isUtility = aes.isUtility
    return out
}

// MARK: - 裁剪：祛黑白边（纯几何，检测四边连续黑/白列并裁掉）
//
// 做法：把图缩到小尺寸逐行/逐列看亮度，从四边往里找连续「接近纯黑(<=12)或纯白(>=243)」的行列，
// 连续超过阈值（默认边长的 2% 或 8 像素）就认为是边框。做完再做一次内缩保险（默认 0 像素）。
/// 多点收敛版：单次扫描每侧只推进会一部分（白边实测每侧只裁掉一半），
/// 所以在裁后的图上反复再检测，直到稳定或到轮数上限。
public func detectBorderCropConverged(_ src: CIImage, maxPasses: Int = 4) -> CGRect {
    var rect = src.extent
    for _ in 0..<maxPasses {
        let sub = src.cropped(to: rect)
        let inner = detectBorderCrop(sub)
        let w = inner.width / max(1, rect.width)
        let h = inner.height / max(1, rect.height)
        rect = inner
        if w > 0.999 && h > 0.999 { break }      // 没有新进展就停
    }
    return rect
}

public func detectBorderCrop(_ src: CIImage, tolerance: Double = 12, minRunRatio: Double = 0.02) -> CGRect {
    let work = 256
    let normalized = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
    let scale = Double(work) / max(normalized.extent.width, normalized.extent.height)
    let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    func luma(_ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
    }
    // 判定改成「整行/整列的均值够黑够白 + 方差够小」：
    // 原来要求每个像素都纯黑/纯白，JPEG 噪声让一个 240 的像素就能否掉整行（实测导致裁不动）。
    func rowStats(_ y: Int) -> (mean: Double, sd: Double) {
        var sum = 0.0, sum2 = 0.0
        for x in 0..<w { let v = luma(x, y); sum += v; sum2 += v * v }
        let m = sum / Double(w)
        return (m, max(0, sum2 / Double(w) - m * m).squareRoot())
    }
    func colStats(_ x: Int) -> (mean: Double, sd: Double) {
        var sum = 0.0, sum2 = 0.0
        for y in 0..<h { let v = luma(x, y); sum += v; sum2 += v * v }
        let m = sum / Double(h)
        return (m, max(0, sum2 / Double(h) - m * m).squareRoot())
    }
    func isBorder(_ s: (mean: Double, sd: Double)) -> Bool {
        return s.sd <= 10 && (s.mean <= tolerance || s.mean >= 255 - tolerance)
    }
    func rowIsBorder(_ y: Int) -> Bool { isBorder(rowStats(y)) }
    func colIsBorder(_ x: Int) -> Bool { isBorder(colStats(x)) }
    let minRun = max(2, Int(Double(min(w, h)) * minRunRatio))
    var top = 0, bottom = h - 1, left = 0, right = w - 1
    while top < h - 1 && top < minRun * 20 && rowIsBorder(top) { top += 1 }
    while bottom > top && bottom > h - minRun * 20 && rowIsBorder(bottom) { bottom -= 1 }
    while left < w - 1 && left < minRun * 20 && colIsBorder(left) { left += 1 }
    while right > left && right > w - minRun * 20 && colIsBorder(right) { right -= 1 }
    // 没找到任何边框就跑一次保险（至少裁 minRun）
    if top < minRun && bottom > h - minRun && left < minRun && right > w - minRun {
        return src.extent
    }
    let k = 1.0 / scale
    return CGRect(x: src.extent.minX + Double(left) * k,
                  y: src.extent.minY + Double(h - 1 - bottom) * k,
                  width: Double(right - left + 1) * k,
                  height: Double(bottom - top + 1) * k)
}

// MARK: - 背景纯化（人像分割 + 背景低频 flatten）
//
// 做法：Vision 人像分割拿人像蒙版 → 背景 = 1 − 人像 → 在背景里把「大半径低频」替换回原图，
// 褶皱、脏点、不均一的墙面会被压平；人物区域不动（用蒙版隔离）。
// 诚实边界：这是「纯色背景净化」，**不是换背景/换天空**（那要生成式）。
/// 人像蒙版（0=背景，1=人像），已缩放到原图尺寸。验证脚本与背景纯化共用同一份，避免两边口径不一致。
public func personMask(_ src: CIImage) -> CIImage? {
    VisionCache.shared.personMask(src) { () -> CIImage? in

    // 大图上先降到 ≤2048 再跑：实测 32MP 的图，人物分割在这一步能吃掉 2.5s。
    // 掩膜本身是低频的，降采样算完再放大回去，观感无差别（coretest 里有对照）。
    let visionSrc = downscaledForMask(src, cap: 2048)
    guard let cg = sharedCtx.createCGImage(visionSrc, from: visionSrc.extent) else { return nil }
    let req = VNGeneratePersonSegmentationRequest()
    req.qualityLevel = .balanced
    req.outputPixelFormat = kCVPixelFormatType_OneComponent8
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil,
          let obs = req.results?.first else { return nil }
    let pw = CGFloat(CVPixelBufferGetWidth(obs.pixelBuffer))
    let ph = CGFloat(CVPixelBufferGetHeight(obs.pixelBuffer))
    return CIImage(cvPixelBuffer: obs.pixelBuffer)
        .transformed(by: CGAffineTransform(scaleX: visionSrc.extent.width / pw, y: visionSrc.extent.height / ph))
        .transformed(by: CGAffineTransform(scaleX: src.extent.width / visionSrc.extent.width,
                                           y: src.extent.height / visionSrc.extent.height))
        .cropped(to: src.extent)

    }
}

// MARK: - 局部 AI 追色（近似：只对指定区域做色温/亮度对齐）
//
// 像素蛋糕有「局部AI追色」：参考图的色调只匹配到画面的某个区域（例如只追人物、不追背景）。
// 我们这里做的是它的**可落地子集**：在指定矩形（羽化）内，把区域的**色温与亮度**朝参考组推。
// ⚠️ 边界：不是完整的颜色分布迁移（那需要 3D LUT 回归或网络），只对齐冷暖与明暗这两个最有感知的维度。
// ⚠️ 蒙版用 Core Image 原生方式生成（CIImage(color:).cropped），**不碰 CGBitmapContext**，
//    所以不需要 y 翻转——这是前面踩坑后总结出来的安全写法。
public func localColorMatch(_ src: CIImage, rect: CGRect, deltaWarm: Double, deltaBright: Double,
                            strength: Double = 1.0, feather: Double = 24) -> CIImage {
    guard rect.width > 2, rect.height > 2 else { return src }
    guard abs(deltaWarm) > 0.01 || abs(deltaBright) > 0.01 else { return src }
    let e = src.extent
    let k = max(0.0, min(1.0, strength))
    // 羽化矩形蒙版
    let hard = CIImage(color: .white).cropped(to: rect)
    let mask = hard
        .composited(over: CIImage(color: .black).cropped(to: e))
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
        .cropped(to: e)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    // 区域内：暖冷（R↑B↓）+ 亮度
    let adjusted = src.applyingFilter("CIColorMatrix", parameters: [
        "inputBiasVector": CIVector(x: deltaWarm / 255.0, y: 0, z: -deltaWarm / 255.0, w: 0)])
        .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: deltaBright / 255.0])
    return adjusted.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: mask])
}

// MARK: - 前景实例分割（macOS 14+）：比单人像掩膜更准的边缘
//
// VNGenerateForegroundInstanceMaskRequest 给出「主体实例」掩膜（人/物/宠物都算），
// 用它替换现有的「人像分割」，背景纯化的边缘会明显更干净。
// ⚠️ 这是 macOS 14+ API，所以 Package.swift 平台已提到 v14，Info.plist 也要同步到 14.0。
public func foregroundMask(_ src: CIImage) -> CIImage? {
    // 同上：大图先降到 ≤2048 再跑 Vision
    let visionSrc = downscaledForMask(src, cap: 2048)
    guard #available(macOS 14.0, *), let cg = sharedCtx.createCGImage(visionSrc, from: visionSrc.extent) else { return nil }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let req = VNGenerateForegroundInstanceMaskRequest()
    guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return nil }
    let instances = obs.allInstances
    guard !instances.isEmpty,
          let pb = try? obs.generateScaledMaskForImage(forInstances: instances, from: handler) else { return nil }
    let pw = CGFloat(CVPixelBufferGetWidth(pb)), ph = CGFloat(CVPixelBufferGetHeight(pb))
    return CIImage(cvPixelBuffer: pb)
        .transformed(by: CGAffineTransform(scaleX: visionSrc.extent.width / pw, y: visionSrc.extent.height / ph))
        .transformed(by: CGAffineTransform(scaleX: src.extent.width / visionSrc.extent.width,
                                           y: src.extent.height / visionSrc.extent.height))
        .cropped(to: src.extent)
}

/// 跑掩膜类模型前把大图降下来（掩膜是低频信息，不需要全分辨率）。
/// 实测 32MP 的图：人物分割 2.5s → 降到 2048 后 0.2s 量级。
public func downscaledForMask(_ src: CIImage, cap: Double = 2048) -> CIImage {
    let e = src.extent
    let longest = max(e.width, e.height)
    guard longest > cap else { return src }
    let k = cap / longest
    return src.transformed(by: CGAffineTransform(scaleX: k, y: k))
}

/// 背景纯化（升级版）：优先用前景实例掩膜，退化时回落到人像分割
public func purifyBackgroundEx(_ src: CIImage, flattenRadius: Double = 24, strength: Double = 70) -> CIImage {
    guard let fg = foregroundMask(src) ?? personMask(src) else { return src }
    let e = src.extent
    let bg = fg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 8.0])
        .cropped(to: e)
        .applyingFilter("CIColorInvert")
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.85, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.85, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.85, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        // 羽化会把蒙版扩散到主体之外，再乘一次前景掩膜夹回来（衣物平整那条教训）
        .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: fg.applyingFilter("CIColorInvert")])
    let k = max(0.0, min(1.0, strength / 100.0))
    let soft = bg.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    let low = fastBlur(src, radius: flattenRadius)
    return low.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: soft])
}
