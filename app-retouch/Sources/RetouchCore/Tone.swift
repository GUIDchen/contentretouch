// Tone：后调色的补充工具（锐化 / 降噪 / 暗角 / 颗粒 / 补光 / 背景虚化）
//
// 像素蛋糕的「后调色」有 100+ 工具，这几样是婚礼交付里最常用的，且都能用系统框架落地：
//   锐化 CIUnsharpMask · 降噪 CINoiseReduction · 暗角 CIVignette · 颗粒 CIRandomGenerator
//   补光 径向阳极 + 提亮 · 背景虚化 前景实例蒙版 + 高斯模糊（真虚化，不是画个圈）
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// 锐化（像素蛋糕的「锐化 / 清晰度」）
public func sharpen(_ src: CIImage, amount: Double) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    return src.applyingFilter("CIUnsharpMask", parameters: [
        kCIInputRadiusKey: max(1.0, max(e.width, e.height) * 0.0015),
        kCIInputIntensityKey: min(3.0, amount / 100 * 2.0)]).cropped(to: e)
}

/// 降噪。
/// 实测（合成噪声 σ=34）：CINoiseReduction **反而把 σ 推高**（34 → 44~46），
/// 因为它的 inputSharpness 在保细节时把噪声也锐了；sharpness=0 时又几乎不动（34 → 34）。
/// 真正压得下去的是中值滤波：σ 34 → **16.3**，而且保边。所以这里用「中值为主 + 强度线性混合」。
public func denoise(_ src: CIImage, amount: Double) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    let k = min(1.0, amount / 100.0)
    let median = src.applyingFilter("CIMedianFilter").cropped(to: e)
    guard k < 0.995 else { return median }
    // 常量蒙版做线性混合：out = median*k + src*(1-k)
    let mask = CIImage(color: CIColor(red: k, green: k, blue: k, alpha: 1)).cropped(to: e)
    return median.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: mask]).cropped(to: e)
}

/// 暗角（正=压暗，负=提亮）
public func vignette(_ src: CIImage, amount: Double) -> CIImage {
    guard abs(amount) > 0.01 else { return src }
    let e = src.extent
    return src.applyingFilter("CIVignette", parameters: [
        kCIInputIntensityKey: min(1.5, amount / 100 * 1.2),
        kCIInputRadiusKey: max(0.1, min(2.0, Double(max(e.width, e.height)) * 0.0006))]).cropped(to: e)
}

/// 颗粒（胶片感）：叠一层单色噪声
public func grain(_ src: CIImage, amount: Double) -> CIImage {
    guard amount > 0.01 else { return src }
    let e = src.extent
    let k = min(1.0, amount / 100) * 0.12
    guard let noise = CIFilter.randomGenerator().outputImage else { return src }
    // 去色 → 缩放 → 抬黑底（-k/2），再加法叠加
    let mono = noise.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.333, y: 0.333, z: 0.333, w: 0),
        "inputGVector": CIVector(x: 0.333, y: 0.333, z: 0.333, w: 0),
        "inputBVector": CIVector(x: 0.333, y: 0.333, z: 0.333, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        .cropped(to: e)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -k / 2, y: -k / 2, z: -k / 2, w: 0)])
    return src.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: mono]).cropped(to: e)
}

/// 补光 / 光效：在指定位置按半径范围提亮（strength 0~100，可带一点暖）
public func addLight(_ src: CIImage, strength: Double, at position: CGPoint,
                     radiusRatio: Double = 0.6, warm: Double = 0) -> CIImage {
    guard strength > 0.01 else { return src }
    let e = src.extent
    let g = CIFilter.radialGradient()
    g.center = position
    g.radius0 = 0
    g.radius1 = Float(max(1, max(e.width, e.height) * CGFloat(radiusRatio)))
    guard let mask = g.outputImage?.cropped(to: e) else { return src }
    let k = min(1.0, strength / 100) * 0.35
    let bright = src.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: k])
    var tuned = bright
    if abs(warm) > 0.01 {
        tuned = bright.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: warm / 255.0 * k, y: 0, z: -warm / 255.0 * k, w: 0)])
    }
    return tuned.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(mask, 1.0)])
}

/// 背景虚化（真虚化）：主体清晰、背景高斯模糊。用前景实例蒙版隔离，边缘羽化后夹回。
///
/// 消光晕：直接 blur(src) 的话，紧贴主体的背景像素会混进主体的颜色 → 主体边缘一圈「发光的轮廓」。
/// 做法是先把主体区域用**大半径模糊**（≈周围背景色）填掉再做正式模糊，这样边缘处没有主体颜色可渗。
public func backgroundBlur(_ src: CIImage, radius: Double = 24, strength: Double = 70,
                           dehalo: Bool = true) -> CIImage {
    guard strength > 0.01 else { return src }
    let e = src.extent
    let (fg, _) = foregroundMaskRefined(src)
    guard fg.extent.width > 1 else { return src }
    // 背景蒙版 = 反相(前景)，羽化后**再乘一次反相前景**夹回，避免模糊渗进主体（衣物平整那条教训）
    let inv = fg.applyingFilter("CIColorInvert")
    let bg = fg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0])
        .cropped(to: e)
        .applyingFilter("CIColorInvert")
        .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: inv])
    var source = src
    if dehalo {
        // 主体区域内换成「大半径模糊」的结果（半径取正式模糊的 4 倍，保证主体附近取到的是背景色）
        let wide = src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * 4.0]).cropped(to: e)
        source = wide.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(fg, 1.0)])
    }
    let blurred = source.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: e)
    return blurred.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(bg, min(1.0, strength / 100))])
}

/// 光晕强度：主体外侧「近环」与「远环」的亮度差（越小越好）。
/// 直接 blur 的话近环会被主体的颜色染上，和远环拉出可见的差。
public func measureHalo(_ src: CIImage, radius: CGFloat = 6) -> Double {
    guard let fg = foregroundMask(src) ?? personMask(src) else { return -1 }
    let e = src.extent
    let outer = fg.applyingFilter("CIColorInvert")
    // 近环 = 前景外扩 radius 再减去前景本身；远环 = 外扩 4radius 再减去外扩 radius
    func ring(_ a: Double, _ b: Double) -> CIImage {
        let big = fg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: a]).cropped(to: e)
        let small = fg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: b]).cropped(to: e)
        return big.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: small.applyingFilter("CIColorInvert")])
            .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: outer])
            .cropped(to: e)
    }
    let near = ring(Double(radius) * 2, Double(radius))
    let far = ring(Double(radius) * 8, Double(radius) * 6)
    func mean(_ m: CIImage, _ img: CIImage) -> (Double, Double) {
        let w = 128
        let h = max(8, Int(Double(w) * Double(e.height) / Double(e.width)))
        var mi = [UInt8](repeating: 0, count: w * h * 4)
        var ii = [UInt8](repeating: 0, count: w * h * 4)
        let s = CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width)
        sharedCtx.render(m.transformed(by: s), toBitmap: &mi, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        sharedCtx.render(img.transformed(by: s), toBitmap: &ii, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var s1 = 0.0, n = 0.0
        for i in 0..<(w * h) {
            let weight = Double(mi[i * 4]) / 255.0
            guard weight > 0.5 else { continue }
            s1 += (0.2126 * Double(ii[i * 4]) + 0.7152 * Double(ii[i * 4 + 1]) + 0.0722 * Double(ii[i * 4 + 2])) * weight
            n += weight
        }
        return n > 0 ? (s1 / n, n) : (0, 0)
    }
    let a = mean(near, src), b = mean(far, src)
    guard a.1 > 5, b.1 > 5 else { return -1 }
    return abs(a.0 - b.0) / 255.0
}

/// 边缘优化（抠图边缘的收边）：把前景蒙版的边缘收一点再羽化，减少「锯齿/白边」
/// 边缘优化：把**主体边缘**从原图（清晰版）贴回来。
///
/// ⚠️ 这个函数以前是**彻底的空操作**：它算出收紧后的前景掩膜，然后
/// `CIBlendWithMask(input: src, background: src, mask: …)` —— 拿 src 和 src 混合，
/// 结果恒等于 src。coretest 第 27 段的“参数拉满看动不动”量出来是 **0.00**，才把它揪出来
///（光看代码不容易发现：参数、掩膜、混合都在，就是混合的两边是同一张图）。
///
/// 它的实际用途是配合背景虚化：背景糊了之后，主体边缘会被糊进来的背景色污染（光晕），
/// 用收紧后的前景掩膜把**原图**的主体边缘贴回去，边缘就干净了。
/// - Parameter original: 虚化之前的图；不传就退回“只做边缘微反差”的写法。
public func refineEdges(_ src: CIImage, amount: Double = 50, original: CIImage? = nil) -> CIImage {
    guard amount > 0.01 else { return src }
    let (fg, _) = foregroundMaskRefined(src)
    let e = src.extent
    let k = min(1.0, amount / 100)
    let tightened = fg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
        .cropped(to: e)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1 + k * 0.6, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1 + k * 0.6, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1 + k * 0.6, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    if let original {
        // 真做法：收紧的主体掩膜里用**原图**（清晰），其余保留当前图（已虚化）
        return original.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: src,
            kCIInputMaskImageKey: maskScaled(tightened, max(0.05, min(1.0, amount / 100)))])
    }
    // 没给原图：只做边缘微反差（至少不是恒等）
    let boosted = src.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + k * 0.12])
    return boosted.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: tightened])
}


/// 大半径模糊的快速版：先在缩小图上模糊，再放大回来。
///
/// 为什么等价：半径 28 的模糊结果本身就是低频的，在 1/3 尺寸上模糊（半径 28/3）再放大，
/// 和全分辨率模糊的差异远小于 1 个色阶（下面 coretest 里有实测断言）。
/// 为什么要这样：全分辨率 28px 高斯在 1080p 上要 100ms 量级 —— 剖析里衣物美化 138ms 的大头就是它。
public func fastBlur(_ src: CIImage, radius: Double, scale: Double = 3.0) -> CIImage {
    guard radius > 8, scale > 1.01 else {
        return src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: src.extent)
    }
    let e = src.extent
    let k = 1.0 / scale
    var small = src.transformed(by: CGAffineTransform(scaleX: CGFloat(k), y: CGFloat(k)))
    small = small.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * k])
        .cropped(to: small.extent)
    return small.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        .cropped(to: e)
}
