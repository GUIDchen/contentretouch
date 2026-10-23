// FaceParsing：Core ML 人脸解析（真正的语义分区，替掉「肤色阈值」的猜）
//
// 模型：app-retouch/Models/FaceParsing.mlmodel（第三方，MIT，见该目录 README）
//   输入 512×512 图像 → 输出 512×512 的每像素类别（CelebAMask-HQ 顺序）
//   实测：编译 0.2 s、推理 21 ms
// 类别：0 背景 1 皮肤 2/3 眉 4/5 眼 6 眼镜 7/8 耳 9 耳饰 10 鼻 11 嘴内 12/13 唇 14 脖子 15 颈饰 16 衣服 17 头发 18 帽子
//
// 设计上的取舍：**没有模型也要能跑**。所有调用方都拿 Optional——
// 拿不到解析结果就退回肤色阈值（Skin.swift 那套）。命令行/精简分发不会因为缺模型而崩。
import Foundation
import CoreML
import Vision
import CoreImage

public enum FaceClass {
    public static let background = 0, skin = 1, lBrow = 2, rBrow = 3, lEye = 4, rEye = 5
    public static let nose = 10, mouth = 11, uLip = 12, lLip = 13, neck = 14, cloth = 16, hair = 17
    public static let skinClasses: Set<Int> = [skin, neck]
    public static let lipClasses: Set<Int> = [uLip, lLip]
    public static let mouthClasses: Set<Int> = [mouth]        // 口腔（牙齿所在）
    public static let eyeClasses: Set<Int> = [lEye, rEye]
    public static let browClasses: Set<Int> = [lBrow, rBrow]
    public static let noseClasses: Set<Int> = [nose]      // §237：10 号「鼻」一直有输出但没被用过
    public static let earClasses: Set<Int> = [7, 8]        // 7/8 耳（CelebAMask-HQ 顺序）
    public static let hairClasses: Set<Int> = [hair]
    public static let clothClasses: Set<Int> = [cloth]
}

public struct FaceParseResult {
    public var labels: [UInt8]      // 512×512，行序从上到下
    public var size: Int            // 512
    public var parseMillis: Double
}

/// 解析器：模型只加载一次（编译产物缓存到 Application Support，避免每次启动都编译）
public final class FaceParser {
    public static let shared = FaceParser()
    private var model: VNCoreMLModel?
    private var loadTried = false
    private let lock = NSLock()

    /// 模型搜索顺序：环境变量 → **注册表启用项** → .app 的 Resources/Models → 可执行文件同级/上一级 → 源码树
    /// §394：注册表那一层让用户能换用第三方解析模型（用户需求：可选择模型 ✓）；
    /// 它是**目录**，里面可能是 .mlmodel / .mlpackage / .mlmodelc 任一种 ⇒ 在此按后缀找第一个 ✓。
    public static func modelURL() -> URL? {
        var cands: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CONTENTRETOUCH_MODEL_DIR"], !env.isEmpty {
            cands.append(URL(fileURLWithPath: env).appendingPathComponent("FaceParsing.mlmodel"))
        }
        if let dir = ModelRegistry.activeDir(slot: "faceparse"),
           let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let exts = ["mlmodel", "mlpackage", "mlmodelc"]
            var found: [URL] = []
            for u in items where exts.contains(u.pathExtension.lowercased()) { found.append(u) }
            // 也要看一层子目录（例如 <id>/FaceParsing.mlpackage ✓）
            if found.isEmpty {
                for sub in items {
                    guard let inner = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else { continue }
                    for u in inner where exts.contains(u.pathExtension.lowercased()) { found.append(u) }
                }
            }
            for u in found { cands.append(u) }
        }
        if let res = Bundle.main.resourceURL {
            cands.append(res.appendingPathComponent("Models/FaceParsing.mlmodel"))
            cands.append(res.appendingPathComponent("FaceParsing.mlmodel"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        cands.append(exe.appendingPathComponent("Models/FaceParsing.mlmodel"))
        cands.append(exe.deletingLastPathComponent().appendingPathComponent("Models/FaceParsing.mlmodel"))
        cands.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("app-retouch/Models/FaceParsing.mlmodel"))
        cands.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Models/FaceParsing.mlmodel"))
        return cands.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    public var isAvailable: Bool { load() != nil }

    private func load() -> VNCoreMLModel? {
        lock.lock(); defer { lock.unlock() }
        if let m = model { return m }
        if loadTried { return nil }
        loadTried = true
        guard let url = FaceParser.modelURL() else { return nil }
        do {
            // 编译产物放到 Application Support 缓存，第二次启动省掉编译时间
            let cacheDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("ContentRetouch/Models", isDirectory: true)
            var compiledURL: URL? = nil
            if let cd = cacheDir {
                try? FileManager.default.createDirectory(at: cd, withIntermediateDirectories: true)
                let c = cd.appendingPathComponent("FaceParsing.mlmodelc")
                if FileManager.default.fileExists(atPath: c.path) { compiledURL = c }
            }
            if compiledURL == nil {
                let c = try MLModel.compileModel(at: url)
                if let cd = cacheDir {
                    let dst = cd.appendingPathComponent("FaceParsing.mlmodelc")
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.copyItem(at: c, to: dst)
                    compiledURL = FileManager.default.fileExists(atPath: dst.path) ? dst : c
                } else {
                    compiledURL = c
                }
            }
            guard let cu = compiledURL else { return nil }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            let ml = try MLModel(contentsOf: cu, configuration: cfg)
            model = try VNCoreMLModel(for: ml)
            return model
        } catch {
            return nil
        }
    }

    /// 解析一张图（会按模型的输入要求缩放/裁切，Vision 负责这部分）
    public func parse(_ cg: CGImage) -> FaceParseResult? {
        guard let m = load() else { return nil }
        let req = VNCoreMLRequest(model: m)
        req.imageCropAndScaleOption = .centerCrop      // 模型要 512×512 正方形
        let t0 = Date()
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil,
              let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
              let arr = obs.featureValue.multiArrayValue else { return nil }
        let shape = arr.shape.map { $0.intValue }
        let size = shape.count >= 2 ? shape[shape.count - 1] : 512
        var labels = [UInt8](repeating: 0, count: arr.count)
        for i in 0..<arr.count {
            labels[i] = UInt8(max(0, min(255, Int(arr[i].floatValue.rounded()))))
        }
        return FaceParseResult(labels: labels, size: size, parseMillis: Date().timeIntervalSince(t0) * 1000)
    }
}

/// 用类别图做掩膜：classes 里的类别为 1，其余为 0；再放大到 extent 尺寸并羽化。
/// 注意 centerCrop：模型看到的是原图**中心的正方形**，映射回去时要按这个比例算。
///
/// guide 是**边缘引导**（传原图）。掩膜来自 512² 的解析图，直接放大到全分辨率时边缘会是一条
/// 糊掉的斜坡——脸与头发/背景的交界处尤其明显（用户说的「范围不够精准」，一部分就是这个，
/// 不只是模型分辨率的问题）。给了引导就走 Core Image 的 CIEdgePreserveUpsample：
/// 用高分辨率原图的亮度做**边缘保持**放大，掩膜边界会贴着真实轮廓收住，而不是糊出去一圈。
public func maskFromLabels(_ r: FaceParseResult, classes: Set<Int>, extent: CGRect,
                           feather: Double = 3) -> CIImage {
    let n = r.size
    // 中心正方形在原图中的区域
    let side = min(extent.width, extent.height)
    let crop = CGRect(x: extent.midX - side / 2, y: extent.midY - side / 2, width: side, height: side)
    var bytes = [UInt8](repeating: 0, count: n * n)
    for y in 0..<n {
        for x in 0..<n {
            let c = Int(r.labels[y * n + x])
            bytes[y * n + x] = classes.contains(c) ? 255 : 0
        }
    }
    // ⚠️ 不能写 CGContext(data: &bytes, ...)：那是把 Swift 数组的临时指针交给一个会长期持有的对象，
    // 初始化返回后指针就悬空了（实测：掩膜全 0，一点效果都没有）。用 CGDataProvider 让 Data 持有内存。
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                           space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return blackMask(extent) }
    // 位图行 0 是图顶，而 CI 的 y 向上：直接放大再按 crop 放好，方向由 CGImage→CIImage 的约定决定
    let scale = side / CGFloat(n)
    var m = CIImage(cgImage: cg)
    // ⚠️ 羽化要在**放大之前**做：早先是在 32MP 的原图尺寸上做高斯，实测那一张 32MP 的图
    // 光这一条掩膜链就要 2.4s（衣物美化 2391ms）。掩膜本身是低频的，512² 上羽化再放大观感一样。
    if feather > 0.5 {
        m = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather / Double(scale)])
    }
    // ⚠️ 这里试过「边缘保持放大」，**结论是放弃**，记下来免得以后再走一遍：
    //   · CIEdgePreserveUpsampleFilter：名字写错一个后缀就静默退回普通放大（被 coretest 抓到），
    //     名字改对之后**直接把进程 abort**；
    //   · CIGuidedFilter：extent 对齐、原点归零之后**仍然 abort**（coretest 第 15 段当场崩在它上面）。
    // 一个参数/格式不合就终止进程的滤镜，不该留在产品代码里——所以退回普通放大。
    // 掩膜精度真正落下来的改进在别处：椭圆脸蒙版、按脸解析上限 3→6、手部凸包轮廓。
    // 剩下的天花板是解析模型固定 512² 输入（本机没有更高分辨率的模型可换）。
    m = m.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    m = m.transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY))
        .cropped(to: extent)
    // 补满整幅：cropped(to:) 只能求交不能扩展，蒙版只覆盖中心正方形的话，
    // 上下两条带子会「没有蒙版」——虽然结果也是 0（安全），但语义上应该是一张完整的图。
    return m.composited(over: blackMask(extent)).cropped(to: extent)
}

/// 整幅解析取任意类别的掩膜。适合**大面积**类别（衣服/头发/皮肤），
/// 小面积五官别用这个（整幅缩到 512 之后五官只剩几个像素），要走 parsedMaskForFace。
public func parsedMaskFromImage(_ src: CIImage, classes: Set<Int>, feather: Double = 6) -> CIImage? {
    guard let cg = sharedCtx.createCGImage(src, from: src.extent) else { return nil }
    // 同一张图在一条管线里会被解析好几次（衣物检查、皮肤掩膜…）——模型推理 135ms 一次，必须缓存
    guard let r = VisionCache.shared.parse(src, { FaceParser.shared.parse(cg) }) else { return nil }
    return maskFromLabels(r, classes: classes, extent: src.extent, feather: feather)
}

/// 皮肤掩膜（整幅解析）：解析不可用时返回 nil。
/// ⚠️ 整幅解析对**小脸**几乎没用：512 的解析图上，整幅画面里 88px 的脸只剩 75px，
/// 类别图放大回来基本是空的（实测婚礼小脸的脸颊覆盖 0.00，磨皮等于没做）。
/// 所以正常路径应该走 parsedSkinMaskForFace（按人脸框裁出来再解析）。
public func parsedSkinMask(_ src: CIImage, feather: Double = 3) -> CIImage? {
    guard let cg = sharedCtx.createCGImage(src, from: src.extent),
          let r = FaceParser.shared.parse(cg) else { return nil }
    return maskFromLabels(r, classes: FaceClass.skinClasses, extent: src.extent, feather: feather)
}

/// 按人脸框裁出来解析，取任意类别集合的掩膜（推荐路径）。
/// margin 是脸框外的留白比例——要留一点，因为解析要看到额头/下巴/脖子才能判准。
public func parsedMaskForFace(_ src: CIImage, face: FaceGeo, classes: Set<Int>, feather: Double = 3,
                              margin: Double = 0.35) -> CIImage? {
    let e = src.extent
    let side = max(face.box.width, face.box.height) * (1 + margin * 2)
    guard side > 24 else { return nil }
    let crop = CGRect(x: face.box.midX - side / 2, y: face.box.midY - side / 2, width: side, height: side)
        .intersection(e)
    guard crop.width > 24, crop.height > 24 else { return nil }
    let cropped = src.cropped(to: crop)
    guard let cg = sharedCtx.createCGImage(cropped, from: cropped.extent) else { return nil }
    // 按脸裁切的解析要单独缓存：每次裁出来都是新图，整图那层缓存打不中（见 Cache.swift 的说明）
    guard let r = VisionCache.shared.parseFace(src, box: crop, { FaceParser.shared.parse(cg) }) else { return nil }
    return maskFromLabels(r, classes: classes, extent: crop.integral, feather: feather)
        .composited(over: blackMask(e)).cropped(to: e)
}

/// 皮肤掩膜（按脸解析）
public func parsedSkinMaskForFace(_ src: CIImage, face: FaceGeo, feather: Double = 3,
                                  margin: Double = 0.35) -> CIImage? {
    parsedMaskForFace(src, face: face, classes: FaceClass.skinClasses, feather: feather, margin: margin)
}

/// 「解析优先、关键点多边形兜底」：牙齿 / 唇 / 眼 三项都走这里。
/// 关键点多边形是「按嘴型/眼型圈一块」，解析是「按语义分出来」，后者不会把嘴唇当牙齿、把眼睑当眼白。
public func bestFeatureMask(_ src: CIImage, face: FaceGeo, classes: Set<Int>,
                            fallback: () -> CIImage) -> CIImage {
    if parsingWorthwhile(face),
       // 羽化给小一点：解析出来的边界本身就是语义边界（嘴唇就是嘴唇），
       // 而多边形是「圈个大概」才需要大羽化去糊边界。实测羽化 0.012*脸宽（490px 脸 = 5.9px）时，
       // 牙齿美白的峰值从 0.030 掉到 0.022（区域被羽化吃掉一半）。
       let m = parsedMaskForFace(src, face: face, classes: classes, feather: max(0.8, face.box.width * 0.004)) {
        // ⚠️ **§217 试过并撤回的"退化守卫"**：曾在这里加"解析掩膜覆盖率 <25% 就退回兜底"
        // （阈值来自 §216 的跨多脸实测：正常 51%~100%、退化 0%），代码是对的，但**量不到收益**：
        // 婚礼 RAW 上牙齿仍然 0 级 —— 因为拦路虎在**上游**：那张照片的牙齿/眼睛关键点包围盒
        // 退化成 13x1 / 76x3，走兜底也只覆盖 ~11 px，效果自然还是 0。
        // 按本项目规矩（没量到收益的复杂度不留）撤回；真正要修的是**关键点尺寸守卫 + 从脸框估区**
        // （§189 在眼下带上的那套），记在 §217。
        let fb = fallback()
        // ⚠️ 覆盖率必须量在**特征自己的包围盒**里，不是脸框里：
        // 嘴/眼只占脸框的几个百分点，拿脸框当分母时连合法掩膜都到不了 25%（第一版就是这么错的，
        // 结果守卫等于没加）。用兜底掩膜的亮区包围盒当分母，才是 §216 那批数据（100% vs 0%）的口径。
        _ = fb
        return m
    }
    return fallback()
}

/// 掩膜在给定矩形内的覆盖率，**在缩略尺度上算**（长边 160px）：
/// 判断"这块掩膜是不是空的"不需要全分辨率，而全分辨率渲一次掩膜在 24MP 上是几十毫秒 ——
/// 守卫本身不能成为新的性能问题。阈值 0.02 与逐项体检/诊断探针用的口径一致。
public func maskCoverageSmall(_ m: CIImage, in rect: CGRect) -> Double {
    let r = rect.intersection(m.extent)
    guard r.width > 2, r.height > 2 else { return 0 }
    let w = 160
    let k = CGFloat(w) / r.width
    let h = max(1, Int((r.height * k).rounded()))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let small = m.transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        .transformed(by: CGAffineTransform(scaleX: k, y: k))
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var hit = 0
    for i in stride(from: 0, to: w * h, by: 1) where Double(buf[i * 4]) / 255 > 0.02 { hit += 1 }
    return Double(hit) / Double(max(1, w * h))
}

/// 每张图最多给几张脸跑「语义解析」。多脸时这个是尾延迟的来源：
/// 实测 7 张脸的人像步骤要 962ms（约 137ms/脸），4+ 张脸的组 p95 是 1063ms。
/// 组照里挑片/修图实际关注的是主要人物，小脸用肤色阈值够用，且解析在那种尺寸上也判不准。
/// 从 3 提到 6：3 张的设定在**合影**上是明显不够用的——第 4 张脸往后会退回肤色阈值，
/// 表现就是「合影里边缘那几个人磨得毛毛的、边缘糊在头发上」。提到 6 之后（每张多约 137ms，
/// 且按脸缓存，调滑杆不会重复推理），4~6 人的合影能全部走语义解析。
/// 再往上不提了：更小的脸在 512 的解析图里本来就没几个像素，跑模型也判不准。
public var maxParsedFacesPerImage = 6

/// 按脸取「解析优先、肤色兜底」的皮肤掩膜（ApplySkin / 祛瑕疵 都走这里）
/// 磨皮用的皮肤掩膜（**所有磨皮路径的咽喉点**：解析优先、肤色兜底）。
///
/// ⚠️ 这里统一**扣掉眼睛**。理由（coretest 第 38 段多图实测）：
///   · 解析掩膜在眼睛中心仍高达 0.80~0.87，"眼睛被磨糊"是真实存在的；
///   · 调用方各自扣必然漏 —— 我第一版只改了 skinMaskForFace，而解析路径**根本不经过它**，
///     于是磨皮在眼睛内的改动几乎没变（2.18~14.42 级）。
/// 放在这个咽喉点上，解析/兜底两条路、所有调用方一次覆盖。
public func bestSkinMask(_ src: CIImage, face: FaceGeo, feather: Double = 3, rank: Int = 0) -> CIImage {
    if rank < maxParsedFacesPerImage, parsingWorthwhile(face),
       let m = parsedSkinMaskForFace(src, face: face, feather: feather) {
        return excludingEyes(m, face: face, extent: src.extent)
    }
    return excludingEyes(skinMaskForFace(src, face: face, feather: feather), face: face, extent: src.extent)
}
/// 给一系列脸按面积排名（大的在前）
public func rankFacesByArea(_ geos: [FaceGeo]) -> [FaceGeo] {
    geos.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
}

/// 人脸区域是否足够大（太小的话 512 的解析图放大回来没有意义）
public func parsingWorthwhile(_ face: FaceGeo) -> Bool {
    face.box.width >= 48 && face.box.height >= 48
}
