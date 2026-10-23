// CoreRender.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

public struct Params: Codable {
    // ⚠️ 这两个是「未改动」占位值，必须和 render() 里的恒等判断**一致**：
    // 判断要求 levelsIn[1]≈255、levelsOut[1]≈250。之前 levelsIn 默认写成 250，
    // 默认参数过不了恒等判断 → 每条导入都白套一条 CIToneCurve：实测过曝样本白点 255→244、
    // 全图平均压暗 9.82 级、97.5% 像素被改；还让高光恢复的输入永远到不了 255（蒙版只到 0.57）。
    public var levelsIn = [0.0, 255.0]
    public var levelsOut = [0.0, 250.0]
    public var gamma = 1.0
    public var brightness = 0.0
    public var contrast = 0.0
    public var desat = 0.0
    public var cbSh = [0.0, 0.0, 0.0]
    public var cbMid = [0.0, 0.0, 0.0]
    public var cbHi = [0.0, 0.0, 0.0]
    public init() {}
}

/// 闭环：出图 → 度量 → 微调 → 取误差最小的一版。返回 (最佳参数, 最佳统计, 误差, 轮数)
public func closedLoop(_ src: CIImage, base p0: Params, target: Stats, iterations: Int = 3)
    -> (Params, Stats, Double, Int) {
    var p = p0
    var best = (p0, Stats(), 999.0)
    var used = 0
    // 阻尼迭代：某一步把误差走高了，就退回上一步并减半步长。
    // 必要性是量出来的——饱和度这一维不是线性的（sat 用 (max−min)/max 度量，
    // 越降每单位饱和度掉的 sat 越少），固定步长会一路冲过头：实测目标 sat 25%，
    // 输出落到 18%（比原图 39% 更远离目标），6 轮全在过冲之后回不来。
    var lastGood = p0
    var prevErr = Double.greatestFiniteMagnitude
    var damp = 1.0
    // ⚠️ **目标无效时必须直接返回原参数**：`Style.target` 的默认值是全 0 的 `Stats()`，
    // 而"全 0"看起来是个完全合理的 Stats —— 闭环于是认认真真地把画面朝**全黑**收敛。
    // §194 实测（批量导出通路）：本图 p50=128、起始 brightness=4.2，
    // 闭环 3 轮后 brightness = **−44.8**、gamma 1.0 → 0.8，导出成片整体压黑（RMSE 0.44，肉眼一眼可见）。
    // 判据：p50 与 p95 同时为 0 才算"没人设过目标"，这时不猜、不动。
    guard target.p50 > 1 || target.p95 > 1 else {
        return (p0, measure(src), 0, 0)
    }
    for it in 0..<max(1, iterations) {
        let out = render(src, p)
        let st = measure(out)
        let e = st.distance(to: target)
        if e < best.2 { best = (p, st, e) }
        used = it + 1
        if e < 0.05 { break }
        if e < prevErr {
            lastGood = p
            prevErr = e
        } else {
            p = lastGood                      // 这一步走坏了，退回去
            damp = max(0.15, damp * 0.5)
        }
        func step(_ v: Double, _ d: Double, _ lo: Double, _ hi: Double) -> Double {
            min(hi, max(lo, v + d * damp))
        }
        // 亮度差用 brightness 走大步，gamma 只管收尾。
        // 早先只有 gamma、还被夹在 0.80~1.35：参考图比原图亮一大截时**根本够不着**——
        // 实测原图 q50 0.13 去追 q50 0.42 的参考，3 轮后误差从 3.42 涨到 3.53，
        // 也就是「追不动」，命令行只好按「原片更接近」放弃套用。brightness 是线性加，
        // 暗部抬升不会像 gamma 那样把层次压死，正好用来跨大档。
        let dQ = target.q50 - st.q50
        p.brightness = step(p.brightness, dQ * 60, -60, 60)
        p.gamma = step(p.gamma, dQ * 0.25, 0.80, 1.35)
        p.levelsOut[0] = step(p.levelsOut[0], (target.q5 - st.q5) * 90, 0, 60)
        p.desat = step(p.desat, (st.sat - target.sat) * 0.7, 0, 80)
        // 暖冷步子：单位换算见 paramsFromStats —— cbGain=26（100 参数 ≈ 26 级），
        // 且 tint 是 R 加 / B 减（差值翻倍），再取 0.6 的步长避免过冲。
        // 早先这里是 dSh * 8，实际每轮只挪 4 级（等价 0.6 级的参数），追 +44 级的参考根本追不动。
        let kStep = 100.0 / cbGain / 2 * 0.6 * damp
        let dHi = target.warmHi - st.warmHi
        p.cbHi = [p.cbHi[0] + dHi * kStep, p.cbHi[1], p.cbHi[2] - dHi * kStep]
        let dSh = target.warmSh - st.warmSh
        p.cbSh = [p.cbSh[0] + dSh * kStep, p.cbSh[1], p.cbSh[2] - dSh * kStep]
    }
    return (best.0, best.1, best.2, used)
}

// MARK: - 预设（Preset）JSON schema v1
//
// 一个预设 = 一份可存可传的「风格 + 人像策略」。存成独立 JSON 文件，不塞进代码里。
// 结构（contentretouch.preset/v1）：
//   schema     固定字符串，用于以后升级时判定
//   name       预设名（界面显示）
//   source     这份风格从哪来：clusterIndex（聚类号）/ refImages（参考图文件名）/ note
//   style      调色参数（与 batch.jsx 的 S 字段一一对应）
//   face       人像策略：perFaceAdaptive（是否逐脸自适应）、attributes（各脸的人物属性）
//   notes      备注
public struct PresetFile: Codable {
    public var schema: String = "contentretouch.preset/v1"
    public var name: String
    public var source: Source
    public var style: StyleParams
    public var face: FacePolicy
    public var notes: String
    /// 这条预设要追的目标统计量。存下来是必须的：早先只存了参数，
    /// 结果「载入预设」只改了预览参数，**导出时仍然按当前风格组的目标跑闭环**——
    /// 预览和出片不是一回事。老文件没有这个字段，解码为 nil，行为退回原样。
    public var target: Stats? = nil

    public struct Source: Codable {
        public var kind: String          // cluster | images | manual
        public var clusterIndex: Int?
        public var refImages: [String]
        public var note: String
    }
    public struct StyleParams: Codable {
        public var levelsIn: [Double]
        public var levelsOut: [Double]
        public var gamma: Double
        public var brightness: Double
        public var contrast: Double
        public var desat: Double
        public var cbShadow: [Double]
        public var cbMid: [Double]
        public var cbHigh: [Double]
        public init(levelsIn: [Double], levelsOut: [Double], gamma: Double, brightness: Double,
                    contrast: Double, desat: Double, cbShadow: [Double], cbMid: [Double], cbHigh: [Double]) {
            self.levelsIn = levelsIn; self.levelsOut = levelsOut; self.gamma = gamma
            self.brightness = brightness; self.contrast = contrast; self.desat = desat
            self.cbShadow = cbShadow; self.cbMid = cbMid; self.cbHigh = cbHigh
        }
    }
    public struct FacePolicy: Codable {
        public var perFaceAdaptive: Bool
        /// 人物属性：索引 -> 女/男/儿童/长辈女/长辈男（与像素蛋糕同一套分类）
        public var attributes: [String: String]
        public var scope: String         // single | all
    }
}

/// 把当前的风格参数导出成预设文件
public func savePreset(_ preset: PresetFile, to path: String) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(preset).write(to: URL(fileURLWithPath: path))
}

public func loadPreset(_ path: String) throws -> PresetFile {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let p = try JSONDecoder().decode(PresetFile.self, from: data)
    guard p.schema == "contentretouch.preset/v1" else {
        throw NSError(domain: "Preset", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "预设版本不认识：\(p.schema)"])
    }
    return p
}

public func render(_ src: CIImage, _ p: Params) -> CIImage {
    var img = src
    let lo = p.levelsIn[0] / 255.0, hi = max(0.001, p.levelsIn[1] / 255.0)
    let olo = p.levelsOut[0] / 255.0, ohi = p.levelsOut[1] / 255.0
    let pts: [CGPoint] = (0...4).map { i in
        let x = Double(i) / 4.0
        var t = (x - lo) / (hi - lo)
        t = min(max(t, 0), 1)
        if abs(p.gamma - 1) > 0.001 { t = pow(t, 1.0 / p.gamma) }
        return CGPoint(x: x, y: olo + t * (ohi - olo))
    }
    // 恒等曲线要跳过：CIToneCurve 是样条插值，就算五个点落在对角线上也会有波纹
    // （实测：恒等参数渲染与原图 RMSE 5%，跳过之后应降到只剩重编码噪声）
    // 判据必须覆盖默认值本身（levelsIn [0,255] / levelsOut [0,250]），否则「什么都没调」
    // 也会走曲线——coretest 第 11 段用 render(src, Params()) 与原图逐像素对账盯着这条。
    let isIdentityCurve = abs(p.levelsIn[0]) < 0.5 && abs(p.levelsIn[1] - 255) < 0.5
        && abs(p.levelsOut[0]) < 0.5 && abs(p.levelsOut[1] - 250) < 0.5 && abs(p.gamma - 1) < 0.001
    let isIdentityOut = isIdentityCurve || (abs(p.levelsIn[0]) < 0.5 && abs(p.levelsIn[1] - 255) < 0.5
        && abs(p.levelsOut[0]) < 0.5 && abs(p.levelsOut[1] - 255) < 0.5 && abs(p.gamma - 1) < 0.001)
    if !isIdentityOut {
        let tc = CIFilter.toneCurve()
        tc.inputImage = img
        tc.point0 = pts[0]; tc.point1 = pts[1]; tc.point2 = pts[2]; tc.point3 = pts[3]; tc.point4 = pts[4]
        img = tc.outputImage ?? img
    }
    // 注意：这里**不能**提前 return。早先是「降饱和/亮度/对比都接近 0 就直接返回」，
    // 结果暖冷偏色（cbSh/cbHi）被静默跳过——只调偏色时参数等于没写。
    if !(abs(p.desat) < 0.01 && abs(p.brightness) < 0.01 && abs(p.contrast) < 0.01) {
        let cc = CIFilter.colorControls()
        cc.inputImage = img
        cc.saturation = Float(max(0, 1 - p.desat / 100))
        cc.brightness = Float(p.brightness / 100)
        cc.contrast = Float(1 + p.contrast / 100)
        img = cc.outputImage ?? img
    }
    // 亮度蒙版：**alpha 必须也等于亮度**。
    // CIBlendWithMask 是按蒙版的 alpha 混合的，早先这里照抄「转灰度」的写法把 inputAVector 给了
    // (0,0,0,0)，(alpha 全 0) → 混合结果恒等于底图 → 暖冷偏色一直是**空操作**。
    // 合成图上的已知答案抓出来的：给 cbSh=[120,0,-120]，阴影 R−B 纹丝不动。
    func lumaMask(_ invert: Bool) -> CIImage {
        let s = invert ? -1.0 : 1.0
        let v = CIVector(x: s * 0.2126, y: s * 0.7152, z: s * 0.0722, w: 0)
        var params: [String: Any] = ["inputRVector": v, "inputGVector": v,
                                     "inputBVector": v, "inputAVector": v]
        if invert { params["inputBiasVector"] = CIVector(x: 1, y: 1, z: 1, w: 1) }
        return img.applyingFilter("CIColorMatrix", parameters: params)
    }
    let lumHi = lumaMask(false)
    let lumSh = lumaMask(true)
    func tint(_ base: CIImage, _ dR: Double, _ dB: Double, _ mask: CIImage) -> CIImage {
        if abs(dR) < 0.005 && abs(dB) < 0.005 { return base }
        let t = base.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: dR / 255.0, y: 0, z: dB / 255.0, w: 0)])
        return t.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
    }
    // ⚠️ 中间调**以前根本没被应用**：cbMid 有字段、有 JSON 序列化、有合并逻辑，
    // 就是没有任何一行把它算进像素里——coretest 第 27 段的"参数有效性体检"量出来是 **0.00**（完全不动）。
    // 中间调掩膜用 L×(1−L)：两条已有的亮度蒙版相乘，正好在 0.5 处最大、两端为 0。
    let midRaw = lumHi.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: lumSh])
    let mid = midRaw.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 4)])
    img = tint(img, p.cbHi[0] * cbGain / 100, p.cbHi[2] * cbGain / 100, lumHi)
    img = tint(img, p.cbMid[0] * cbGain / 100, p.cbMid[2] * cbGain / 100, mid)
    img = tint(img, p.cbSh[0] * cbGain / 100, p.cbSh[2] * cbGain / 100, lumSh)
    return img
}
