// Liquify：手动液化的完整工具集（向前变形 / 膨胀 / 收缩 / 旋转 / 褶皱 + 冻结 + 重建）
//
// 像素蛋糕的手动液化有 向前变形 / 重建 / 平滑 / 旋转 / 褶皱 / 膨胀 / 左推 / 冻结 / 解冻。
// 老实现只有 CIBumpDistortion / CIPinchDistortion（膨胀 / 收缩），做不了「往前推」。
// 这里用 CIWarpKernel 补齐方向性变形（本机实测可用）：
//   kernel vec2 f(float2 center, float radius, float2 delta) { ... return p - delta * w; }
//   warp 内核的返回值是「去源图哪个坐标取值」，所以位移要减去。
// 冻结 = 记录冻结笔画 → 变形完把冻结区从原图贴回来（不需要内核）。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

public enum LiquifyMode: String, CaseIterable {
    case push = "向前变形"      // 拖着走（方向性）
    case pushLeft = "左推"      // 固定往笔画左侧推（向前变形的特例）
    case expand = "膨胀"
    case pinch = "收缩"
    case pucker = "褶皱"        // 与收缩同机制，名字照像素蛋糕
    case twirl = "旋转"
    case smooth = "平滑"
    case freeze = "冻结"
    case thaw = "解冻"        // 与冻结反向：把冻结区解开
    case reconstruct = "重建"  // PS 的复原画笔：涂过的地方把之前的形变退掉
}

extension CGPoint {
    func scaled(_ k: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
}

public struct WarpStroke {
    public var mode: LiquifyMode
    public var center: CGPoint
    public var radius: Double
    /// push 用：位移量（图像像素）；twirl 用：旋转强度的 100 倍；expand/pinch 用：强度 -1~1
    public var delta: CGPoint
    public var strength: Double
    /// 密度（0~1）：边缘软硬。1 = 硬边（内部大片全强度），越小过渡带越宽
    public var density: Double = 0.6
    public init(mode: LiquifyMode, center: CGPoint, radius: Double, delta: CGPoint = .zero,
                strength: Double = 0, density: Double = 0.6) {
        self.mode = mode; self.center = center; self.radius = radius
        self.delta = delta; self.strength = strength; self.density = density
    }
}

// 密度（density）控制笔刷边缘的软硬：内核里把 smoothstep 的内沿往外推，
// 密度越低，笔刷内部"全强度"的区域越小、过渡带越宽（PS 里就是这个意思）。
// 之前液化根本没有"密度"这个维度——只有一个半径，边缘软硬写死。
private let pushKernelSource = """
kernel vec2 pushWarp(float2 center, float radius, float2 delta, float density) {
    vec2 p = destCoord();
    float d = distance(p, center);
    float inner = radius * (1.0 - clamp(density, 0.0, 1.0) * 0.85);
    float w = 1.0 - smoothstep(inner, radius, d);
    return p - delta * w;
}
"""

private let twirlKernelSource = """
kernel vec2 twirlWarp(float2 center, float radius, float amount, float density) {
    vec2 p = destCoord();
    vec2 v = p - center;
    float d = length(v);
    if (d >= radius || d < 0.001) return p;
    float inner = radius * (1.0 - clamp(density, 0.0, 1.0) * 0.85);
    float w = 1.0 - smoothstep(inner, radius, d);
    float a = amount * w;
    float c = cos(a);
    float s = sin(a);
    vec2 r = vec2(v.x * c - v.y * s, v.x * s + v.y * c);
    return center + r;
}
"""

/// 膨胀 / 收缩 / 褶皱：**自己做径向 warp**，不用 CIBumpDistortion / CIPinchDistortion。
///
/// 为什么换掉系统滤镜（这是本轮修掉的一个真问题）：实测在 1050×1400 的预览上，
/// 一笔「收缩」会让**整张图放大**（出图尺寸还是 1050×1400，但内容整体放大了约 1.7 倍）——
/// 那不是我们想要的"局部收缩"。系统滤镜的几何行为在超出它预期输入尺寸时不可控，
/// 而自己写的 warp 只改笔刷圆内、圆外原样返回，extent 也不会变。
/// amount 的正负决定方向：> 0 向外扩（膨胀），< 0 向内收（收缩/褶皱）。
private let radialKernelSource = """
kernel vec2 radialWarp(float2 center, float radius, float amount, float density) {
    vec2 p = destCoord();
    vec2 v = p - center;
    float d = length(v);
    if (d >= radius || d < 0.001) return p;
    float inner = radius * (1.0 - clamp(density, 0.0, 1.0) * 0.85);
    float w = 1.0 - smoothstep(inner, radius, d);
    float k = 1.0 - amount * w;
    return center + v * k;
}
"""

let pushKernel: CIWarpKernel? = CIWarpKernel(source: pushKernelSource)
let twirlKernel: CIWarpKernel? = CIWarpKernel(source: twirlKernelSource)
let radialKernel: CIWarpKernel? = CIWarpKernel(source: radialKernelSource)

/// 内核编译状态：CIWarpKernel(source:) 编译失败时返回 **nil**，而调用处写的是 guard let else continue，
/// 于是那个模式会**静默失效**——界面上点了、拖了，画面一动不动，看起来就像"功能没做"。
/// 把状态暴露出来，让自检能一眼看出哪个内核没编过。
public func liquifyKernelStatus() -> (push: Bool, twirl: Bool, radial: Bool) {
    (pushKernel != nil, twirlKernel != nil, radialKernel != nil)
}

/// 一只笔画集 → 变形后的图。freeze 里的区域在最后被贴回原图（冻结）。
public func applyLiquify(_ src: CIImage, strokes: [WarpStroke], freeze: [WarpStroke] = []) -> CIImage {
    guard !strokes.isEmpty else { return src }
    let origin = src.extent.origin
    var out = src.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    let e = out.extent
    for s in strokes {
        let c = CGPoint(x: s.center.x - origin.x, y: s.center.y - origin.y)
        switch s.mode {
        case .push:
            guard let k = pushKernel, abs(s.delta.x) > 0.01 || abs(s.delta.y) > 0.01 else { continue }
            let pad = s.radius
            if let w = k.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -pad, dy: -pad) },
                               image: out, arguments: [CIVector(x: c.x, y: c.y), s.radius,
                                                       CIVector(x: s.delta.x, y: s.delta.y), s.density]) {
                out = w.cropped(to: e)
            }
        case .twirl:
            guard let k = twirlKernel, abs(s.strength) > 0.001 else { continue }
            if let w = k.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -s.radius, dy: -s.radius) },
                               image: out, arguments: [CIVector(x: c.x, y: c.y), s.radius, s.strength, s.density]) {
                out = w.cropped(to: e)
            }
        case .pushLeft:
            // 左推 = 把笔画方向的左侧当位移方向（顺时针转 90°），幅度按笔刷半径走
            guard let k = pushKernel, abs(s.strength) > 0.001 else { continue }
            let d = CGPoint(x: -s.delta.y, y: s.delta.x).scaled(s.strength * s.radius * 0.35)
            if let w = k.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -s.radius, dy: -s.radius) },
                               image: out, arguments: [CIVector(x: c.x, y: c.y), s.radius,
                                                       CIVector(x: d.x, y: d.y), s.density]) {
                out = w.cropped(to: e)
            }
        case .smooth:
            // 平滑：把这一块往「高斯模糊版」推一部分（与磨皮同一套机制），越刷越平
            let k = max(0.0, min(1.0, abs(s.strength)))
            guard k > 0.001 else { continue }
            let r = CGRect(x: c.x - s.radius, y: c.y - s.radius, width: s.radius * 2, height: s.radius * 2)
            let m = rectMask(extent: e, rect: r, feather: max(1, s.radius * 0.3), ellipse: true)
            let low = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: s.radius * 0.25])
                .cropped(to: e)
            out = low.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(m, k)])
        case .expand, .pinch, .pucker:
            guard let k = radialKernel, abs(s.strength) > 0.001 else { continue }
            // 归一化到 -1…1：膨胀为正、收缩/褶皱为负；强度乘 0.5 让满强度也不会把结构翻掉
            let sign = (s.mode == .expand) ? 1.0 : -1.0
            let amount = sign * min(1.0, abs(s.strength)) * 0.5
            if let w = k.apply(extent: e, roiCallback: { _, r in r.insetBy(dx: -s.radius, dy: -s.radius) },
                               image: out, arguments: [CIVector(x: c.x, y: c.y), s.radius, amount, s.density]) {
                out = w.cropped(to: e)
            }
        case .freeze, .thaw, .reconstruct:
            // 冻结/解冻/重建都不是"形变"，它们改的是笔触集合本身（在界面层处理），
            // 出图时不做任何像素变换——留在这儿是为了让 switch 完整、语义清楚。
            continue
        }
    }
    // 冻结：把冻结区从原图贴回来
    if !freeze.isEmpty {
        var mask = blackMask(e)
        for f in freeze {
            let c = CGPoint(x: f.center.x - origin.x, y: f.center.y - origin.y)
            let r = CGRect(x: c.x - f.radius, y: c.y - f.radius, width: f.radius * 2, height: f.radius * 2)
            // 冻结要「真锁住」：羽化后把蒙版推高再截断，让稳定区扩到笔刷半径之外，
            // 否则笔刷边缘那圈半强度区域仍会被推走（实测最大变化 0.0941）
            let patch = rectMask(extent: e, rect: r, feather: max(1, f.radius * 0.15), ellipse: true)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.8, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1.8, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.8, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            mask = patch.composited(over: mask)
        }
        out = src.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            .applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
    }
    return out.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)).cropped(to: src.extent)
}
