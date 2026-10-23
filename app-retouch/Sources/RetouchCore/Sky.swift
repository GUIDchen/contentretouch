// Sky：换天空（**非生成式**：检测天空区域 → 用渐变/图片替换 → 羽化边界 + 色调匹配）
//
// 像素蛋糕的换天空是生成式的；这里做的是**合成式**版本，能力边界写在注释里：
//   · 能换：整片天空区（婚纱外景、风光、逆光背景）
//   · 不能：把树梢/发丝间的天空抠干净（那需要 matting 模型），也不能无中生有补云（生成式）
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

public struct SkyOptions {
    public var amount = 0.0          // 0~100
    public var style = "blue"        // blue（晴天蓝）/ sunset（晚霞）/ grey（阴天灰）/ warm（暖金）
    public var horizonBias = 0.0     // -1~1，地平线微调（正=往下扩）
    public var matchTone = true      // 让新天空与原场景的明暗/色温靠拢
    public init() {}
    public var anyEnabled: Bool { amount > 0.01 }
}

/// 天空区域的「分数图」：0=不是天空，1=是天空。
/// 判据是**位置 + 亮度 + 蓝度**三条的组合，而不是单一阈值 —— 白墙、白纱、水面都亮，
/// 但它们在画面下部或不够蓝，会被位置项和蓝度项压下去。
public func skyScore(_ src: CIImage, horizonBias: Double = 0) -> CIImage {
    let e = src.extent
    let lum = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    // 蓝度代理 = B - R（Core Image 没有逐像素 max()，用单通道差更稳）。
    // ⚠️ 一开始我写成了「B - max(R,G)」那种矩阵，但 CIColorMatrix 的语义是
    // output = M × input + bias，逐行对应输出通道——那组数根本算不出想要的结果（掩膜恒为 0）。
    // 现在把 (B - R + 0.5) 同时写进三个通道，得到一张灰度「蓝度图」。
    let blueness = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: -1, y: 0, z: 1, w: 0),
        "inputGVector": CIVector(x: -1, y: 0, z: 1, w: 0),
        "inputBVector": CIVector(x: -1, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)])
    // 亮度项：> 0.45 开始算亮
    let bright = lum.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 3.0, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 3.0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 3.0, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: -1.35, y: -1.35, z: -1.35, w: 0)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    // 蓝度项：> 0.02 开始算蓝
    let blue = blueness.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 20, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 20, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 20, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: -0.4, y: -0.4, z: -0.4, w: 0)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    // 位置项：越靠上越可能是天空（顶部 1，到 55% 高度降到 0）
    // horizonBias 就是把这条边界整体上下挪：正 = 地平线往下（天空区变大），负 = 往上。
    let horizonY = e.minY + e.height * (0.55 - 0.12 * horizonBias)
    // ⚠️ 白块必须**压在黑底上做成不透明**再模糊：直接 blur 一个 crop 过的白块，
    // 块外的 alpha 是 0（预乘空间里等于全黑），乘法链拿到的是 0 —— 结果位置项完全不起作用，
    // 实测掩膜在 y=140/180/240 三处都是同一个值（这个坑和掩膜那几处是同一个）。
    let topUnblurred = CIImage(color: .white)
        .cropped(to: CGRect(x: e.minX, y: horizonY, width: e.width, height: e.height - (horizonY - e.minY)))
        .composited(over: CIImage(color: .black).cropped(to: e))
    let vert = topUnblurred.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: e.height * 0.06])
        .cropped(to: e)
    // 三项相乘：只要有一项低，就不算天空
    var m = bright.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: blue])
    m = m.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: vert])
    // 三项相乘后，实际取值集中在 0.2~0.6 这个区间（比如纯净蓝天 = 0.22），
    // 用 threshold 100（0.39）去判覆盖率会把天空整片判成「不是天空」——实测就这么空了一轮。
    // 这里用 gamma 0.5 把中段拉开：0.22→0.47、0.5→0.71、0.9→0.95，阈值保持 100 就自洽了。
    return m.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.5])
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(2, e.height * 0.004)])
        .cropped(to: e)
}

/// 生成一张程序化天空（渐变 + 少量云感），避免依赖外部图片
public func skyImage(style: String, extent: CGRect) -> CIImage {
    let top: CIColor, bottom: CIColor
    switch style {
    case "sunset":
        top = CIColor(red: 0.18, green: 0.26, blue: 0.52)
        bottom = CIColor(red: 1.0, green: 0.64, blue: 0.36)
    case "grey":
        top = CIColor(red: 0.62, green: 0.66, blue: 0.72)
        bottom = CIColor(red: 0.86, green: 0.88, blue: 0.90)
    case "warm":
        top = CIColor(red: 0.35, green: 0.52, blue: 0.78)
        bottom = CIColor(red: 1.0, green: 0.85, blue: 0.62)
    default:   // blue
        top = CIColor(red: 0.16, green: 0.42, blue: 0.82)
        bottom = CIColor(red: 0.72, green: 0.86, blue: 0.96)
    }
    let g = CIFilter(name: "CILinearGradient")
    g?.setValue(CIVector(x: extent.midX, y: extent.maxY), forKey: "inputPoint0")
    g?.setValue(CIVector(x: extent.midX, y: extent.minY), forKey: "inputPoint1")
    g?.setValue(top, forKey: "inputColor0")
    g?.setValue(bottom, forKey: "inputColor1")
    var sky = (g?.outputImage ?? CIImage(color: top)).cropped(to: extent)
    // 加一点云：用已有素材里的随机噪声做低频化，得到自然的不均匀感
    if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
        // ⚠️ **必须先裁剪再模糊**（第 121 节修的性能 bug）：
        // CIRandomGenerator 是**无限大**的图，原来先缩放→**模糊**→最后才 cropped，
        // 于是 Core Image 被迫对一个无限区域做高斯模糊 —— 实测这一步 23841 ms，
        // 单张出图 74 秒就是这么来的（用户侧"换个天空要等一分钟"）。
        // 裁剪把输入收成有界，模糊只作用在这块上。
        // ⚠️ 也不能"缩小无限噪声"：scale 0.004 意味着源区域要生成 (1/0.004)² = 6 万多倍的像素，
        // 实测仍然是 21 秒。正确做法是**取一小块噪声再放大**——源区域有界（96×96），代价几乎为零。
        // tile 越小 → 放大后每个噪声像素越大 → 云的结构越大越含蓄。
        // 96 时实测云很明显（与原来的"轻微不均匀感"不是一回事），改用 24 + 更大模糊回到设计意图。
        let tile = 16.0
        let clouds = noise.cropped(to: CGRect(x: 0, y: 0, width: tile, height: tile))
            .transformed(by: CGAffineTransform(scaleX: extent.width / tile, y: extent.height / tile))
            .cropped(to: extent)
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(10, extent.height * 0.04)])
            .cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                // 云的**浓度**看这里（0.10/−0.02 是原值；实测在大结构下偏明显，收到 0.06/−0.01）。
                // 想更强/更弱改这两个数即可 —— 模糊只影响云的边缘软硬，改不了浓度。
                "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.01, y: -0.01, z: -0.01, w: 0)])
        sky = clouds.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: sky]).cropped(to: extent)
    }
    return sky
}

/// 换天空。返回 (结果, 天空区域占比) —— 占比用于界面提示「这张图没检出天空」
public func replaceSky(_ src: CIImage, _ o: SkyOptions) -> (image: CIImage, coverage: Double) {
    let e = src.extent
    guard o.anyEnabled else { return (src, 0) }
    // ⚠️ 这里以前写的是「平移一次再平移回来」——两次变换互相抵消，等于空操作。
    // 实测 horizonBias 取 -1/0/+1 时检出覆盖率都是 47.7%。现在改成把位置项的边界真的挪一挪。
    var mask = skyScore(src, horizonBias: o.horizonBias)
    let cov = maskCoverage(mask, in: e, threshold: 100)
    guard cov > 0.01 else { return (src, 0) }
    // 二次闸门：**蓝度**。亮度 + 位置这两条会把「室内亮背景」也判成天空
    //（实测室内婚礼片检出了 17%「天空」）。真天空在被选中的区域里平均 B-R 明显为正。
    let blue = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: -1, y: 0, z: 1, w: 0),
        "inputGVector": CIVector(x: -1, y: 0, z: 1, w: 0),
        "inputBVector": CIVector(x: -1, y: 0, z: 1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 0.5, y: 0.5, z: 0.5, w: 0)]).cropped(to: e)
    let blueInSky = maskAverage(blue, mask: mask, in: e)
    guard blueInSky > 0.52 else { return (src, 0) }   // 0.5 = B 与 R 相等；>0.52 才算「偏蓝」
    // 再把**主体（人）**从天空掩膜里明确减掉。实测"亮度+位置+蓝度"这套启发式压到人身上只有 2%
    //（coretest 第 26 段），但那 2% 是白白糊在人身上；减掉是**严格更好且几乎免费**。
    // 这就是审阅里"天空需要分割模型"的一条低成本替代：用户身上的误判先用主体掩膜兜住。
    var skyMask = mask
    if let person = personMask(src) {
        let safe = person.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.4, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.4, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.4, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3]).cropped(to: e)
        skyMask = skyMask.applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: safe.applyingFilter("CIColorInvert")])
        mask = skyMask
    }
    var sky = skyImage(style: o.style, extent: e)
    if o.matchTone {
        // 色调匹配：把新天空的亮度/色温往原图天空拉一点，避免「贴上去的假」
        let k = min(1.0, cov * 2.0)
        let warm = estimateWhiteBalance(src)
        _ = k
        sky = sky.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(min(1.15, max(0.9, warm.rGain))), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(min(1.15, max(0.9, warm.bGain))), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).cropped(to: e)
    }
    let strength = min(1.0, o.amount / 100)
    let out = sky.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(mask, strength)])
    return (out.cropped(to: e), cov)
}


/// 掩膜加权平均（用 mask 当权重，取 img 的平均值）——用于「天空区到底蓝不蓝」这类判断
public func maskAverage(_ img: CIImage, mask: CIImage, in extent: CGRect) -> Double {
    let w = 64
    let h = max(8, Int(Double(w) * Double(extent.height) / Double(extent.width)))
    let scale = CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(w) / extent.width)
    func render(_ i: CIImage) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(i.transformed(by: scale), toBitmap: &b, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return b
    }
    let ii = render(img), mm = render(mask)
    var sum = 0.0, wt = 0.0
    for i in 0..<(w * h) {
        let k = Double(mm[i * 4]) / 255.0
        guard k > 0.3 else { continue }
        sum += Double(ii[i * 4]) / 255.0 * k
        wt += k
    }
    return wt > 0 ? sum / wt : 0
}
