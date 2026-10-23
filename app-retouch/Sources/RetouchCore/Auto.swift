// Auto：自动/智能这一层（白平衡、边缘感知锐化、高光恢复、补光方向）
//
// 这几样都是像素蛋糕「后调色 / 图像美化」里点一下就能用的东西，共同点是：
// 先**测量本图**，再按测量结果出手，而不是让用户猜参数。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 自动白平衡（灰世界 + 高光白点）

public struct WhiteBalance {
    public var rGain = 1.0
    public var gGain = 1.0
    public var bGain = 1.0
    public var castR = 0.0        // 校正前的 R-B 偏差（正=偏暖）
    public var castB = 0.0
    public var source = "灰世界"
}

/// 估计色偏并给出校正增益。
/// 灰世界：假设全图平均色是灰；高光白点：用最亮那批像素当白参考（对有大片白纱/白墙的婚礼片更准）。
public func estimateWhiteBalance(_ src: CIImage, useHighlight: Bool = true) -> WhiteBalance {
    let e = src.extent
    var wb = WhiteBalance()
    // 缩到小图统计（96 宽足够稳，且不吃性能）
    let small = src.transformed(by: CGAffineTransform(scaleX: 96 / max(1, e.width), y: 96 / max(1, e.width)))
    let w = 96, h = max(1, Int(round(96 * Double(e.height) / max(1, Double(e.width)))))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
    var hiR = 0.0, hiG = 0.0, hiB = 0.0, hn = 0.0
    var lums: [Double] = []
    for i in 0..<(w * h) {
        let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        lums.append(l)
    }
    let sorted = lums.sorted()
    let hiCut = sorted[Int(Double(sorted.count) * 0.9)]
    for i in 0..<(w * h) {
        let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
        // 灰世界要排除过暗/过亮的像素（黑背景和白高光都会把均值拉偏）
        if lums[i] > 20 && lums[i] < 245 {
            sr += r; sg += g; sb += b; n += 1
        }
        if useHighlight && lums[i] >= hiCut && lums[i] > 60 && lums[i] < 254 {
            hiR += r; hiG += g; hiB += b; hn += 1
        }
    }
    guard n > 10 else { return wb }
    let grayR = sr / n, grayG = sg / n, grayB = sb / n
    wb.castR = grayR - grayB
    wb.castB = 0
    // 高光白点可用时优先（灰世界在有色场景里会过度校正）
    if useHighlight && hn > 20 {
        let hR = hiR / hn, hG = hiG / hn, hB = hiB / hn
        let m = (hR + hG + hB) / 3
        if m > 20 {
            wb.rGain = m / max(1, hR)
            wb.gGain = m / max(1, hG)
            wb.bGain = m / max(1, hB)
            wb.source = "高光白点"
        }
    } else {
        let m = (grayR + grayG + grayB) / 3
        wb.rGain = m / max(1, grayR)
        wb.gGain = m / max(1, grayG)
        wb.bGain = m / max(1, grayB)
    }
    // 限幅：自动白平衡最容易过度，限制在 ±18%
    wb.rGain = min(1.18, max(0.82, wb.rGain))
    wb.gGain = min(1.18, max(0.82, wb.gGain))
    wb.bGain = min(1.18, max(0.82, wb.bGain))
    return wb
}

/// 按估计结果做白平衡（强度 0~100）
public func applyWhiteBalance(_ src: CIImage, amount: Double, useHighlight: Bool = true) -> CIImage {
    guard amount > 0.01 else { return src }
    let wb = estimateWhiteBalance(src, useHighlight: useHighlight)
    let k = min(1.0, amount / 100.0)
    func g(_ v: Double) -> Double { 1 + (v - 1) * k }
    return src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: g(wb.rGain), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: g(wb.gGain), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: g(wb.bGain), w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: src.extent)
}

// MARK: - 边缘感知锐化（只锐边缘，不放大噪点）

/// 用「局部梯度」当锐化蒙版：边缘处权重高、平坦区权重低。
/// 普通 unsharp 会把噪声一起锐出来；这个版本在平坦区几乎不动。
public func sharpenEdgeAware(_ src: CIImage, amount: Double, radius: Double = 0) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    let r = radius > 0.5 ? radius : max(1.0, Double(max(e.width, e.height)) * 0.0015)
    let k = min(1.0, amount / 100.0)
    let lum = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        // ⚠️ alpha 必须留 1：w=0 会让这张亮度图变成「alpha=0」，在预乘空间里就是全黑，
        // 拿它当蒙版用的滤镜（CIBlendWithMask）会看到 0 → 效果静默失效（探针当场测出亮度图全 0）。
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    // 梯度幅值：|原图 - 模糊|，再拉伸成 0~1 的权重
    let blur = lum.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r]).cropped(to: e)
    let gradRaw = lum.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blur])
        .cropped(to: e)
    // 阈值必须**按本图的梯度分布自适应**：写死「×6 − 0.6」时实测蒙版 p95 = 0（全图都不锐化），
    // 因为真实照片的梯度幅值 p95 只有 8/255。这里把 p50 映射到 0.1、p95 映射到 0.9。
    let gs = measure(gradRaw, work: 256)
    let lo = max(1.0, gs.p50)
    let hi = max(lo + 4.0, gs.p95)
    let scale = 255.0 / (hi - lo)
    let bias = -lo * scale / 255.0 * 0.9
    let grad = gradRaw.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    let sharp = src.applyingFilter("CIUnsharpMask", parameters: [
        kCIInputRadiusKey: r, kCIInputIntensityKey: min(3.0, k * 2.0)]).cropped(to: e)
    // 只在边缘处把锐化结果贴回去
    return sharp.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: grad])
}

// MARK: - 高光恢复

/// 把溢出的高光按「周边色」拉回来一点（不是生成式重绘，是把通道里还剩下的信息用起来）。
/// 做法：对接近纯白的像素，用大半径模糊的色度替换其色度、亮度按 recovery 压回。
public func recoverHighlights(_ src: CIImage, amount: Double, threshold: Double = 0.90) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    let k = min(1.0, amount / 100.0)
    let lum = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        // ⚠️ alpha 必须留 1：w=0 会让这张亮度图变成「alpha=0」，在预乘空间里就是全黑，
        // 拿它当蒙版用的滤镜（CIBlendWithMask）会看到 0 → 效果静默失效（探针当场测出亮度图全 0）。
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    // 蒙版 = clamp((亮度 - 阈值) / (1 - 阈值))
    let mask = lum.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1 / max(0.02, 1 - threshold), y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1 / max(0.02, 1 - threshold), z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1 / max(0.02, 1 - threshold), w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: -threshold / max(0.02, 1 - threshold),
                                    y: -threshold / max(0.02, 1 - threshold),
                                    z: -threshold / max(0.02, 1 - threshold), w: 0)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    // 恢复出的像素：亮度压到 threshold 附近，色度沿用附近区域的色度
    let lowered = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1 - 0.35 * k, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1 - 0.35 * k, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 1 - 0.35 * k, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0.20 * k, y: 0.20 * k, z: 0.20 * k, w: 0)])
    let soft = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0]).cropped(to: e)
    return lowered.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: soft])
}

// MARK: - 自动补光方向

public struct LightDirection {
    public var dx = 0.0        // -1 左 / +1 右
    public var dy = 0.0        // -1 下 / +1 上
    public var strength = 0.0  // 0~1，梯度有多强
}

/// 估计主光方向：把人脸（没脸就用整幅）横向/纵向切成两半比亮度，亮的那半就是光源方向。
public func estimateLightDirection(_ src: CIImage, face: CGRect? = nil) -> LightDirection {
    let e = src.extent
    var region = e
    if let f = face, f.width > 8, f.height > 8 {
        region = f.insetBy(dx: f.width * 0.15, dy: f.height * 0.15)
    }
    let w = 64, h = 64
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(src, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    _ = region
    var left = 0.0, right = 0.0, top = 0.0, bottom = 0.0, nl = 0.0, nr = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            let l = 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
            if x < w / 2 { left += l; nl += 1 } else { right += l; nr += 1 }
            if y < h / 2 { top += l } else { bottom += l }
        }
    }
    var d = LightDirection()
    guard nl > 0, nr > 0 else { return d }
    let lMean = left / nl, rMean = right / nr
    let tMean = top / Double(w * h / 2), bMean = bottom / Double(w * h / 2)
    let mx = max(lMean, rMean), mn = min(lMean, rMean)
    let my = max(tMean, bMean), myn = min(tMean, bMean)
    d.dx = (rMean - lMean) / max(1, mx) * 2
    d.dy = (bMean - tMean) / max(1, my) * 2
    d.strength = max((mx - mn) / max(1, mx) * 4, (my - myn) / max(1, my) * 4)
    d.dx = min(1, max(-1, d.dx))
    d.dy = min(1, max(-1, d.dy))
    d.strength = min(1, max(0, d.strength))
    return d
}

/// 只在暗的那一侧补光（方向由 estimateLightDirection 给），比「固定打在上部中央」更贴光向。
public func autoFillLight(_ src: CIImage, amount: Double, face: CGRect? = nil) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    let dir = estimateLightDirection(src, face: face)
    // 补光点摆在暗侧：光源在右，就往左边补
    let cx = dir.dx >= 0 ? e.minX + e.width * 0.30 : e.minX + e.width * 0.70
    let cy = dir.dy >= 0 ? e.minY + e.height * 0.35 : e.minY + e.height * 0.65
    return addLight(src, strength: amount, at: CGPoint(x: cx, y: cy), radiusRatio: 0.8)
}
