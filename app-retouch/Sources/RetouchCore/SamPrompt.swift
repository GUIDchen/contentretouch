// SAM：用 MobileSAM 做「点提示」的精细主体分割
//
// 模型：MobileSAM（Apache-2.0，19 MB）—— encoder 出图像嵌入，decoder 吃「点提示」出掩膜。
// 为什么值得引：系统的前景实例掩膜是「大致圈住」，边缘（头发丝、半透明纱）不够准；
// SAM 是「点一下任意位置，给出那一个物体的像素级掩膜」，抠图/虚化的边缘质量是另一个档位。
//
// 提示编码那部分（positional encoding）按官方 SAM 的公式在 Swift 里实现，权重来自
// mobile_sam_prompt_encoder_weights.json（gaussian_matrix [2,128] / point_embeddings [4,256] / no_mask_embed [256]）。
import Foundation
import CoreML
import CoreImage
import Vision

public struct SamPoint { public var x: Double; public var y: Double; public var foreground: Bool
    public init(x: Double, y: Double, foreground: Bool = true) { self.x = x; self.y = y; self.foreground = foreground }
}

public final class SamSegmenter {
    public static let shared = SamSegmenter()
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var gaussian: [[Double]] = []
    private var pointEmbeddings: [[Double]] = []
    private var noMaskEmbed: [Double] = []
    private var embedDim = 256
    private var embedSize = 64
    private var inputSize = 1024
    private var loadTried = false
    private let lock = NSLock()

    public static var debug = false

    public struct Result {
        public var mask: CIImage        // 原图坐标系
        public var score: Double
        public var encoderMillis: Double
        public var decoderMillis: Double
    }

    /// 装好/删掉模型后要重置，否则 loadTried 会把结果钉死
    public func reset() {
        lock.lock(); encoder = nil; decoder = nil; loadTried = false; lock.unlock()
    }

    public static func modelDir() -> URL? {
        var cands: [URL] = []
        // 可选下载装到这里（优先于源码树，便于「装了就用」）
        cands.append(SamStore.installDir)
        if let env = ProcessInfo.processInfo.environment["CONTENTRETOUCH_MODEL_DIR"], !env.isEmpty {
            cands.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            cands.append(res.appendingPathComponent("Models/SAM"))
            cands.append(res.appendingPathComponent("Models"))
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        cands.append(exe.appendingPathComponent("Models/SAM"))
        cands.append(exe.deletingLastPathComponent().appendingPathComponent("Models/SAM"))
        cands.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("app-retouch/Models/SAM"))
        cands.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Models/SAM"))
        for c in cands where FileManager.default.fileExists(atPath: c.appendingPathComponent("mobile_sam_encoder.mlpackage").path) {
            return c
        }
        return nil
    }

    /// ⚠️ 这里原来写的是 `load() != nil` —— 而 `load()` 返回的是**非可选 Bool**，
    /// 于是 `!= nil` 恒为真：**isAvailable 永远返回 true**（编译器警告 "comparing non-optional value
    /// of type 'Bool' to 'nil' always returns true" 指的就是它）。
    /// 后果：没装 SAM 的机器上（比如刚装好的用户），代码会照常往 SAM 路径上走、界面也会说"可用"。
    /// 2026-09-26 修正（顺带让 coretest 那条"SAM 模型可用"不再是永远通过）。
    public var isAvailable: Bool { load() }

    private func load() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if encoder != nil && decoder != nil { return true }
        if loadTried { return false }
        loadTried = true
        guard let dir = SamSegmenter.modelDir() else { return false }
        do {
            let cfg = MLModelConfiguration(); cfg.computeUnits = .all
            func compiled(_ name: String) throws -> URL {
                let pkg = dir.appendingPathComponent(name + ".mlpackage")
                let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("ContentRetouch/Models", isDirectory: true)
                if let c = cache {
                    try? FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
                    let dst = c.appendingPathComponent(name + ".mlmodelc")
                    if FileManager.default.fileExists(atPath: dst.path) { return dst }
                    let c2 = try MLModel.compileModel(at: pkg)
                    try? FileManager.default.removeItem(at: dst)
                    if (try? FileManager.default.copyItem(at: c2, to: dst)) != nil { return dst }
                    return c2
                }
                return try MLModel.compileModel(at: pkg)
            }
            encoder = try MLModel(contentsOf: try compiled("mobile_sam_encoder"), configuration: cfg)
            decoder = try MLModel(contentsOf: try compiled("mobile_sam_decoder"), configuration: cfg)
            // 提示编码器权重
            let j = dir.appendingPathComponent("mobile_sam_prompt_encoder_weights.json")
            let data = try Data(contentsOf: j)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            func doubles(_ key: String, _ rows: Int? = nil) -> [[Double]] {
                guard let a = obj[key] as? [Any] else { return [] }
                if let rows = rows, let nested = a as? [[Any]] {
                    _ = rows
                    return nested.map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
                }
                if let nested = a as? [[Any]] {
                    return nested.map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
                }
                return [a.compactMap { ($0 as? NSNumber)?.doubleValue }]
            }
            gaussian = doubles("gaussian_matrix")
            pointEmbeddings = doubles("point_embeddings")
            noMaskEmbed = doubles("no_mask_embed").first ?? []
            embedDim = (obj["embed_dim"] as? NSNumber)?.intValue ?? 256
            if let s = obj["image_embedding_size"] as? [Any], s.count == 2 {
                embedSize = (s[0] as? NSNumber)?.intValue ?? 64
            }
            if let s = obj["input_image_size"] as? [Any], s.count == 2 {
                inputSize = (s[0] as? NSNumber)?.intValue ?? 1024
            }
            return !gaussian.isEmpty && !pointEmbeddings.isEmpty && !noMaskEmbed.isEmpty
        } catch {
            encoder = nil; decoder = nil
            return false
        }
    }

    /// 图像预处理：长边缩到 1024、右下补零、ImageNet 归一化、CHW 排布
    private func makeInput(_ src: CIImage) -> (MLMultiArray, CGRect, Double)? {
        let e = src.extent
        let scale = Double(inputSize) / Double(max(e.width, e.height))
        let w = Int((Double(e.width) * scale).rounded()), h = Int((Double(e.height) * scale).rounded())
        let resized = src.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(resized, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        guard let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)],
                                         dataType: .float32) else { return nil }
        let mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225]
        let n = inputSize * inputSize
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * n)
        for i in 0..<(3 * n) { ptr[i] = 0 }
        for y in 0..<h {
            for x in 0..<w {
                let si = (y * w + x) * 4
                for c in 0..<3 {
                    let v = Double(buf[si + c]) / 255.0
                    ptr[c * n + y * inputSize + x] = Float((v - mean[c]) / std[c])
                }
            }
        }
        // 注意：位图行 0 是顶行，而 SAM 的坐标原点在左上，这里保持一致（不做翻转）
        return (arr, CGRect(x: 0, y: 0, width: w, height: h), scale)
    }

    /// 单个提示点的 sparse embedding（官方 prompt encoder 的公式）
    private func sparseEmbedding(_ p: SamPoint, scale: Double, offset: CGPoint) -> MLMultiArray? {
        guard let arr = try? MLMultiArray(shape: [1, 1, NSNumber(value: embedDim)], dataType: .float32) else { return nil }
        // 点坐标：先按缩放后的像素位置，再归一化到 [0,1]
        let px = (p.x - Double(offset.x)) * scale
        let py = (p.y - Double(offset.y)) * scale
        let nx = px / Double(inputSize), ny = py / Double(inputSize)
        let cx = 2 * nx - 1, cy = 2 * ny - 1
        // pos = gaussian_matrix^T @ [cx, cy] → [128]，再 sin/cos 拼成 256
        var pos = [Double](repeating: 0, count: gaussian.first?.count ?? 128)
        for i in 0..<pos.count {
            pos[i] = gaussian[0][i] * cx + gaussian[1][i] * cy
        }
        var emb = [Double](repeating: 0, count: embedDim)
        let half = embedDim / 2
        for i in 0..<half {
            emb[i] = sin(2 * Double.pi * pos[i])
            emb[i + half] = cos(2 * Double.pi * pos[i])
        }
        let label = p.foreground ? 1 : 0
        let pe = pointEmbeddings[label]
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: embedDim)
        for i in 0..<embedDim { ptr[i] = Float(emb[i] + (i < pe.count ? pe[i] : 0)) }
        return arr
    }

    public enum PickMode { case highestIoU, largest }

    /// 在 src 上以 point（原图像素坐标，原点左下）为提示，分割出该点的物体
    public func segment(_ src: CIImage, point: SamPoint, pick: PickMode = .largest) -> Result? {
        guard load(), let enc = encoder, let dec = decoder else { return nil }
        guard let (input, contentRect, scale) = makeInput(src) else { return nil }
        let t0 = Date()
        guard let embOut = try? enc.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let emb = embOut.featureValue(for: "image_embeddings")?.multiArrayValue else { return nil }
        let t1 = Date()
        // 提示点：我们的坐标系原点在左下，SAM 在左上 → y 要翻
        let flipped = SamPoint(x: point.x, y: Double(src.extent.height) - point.y, foreground: point.foreground)
        guard let sparse = sparseEmbedding(flipped, scale: scale, offset: .zero) else { return nil }
        guard let dense = try? MLMultiArray(shape: [1, NSNumber(value: embedDim), NSNumber(value: embedSize), NSNumber(value: embedSize)],
                                           dataType: .float32) else { return nil }
        let dptr = dense.dataPointer.bindMemory(to: Float.self, capacity: embedDim * embedSize * embedSize)
        for c in 0..<embedDim {
            let v = Float(c < noMaskEmbed.count ? noMaskEmbed[c] : 0)
            for i in 0..<(embedSize * embedSize) { dptr[c * embedSize * embedSize + i] = v }
        }
        guard let out = try? dec.prediction(from: try MLDictionaryFeatureProvider(dictionary: [
            "image_embeddings": emb, "sparse_embeddings": sparse, "dense_embeddings": dense])),
              let masks = out.featureValue(for: "masks")?.multiArrayValue,
              let iou = out.featureValue(for: "iou_predictions")?.multiArrayValue else { return nil }
        let t2 = Date()
        // masks: [1,3,256,256] —— SAM 一次给 3 个候选（整体 / 部分 / 子部分）+ IoU 预测
        let side = masks.shape[2].intValue
        let n = side * side
        let mptr = masks.dataPointer.bindMemory(to: Float.self, capacity: masks.count)
        var areas = [Int](repeating: 0, count: 3)
        for k in 0..<3 { for i in 0..<n where mptr[k * n + i] > 0 { areas[k] += 1 } }
        if Self.debug {
            for k in 0..<3 {
                print(String(format: "    [SAM] 候选 %d：正例 %d/%d（%.2f%%）iou %.3f",
                             k, areas[k], n, Double(areas[k]) / Double(n) * 100, iou[k].doubleValue))
            }
        }
        // 实测：提示点打在脸上时，「IoU 最高」的候选只覆盖 0.6%（就是那张脸），
        // 而另一个候选覆盖 15%（整个人）。做主体掩膜要「大而完整」，所以默认按面积挑。
        var best = 0
        var bestScore = -Double.infinity
        switch pick {
        case .highestIoU:
            for k in 0..<3 {
                let v = iou[k].doubleValue
                if v > bestScore { bestScore = v; best = k }
            }
        case .largest:
            for k in 0..<3 where areas[k] > areas[best] { best = k }
            bestScore = iou[best].doubleValue
        }
        var bytes = [UInt8](repeating: 0, count: n)
        var positives = 0
        var lo = Float.infinity, hi = -Float.infinity
        for i in 0..<n {
            let v = mptr[best * n + i]
            lo = min(lo, v); hi = max(hi, v)
            if v > 0 { bytes[i] = 255; positives += 1 }
        }
        if Self.debug {
            print(String(format: "    [SAM] 选中 %d，值域 %.3f~%.3f，正例 %d/%d",
                         best, lo, hi, positives, n))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        // 256x256 掩膜对应「缩放 + 补零」后的 1024x1024 → 先裁掉补零区，再放大回原图尺寸
        let rect = CGRect(x: 0, y: 0, width: contentRect.width / Double(inputSize) * Double(side),
                          height: contentRect.height / Double(inputSize) * Double(side))
        let cropTop = CGRect(x: rect.minX, y: Double(side) - rect.maxY, width: rect.width, height: rect.height)
        var m = CIImage(cgImage: cg).cropped(to: cropTop)
        if Self.debug {
            print(String(format: "    [SAM] contentRect %.0fx%.0f scale %.3f cropTop %.0f,%.0f %.0fx%.0f",
                         contentRect.width, contentRect.height, scale,
                         cropTop.minX, cropTop.minY, cropTop.width, cropTop.height))
        }
        let sx = src.extent.width / cropTop.width, sy = src.extent.height / cropTop.height
        m = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        // CGImage 的行 0 就是「上」，转成 CIImage 后上依然在上，**不需要再翻**
        // （之前多写了一次 translate+scale(y:-1)，把图挪到 y 负区，结果 extent 变成空）
        m = m.transformed(by: CGAffineTransform(translationX: src.extent.minX, y: src.extent.minY)).cropped(to: src.extent)
        return Result(mask: m, score: bestScore, encoderMillis: t1.timeIntervalSince(t0) * 1000,
                      decoderMillis: t2.timeIntervalSince(t1) * 1000)
    }
}


/// 用 SAM refine 一张「大致的前景掩膜」成像素级掩膜。
///
/// 分工：系统 API（VNGenerateForegroundInstanceMaskRequest）负责**知道主体在哪**，
/// SAM 负责**把边界画准**。直接拿一个点去猜主体在哪是不可靠的 ——
/// 实测婚礼合影里「脸下方 1.2 个脸高」那个点落到了新郎身上，分出来的是他而不是新娘。
public func refineMaskWithSAM(_ src: CIImage, hint: CIImage) -> SamSegmenter.Result? {
    guard SamSegmenter.shared.isAvailable else { return nil }
    let e = src.extent
    // 提示点取 hint 的亮区重心（hint 太稀就放弃，别乱点）
    let box = bboxOfBright(hint, in: e, threshold: 128)
    guard !box.isNull, box.width > 8, box.height > 8 else { return nil }
    let cx = Double(box.midX), cy = Double(box.midY)
    guard let r = SamSegmenter.shared.segment(src, point: SamPoint(x: cx, y: cy), pick: .largest) else { return nil }
    // 合理区间检查：太小说明分到了局部（比如一只手），太大说明把背景也吞了
    let cov = maskCoverage(r.mask, in: e, threshold: 128)
    guard cov > 0.03 && cov < 0.92 else { return nil }
    return r
}

/// 「精细前景掩膜」：SAM 可用就用**多提示点**版本（合影里每个人都盖到），
/// 否则退回单提示，再不行退回系统掩膜。
public func foregroundMaskRefined(_ src: CIImage) -> (mask: CIImage, source: String) {
    guard SamSegmenter.shared.isAvailable else {
        guard let sys = foregroundMask(src) ?? personMask(src) else { return (blackMask(src.extent), "无") }
        return (sys, "系统前景实例掩膜（无 SAM）")
    }
    let multi = refineMaskMultiPrompt(src)
    if !multi.source.hasPrefix("系统") { return (multi.mask, multi.source) }
    if let sys = foregroundMask(src) ?? personMask(src), let r = refineMaskWithSAM(src, hint: sys) {
        return (r.mask, String(format: "SAM 单提示（IoU %.2f）", r.score))
    }
    return (multi.mask, multi.source)
}


/// 多提示点精修：合影里每个人都用一个提示点，分别分割后取并集。
///
/// 为什么需要：单点只分割「那一个点所在的物体」。实测婚礼合影里，用系统掩膜整体的重心去提示，
/// 分出来的是站在中间的那个人，旁边那位不在掩膜里 —— 做背景虚化时他会被虚掉。
public func refineMaskMultiPrompt(_ src: CIImage) -> (mask: CIImage, source: String) {
    let e = src.extent
    guard SamSegmenter.shared.isAvailable,
          let cg = sharedCtx.createCGImage(src, from: e) else {
        return (foregroundMask(src) ?? personMask(src) ?? blackMask(e), "无 SAM")
    }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let req = VNGenerateForegroundInstanceMaskRequest()
    guard #available(macOS 14.0, *), (try? handler.perform([req])) != nil,
          let obs = req.results?.first else {
        return (foregroundMask(src) ?? personMask(src) ?? blackMask(e), "系统掩膜（无法取实例）")
    }
    let instances = obs.allInstances.sorted()
    guard !instances.isEmpty else { return (blackMask(e), "没有实例") }

    // ⚠️ 合并掩膜必须用「取大」而不是 composited(over:)：这些掩膜的 alpha 都是 1，
    // 在同一个 extent 上叠加是**替换**不是并集 —— 实测多提示只留下了最后一个人的掩膜
    //（新娘在、新郎没了）。CILightenBlendMode 就是逐像素取 max。
    func merge(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: e)
    }
    var union = blackMask(e)
    var used = 0
    var scores: [Double] = []
    for idx in instances {
        // 每个实例的掩膜 → 取重心当 SAM 的提示点
        guard let pb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: idx), from: handler) else { continue }
        let pw = CGFloat(CVPixelBufferGetWidth(pb)), ph = CGFloat(CVPixelBufferGetHeight(pb))
        let inst = CIImage(cvPixelBuffer: pb)
            .transformed(by: CGAffineTransform(scaleX: e.width / pw, y: e.height / ph))
            .cropped(to: e)
        let box = bboxOfBright(inst, in: e, threshold: 128)
        guard !box.isNull, box.width > 8, box.height > 8 else { continue }
        let pt = SamPoint(x: Double(box.midX), y: Double(box.midY))
        guard let r = SamSegmenter.shared.segment(src, point: pt, pick: .largest) else {
            union = merge(inst, union)               // SAM 失败就退回该实例的系统掩膜
            used += 1
            continue
        }
        // 合理性闸门用「该实例自身的面积」当参照：SAM 结果不该比实例小太多、也不该吞掉整幅
        let instArea = maskCoverage(inst, in: e, threshold: 128)
        let samArea = maskCoverage(r.mask, in: e, threshold: 128)
        if samArea > 0.02 && samArea < 0.92 && samArea > instArea * 0.5 {
            union = merge(r.mask, union)
            scores.append(r.score)
        } else {
            union = merge(inst, union)
        }
        used += 1
    }
    guard used > 0, maskCoverage(union, in: e, threshold: 128) > 0.01 else {
        return (foregroundMask(src) ?? blackMask(e), "SAM 结果不合理，退回系统掩膜")
    }
    let avg = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    return (union, String(format: "SAM 多提示（%d 个实例，平均 IoU %.2f，覆盖率 %.1f%%）",
                          used, avg, maskCoverage(union, in: e, threshold: 128) * 100))
}
