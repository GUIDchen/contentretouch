// Auto2：自动曝光/分级、自动裁正、自动肤色校正
//
// 与 Auto.swift 同一套思路：先量本图，再出手；并且**对已经正常的图几乎不动**（自动功能最大的风险是乱改）。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 自动曝光 / 自动分级

public struct AutoExposurePlan {
    public var gamma = 1.0
    public var blackIn = 0.0          // 输入黑场（0~255）
    public var whiteIn = 255.0
    public var blackOut = 0.0
    public var whiteOut = 255.0
    public var beforeP5 = 0.0
    public var beforeP50 = 0.0
    public var beforeP95 = 0.0
    public var beforeClip = 0.0       // 溢出像素占比
    public var changed = false        // 判定「需要动」才 true
}

/// 量本图并给出一份分级方案（不动比乱动重要：判据不明显就返回 changed=false）
public func planAutoExposure(_ src: CIImage, targetP50: Double = 118) -> AutoExposurePlan {
    let e = src.extent
    let w = 256
    let h = max(1, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
    let small = src.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var hist = [Int](repeating: 0, count: 256)
    let n = w * h
    for i in 0..<n {
        let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        hist[Int(max(0, min(255, l)))] += 1
    }
    func pct(_ q: Double) -> Double {
        var acc = 0
        for v in 0..<256 { acc += hist[v]; if Double(acc) >= Double(n) * q { return Double(v) } }
        return 255
    }
    var plan = AutoExposurePlan()
    plan.beforeP5 = pct(0.05); plan.beforeP50 = pct(0.5); plan.beforeP95 = pct(0.95)
    let clipHi = Double(hist[255]) / Double(n)
    let clipLo = Double(hist[0]) / Double(n)
    plan.beforeClip = clipHi + clipLo

    // 判定「需要动」：中调偏离目标 > 8，**或者**跨度太窄（低对比 = 灰蒙蒙）。
    // 跨度判据要排除纯色退化图（span ≈ 0 没有可拉的直方图），否则一张平灰图会被判成需要处理。
    let rawSpan = plan.beforeP95 - plan.beforeP5
    let midOff = abs(plan.beforeP50 - targetP50) > 8
    let tooFlat = rawSpan < 120 && rawSpan > 5
    if !midOff && !tooFlat {
        plan.changed = false
        return plan
    }
    // 黑白场：往两端各留 0.5% 的余量，避免把噪声当黑场
    let lo = max(0, min(60, pct(0.005)))
    let hi = min(255, max(200, pct(0.995)))
    plan.blackIn = lo
    plan.whiteIn = hi
    plan.blackOut = 0
    plan.whiteOut = 255
    // 中调映射到目标：先算线性拉伸后 p50 落在哪，再反推 gamma
    let span = max(1.0, hi - lo)     // 黑白场之间的跨度（与上面的 rawSpan 不是一回事）
    let mid = max(0.02, min(0.98, (plan.beforeP50 - lo) / span))
    let want = max(0.02, min(0.98, targetP50 / 255.0))
    // CIGammaAdjust 是 out = in^power；想让 mid 落到 want，就要 power = ln(want)/ln(mid)
    // （power < 1 提亮、> 1 压暗，实测：0.5 灰 power=0.5 → 180、power=2 → 64）
    let g = log(want) / log(mid)
    // ⚠️ 这个夹紧范围原来写的是 [0.6, 1.6]，实测**暗照片够不到目标**：
    // 多图体检里 p50 34 的照片自动曝光后只到 48、p50 48 的只到 84（目标 118）——
    // 因为需要的 gamma 比 0.6 小得多，被夹住了。
    // 现在放宽到 [0.45, 1.8]：约等于最多提亮 1.15 档 / 压暗 0.85 档，仍然有界
    //（再狠就会把暗部噪声一起拉出来）。
    plan.gamma = min(1.8, max(0.45, g))
    // 试过一版"按直方图预测死白、超预算就退档"的高光保护：对极暗照片（p50 34）**反而更暗**
    //（34 → 28，比不保护还差），所以**撤回了**。当前行为：极暗照片硬提亮会有约 2% 死白
    //（wedding_02：0% → 2.2%），这是已知边界；coretest 第 36 段把这个数字量出来盯着，
    // 超过 3% 会失败。等有更好的做法（例如分离式高光 roll-off）再动这里。
    plan.changed = true
    return plan
}

/// 按方案做自动曝光/分级；amount 0~100 控制应用多少
public func autoExpose(_ src: CIImage, amount: Double = 100, targetP50: Double = 118) -> CIImage {
    guard amount > 0.01 else { return src }
    let plan = planAutoExposure(src, targetP50: targetP50)
    guard plan.changed else { return src }
    let k = min(1.0, amount / 100.0)
    let lo = plan.blackIn / 255.0 * k
    let hi = 1 - (1 - plan.whiteIn / 255.0) * k
    guard hi - lo > 0.05 else { return src }
    // ⚠️ 这里**不能**用 render() 的 CIToneCurve：它只有 5 个控制点且是样条插值，
    // 分级拉开后中间段会剧烈过冲 —— 实测「输入 120 → 输出 194」（期望 101）。
    // 改成两步可预测的操作：先线性拉伸（CIColorMatrix），再 gamma（CIGammaAdjust，power<1 = 提亮）。
    let scale = 1.0 / (hi - lo)
    let bias = -lo * scale
    var out = src.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)]).cropped(to: src.extent)
    let gamma = 1 + (plan.gamma - 1) * k
    if abs(gamma - 1) > 0.01 {
        out = out.applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma]).cropped(to: src.extent)
    }
    return out
}

// MARK: - 自动裁正（梯度方向直方图）

/// 估计画面的倾斜角（度，正 = 顺时针歪）。返回 nil 表示没有明显主轴（纯虚化/纯色画面）。
public func estimateTiltAngle(_ src: CIImage, maxAngle: Double = 15) -> Double? {
    let e = src.extent
    let w = 256
    let h = max(8, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
    // ⚠️ 必须先模糊：旋转后的直线在栅格化时会变成「阶梯」，阶梯的水平/垂直台阶梯度远强于
    // 线本身的走向 —— 实测不模糊时，5° 旋转的峰值仍然落在 0°/90°（完全测不出来）；
    // 模糊 r=1.5~3 之后峰值才回到 84°/174°（即 -6°/+84°，与真值 5° 相差 1° 以内）。
    let blurred = src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.5])
        .cropped(to: e)
    let small = blurred.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width))
        .transformed(by: CGAffineTransform(translationX: -e.minX * CGFloat(w) / e.width,
                                           y: -e.minY * CGFloat(w) / e.width))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
    }
    // 180 个方向 bin，权重 = 梯度幅值（只算够强的梯度）
    var hist = [Double](repeating: 0, count: 180)
    var total = 0.0
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let gx = lum(x + 1, y) - lum(x - 1, y)
            // 位图行序是从上往下，而 CI 的 y 向上 —— 所以这里要取负，否则倾角正负号是反的
            // （实测：+5° 的旋转会算成 -6°）
            let gy = -(lum(x, y + 1) - lum(x, y - 1))
            let mag = (gx * gx + gy * gy).squareRoot()
            guard mag > 12 else { continue }          // 弱梯度是噪声
            var ang = atan2(gy, gx) * 180 / .pi       // 梯度方向
            ang = ang.truncatingRemainder(dividingBy: 180)
            if ang < 0 { ang += 180 }
            let bin = Int(ang) % 180
            hist[bin] += mag
            total += mag
        }
    }
    guard total > 500 else { return nil }
    // 找主峰
    var best = 0
    for (i, v) in hist.enumerated() where v > hist[best] { best = i }
    // 峰值附近做加权平均（1° 的分辨率不够，需要细化）
    // ⚠️ 细化要用「相对峰值的偏移」加权，不能直接对 bin 下标加权：
    // 峰值在 0° 附近时窗口会跨到 172~179，直接平均下标会算出 ~90° 的鬼值
    //（实测正放的网格因此返回 nil）
    var sum = 0.0, weight = 0.0
    for d in -8...8 {
        let idx = ((best + d) % 180 + 180) % 180
        let wgt = hist[idx] * (1 - Double(abs(d)) / 9.0)   // 三角窗
        sum += Double(d) * wgt
        weight += wgt
    }
    guard weight > 0 else { return nil }
    let gradAngle = Double(best) + sum / weight        // 梯度主方向（0~180）
    // 边缘方向 = 梯度方向 + 90；倾斜角就是它相对 0/90 轴的偏差
    var edge = gradAngle + 90
    edge = edge.truncatingRemainder(dividingBy: 90)
    if edge > 45 { edge -= 90 }
    guard abs(edge) <= maxAngle else { return nil }
    return edge
}

/// 自动裁正：按估计角反向旋转，并裁回原尺寸（去掉旋转带进来的黑角）
public func autoLevel(_ src: CIImage, maxAngle: Double = 15) -> (image: CIImage, angle: Double)? {
    guard let tilt = estimateTiltAngle(src, maxAngle: maxAngle) else { return nil }
    guard abs(tilt) > 0.15 else { return (src, 0) }        // 已经正了就别动
    let e = src.extent
    let move = CGAffineTransform(translationX: -e.minX, y: -e.minY)
    let rot = CGAffineTransform(rotationAngle: -tilt * .pi / 180)
    let t = src.transformed(by: move).transformed(by: rot)
    let size = e.size
    // 裁剪中心要取「内容中心旋转后的位置」，不能取变换后 image extent 的中心：
    // CIImage.transformed 是绕原点转的，内容中心会跟着挪（实测按 extent 中心裁会把黑角带进来）
    let contentCenter = CGPoint(x: e.midX, y: e.midY).applying(move).applying(rot)
    let c = contentCenter
    // 内接矩形必须按旋转角缩小：直接用原尺寸裁会带进黑角，
    // 下次测倾斜时那些黑角边界就成了最强的「直线」（实测 -4° 校完残留 +12.7°、+8° 直接测不出）
    let th = abs(tilt) * .pi / 180
    let k = min(size.width / (size.width * CGFloat(cos(th)) + size.height * CGFloat(sin(th))),
                size.height / (size.width * CGFloat(sin(th)) + size.height * CGFloat(cos(th))))
    let rw = size.width * k, rh = size.height * k
    let rect = CGRect(x: c.x - rw / 2, y: c.y - rh / 2, width: rw, height: rh)
    let cropped = t.cropped(to: rect).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
    return (cropped, tilt)
}

// MARK: - 自动肤色校正

public struct SkinTone {
    public var hue = 0.0         // 度
    public var saturation = 0.0  // 0~1
    public var value = 0.0       // 0~1
}

/// 量皮肤区的平均色相/饱和度（用皮肤掩膜加权）
public func measureSkinTone(_ src: CIImage, mask: CIImage) -> SkinTone? {
    let e = src.extent
    let w = 128
    let h = max(1, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
    func renderSmall(_ i: CIImage) -> [UInt8] {
        let s = i.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(s, toBitmap: &buf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    let a = renderSmall(src), m = renderSmall(mask)
    // ⚠️ 先把皮肤像素的平均 RGB 求出来，再由这个平均色算色相。
    // 逐像素算色相再平均在低饱和区是纯噪声（实测同一张图 +15°/-15° 的「平均色相」一个降一个升，
    // 因为皮肤的平均饱和度只有 0.17，色相本身没意义）。
    var mr = 0.0, mg = 0.0, mb = 0.0, wt = 0.0
    var satSum = 0.0
    for i in 0..<(w * h) {
        let weight = Double(m[i * 4]) / 255.0
        guard weight > 0.2 else { continue }
        let r = Double(a[i * 4]) / 255, g = Double(a[i * 4 + 1]) / 255, b = Double(a[i * 4 + 2]) / 255
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        satSum += (mx <= 0 ? 0 : (mx - mn) / mx) * weight
        mr += r * weight; mg += g * weight; mb += b * weight; wt += weight
    }
    guard wt > 0.5 else { return nil }
    let r = mr / wt, g = mg / wt, b = mb / wt
    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
    let d = mx - mn
    var hue = 0.0
    if d > 0.002 {
        if mx == r { hue = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
        else if mx == g { hue = 60 * ((b - r) / d + 2) }
        else { hue = 60 * ((r - g) / d + 4) }
    }
    if hue < 0 { hue += 360 }
    return SkinTone(hue: hue, saturation: satSum / wt, value: mx)
}

/// 自动肤色校正：把肤色色相朝目标带（默认 26°）拉，饱和度过低/过高也收一点。
/// 只在皮肤掩膜内生效。
public func autoSkinTone(_ src: CIImage, mask: CIImage, amount: Double = 100,
                         targetHue: Double = 26) -> (image: CIImage, before: SkinTone?, shift: Double) {
    guard amount > 0.01, let st = measureSkinTone(src, mask: mask) else { return (src, nil, 0) }
    var delta = targetHue - st.hue
    // 色相是环：取最短路径
    if delta > 180 { delta -= 360 }
    if delta < -180 { delta += 360 }
    // 限制幅度：自动肤色最怕把冷白皮拉成橙皮
    let k = min(1.0, amount / 100.0)
    let shift = max(-12.0, min(12.0, delta)) * k * 0.6
    guard abs(shift) > 0.2 else { return (src, st, 0) }
    let hueAdjusted = src.applyingFilter("CIHueAdjust", parameters: ["inputAngle": shift * .pi / 180])
        .cropped(to: src.extent)
    // 顺手把饱和往 0.35 收一点（只收不放）
    let satDelta = st.saturation > 0.45 ? -(st.saturation - 0.45) : 0
    let adjusted = satDelta < -0.01
        ? hueAdjusted.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: Float(1 + satDelta * k)])
        : hueAdjusted
    return (adjusted.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(mask, 1.0)]), st, shift)
}
