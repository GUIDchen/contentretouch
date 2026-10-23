// 前沿能力：直接吃系统里已经训练好的模型，而不是自己手搓启发式
//
// 本机能用的、2023 之后才进 Vision 的几个请求（都用探针实际跑过，不是照着文档猜的）：
//   · VNCalculateImageAestheticsScoresRequest（macOS 14+）：Apple 训练的美学评分，还能判「这是不是
//     文档/截图」（isUtility）。挑图一直是我自己按清晰度/闭眼/构图堆公式，现在有一份学习模型的判断可用。
//   · VNGenerateImageFeaturePrintRequest（macOS 11+）：768 维图像嵌入，相似检索用它比「颜色统计」
//     靠谱一个量级——它是学过内容的，不是只比色调。
//   · VNDetectHumanHandPoseRequest / VNDetectHumanBodyPose3DRequest：手部 21 点与 3D 人体姿态。
//
// 实测（本机，M 系列，已预热）：
//   美学分 ≈ 61 ms/张（首次 12 ms 是模型已驻留的偶然情况，取中位 61）
//   特征打印 ≈ 17.5 ms/张，768 维；同场景两张距离 0.73，跨场景 1.01 / 1.09 → 距离有区分度
import Foundation
import Vision
import CoreImage

public struct AestheticInfo {
    public var overall: Double = 0        // 0~1，越大越「好看」（Apple 的判断）
    public var isUtility: Bool = false    // true = 截图/文档/翻拍，不是要交付的照片
    public var ok: Bool = false           // 模型是否跑成功（跑不了就别拿 0 当低分）
}

/// Apple 的美学评分。跑不动就返回 ok=false，调用方据此**不加分也不扣分**（不拿 0 冒充低分）。
/// 注意可用性：这个请求在 SDK 里标的是 macOS 15+（包的最低支持是 14），所以运行时判定。
/// 系统不支持就返回 ok=false，挑图退回原来的启发式打分，不会因为缺这个能力就崩。
public func aestheticScore(_ cg: CGImage) -> AestheticInfo {
    var info = AestheticInfo()
    guard #available(macOS 15.0, *) else { return info }
    let req = VNCalculateImageAestheticsScoresRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil, let r = req.results?.first else { return info }
    info.overall = Double(r.overallScore)
    info.isUtility = r.isUtility
    info.ok = true
    return info
}

/// 768 维图像嵌入（相似检索用）。失败返回 nil。
public func featurePrint(_ cg: CGImage) -> [Float]? {
    let req = VNGenerateImageFeaturePrintRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil,
          let o = req.results?.first as? VNFeaturePrintObservation else { return nil }
    return floats(of: o)
}

/// 把 VNFeaturePrintObservation 取成 [Float]。
/// 取嵌入分量：走 observation 自带的 `data`。本机实测 elementType = .float、768 维、
/// 3072 字节 = 768×4，即 float32 连续排列。取之前先校验字节数，对不上就放弃，不硬解释内存布局。
func floats(of o: VNFeaturePrintObservation) -> [Float]? {
    guard o.elementCount > 0, o.elementType == .float else { return nil }
    let raw = o.data
    guard raw.count == o.elementCount * MemoryLayout<Float>.size else { return nil }
    return raw.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return nil }
        return Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: Float.self), count: o.elementCount))
    }
}

/// L2 距离（两个嵌入等长才有意义）
// MARK: - 嵌入表（存盘 + 检索）

/// 一万多张的嵌入表：JSONL 里塞 768 个 float 会膨胀到几百 MB，所以单独一个二进制文件。
/// 格式：魔数 CRFP + 版本 + 维度 + 条数 + 连续 Float32 行；行序与索引 JSONL 的记录顺序一一对应。
/// 3D 人体姿态 → 身体朝向（度，0 = 正面、±90 = 正侧）。
///
/// 上一轮我记的是「3D 姿态只能拿到投影后的 2D 点」，**这个结论是错的**：
/// VNHumanBodyPose3DObservation 的 cameraRelativePosition(_:) 给的就是相机坐标系下的 3D 点，
/// 肩膀的深度差直接读得到（探针编译 + 实跑都过了）。
///
/// 用途很具体：全身美型（收腰/宽肩）是**按 2D 关键点做横向位移**的，身体一旦转到侧面，
/// 左右肩在画面里几乎重合，再横向推就会把身体推歪。有了朝向就能先判「这是不是侧身」，
/// 侧身时把强度压下来并如实告诉用户——而不是照做然后出怪图。
public func bodyYaw3D(_ cg: CGImage) -> (yaw: Double, ok: Bool) {
    guard #available(macOS 14.0, *) else { return (0, false) }
    let req = VNDetectHumanBodyPose3DRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([req])) != nil,
          let obs = req.results?.first,
          let ls = try? obs.cameraRelativePosition(.leftShoulder),
          let rs = try? obs.cameraRelativePosition(.rightShoulder) else { return (0, false) }
    let dx = Double(ls.columns.3.x - rs.columns.3.x)
    let dz = Double(ls.columns.3.z - rs.columns.3.z)
    guard abs(dx) > 1e-5 || abs(dz) > 1e-5 else { return (0, false) }
    var yaw = atan2(dz, dx) * 180 / .pi
    if yaw > 90 { yaw -= 180 } else if yaw < -90 { yaw += 180 }
    return (yaw, true)
}

public final class EmbeddingStore {
    public private(set) var dim = 0
    public private(set) var count = 0
    public private(set) var data: [Float] = []
    public init() {}

    public func load(_ path: String) {
        guard let d = FileManager.default.contents(atPath: path), d.count > 20 else { return }
        let magic = String(bytes: d[0..<4], encoding: .ascii) ?? ""
        guard magic == "CRFP" else { return }
        func int32(_ off: Int) -> Int {
            Int(d.subdata(in: off..<(off + 4)).withUnsafeBytes { $0.load(as: Int32.self) })
        }
        dim = int32(4); count = int32(8)
        guard dim > 0, count > 0, d.count >= 12 + dim * count * 4 else { return }
        data = [Float](repeating: 0, count: dim * count)
        d.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: 12).assumingMemoryBound(to: Float.self)
            data.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src, count: dim * count)
            }
        }
    }

    public func save(_ path: String) throws {
        var out = Data("CRFP".utf8)
        var d32 = Int32(dim), c32 = Int32(count)
        withUnsafeBytes(of: &d32) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &c32) { out.append(contentsOf: $0) }
        data.withUnsafeBufferPointer { p in
            out.append(Data(bytes: p.baseAddress!, count: p.count * MemoryLayout<Float>.size))
        }
        try out.write(to: URL(fileURLWithPath: path))
    }

    public func build(_ rows: [[Float]?]) {
        let d = rows.compactMap { $0?.count }.max() ?? 0
        dim = d
        count = rows.count
        data = [Float](repeating: 0, count: d * rows.count)
        for (i, r) in rows.enumerated() {
            guard let r = r, r.count == d else { continue }   // 取不到的行留 0，检索时按「无效」跳过
            for j in 0..<d { data[i * d + j] = r[j] }
        }
    }

    public func row(_ i: Int) -> [Float] {
        guard i >= 0, i < count, dim > 0 else { return [] }
        return Array(data[(i * dim)..<((i + 1) * dim)])
    }

    public func isValid(_ i: Int) -> Bool {
        guard i >= 0, i < count, dim > 0 else { return false }
        var s = 0.0
        for j in 0..<dim { s += abs(Double(data[i * dim + j])) }
        return s > 0.001
    }

    /// 暴力全扫的 topK。13529 张 × 768 维 ≈ 1000 万次乘加，本机 10 ms 级——
    /// 这个规模没必要上 ANN 索引（HNSW 之类），先把最笨的做对。
    /// ponytail: 数据量再大一个量级（十万+）时再换 HNSW/IVF，届时接口不变。
    public func search(_ q: [Float], topK: Int = 20) -> [(index: Int, distance: Double)] {
        guard dim > 0, q.count == dim else { return [] }
        var out: [(Int, Double)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard isValid(i) else { continue }
            var s = 0.0
            let base = i * dim
            for j in 0..<dim {
                let d = Double(data[base + j] - q[j])
                s += d * d
            }
            out.append((i, s.squareRoot()))
        }
        out.sort { $0.1 < $1.1 }
        return out.prefix(topK).map { (index: $0.0, distance: $0.1) }
    }
}
