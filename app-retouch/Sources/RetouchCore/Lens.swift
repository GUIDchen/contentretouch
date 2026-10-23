// Lens：镜头校正（畸变 / 暗角 / 色差）与透视校正（水平 / 垂直）
//
// 对应像素蛋糕「图像美化」里的镜头校正，以及「裁剪旋转」里的水平/垂直校正。
// 全部用系统滤镜落地，不引外部依赖：
//   畸变 CIPinchDistortion · 暗角 CIVignette · 色差 分通道绕中心缩放再合成 · 透视 CIPerspectiveCorrection
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// 镜头畸变校正：amount -100~100，负=校正桶形（边缘外扩后的内收），正=校正枕形
public func correctLensDistortion(_ src: CIImage, amount: Double) -> CIImage {
    guard abs(amount) > 0.01 else { return src }
    let e = src.extent
    let k = max(-1.0, min(1.0, amount / 100.0))
    return src.applyingFilter("CIPinchDistortion", parameters: [
        kCIInputCenterKey: CIVector(x: e.midX, y: e.midY),
        kCIInputRadiusKey: Double(max(e.width, e.height)) * 0.55,
        kCIInputScaleKey: Float(k * 0.6)]).cropped(to: e)
}

/// 镜头暗角校正（周边光量补偿）：把四角提亮回中心。amount 0~100
public func correctVignetting(_ src: CIImage, amount: Double) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    // CIVignette 的 intensity 取负值即提亮四角
    return src.applyingFilter("CIVignette", parameters: [
        kCIInputIntensityKey: -min(1.0, amount / 100.0),
        kCIInputRadiusKey: max(0.1, min(2.0, Double(max(e.width, e.height)) * 0.0006))]).cropped(to: e)
}

/// 横向色差校正：R 与 B 通道绕中心反向缩放，G 不动（色差的物理表现就是三通道半径不一致）
public func correctChromaticAberration(_ src: CIImage, amount: Double) -> CIImage {
    guard abs(amount) > 0.01 else { return src }
    let e = src.extent
    let k = max(-1.0, min(1.0, amount / 100.0)) * 0.010      // 最多 1% 的缩放差（真实横向色差一般 <0.5%）
    let c = CGPoint(x: e.midX, y: e.midY)
    func channel(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
        src.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
    func scaleAbout(_ img: CIImage, _ s: Double) -> CIImage {
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .scaledBy(x: CGFloat(s), y: CGFloat(s))
            .translatedBy(x: -c.x, y: -c.y)
        return img.transformed(by: t).cropped(to: e)
    }
    // 方向别搞反：色差是「R 偏大 / B 偏小」时，校正要往反方向缩回来。
    // 第一版写反了，实测边缘 R-B 平均差从 2.565 反而涨到 3.070（探针当场抓到）。
    let red = scaleAbout(channel(1, 0, 0), 1 - k)
    let grn = channel(0, 1, 0)
    let blu = scaleAbout(channel(0, 0, 1), 1 + k)
    return red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: grn])
        .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blu])
        .cropped(to: e)
}

/// 透视校正（水平 / 垂直梯形校正）：-100~100，靠调整四角把梯形拉回矩形
public func perspectiveCorrect(_ src: CIImage, horizontal: Double, vertical: Double) -> CIImage {
    guard abs(horizontal) > 0.01 || abs(vertical) > 0.01 else { return src }
    let e = src.extent
    // 四角必须构成**梯形**才有校正意义：四角同时平移只会得到一个平行四边形（等于错切），
    // 对「垂直线收敛」这种梯形畸变完全无效（第一版就这么写的，探针测出左右行错位恒为 0）。
    let hk = CGFloat(max(-1.0, min(1.0, horizontal / 100.0))) * 0.15
    let vk = CGFloat(max(-1.0, min(1.0, vertical / 100.0))) * 0.15
    let f = CIFilter.perspectiveCorrection()
    f.inputImage = src
    // 垂直校正：只收上边（把上边变窄），下边保持不动
    let tin = e.width * vk / 2, tinY = e.height * hk / 2
    f.topLeft = CGPoint(x: e.minX + tin, y: e.maxY - tinY)
    f.topRight = CGPoint(x: e.maxX - tin, y: e.maxY + tinY)
    f.bottomLeft = CGPoint(x: e.minX, y: e.minY - tinY)
    f.bottomRight = CGPoint(x: e.maxX, y: e.minY + tinY)
    guard let out = f.outputImage, out.extent.width > 2, out.extent.height > 2 else { return src }
    let sx = e.width / out.extent.width, sy = e.height / out.extent.height
    let scaled = out.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        .transformed(by: CGAffineTransform(translationX: -out.extent.minX * sx, y: -out.extent.minY * sy))
    return scaled.cropped(to: CGRect(x: 0, y: 0, width: e.width, height: e.height))
}
