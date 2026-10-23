// CoreHeal.swift：笔刷式修复（污点/修补/仿制）+ 径向变形（膨胀/收缩），从 RetouchCore.swift 按主题拆出。
// 纯自由函数，搬运不改一行逻辑；拆分规则见 docs/功能账本_交接.md 第 115 节。
import Foundation
import CoreImage
import Foundation
import Vision
import CoreImage.CIFilterBuiltins

// MARK: - 液化（近似）与祛斑（近似）
//
// 液化：用 Core Image 自带的 Bump/Pinch 当笔刷（落点 + 半径 + 强度）。
//   ⚠️ 局限（写清楚）：**不是网格变形**，做不了「向前变形」那种自由推拉，也没有冻结/重建。
// 祛斑：皮肤掩膜内做高通检测出斑点 → 用大半径模糊填充。
//   ⚠️ 局限：结果是「斑淡了」，不是「像没长过」（真 inpainting 需要模型）。
//
// 两者都遵守踩过坑的规矩：先把图挪到原点再处理，最后挪回去（裁剪图的 extent 原点不为 0）。
public struct LiquifyStroke {
    public var center: CGPoint      // 原图坐标
    public var radius: Double
    public var strength: Double     // -1~1，正=膨胀，负=收缩
    public init(center: CGPoint, radius: Double, strength: Double) {
        self.center = center; self.radius = radius; self.strength = strength
    }
}

/// 径向变形（膨胀/收缩）——**内部转调已验证的 warp 内核实现**（第 114 节修的根因 bug）。
///
/// 原实现直接调 CIBumpDistortion / CIPinchDistortion，`scale = 强度 × 0.5`：
/// 而这两个滤镜的 scale 在这个量级**基本看不见**（实测同参数下 scale=0.4 峰值 0、scale=5 才可见）。
/// 后果：**所有走这条路的形体调整都是死的** —— 收腰/宽肩（体检均值 0.01、峰值 0）、
/// 整体液化、以及面部重塑里用它的那几项。
/// 现在把它接到手动液化那套 CIWarpKernel（用户已经在用的、看得见的实现）上，
/// 一处修、三处好；`strength` 的正负号语义不变（正=膨胀 / 负=收缩）。
public func liquify(_ src: CIImage, strokes: [LiquifyStroke], scale: CGFloat = 1) -> CIImage {
    guard !strokes.isEmpty else { return src }
    let warps = strokes.map { s in
        WarpStroke(mode: s.strength >= 0 ? .expand : .pinch,
                   center: s.center, radius: s.radius, strength: abs(s.strength) * Double(scale))
    }
    return applyLiquify(src, strokes: warps)
}

public func removeBlemishes(_ src: CIImage, skinMask: CIImage, threshold: Double = 0.055,
                            detectRadius: Double = 3, fixRadius: Double = 8, strength: Double = 0.85) -> CIImage {
    return removeBlemishesWithMask(src, skinMask: skinMask, threshold: threshold,
                                   detectRadius: detectRadius, fixRadius: fixRadius, strength: strength).image
}

/// 与 removeBlemishes 同一套算法，但**把中间那张斑点蒙版也返回**。
/// 为什么单独开这个口：coretest 量到"合成暗点只回收 20%"，需要知道卡在哪一步——
/// 是斑点没检出（掩膜为 0），还是检出后被皮肤掩膜/强度掐掉了。
/// 产品路径与调试路径**共用同一份实现**，不会出现"调试用一套、上线用另一套"。
public func removeBlemishesWithMask(_ src: CIImage, skinMask: CIImage, threshold: Double = 0.055,
                                    detectRadius: Double = 3, fixRadius: Double = 8,
                                    strength: Double = 0.85) -> (image: CIImage, spotMask: CIImage) {
    let origin = src.extent.origin
    let norm = src.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    let blurred = norm.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: detectRadius])
        .cropped(to: norm.extent)
    // 高频残差 → 阈值 → 斑点蒙版。
    //
    // ⚠️ **这里原样保留"只检测一个方向"的写法，但我怀疑方向是反的，并把证据记在这里**：
    // `CISubtractBlendMode(input: norm, background: blurred)` 算的是 `norm − blurred`，
    // 为正表示"这一块比周围**亮**"——而痣、痘印、色斑绝大多数是**暗**的（负值被下面的 clamp 截成 0）。
    // 代码注释写的是"暗斑：原图比模糊图暗"，与算式相反。
    //
    // 我按"两个方向都算再取并集"改过一版，但**合成暗点的回收率没有变化（仍是 20%）**，
    // 说明瓶颈不在检测方向（或者还在别处）。**没验证有用就不改**，所以先还原；
    // 下一轮的正确做法：把中间那张斑点蒙版在斑点处的取值直接打出来，看它到底是 0 还是有值。
    // 实测证据（coretest 第 27 段的合成暗点用例）：
    //   斑点蒙版在暗点处 **0.000**（周围 0.017）｜皮肤蒙版在暗点处 0.878
    // 皮肤是好的、斑点没检出——因为它只算了一个方向：
    //   CISubtractBlendMode(input: norm, background: blurred) = norm − blurred
    // 为正表示"这块比周围亮"，于是**只有亮斑能检出，暗斑（痣/痘印/色斑）永远是 0**
    //（负值被 clamp 截掉）。注释当初写的是"暗斑：原图比模糊图暗"，与算式相反。
    // 现在两个方向都算再取并集：暗斑用 blurred − norm、亮斑用 norm − blurred。
    // ⚠️ 这里原来是 `min(1.0, 1.0 / threshold)` —— **t 永远是 1.0**（threshold 都 < 1），
    // 于是 scaledClamped 成了恒等变换，**threshold 参数完全无效**：祛斑祛痘 0.055 / 面部祛瑕疵 0.05 /
    // 鼻孔瑕疵 0.09 / 祛痣 0.10 四个名义上不同的灵敏度，实际跑的是同一条曲线。
    // 这也是 coretest 里"斑点蒙版怎么调参数都卡在 0.4"的真正原因（§191）。
    // 现在按原意放大：残差 ≥ threshold 就打满 1.0（0.09 → ×11.1、0.05 → ×20、0.03 → ×33），上限 64 防爆。
    let t = max(1.0, min(64.0, 1.0 / max(0.001, threshold)))
    func scaledClamped(_ img: CIImage) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: t, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: t, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: t, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    }
    let darkSpot = scaledClamped(blurred.applyingFilter("CISubtractBlendMode",
                                                        parameters: [kCIInputBackgroundImageKey: norm]))
    let lightSpot = scaledClamped(norm.applyingFilter("CISubtractBlendMode",
                                                     parameters: [kCIInputBackgroundImageKey: blurred]))
    var spot = maskUnion(darkSpot, lightSpot)
    // ⚠️ **蒙版要饱和**：实测（coretest 第 27 段的参数扫描）斑点处的蒙版值一直卡在 **0.4 左右**，
    // 无论 detectRadius / fixRadius / threshold 怎么调 —— 于是最后只把斑点替换掉 40%×strength，
    // 表现就是"祛了但还是看得见"（合成暗点回收率长期停在 ~20%）。
    // 这里对蒙版做一次提升（×2.5 再截断）：检出的斑点应当被**整块替换**，而不是淡淡叠一层。
    spot = spot.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        .applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
    let regionMask = spot.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: skinMask])
    let mask = regionMask
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    // ── 大面积斑点：**交给已可下载的 LaMa**（生成式修复），比"模糊填充"能补纹理 ──
    // 时机：斑点蒙版的包围盒够大时（小斑点用模糊填充更快也更自然，没必要动用模型）。
    // 没装模型 / 模型跑不起来 → 一路退回下面的模糊填充（"不装也能用"依然成立）。
    // ⚠️ 区域必须从**不含 strength** 的掩膜算：用上面那张带的掩膜时，滑杆越强包围盒越大，
    // 于是"模糊填充 / 样例修补 / LaMa 生成式"三种**不同算法**会随滑杆切换 —— 同一张图同一个斑点，
    // 拖到 60 走 A 算法、拖到 70 走 B 算法，既不是单调的，也很难解释（§191 实测：区外出现 157 级差异）。
    let spotBox = bboxOfBright(regionMask, in: norm.extent, threshold: 110)
    let bigHole = min(spotBox.width, spotBox.height) > 18 || max(spotBox.width, spotBox.height) > 40
    // §280：探针。为什么必须加它 —— §278 我用**读码**宣布「18px 门槛是唯一原因」，§279 的放大实验直接推翻 ✗。
    // 纪律：读码只能提出假设，**中间量必须由探针量出来**。触发 CR_HEALTRACE=1。
    if ProcessInfo.processInfo.environment["CR_HEALTRACE"] == "1" {
        FileHandle.standardError.write(String(format: "HEALTRACE spotBox %.0fx%.0f ｜ bigHole=%@ ｜ isReady=%@ ｜ 工作图 %.0fx%.0f\n",
            spotBox.width, spotBox.height, bigHole ? "true" : "false",
            LaMaInpainter.shared.isReady ? "true" : "false",
            norm.extent.width, norm.extent.height).data(using: .utf8)!)
    }
    // §289：**不再默认优先 LaMa** —— §288 用有真值的同洞对比实测：LaMa 在这类洞上比样例修补差 1.5~2.5 倍
    //（祛痘 43.9 对 16.2；修补 42.6 对 29.2），甚至比模糊填还差 ✗。按「量出负收益就退」的纪律，
    // 改成**显式可选、默认关**：只有显式设 CR_LAMA_PREFER=1 才走生成式分支，否则一律用样例修补 ✓。
    let preferLaMa = laMaPreferred()   // §354：门控抽成纯函数（env 优先，其次界面开关）
    if bigHole, preferLaMa,
       let lama = LaMaInpainter.shared.inpaint(norm, mask: mask, hole: spotBox.insetBy(dx: -4, dy: -4)) {
        let merged = lama.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: norm, kCIInputMaskImageKey: mask])
        // §281：把两种可能分开量 —— 「模型没改东西」vs「改完被合回掩膜抹掉」。
        // 只看调用点就能分：①返回图与输入在斑区内的平均差（≈0 ⇒ 模型没改）；
        //                     ②merged 与输入的平均差（≈0 ⇒ 改了但被掩膜抹掉）。
        if ProcessInfo.processInfo.environment["CR_HEALTRACE"] == "1" {
            func meanAbsDiff(_ a: CIImage, _ b: CIImage) -> Double {
                let r = spotBox.insetBy(dx: -6, dy: -6).intersection(norm.extent)
                guard r.width > 2, r.height > 2 else { return -1 }
                let d = a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: r)
                guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: d,
                                                                         kCIInputExtentKey: CIVector(cgRect: r)]),
                      let out = f.outputImage else { return -1 }
                var px = [UInt8](repeating: 0, count: 4)
                sharedCtx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return (Double(px[0]) + Double(px[1]) + Double(px[2])) / 3
            }
            let dModel = meanAbsDiff(lama, norm)
            let dMerged = meanAbsDiff(merged, norm)
            let dMask = meanAbsDiff(mask, CIImage(color: .black).cropped(to: norm.extent))
            FileHandle.standardError.write(String(format: "HEALDIFF 模型改动 %.2f ｜ 合回后改动 %.2f ｜ 掩膜均值 %.1f ｜ 斑区 %.0fx%.0f\n",
                dModel, dMerged, dMask, spotBox.width, spotBox.height).data(using: .utf8)!)
        }
        return (merged.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)), spot)
    }
    // ── 中等大小的斑点：改用**样例修补** ──
    // 为什么：模糊填充的来源是"斑点自己的模糊版"，里面仍含斑点，所以只能亮回一半
    //（实测回收率卡在 49%）。样例修补是从**周围皮肤**搬一块最像的过来（实测中心误差 0.7~1.6，
    // 而模糊填充是 40.9），对 6px 以上的斑点明显更好。小的仍然走模糊（更快，且小斑点看不出差别）。
    // ── 中等大小的斑点（包围盒 > 6px）：样例修补 ──
    // ⚠️ 这条 6px 门槛是**绝对像素**，而同一个痘印在 480px 测试图 / 1050px 预览 / 4000px 导出里的
    // 像素数差几十倍 —— 所以"预览与导出可能走不同档"这件事在结构上是存在的。
    // 但 2026-09-25 的实测（coretest [扫描2]，硬边与软边两种夹具 × 3~40px）表明：
    //   · 3px 硬边：模糊 58% ／ 样例 32%（模糊明显更好）
    //   · 5~11px：模糊 45/22% ／ 样例 21/22%（持平或模糊更好）
    //   · ≥17px：两者都只剩 2~12%（那已经不是"痘印"尺度，该走 LaMa）
    // 也就是说**在我的夹具上样例修补从未胜出**，而作者当初"样例更好"的结论来自
    // 自然纹理大洞（180×180、中心误差 0.7 vs 40.9）—— 两者不矛盾（夹具不同）。
    // 结论：**不动这个门槛**（没有证据支持改动），把测量留在 coretest 里；
    // 想要更一致的尺度行为，前提是先在**自然纹理洞**上量出样例胜出的区间，再把它写成相对门槛。
    if min(spotBox.width, spotBox.height) > 6,
       let r = inpaintExemplar(norm, mask: mask, roi: spotBox.insetBy(dx: -28, dy: -28)) {
        let merged = r.image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: norm, kCIInputMaskImageKey: mask])
        return (merged.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)), spot)
    }
    let fixed = blurred.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: fixRadius]).cropped(to: norm.extent)
    let out = fixed.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: norm, kCIInputMaskImageKey: mask])
    return (out.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y)), spot)
}

// MARK: - 污点修复（笔刷式，近似）
//
// 做法：把画笔经过的点画成圆形蒙版，再把「大半径模糊」的结果通过蒙版贴回去——
// 等价于「把这一小块用周围颜色填平」，这就是污点修复的近似实现。
// ⚠️ 边界：不是真 inpainting（不会重建纹理），适合去掉小污点/小杂物，不适合大面积物体。
// ⚠️ 坐标：位图蒙版**不要翻 y**（探针 D 实测结论）——旧写法 cy = H − y 会把笔刷画到镜像位置。
public func healSpots(_ src: CIImage, points: [CGPoint], radius: Double = 20,
                       strength: Double = 1.0, feather: Double = 0.55) -> CIImage {
    guard !points.isEmpty, radius > 1 else { return src }
    let e = src.extent
    let W = Int(e.width), H = Int(e.height)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for p in points {
        let cy = p.y - e.minY                          // 位图不翻 y（探针 D）
        ctx.fillEllipse(in: CGRect(x: p.x - e.minX - radius, y: cy - radius,
                                   width: radius * 2, height: radius * 2))
    }
    guard let cg = ctx.makeImage() else { return src }
    var mask = CIImage(cgImage: cg)
    if strength < 0.999 {
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
    }
    // 首选**基于样例的修补**：它复制的是周围真实纹理，跨纹理时不会糊成一片
    //（原来是高斯模糊填，平坦区还行、一跨纹理就是一块糊斑）。失败/洞太大时退回模糊填。
    //
    // ✅ 上一轮留下的疑点（"包装路径比直调差一个量级"）**已经查清**，结论是：不是对不齐。
    //   决定性实验：把圆蒙版渲染成位图后量白斑位置 —— x 100..139、y 260..299，
    //   而图里那个洞的重心在缓冲 (119, 279)，正落在白斑中心；二者完全对得上。
    //   隔离实验：方蒙版 1.6｜方蒙版+ROI 1.6｜圆蒙版 15.8｜圆蒙版+ROI 15.8 —— **ROI 完全不影响质量**，
    //   差别只来自蒙版**形状**；而换来的"精修轮"（把洞反序重合成两遍）实测零收益、成本 3.5 倍，已撤。
    //   真正的解释：合成用例的底图是**周期条纹**，样例修补在周期纹理上可能锁定到"结构对但相位错"
    //   的源块（误差 ≈ 半个周期的幅度）。这是**用例的性质**，不是包装路径的 bug；
    //   自然纹理大多不是周期的，所以不据此改实现。
    //   保留结论：这条路径比原来的模糊填（40.9）好，且与直调共用同一算法。
    // 边缘软硬由 feather 控制（0~1）：原来写死 0.35，笔刷小的时候边界是硬的，像"贴了个圆点"。
    let soft = max(0.02, min(1.0, feather))
    var maskSoft = mask.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * (0.05 + soft * 0.6)])
        .cropped(to: e)
    if strength < 0.999 { maskSoft = maskScaled(maskSoft, max(0.01, strength)) }   // 程度
    if strength > 0.999, soft < 0.04,
       let r = inpaintExemplar(src, mask: mask, roi: strokeBounds(points, radius: radius, extent: e)) {
        return r.image
    }
    // 装了 LaMa（可选下载的生成式修复）且洞够大 → 优先用它：大面积缺失它比样例修补强得多。
    // 没装 / 跑不了就一路退回下面的样例修补（所以"不装也能用"是成立的，不是降级成不可用）。
    let holes = Double(points.count) * Double.pi * radius * radius
    // §289：与祛瑕那处同样，**默认不优先 LaMa**（§288 的同洞真值对比实测它更差 ✗），显式 CR_LAMA_PREFER=1 才走。
    if holes > Double(e.width * e.height) * 0.004,
       laMaPreferred(),
       let lama = LaMaInpainter.shared.inpaint(src, mask: mask,
                                               hole: strokeBounds(points, radius: radius, extent: e)) {
        return lama.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskSoft])
    }
    if let r = inpaintExemplar(src, mask: mask, roi: strokeBounds(points, radius: radius, extent: e)) {
        // 样例修补的结果也按**羽化后的蒙版**混回去（原来是硬边直接返回，边界会有一条看得见的圈）
        return r.image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskSoft])
    }
    // ⚠️ **"分块样例补洞"两次都试过，两次都不发布**（第 126、129 节）：
    // 思路是把超过 6% 上限的大洞切成 ≤5% 的小块，分别走样例补洞，期望比"整块取样复制"好。
    //   · 第 126 节：用例的真值跨人脸/头发，**本来就不可重建** → 量不出差异（结论无效）；
    //   · 第 129 节：先用"自相似度"自动挑出**可重建的重复纹理区**再造 240x240 洞（占图面 8.2%、
    //     掩膜 6.79% 刚好超过 6% 上限），实测：挖掉后 50.5 ｜ **取样复制 36.5 ｜ 分块样例 44.6** ——
    //     分块反而差 22%（分块之间会互相拿对方刚合成出来的内容当源，误差会传播）。
    // 所以这一版仍然直接走下面的取样复制；coretest 第 54 节留了断言护住这个结论。
    // ⚠️ **大面积兜底：取样复制优先，模糊填最后**（第 113 节实测，自然纹理 180x180 洞、2.5% 图面）：
    // （第 126 节曾在"不可重建"的用例上试过分块、量不出差异而撤回；第 129 节换用自动挑出的可重建区域，这次有实测支撑。）
    // **大面积兜底：取样复制优先，模糊填最后**（第 113 节实测，自然纹理 180x180 洞、2.5% 图面）：
    //   挖掉后 154.5 ｜ 模糊填 154.5（等于没补）｜ 取样复制 64.8 ｜ 样例补洞 6.6
    // 模糊填对"一片平坦的洞"根本没有重建能力（糊的还是一块平的）；取样复制至少把旁边真实的
    // 纹理搬过来。⚠️ 上一轮我据"周期条纹用例"（取样 49.8 vs 模糊 40.9）决定不动，
    // 那个用例的性质是**周期纹理**（复制会搬来相位错的条纹），不能代表自然纹理 —— 用例换了，结论就翻。
    let off = CGPoint(x: -radius * 2, y: 0)
    return cloneAligned(src, points: points, offsets: Array(repeating: off, count: points.count),
                        radius: radius, feather: max(0.15, soft), opacity: strength)
}

// MARK: - 仿制图章 / 修补（笔刷式）
//
// 仿制图章：把「取样点」周围的像素复制到笔刷经过的位置——实现上就是把整张图平移 (笔刷点−取样点)，
//   再用圆形羽化蒙版贴回去；每个落点做一次。
// 修补：同一套机制，只是取样点由程序自动选（默认向右 offset 倍半径处），等于「用旁边的纹理补自己」。
// ⚠️ 蒙版用 Core Image 原生方式生成（不碰 CGBitmapContext，所以不存在 y 镜像问题）。
public func cloneStamp(_ src: CIImage, source: CGPoint, points: [CGPoint],
                       radius: Double = 24, autoOffset: CGPoint? = nil,
                       feather: Double = 0.55, opacity: Double = 1.0) -> CIImage {
    guard !points.isEmpty, radius > 1 else { return src }
    let e = src.extent
    var out = src
    for p in points {
        let s = autoOffset ?? source
        let dx = p.x - s.x, dy = p.y - s.y
        let shifted = src.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        // 软化半径收一点、羽化加大：原来硬边圆 + 只羽化 0.3r，边界上就是"贴了一个圆点"，
        // 越小的笔刷越明显（用户反馈"范围太大、不够精修"，一半是默认半径，一半是这个硬边）。
        let r = radius * 0.86
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        // 羽化与不透明度由工具属性给（原来写死 0.55 且不透明度固定 1）
        let soft = radius * (0.05 + max(0.02, min(1.0, feather)) * 0.7)
        var mask = CIImage(color: .white).cropped(to: rect)
            .composited(over: CIImage(color: .black).cropped(to: e))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: soft])
            .cropped(to: e)
        if opacity < 0.999 { mask = maskScaled(mask, max(0.01, opacity)) }
        out = shifted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
    }
    return out
}

/// 仿制（**对齐模式，来源跟着笔走**）。
///
/// 与 cloneStamp 的区别（也是修掉的问题）：cloneStamp 对每个落点都重算 dx = 落点 − 取样点，
/// 于是**一笔涂过去，每个点复制的都是取样点周围同一块纹理** —— 笔刷走过的轨迹上会看到同一个图案
/// 被反复盖上去（一眼假，用户反馈"只采用第一次点击时采用的点"就是这个观感）。
/// 真正的仿制是：偏移量（落点−来源）在**这一笔里恒定**，来源随之平移，涂出来的是一整条连续的纹理。
/// offsets[i] = 第 i 个落点的平移量（= 该取样段的锚点 − 取样点）。段内恒定，换取样点后换新值。
public func cloneAligned(_ src: CIImage, points: [CGPoint], offsets: [CGPoint],
                         radius: Double = 24, feather: Double = 0.55,
                         opacity: Double = 1.0) -> CIImage {
    guard !points.isEmpty, radius > 1, !offsets.isEmpty else { return src }
    let e = src.extent
    var out = src
    for (i, p) in points.enumerated() {
        let offset = offsets[min(i, offsets.count - 1)]
        let shifted = src.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
        let r = radius * 0.86
        let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        let soft = radius * (0.05 + max(0.02, min(1.0, feather)) * 0.7)
        var mask = CIImage(color: .white).cropped(to: rect)
            .composited(over: CIImage(color: .black).cropped(to: e))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: soft])
            .cropped(to: e)
        if opacity < 0.999 { mask = maskScaled(mask, max(0.01, opacity)) }
        out = shifted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask])
    }
    return out
}

/// 修补：自动取样（右侧 offset 倍半径处）+ 仿制 —— 像素蛋糕的「修补」是同一类操作。
public func patch(_ src: CIImage, points: [CGPoint], radius: Double = 24, offsetFactor: Double = 2.2,
                   feather: Double = 0.55) -> CIImage {
    guard let first = points.first else { return src }
    // ⚠️ 试过把这里也换成基于样例的修补，**实测更差**，所以退回原实现：
    //   · 同一个合成用例（40×40 的洞、有纹理底图）里，直接走 inpaintExemplar 的洞内平均误差是 0.7，
    //     而经「笔触蒙版 → 同一算法」这条路是 28.6（模糊填是 41，所以它确实比模糊好，但差了一个量级）；
    //   · 怀疑与笔触蒙版的覆盖/朝向有关（画笔圆比洞大一圈、还要先补一圈本来正确的像素），
    //     但这一轮没有把根因坐实——**没坐实就不发布**：宁可留着这条更笨但可解释的实现。
    //   · 真正跑得好的是祛痘（healSpots）那条路径，它与这里共用 inpaintExemplar，用例里是 0.7。
    _ = first; _ = offsetFactor
    // 修补 = **内容识别填充**（PS 的修补工具就是这个语义）：直接复用祛痘那条样例补洞包装。
    // 依据（同一合成用例、洞内平均误差）：取样复制 49.8 ｜ 高斯模糊填 40.9 ｜ 样例补洞 1.0（直调）/16.2（包装）。
    // 取样复制这条路**还给仿制图章**——那才是它该在的地方（一笔连续纹理）。
    // 兜底也在里面：样例补洞失败/洞太大时 healSpots 自己退回模糊填。
    return healSpots(src, points: points, radius: radius, strength: 1.0, feather: feather)
}

/// 一串落点的包围盒（含半径与外扩），给修补算法当 ROI 用
public func strokeBounds(_ points: [CGPoint], radius: Double, extent: CGRect) -> CGRect {
    guard let f = points.first else { return extent }
    var r = CGRect(x: f.x, y: f.y, width: 0, height: 0)
    for p in points { r = r.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
    // 外扩量必须**够到搜索半径**：ROI 之外的像素在算法里等于不存在，只外扩一点点会让
    // 「找最像的那一块」直接找不到（越界即跳过）。搜索半径本身按洞的大小算（见 Inpaint.swift），
    // 这里用同样的公式估一遍，再加 8 px 余量。
    // 为什么非要有 ROI：落点蒙版是「整幅黑底 + 一小块白」，拿它的 extent 当 ROI 就等于整幅图，
    // 全分辨率的片子会白渲染一张上百 MB 的位图。
    let holes = Double(points.count) * Double.pi * radius * radius
    let search = min(40.0, max(16.0, holes.squareRoot() * 1.2))
    let margin = radius + search + 8
    return r.insetBy(dx: -margin, dy: -margin).intersection(extent)
}

/// 把一串笔触落点连成一张蒙版（白=要处理），供修补/祛痘这类「涂一块」的操作复用
public func strokeMask(extent: CGRect, points: [CGPoint], radius: Double) -> CIImage? {
    guard !points.isEmpty, radius > 1 else { return nil }
    let W = Int(extent.width), H = Int(extent.height)
    guard W > 8, H > 8 else { return nil }
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    // 沿相邻落点之间补插圆形，避免快速拖动时断成一个个孤立的洞（这是"涂一片"的常见毛病）
    var prev: CGPoint? = nil
    for p in points {
        let cur = CGPoint(x: p.x - extent.minX, y: p.y - extent.minY)   // 位图不翻 y（探针 D）
        if let a = prev {
            let steps = max(1, Int(hypot(cur.x - a.x, cur.y - a.y) / max(1, radius * 0.5)))
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                let q = CGPoint(x: a.x + (cur.x - a.x) * t, y: a.y + (cur.y - a.y) * t)
                ctx.fillEllipse(in: CGRect(x: q.x - radius, y: q.y - radius, width: radius * 2, height: radius * 2))
            }
        } else {
            ctx.fillEllipse(in: CGRect(x: cur.x - radius, y: cur.y - radius, width: radius * 2, height: radius * 2))
        }
        prev = cur
    }
    guard let cg = ctx.makeImage() else { return nil }
    return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        .cropped(to: extent)
}
