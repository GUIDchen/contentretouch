// §312：把 SAM 版智能消除的两个掩膜工具从 App 目标移到 RetouchCore。
// 原因（§311）：coretest 是独立目标、只依赖 RetouchCore ⇒ 放在 App 目标里测试看不见 ✗。
// 这两个函数本质是掩膜工具（不是界面逻辑），放核心层更合位置，也让别的探针/门能用。
import Foundation
import CoreImage

/// 以点为中心造一个白色羽化圆，当 SAM 的提示掩膜（hint）。
public func healHintMask(at p: CGPoint, radius: CGFloat, in extent: CGRect) -> CIImage {
    let r = max(4, radius)
    let base = CIImage(color: .black).cropped(to: extent)
    let disk = CIImage(color: .white)
        .cropped(to: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: r * 0.25])
    return disk.composited(over: base).cropped(to: extent)
}

/// 在掩膜里均匀取若干个点（交给现有点笔画修复，零新修复代码）。
public func healSamplePoints(in mask: CIImage, extent: CGRect, max n: Int = 10) -> [CGPoint] {
    let w = 96
    let h = max(1, Int(Double(w) * extent.height / max(1, extent.width)))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let scaled = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / max(1, extent.width),
                                                        y: CGFloat(h) / max(1, extent.height)))
    sharedCtx.render(scaled, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var pts: [CGPoint] = []
    for y in 0..<h { for x in 0..<w where buf[(y * w + x) * 4] > 128 {
        pts.append(CGPoint(x: extent.minX + (CGFloat(x) + 0.5) * extent.width / CGFloat(w),
                           y: extent.minY + (CGFloat(h) - (CGFloat(y) + 0.5)) * extent.height / CGFloat(h)))
    } }
    guard pts.count > n else { return pts }
    let step = max(1, pts.count / n)
    return Array(stride(from: 0, to: pts.count, by: step).map { pts[$0] }.prefix(n))
}
