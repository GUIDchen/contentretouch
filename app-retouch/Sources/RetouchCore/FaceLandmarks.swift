// FaceLandmarks.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

public struct FaceGeo {
    public var index = 0
    public var box = CGRect.zero          // 图像像素坐标（原点左下）
    public var quality: Float = 0
    public var leftEye: [CGPoint] = []
    public var rightEye: [CGPoint] = []
    public var innerLips: [CGPoint] = []
    public var outerLips: [CGPoint] = []
    public var nose: [CGPoint] = []
    public var leftEyebrow: [CGPoint] = []
    public var rightEyebrow: [CGPoint] = []
    public var faceContour: [CGPoint] = []
    // 头部姿态（弧度）：Vision 直接给，比自己从关键点猜可靠得多
    public var yaw: Double = 0            // 左右扭头（0 = 正脸）
    public var roll: Double = 0           // 歪头
    public var pitch: Double = 0
    public init() {}

    public func bbox(_ pts: [CGPoint]) -> CGRect {
        guard !pts.isEmpty else { return .null }
        var r = CGRect.null
        for p in pts { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        return r
    }
    /// 把整份几何（框 + 所有关键点）先平移再缩放：给"掩膜降到低分辨率上算"用。
    /// 关键点与框都是**图像像素坐标**，所以整份一起变换才对得上。
    public func transformed(scale k: CGFloat, offsetX: CGFloat, offsetY: CGFloat) -> FaceGeo {
        var g = self
        func t(_ pts: [CGPoint]) -> [CGPoint] {
            pts.map { CGPoint(x: ($0.x - offsetX) * k, y: ($0.y - offsetY) * k) }
        }
        g.box = CGRect(x: (box.minX - offsetX) * k, y: (box.minY - offsetY) * k,
                       width: box.width * k, height: box.height * k)
        g.leftEye = t(leftEye); g.rightEye = t(rightEye)
        g.innerLips = t(innerLips); g.outerLips = t(outerLips)
        g.nose = t(nose); g.leftEyebrow = t(leftEyebrow); g.rightEyebrow = t(rightEyebrow)
        g.faceContour = t(faceContour)
        return g
    }

    public func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        var x = 0.0, y = 0.0
        for p in pts { x += p.x; y += p.y }
        return CGPoint(x: x / CGFloat(pts.count), y: y / CGFloat(pts.count))
    }
}

/// 一次请求拿齐：人脸框 + 全部关键点 + 人脸质量分。
/// 小脸回退：脸在缩小图上小于 ~120 px 时关键点会检不到（实测 1712×2284 缩到 750×1000 后关键点从 1 变 0），
/// 这时把脸附近裁出来放大再跑一次，坐标映射回来。
public func detectFaceGeos(_ cg: CGImage, size: CGSize) -> [FaceGeo] {
    // 缓存：同一条管线里人脸检测会被调多次（人像/衣物/打分…），一次 40~70ms
    let img = CIImage(cgImage: cg)
    return VisionCache.shared.faceGeos(img) { detectFaceGeosUncached(cg, size: size) }
}

func detectFaceGeosUncached(_ cg: CGImage, size: CGSize) -> [FaceGeo] {
    let direct = landmarkPass(cg, size: size)
    if !direct.isEmpty { return direct }
    let W = size.width, H = size.height
    let rr = VNDetectFaceRectanglesRequest()
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([rr])) != nil,
          let big = (rr.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return [] }
    let b = big.boundingBox
    var c = CGRect(x: b.minX * W, y: b.minY * H, width: b.width * W, height: b.height * H)
    c = c.insetBy(dx: -c.width * 0.7, dy: -c.height * 0.7)
        .intersection(CGRect(x: 0, y: 0, width: W, height: H)).integral
    guard c.width > 8, c.height > 8 else { return [] }
    let scale = min(6.0, max(1.0, 640.0 / c.width))
    let cropped = CIImage(cgImage: cg).cropped(to: c).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cg2 = sharedCtx.createCGImage(cropped, from: cropped.extent) else { return [] }
    return landmarkPass(cg2, size: cropped.extent.size).map { g in
        var o = g
        func back(_ p: CGPoint) -> CGPoint { CGPoint(x: c.minX + p.x / scale, y: c.minY + p.y / scale) }
        o.box = CGRect(x: c.minX + g.box.minX / scale, y: c.minY + g.box.minY / scale,
                       width: g.box.width / scale, height: g.box.height / scale)
        o.leftEye = g.leftEye.map(back); o.rightEye = g.rightEye.map(back)
        o.innerLips = g.innerLips.map(back); o.outerLips = g.outerLips.map(back)
        o.nose = g.nose.map(back)
        o.leftEyebrow = g.leftEyebrow.map(back); o.rightEyebrow = g.rightEyebrow.map(back)
        o.faceContour = g.faceContour.map(back)
        return o
    }
}

/// 单次关键点 + 质量检测（不做回退）
func landmarkPass(_ cg: CGImage, size: CGSize) -> [FaceGeo] {
    let lm = VNDetectFaceLandmarksRequest()
    let q = VNDetectFaceCaptureQualityRequest()
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    guard (try? handler.perform([lm, q])) != nil else { return [] }
    let obs = lm.results ?? []
    let qs = (q.results ?? []).map { ($0.boundingBox, $0.faceCaptureQuality ?? 0) }
    var out: [FaceGeo] = []
    for (i, o) in obs.enumerated() {
        var g = FaceGeo()
        // Vision 的人脸姿态是弧度，nil 时留 0
        g.yaw = o.yaw?.doubleValue ?? 0
        g.roll = o.roll?.doubleValue ?? 0
        g.pitch = o.pitch?.doubleValue ?? 0
        g.index = i
        let b = o.boundingBox
        g.box = CGRect(x: b.minX * size.width, y: b.minY * size.height,
                       width: b.width * size.width, height: b.height * size.height)
        func map(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let r = r else { return [] }
            return r.normalizedPoints.map {
                CGPoint(x: g.box.minX + $0.x * g.box.width, y: g.box.minY + $0.y * g.box.height)
            }
        }
        g.leftEye = map(o.landmarks?.leftEye)
        g.rightEye = map(o.landmarks?.rightEye)
        g.innerLips = map(o.landmarks?.innerLips)
        g.outerLips = map(o.landmarks?.outerLips)
        g.nose = map(o.landmarks?.nose)
        g.leftEyebrow = map(o.landmarks?.leftEyebrow)
        g.rightEyebrow = map(o.landmarks?.rightEyebrow)
        g.faceContour = map(o.landmarks?.faceContour)
        // 质量分按包围盒就近配对（两个请求各自独立检出，顺序不保证一致）
        if let m = qs.min(by: { a, b2 in
            let d1 = hypot(a.0.midX - b.midX, a.0.midY - b.midY)
            let d2 = hypot(b2.0.midX - b.midX, b2.0.midY - b.midY)
            return d1 < d2
        }) { g.quality = m.1 }
        out.append(g)
    }
    return out
}

/// 眼睛/脸颊的扩展矩形（人像面板里多处共用）
/// 祛瑕疵的皮肤区：优先用肤色检测（排除眼睛/眉毛/头发/唇），脸太小时自动退回脸框椭圆。
/// 早先用的是纯椭圆，会把眼睛和头发也当皮肤处理。
func faceSkinMask(_ src: CIImage, _ g: FaceGeo) -> CIImage {
    bestSkinMask(src, face: g)
}

/// 用解析出的**头发掩膜**测发际线高度（脸中轴带上「头发第一次出现」的 y）。
/// 为什么要量：早先发际线位移的圆心写死在「脸框 84% 高度」，额头高低不同的人会打偏
///（额头天生就高的脸，圆心会落在头发里；额头矮的又落在眉毛附近）。
/// 解析结果有按脸缓存，同一张脸重复问不会重复推理。
public func hairlineY(_ src: CIImage, face: FaceGeo) -> Double? {
    let e = src.extent
    guard let hair = parsedMaskForFace(src, face: face, classes: FaceClass.hairClasses,
                                       feather: 2, margin: 0.7) else { return nil }
    let box = face.box
    let x = box.midX
    let x0 = max(e.minX, x - box.width * 0.12)
    let w = min(e.maxX - x0, box.width * 0.24)
    guard w > 4 else { return nil }
    var y = box.minY + box.height * 0.45
    let yTop = min(e.maxY - 2, box.maxY + box.height * 0.45)
    var buf = [UInt8](repeating: 0, count: Int(w) * 4)
    while y < yTop {
        sharedCtx.render(hair, toBitmap: &buf, rowBytes: Int(w) * 4,
                         bounds: CGRect(x: x0, y: y, width: w, height: 1), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var hits = 0
        for i in 0..<Int(w) where buf[i * 4] > 128 { hits += 1 }
        if hits >= Int(Double(w) * 0.4) { return Double(y) }
        y += max(2, CGFloat(box.height) * 0.01)
    }
    return nil
}
