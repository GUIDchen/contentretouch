// Auto3：自动暗角校正、自动降噪强度
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 自动暗角（周边光量）

public struct AutoVignettePlan {
    public var cornerToCenter = 1.0     // 四角与中心的亮度比（<1 = 四角偏暗）
    public var needed = false
    public var amount = 0.0             // 建议的校正量 0~100
    public var detail = ""
}

/// 量四角与中心的亮度比，给出校正量。
/// 判据：比值 < 0.92 才动手（轻微暗角是镜头的自然表现，不该一律抹掉）。
public func planAutoVignette(_ src: CIImage) -> AutoVignettePlan {
    let e = src.extent
    var plan = AutoVignettePlan()
    let w = 128
    let h = max(8, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
    let small = src.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
    }
    // 中心：中间 1/3；四角：四个 1/6 的方块
    func mean(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
        var s = 0.0, n = 0.0
        for y in y0..<min(y1, h) { for x in x0..<min(x1, w) { s += lum(x, y); n += 1 } }
        return n > 0 ? s / n : 0
    }
    let cx0 = w / 3, cx1 = w * 2 / 3, cy0 = h / 3, cy1 = h * 2 / 3
    let center = mean(cx0, cy0, cx1, cy1)
    let cw = w / 6, chh = h / 6
    let corners = [mean(0, 0, cw, chh), mean(w - cw, 0, w, chh),
                   mean(0, h - chh, cw, h), mean(w - cw, h - chh, w, h)]
    let cornerAvg = corners.reduce(0, +) / 4
    guard center > 4 else { return plan }
    plan.cornerToCenter = cornerAvg / center
    plan.detail = String(format: "四角/中心 = %.3f（四角 %.0f，中心 %.0f）", plan.cornerToCenter, cornerAvg, center)
    if plan.cornerToCenter < 0.92 {
        // 标定过的映射：实测 correctVignetting 的响应近似线性（校正量 0/20/40/60/80/100
        // 对应比值 0.825/0.858/0.893/0.930/0.967/1.008，约 0.0018 每单位）。
        // 目标是把比值推到 0.97 附近，所以 amount = (0.97 - ratio) / 0.0018。
        plan.amount = min(100.0, max(0.0, (0.97 - plan.cornerToCenter) / 0.0018))
        plan.needed = true
    }
    return plan
}

// MARK: - 自动降噪强度

public struct AutoDenoisePlan {
    public var noiseSigma = 0.0        // 估计的噪声强度（0~255 级别）
    public var amount = 0.0            // 建议降噪量 0~100
    public var needed = false
    public var detail = ""
}

/// 用「高通能量的稳健中位数」估噪声：噪声在平坦区最干净地暴露出来。
/// sigma ≈ 1.4826 × MAD(高频)。这样估出来的值不受画面内容（边缘）影响。
public func planAutoDenoise(_ src: CIImage, isoHint: Double = 0) -> AutoDenoisePlan {
    let e = src.extent
    var plan = AutoDenoisePlan()
    let w = 256
    let h = max(8, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
    let small = src.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width))
    let blur = small.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.0])
    var a = [UInt8](repeating: 0, count: w * h * 4)
    var b = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &a, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    sharedCtx.render(blur, toBitmap: &b, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var diffs: [Double] = []
    diffs.reserveCapacity(w * h)
    for i in 0..<(w * h) {
        let la = 0.2126 * Double(a[i * 4]) + 0.7152 * Double(a[i * 4 + 1]) + 0.0722 * Double(a[i * 4 + 2])
        let lb = 0.2126 * Double(b[i * 4]) + 0.7152 * Double(b[i * 4 + 1]) + 0.0722 * Double(b[i * 4 + 2])
        diffs.append(abs(la - lb))
    }
    let sorted = diffs.sorted()
    let median = sorted[sorted.count / 2]
    plan.noiseSigma = 1.4826 * median
    plan.detail = String(format: "高频 MAD 中位数 %.2f → σ ≈ %.2f（0~255 级）", median, plan.noiseSigma)
    // 实测基线：干净照片 σ ≈ 1~2；ISO1600 以上通常 σ > 4
    if plan.noiseSigma > 2.2 {
        // 干净照片 σ≈1~2；σ=8 就已经明显可见，σ>20 属于重度噪声 → 给满
        plan.amount = min(100.0, (plan.noiseSigma - 2.0) * 6.0)
        plan.needed = true
    }
    return plan
}
