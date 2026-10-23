// Scene：把系统 Vision 的「AI 能力面」接进来（不碰生成式）
//
// 探针结论（coretest 会打印同样的数字）：
//   注意力显著性  ✅ 给主体框（婚礼图 x0.10 y0.29 w0.79 h0.69，置信度 0.58）
//   物体性显著性  ✅ 给显著物体个数
//   图像分类      ✅ ImageNet 词表（婚礼图：clothing 0.80 / suit 0.79 / people 0.74 / celebration 0.45）
//   人体框        ✅ 婚礼图 2 个（对全身照比人脸框更管用）
//   人物实例分割  ✅ 婚礼图 2 个实例（[1,2]）→ 可以按人分开处理
//   3D 人体姿态   ✅ 可用（婚礼图 1 个）
// 这套东西能做的三件事：智能裁剪 / 构图打分 / 场景识别→推荐参数。
import Foundation
import CoreImage
import Vision

// MARK: - 显著性（主体在哪）

public struct SaliencyInfo {
    public var subject: CGRect = .zero       // 归一化（原点左下）
    public var confidence: Float = 0
    public var objectCount: Int = 0
}

public func detectSaliency(_ cg: CGImage) -> SaliencyInfo? {
    let att = VNGenerateAttentionBasedSaliencyImageRequest()
    let obj = VNGenerateObjectnessBasedSaliencyImageRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([att, obj])) != nil else { return nil }
    guard let a = att.results?.first else { return nil }
    var info = SaliencyInfo()
    if let s = a.salientObjects?.first {
        info.subject = s.boundingBox
        info.confidence = s.confidence
    }
    info.objectCount = obj.results?.first?.salientObjects?.count ?? 0
    return info
}

/// 显著性图（小尺寸灰度图），用来判断主体是不是「一小块」还是「占满画面」
// MARK: - 场景识别

public struct SceneInfo {
    public var labels: [(String, Float)] = []
    public var category: String = "未知"
    public var reasons: [String] = []
    public var faces: Int = 0
    public var people: Int = 0
    public var animals: Int = 0
    public var saliency: SaliencyInfo?
    public init(category: String = "未知") { self.category = category }
}

/// 关键词表：ImageNet 词表里跟拍婚礼/人像相关的那些（不是官方预设映射，是我们自己的经验映射）
private let sceneKeywords: [String: [String]] = [
    "婚礼/宴席": ["celebration", "wedding", "bouquet", "red_envelope", "suit", "gown", "bridegroom", "dress_suit"],
    "儿童": ["child", "baby", "infant", "teen", "schoolchild", "crib"],
    "宠物": ["dog", "cat", "puppy", "kitten", "retriever", "terrier", "tabby"],
    "多人合影": ["people", "adult", "crowd", "group"],
    "风光/场景": ["landscape", "mountain", "valley", "seashore", "lakeside", "sky", "building", "street"]
]

public func classifyScene(_ cg: CGImage) -> SceneInfo {
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let cls = VNClassifyImageRequest()
    var info = SceneInfo()
    if (try? handler.perform([cls])) != nil, let res = cls.results {
        info.labels = res.prefix(12).map { ($0.identifier, $0.confidence) }
    }
    // 检测：脸 / 人 / 动物
    let fr = VNDetectFaceRectanglesRequest()
    let hr = VNDetectHumanRectanglesRequest()
    hr.upperBodyOnly = false
    let an = VNRecognizeAnimalsRequest()
    _ = try? handler.perform([fr, hr, an])
    info.faces = fr.results?.count ?? 0
    info.people = hr.results?.count ?? 0
    info.animals = an.results?.count ?? 0
    // 动物识别（ImageNet 分类器）在部分宠物照上给 0，但动物姿态能给出来（实测同一张图 0 vs 2），
    // 所以两个信号取大的那个 —— 单一信号会漏判
    if #available(macOS 14.0, *) {
        let ap = VNDetectAnimalBodyPoseRequest()
        if (try? handler.perform([ap])) != nil {
            info.animals = max(info.animals, ap.results?.count ?? 0)
        }
    }
    info.saliency = detectSaliency(cg)

    // 类别判定：检测优先，分类词补足（检测比词表可靠）
    if info.animals > 0 {
        info.category = "宠物"
        info.reasons.append("动物识别到 " + String(info.animals) + " 个")
    } else if info.faces >= 3 || info.people >= 3 {
        info.category = "多人合影"
        info.reasons.append("检出 " + String(info.faces) + " 张脸 / " + String(info.people) + " 个人")
    } else {
        var best = ("", 0.0)
        for (cat, keys) in sceneKeywords {
            let score = info.labels.filter { keys.contains($0.0) }.map { Double($0.1) }.reduce(0, +)
            if score > best.1 { best = (cat, score) }
        }
        if info.faces > 0 {
            // 有脸就不是风光；结婚宴席的信号强于普通合影
            if best.0 == "婚礼/宴席" && best.1 > 0.8 {
                info.category = best.0
                info.reasons.append("分类信号 " + String(format: "%.2f", best.1) + "（" + info.labels.prefix(4).map { $0.0 }.joined(separator: "/") + "）")
            } else if best.0 == "儿童" {
                info.category = "儿童"
                info.reasons.append("分类信号 " + String(format: "%.2f", best.1))
            } else {
                info.category = "人像"
                info.reasons.append("检出 " + String(info.faces) + " 张脸，且没有宴席/儿童信号")
            }
        } else if best.1 > 0.3 {
            info.category = best.0
            info.reasons.append("分类信号 " + String(format: "%.2f", best.1))
        } else {
            info.category = "风光/场景"
            info.reasons.append("无脸无人无动物，分类最高 " + String(format: "%.2f", best.1))
        }
    }
    return info
}

// MARK: - 场景 → 推荐参数

public struct SceneSuggestion {
    public var category: String
    public var portrait = PortraitOptions()
    public var skinGrade = "medium"
    public var skinTone = true
    public var texturePreserve = true
    public var extras: [String: Double] = [:]
    public var reasons: [String] = []
}

/// 按场景给一套起点参数。诚实说明：这是我们自己的经验值，不是「官方预设映射」。
public func suggestParams(for info: SceneInfo) -> SceneSuggestion {
    var s = SceneSuggestion(category: info.category)
    s.reasons = info.reasons
    switch info.category {
    case "婚礼/宴席":
        s.portrait.spotBlemish = 45; s.portrait.shine = 50; s.portrait.darkCircle = 50
        s.portrait.teeth = 45; s.portrait.eyes = 35; s.portrait.lipColor = 30; s.portrait.blush = 30
        s.portrait.faceSlim = 35; s.portrait.eyeBig = 25; s.portrait.jawLine = 25
        s.portrait.hands = 30
        s.skinGrade = "medium"; s.skinTone = true
        s.extras = ["sharpen": 25, "vignette": 12, "bgPurify": 25]
        s.reasons.append("宴席/礼服场景：祛瑕 + 牙齿 + 唇色 + 手部，背景轻纯化")
    case "儿童":
        s.portrait.spotBlemish = 20; s.portrait.shine = 30; s.portrait.darkCircle = 35
        s.portrait.eyeBig = 25; s.portrait.blush = 25; s.portrait.teeth = 20
        s.skinGrade = "light"; s.skinTone = true
        s.extras = ["sharpen": 20]
        s.reasons.append("儿童：轻磨皮、少动结构（脸型/鼻子一律不推）")
    case "宠物":
        s.portrait = PortraitOptions()          // 宠物不吃人脸参数
        s.skinGrade = "off"; s.skinTone = false
        s.extras = ["bgBlur": 30, "sharpen": 25, "denoise": 20]
        s.reasons.append("宠物：背景虚化 + 锐化，人脸参数不参与")
    case "多人合影":
        s.portrait.spotBlemish = 35; s.portrait.shine = 40; s.portrait.darkCircle = 40
        s.portrait.teeth = 30; s.portrait.faceSlim = 20
        s.skinGrade = "medium"; s.skinTone = true
        s.extras = ["sharpen": 25, "lensVignette": 25]
        s.reasons.append("合影：统一轻磨皮 + 暗角校正，不做大幅面孔重塑")
    case "人像":
        s.portrait.spotBlemish = 45; s.portrait.shine = 45; s.portrait.darkCircle = 55
        s.portrait.faceSlim = 40; s.portrait.eyeBig = 30; s.portrait.noseSlim = 25
        s.portrait.teeth = 40; s.portrait.eyes = 35; s.portrait.lipColor = 25; s.portrait.blush = 30
        s.portrait.hands = 30
        s.skinGrade = "medium"; s.skinTone = true
        s.extras = ["sharpen": 25, "bgBlur": 20]
        s.reasons.append("单人/双人像：标准美颜一套，背景轻虚化")
    default:
        s.skinGrade = "off"; s.skinTone = false
        s.extras = ["sharpen": 30, "denoise": 20, "lensDistortion": -20, "lensVignette": 20]
        s.reasons.append("无主体的场景：只做镜头校正 + 影调，不动人脸")
    }
    return s
}

// MARK: - 智能裁剪

/// 按目标长宽比、以主体为基准算裁剪框（返回像素坐标）。
/// placement = "center" 主体居中；"thirds" 把主体放在三分线上（人像常用）。
///
/// ⚠️ 全程在**像素**坐标里算比例：归一化的 w 与 h 不是同一个单位（宽高各除以不同的数），
/// 混着算比例会算错——第一版就是这么写的，2:3 的图上要 1:1 会得到 0.67:1（正方形画布上测不出来）。
public func smartCropRect(imageSize: CGSize, aspect: Double, subject: CGRect,
                          placement: String = "thirds", margin: Double = 0.06) -> CGRect {
    let W = Double(imageSize.width), H = Double(imageSize.height)
    guard W > 1, H > 1, aspect > 0.05 else { return CGRect(origin: .zero, size: imageSize) }
    var sub = subject
    if sub.width < 0.01 || sub.height < 0.01 {
        sub = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    let sw = Double(sub.width) * W, sh = Double(sub.height) * H
    let bx = Double(sub.midX) * W, by = Double(sub.midY) * H
    // 裁剪框至少装得下主体（含边距）
    let needW = min(W, sw / max(0.2, 1 - margin * 2))
    let needH = min(H, sh / max(0.2, 1 - margin * 2))
    var cw = max(needW, needH * aspect)
    var ch = cw / aspect
    if ch < needH { ch = needH; cw = ch * aspect }
    cw = min(cw, W); ch = min(ch, H)
    if cw / ch > aspect { cw = ch * aspect } else { ch = cw / aspect }
    // 主体在裁剪框里的目标位置
    var fx = 0.5, fy = 0.5
    if placement == "thirds" {
        fx = bx < W / 2 ? 1.0 / 3.0 : 2.0 / 3.0
        fy = by < H / 2 ? 1.0 / 3.0 : 2.0 / 3.0
    }
    var ox = bx - cw * fx
    var oy = by - ch * fy
    // 硬约束：主体必须完整落在裁剪框里（构图让位于「别把人切了」）
    let loX = max(0.0, Double(sub.maxX) * W - cw), hiX = min(W - cw, Double(sub.minX) * W)
    if loX <= hiX { ox = min(max(ox, loX), hiX) } else { ox = min(max(0, ox), W - cw) }
    let loY = max(0.0, Double(sub.maxY) * H - ch), hiY = min(H - ch, Double(sub.minY) * H)
    if loY <= hiY { oy = min(max(oy, loY), hiY) } else { oy = min(max(0, oy), H - ch) }
    return CGRect(x: ox, y: oy, width: cw, height: ch)
}

// MARK: - 人物实例（多人分别处理）

/// 每个人一张掩膜（按实例分开）。返回顺序按掩膜重心从左到右，便于按人编号。
/// rect 是**掩膜内容的包围盒**（不是掩膜 extent —— extent 永远是整幅图，拿它当「人在哪」会错）。
public func personInstanceMasks(_ src: CIImage) -> [(rect: CGRect, mask: CIImage)] {
    guard #available(macOS 14.0, *),
          let cg = sharedCtx.createCGImage(src, from: src.extent) else { return [] }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let req = VNGeneratePersonInstanceMaskRequest()
    guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return [] }
    var out: [(CGRect, CIImage)] = []
    for i in obs.allInstances {
        guard let pb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler) else { continue }
        // 实例掩膜本身是「软」的（轮廓外还有 0.1~0.3 的溢出）。在**这里**做一次收紧，
        // 后面所有人（包围盒、覆盖率、按人处理）拿到的就是硬的、贴着人的掩膜 ——
        // 不收的话：包围盒被撑大、按人处理会在人周围糊出一块看得见的矩形。
        let raw = CIImage(cvPixelBuffer: pb)
            .transformed(by: CGAffineTransform(scaleX: src.extent.width / CGFloat(CVPixelBufferGetWidth(pb)),
                                               y: src.extent.height / CGFloat(CVPixelBufferGetHeight(pb))))
            .cropped(to: src.extent)
        let m = raw.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.8, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.8, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.8, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -0.45, y: -0.45, z: -0.45, w: 0)])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .cropped(to: src.extent)
        let box = bboxOfBright(m, in: src.extent)
        guard box.width > 8, box.height > 8 else { continue }      // 空掩膜直接丢
        out.append((box, m))
    }
    return out.sorted { (a: (rect: CGRect, mask: CIImage), b: (rect: CGRect, mask: CIImage)) -> Bool in
        centroidOfBright(a.mask, in: src.extent).x < centroidOfBright(b.mask, in: src.extent).x
    }
}

/// 掩膜的亮度重心（给多人排序、也知道每个人在哪）
public func centroidOfBright(_ mask: CIImage, in extent: CGRect) -> CGPoint {
    let (buf, w, h) = sampleMask(mask, in: extent)
    var sx = 0.0, sy = 0.0, s = 0.0
    for y in 0..<h { for x in 0..<w {
        let v = buf[y * w + x]
        if v <= 8 { continue }
        sx += Double(x) * v; sy += Double(h - y) * v; s += v
    } }
    guard s > 0 else { return .zero }
    return CGPoint(x: extent.minX + sx / s / Double(w) * Double(extent.width),
                   y: extent.minY + sy / s / Double(h) * Double(extent.height))
}

// MARK: - 掩膜采样（三个统计都走这里，避免各写一份）

/// 把掩膜**在指定矩形内**缩到小图再采样。
///
/// ⚠️ 两个坑都踩过，都记在这儿：
/// 1. `CIContext.render(bounds:)` **不做缩放**：bounds 是「原图坐标里的哪一块」，
///    直接用它采样小尺寸等于只看原图左下角那一小块 —— 掩膜的包围盒/重心/覆盖率全踩过这个坑。
/// 2. **`extent` 参数以前根本没被用**：函数把整张掩膜缩放后全量采样，于是
///    `maskCoverage(mask, in: 某个区域)` 量的其实是**整幅图**的覆盖率。
///    症状很隐蔽：脸框内的覆盖率与全图覆盖率**一模一样**（0.026 vs 0.0264），
///    而掩膜本身是对的（鼻子 0.99、脸颊 0.89）——**量尺坏了，不是掩膜坏了**。
///    这把量尺被多处闸门用着（衣物解析、天空、各种掩膜体检），所以必须修对。
func sampleMask(_ mask: CIImage, in extent: CGRect, width: Int = 128) -> (buf: [Double], w: Int, h: Int) {
    let region = extent.intersection(mask.extent)
    guard region.width > 0.5, region.height > 0.5 else { return ([], 1, 1) }
    let n = mask.cropped(to: region)
        .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
    let sx = Double(width) / max(1, Double(n.extent.width))
    let h = max(1, Int(round(Double(n.extent.height) * sx)))
    let scaled = n.transformed(by: CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sx)))
    var raw = [UInt8](repeating: 0, count: width * h * 4)
    sharedCtx.render(scaled, toBitmap: &raw, rowBytes: width * 4,
                     bounds: CGRect(x: 0, y: 0, width: width, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var out = [Double](repeating: 0, count: width * h)
    for i in 0..<(width * h) { out[i] = Double(raw[i * 4]) }
    return (out, width, h)
}

/// 掩膜「有内容」部分的包围盒（阈值 20/255，忽略羽化边缘的碎值）
public func bboxOfBright(_ mask: CIImage, in extent: CGRect, threshold: Double = 60) -> CGRect {
    let (buf, w, h) = sampleMask(mask, in: extent)
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h { for x in 0..<w {
        if buf[y * w + x] <= threshold { continue }
        minX = min(minX, x); maxX = max(maxX, x)
        let ry = h - y
        minY = min(minY, ry); maxY = max(maxY, ry)
    } }
    guard maxX >= minX, maxY >= minY else { return .null }
    return CGRect(x: extent.minX + Double(minX) / Double(w) * Double(extent.width),
                  y: extent.minY + Double(minY) / Double(h) * Double(extent.height),
                  width: Double(maxX - minX + 1) / Double(w) * Double(extent.width),
                  height: Double(maxY - minY + 1) / Double(h) * Double(extent.height))
}

/// 掩膜内容占比（0~1），用来判断实例是不是空的
public func maskCoverage(_ mask: CIImage, in extent: CGRect, threshold: Double = 60) -> Double {
    let (buf, w, h) = sampleMask(mask, in: extent)
    var n = 0
    for v in buf where v > threshold { n += 1 }
    return Double(n) / Double(max(1, w * h))
}

/// 肩线倾角（度，正 = 画面右侧那肩更高）。用 2D 人体姿态的两个肩点，直接对应图像坐标。
/// （3D 人体姿态本机也能用，但它给的是归一化三维坐标，跟图像旋转不是同一套量，这里不用它。）
/// ⚠️ 已知特性（第 145 节实测）：这是叠在**姿态检测器**上的启发式，而姿态模型是在正立人像上训练的 ——
/// 对旋转过的人像，检出倾角**不随旋转成比例**：夹具旋转 +7°/-7°/+14° 时倾角变化量是 -5.9/-10.9/+9.6。
/// 所以：① 不要拿"旋转 N 度 → 倾角应变化 N 度"当判据（会做出时红时绿的门）；
///       ② 体检只用**同一次运行内**可精确验证的量（应用的旋转 = 检出倾角的精确反向、夹在 ±10°）。
public func shoulderTilt(_ cg: CGImage, extent: CGRect) -> Double? {
    let b = detectBodyPoints(cg, extent: extent)
    guard let ls = b.leftShoulder, let rs = b.rightShoulder else { return nil }
    let dx = Double(rs.x - ls.x), dy = Double(rs.y - ls.y)
    guard abs(dx) > 1 else { return nil }
    var deg = atan2(dy, dx) * 180 / .pi
    if deg > 90 { deg -= 180 }          // 肩线是一条「左右线」，180° 与 0° 是同一件事
    if deg < -90 { deg += 180 }
    return deg
}


// MARK: - 姿态分级 + 连拍同组选优

/// 姿态分级：用 Vision 给的 yaw/roll（度）判，不靠猜。
/// 分级阈值是行业里常用的分档：正脸 ≤15°、3/4 侧脸 ≤40°、侧脸 ≤70°、再大算背身/几乎看不到正脸。
public func poseGrade(yawDeg: Double, faces: Int) -> String {
    guard faces > 0 else { return "无脸" }
    let a = abs(yawDeg)
    if a <= 15 { return "正面" }
    if a <= 40 { return "3/4 侧脸" }
    if a <= 70 { return "侧脸" }
    return "背身/扭头过度"
}

public struct BurstGroup {
    public var indices: [Int]
    public var best: Int          // 组内最高分的下标
    public var reason = ""
    public init(indices: [Int] = [], best: Int = 0, reason: String = "") {
        self.indices = indices; self.best = best; self.reason = reason
    }
}

/// 连拍分组：优先用 EXIF 拍摄时间（间隔 ≤ window 秒算同一组）；
/// 没有 EXIF 就退回「文件名前缀 + 修改时间」——影楼素材很多是被脱过 EXIF 的（实测我们的婚礼素材就没有）。
public func groupBursts(paths: [String], window: Double = 3.0) -> [BurstGroup] {
    struct Entry { var idx: Int; var time: Double; var key: String }
    var entries: [Entry] = []
    for (i, p) in paths.enumerated() {
        var t: Double = 0
        var key = URL(fileURLWithPath: p).lastPathComponent
        // 1) EXIF 拍摄时间
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let d = f.date(from: s) { t = d.timeIntervalSince1970 }
            }
        }
        // 2) 去掉序号后的文件名当分组键（0001_xxx_01 / 0001_xxx_02 → 同一组）
        let base = (key as NSString).deletingPathExtension
        let parts = base.split(separator: "_")
        if parts.count >= 2 { key = parts.dropLast().joined(separator: "_") }
        if t == 0 {
            // 没有 EXIF：用修改时间
            if let a = try? FileManager.default.attributesOfItem(atPath: p),
               let d = a[.modificationDate] as? Date { t = d.timeIntervalSince1970 }
        }
        entries.append(Entry(idx: i, time: t, key: key))
    }
    entries.sort { ($0.key, $0.time) < ($1.key, $1.time) }
    var groups: [[Int]] = []
    var current: [Int] = []
    var lastKey = ""
    var lastTime = -1e9
    for e in entries {
        if e.key != lastKey || (e.time - lastTime) > window {
            if !current.isEmpty { groups.append(current) }
            current = [e.idx]
        } else {
            current.append(e.idx)
        }
        lastKey = e.key
        lastTime = e.time
    }
    if !current.isEmpty { groups.append(current) }
    return groups.map { BurstGroup(indices: $0, best: $0.first ?? 0, reason: "同组 \($0.count) 张") }
}

/// 组内选最优：分数最高的那张（分数并列时取更靠前的，保证结果稳定）
public func pickBestPerGroup(_ scores: [ImageScore], groups: [BurstGroup]) -> [BurstGroup] {
    groups.map { g in
        var out = g
        var bestIdx = g.indices.first ?? 0
        var bestScore = -Double.infinity
        for i in g.indices where i < scores.count {
            if scores[i].total > bestScore { bestScore = scores[i].total; bestIdx = i }
        }
        out.best = bestIdx
        let sm = bestIdx < scores.count ? scores[bestIdx] : nil
        out.reason = "同组 \(g.indices.count) 张，选 \(sm?.file ?? "?")（\(String(format: "%.1f", bestScore))）"
        return out
    }
}


/// 出片建议：姿态 + 表情 + 眼睛 一起给一句人话，直接用在挑图/连拍的结论里。
public func shootingAdvice(pose: String, smile: Double, closedEyes: Int, judgedFaces: Int,
                           faceQuality: Double) -> String {
    var parts: [String] = []
    switch pose {
    case "正面": parts.append("正面——适合主视觉/证件/合影")
    case "3/4 侧脸": parts.append("3/4 侧脸——适合主视觉，脸型更立体")
    case "侧脸": parts.append("侧脸——适合氛围片/纪实，不适合当封面")
    case "背身/扭头过度": parts.append("背身/扭头过度——不建议出片")
    default: parts.append("无脸——按风光/静物处理")
    }
    if closedEyes > 0 {
        parts.append("有 \(closedEyes)/\(judgedFaces) 张脸闭眼，先看有没有同组的睁眼版本")
    } else if judgedFaces > 0 {
        parts.append("无人闭眼")
    }
    if smile > 0.4 { parts.append("笑容明显（张嘴）") }
    else if smile > 0.22 { parts.append("微笑") }
    if faceQuality > 0 && faceQuality < 0.25 { parts.append("人脸质量低（可能失焦/动态模糊）") }
    return parts.joined(separator: "；")
}

/// 连拍组结论：选哪张 + 为什么选它 + 为什么不选别的
public func burstDecision(_ scores: [ImageScore], group: BurstGroup) -> String {
    guard group.best < scores.count else { return "该组没有可用分数" }
    let best = scores[group.best]
    var out = "选 \(best.file)（总分 \(String(format: "%.1f", best.total))）"
    out += "\n      为什么：" + shootingAdvice(pose: poseGrade(yawDeg: best.headYaw, faces: best.faces),
                                             smile: best.smile, closedEyes: best.closedEyes,
                                             judgedFaces: best.judgedFaces, faceQuality: best.faceQuality)
    let others = group.indices.filter { $0 != group.best && $0 < scores.count }
    if !others.isEmpty {
        var reasons: [String] = []
        for i in others {
            let s = scores[i]
            var why: [String] = []
            if s.total < best.total { why.append(String(format: "总分低 %.1f", best.total - s.total)) }
            if s.closedEyes > 0 { why.append("有闭眼") }
            if abs(s.headYaw) > abs(best.headYaw) + 10 { why.append("扭头更多") }
            if s.smile < best.smile - 0.15 { why.append("笑容更弱") }
            if s.sharpness < best.sharpness * 0.7 { why.append("更不实") }
            if why.isEmpty { why.append("与选中张接近，作为备选") }
            reasons.append(s.file + "：" + why.joined(separator: "、"))
        }
        out += "\n      没选的：" + reasons.joined(separator: "；")
    }
    return out
}
