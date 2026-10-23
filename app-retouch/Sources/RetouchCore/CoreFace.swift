// CoreFace.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

/// 人脸检测（M3 的「参数按脸组织」用）
public struct FaceBox {
    public var rect: CGRect
    public var quality: Float
}

// MARK: - 人像：按脸组织参数
public struct FaceInfo {
    public var index: Int
    public var rect: CGRect          // Vision 归一化坐标（原点左下）
    public var quality: Float
    /// 关键点几何（脸缘/眼/唇…）。**有它就能用轮廓做蒙版，比"按脸框外推的椭圆"准得多**。
    /// 用户报的"脸面提亮范围不准确"就是这个：椭圆按 (0.58w, 0.62h) 硬推，
    /// 下巴/额头盖不住、两侧又伸到头发上；而轮廓掩膜（contourFaceMask）第 47 轮就写好了，
    /// 只是逐脸参数这条路一直没接上（第 7 次"改了 A、B 还在用旧的"）。
    public var geo: FaceGeo?
    public init(index: Int, rect: CGRect, quality: Float, geo: FaceGeo? = nil) {
        self.index = index; self.rect = rect; self.quality = quality; self.geo = geo
    }
}

/// 一次性检出所有脸（归一化坐标 + 人脸质量分）。
/// 转成 detectFaceGeos 的薄封装：这样磨皮/衣物这些老功能也自动获得「小脸回退」与同一套质量分配。
public func detectFaceInfos(_ cg: CGImage) -> [FaceInfo] {
    let size = CGSize(width: cg.width, height: cg.height)
    guard size.width > 1, size.height > 1 else { return [] }
    return detectFaceGeos(cg, size: size).map {
        FaceInfo(index: $0.index,
                 rect: CGRect(x: $0.box.minX / size.width, y: $0.box.minY / size.height,
                              width: $0.box.width / size.width, height: $0.box.height / size.height),
                 quality: $0.quality, geo: $0)
    }
}

/// 给某张脸做一张羽化蒙版（归一化矩形 → 像素坐标；feather 0~1 控制边缘软硬）。
///
/// ⚠️ 早先这里是**内切圆**（半径 = min(宽,高)/2），于是「这张脸的提亮/暖冷」只作用在脸中间一个圆斑上：
/// 下巴、额头、脸颊两侧都在圆外（提亮提不到），而圆的左右两侧又伸出发际线、盖到头发上
///（把人脸算成圆的，是这个项目里最典型的「差一点就对了」的错）。
/// 现在改成**按脸框长宽比的椭圆**：单位圆做径向渐变，再按 (rx, ry) 缩放并平移过去。
public func faceMask(extent: CGRect, face: FaceInfo, feather: Double = 0.35) -> CIImage {
    // 优先用**脸缘轮廓**（关键点）：贴合脸型，不会盖到头发、也不会漏掉下巴/额头。
    if let geo = face.geo, let m = contourFaceMask(extent: extent, face: geo, feather: 0.14) { return m }
    let w = face.rect.width * extent.width
    let h = face.rect.height * extent.height
    let cx = extent.minX + (face.rect.minX + face.rect.width / 2) * extent.width
    let cy = extent.minY + (face.rect.minY + face.rect.height / 2) * extent.height
    guard w > 2, h > 2 else { return blackMask(extent) }
    // 椭圆比脸框略大一点：脸框通常只框到眉/嘴，下巴与发际线要靠这点余量盖住
    let rx = w * 0.58, ry = h * 0.62
    let soft = max(1.0, min(rx, ry) * feather)
    let g = CIFilter.radialGradient()
    g.center = .zero
    g.radius0 = Float(max(0.001, 1.0 - soft / max(rx, ry)))
    g.radius1 = 1.0
    g.color0 = CIColor.white
    g.color1 = CIColor.black
    guard let grad = g.outputImage else { return blackMask(extent) }
    return grad
        .transformed(by: CGAffineTransform(scaleX: rx, y: ry))
        .transformed(by: CGAffineTransform(translationX: cx, y: cy))
        .cropped(to: extent)
}

/// 逐脸出图：先全局渲染一版，再把每张脸的局部调整用蒙版叠回去。
/// perFace 里没给到的人脸就沿用全局结果（scope=all 时所有人共用同一份调整）。
public func renderWithFaces(_ src: CIImage, global p: Params, faces: [FaceInfo],
                            perFace: [Int: Params]) -> CIImage {
    var out = render(src, p)
    guard !faces.isEmpty, !perFace.isEmpty else { return out }
    let extent = src.extent
    for (idx, fp) in perFace {
        guard let face = faces.first(where: { $0.index == idx }) else { continue }
        let local = render(src, fp)
        let mask = faceMask(extent: extent, face: face)
        out = local.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
    }
    return out
}

/// 由关键点生成"特征掩膜"：**多边形 ∪ 包围盒椭圆**。
///
/// 为什么不能只用多边形：Vision 的 eyes/outerLips 关键点都是**细长曲线**，
/// 实测（coretest 第 38/40 段）3/6 张照片上多边形的**质心落在多边形之外**，
/// 当填充掩膜用时特征内部根本盖不住——表现就是"扣眼睛没扣掉""唇色/牙齿效果很弱"。
/// 椭圆（按包围盒外扩）保证内部一定被覆盖，两者取并集既贴形状又不会漏。
public func featureMask(extent: CGRect, polygons: [[CGPoint]], feather: Double) -> CIImage {
    var out = polygonMask(extent: extent, polygons: polygons, feather: feather)
    for poly in polygons {
        let xs = poly.map { $0.x }, ys = poly.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX > 1, maxY - minY > 1 else { continue }
        let w = maxX - minX, h = maxY - minY
        // 眼睛横向更扁、嘴唇横向更宽：统一按"短边 12% / 长边 25%"外扩，两类都够用
        let r = CGRect(x: minX, y: minY, width: w, height: h)
            .insetBy(dx: -w * 0.12, dy: -h * 0.25)
        out = maskUnion(out, rectMask(extent: extent, rect: r,
                                      feather: max(0.8, min(w, h) * 0.10), ellipse: true))
    }
    return out
}

/// 用**脸部轮廓关键点**做掩膜（比椭圆贴得多）。
///
/// 为什么需要它：coretest 第 24 段量过——当脸不够大/眼周判不准而退回**椭圆**时，
/// 椭圆有 **34% 的面积落在真正的皮肤之外**（头发、背景），也就是那部分被误磨。
/// 小脸照片恰恰只能走这条路，所以这个误差是真实的画质损失。
/// Vision 的 faceContour 给的正是脸缘（下巴/两颊/鬓角），连成多边形比椭圆贴合得多。
///
/// 处理细节：faceContour 是一条**开口**曲线（沿下颌到两侧），所以还要用脸框上沿把它闭合，
/// 否则额头那一块会被切掉。
public func contourFaceMask(extent: CGRect, face: FaceGeo, feather: Double = 0.12) -> CIImage? {
    var pts = face.faceContour
    guard pts.count >= 5 else { return nil }
    let box = face.box
    // 按 x 排序后取左右两端，各自向上接到脸框上沿附近，形成闭环
    let sorted = pts.sorted { $0.x < $1.x }
    let left = sorted.first!, right = sorted.last!
    let topY = min(box.maxY - box.height * 0.02, max(left.y, right.y) + box.height * 0.95)
    pts.append(CGPoint(x: right.x - box.width * 0.02, y: topY))
    pts.append(CGPoint(x: left.x + box.width * 0.02, y: topY))
    let m = rasterize([pts], extent: extent)
    guard let raw = m.first else { return nil }
    let soft = max(1, min(box.width, box.height) * feather)
    return raw.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: soft]).cropped(to: extent)
}
