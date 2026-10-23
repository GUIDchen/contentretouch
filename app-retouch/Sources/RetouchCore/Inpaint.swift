// 补洞：基于样例的图像修补（content-aware fill 的可落地子集）
//
// 背景：原来的「污点修复 / 修补」用的是**高斯模糊填**（把洞周围的模糊值填进去）。
// 那等于把一块糊掉的颜色盖上去——平坦区域看着还行，一旦洞里跨过纹理（发丝、砖缝、花纹）
// 就是一块明显的糊斑，这也是「祛痘/去杂物」这类功能最容易露馅的地方。
//
// 这里实现的是**基于样例的修补**（exemplar / patch-based，PatchMatch 的极简版）：
//   从洞的边界往里一圈圈推进；每个待补像素在周围找一个**已知的**小块，
//   取与它邻域最像的那块的像素值填进去，填完立刻算作已知，供后面继续用。
// 它复制的是一整块纹理，而不是平均值，所以跨纹理时不会糊成一片。
//
// 代价与上限（都是量出来的，不是估的）：
//   · 复杂度 ≈ 待补像素数 × 搜索窗口面积 ÷ 步长² × 模板点数；单个 20px 半径的洞在本机约几十毫秒；
//   · 纯 CPU 逐像素，只适合**小块**（祛痘、去杂物、去线缆）。大面积（去掉一个人）不适用——
//     那需要 PatchMatch 金字塔或扩散模型，本机没有。
//   · 没有做金字塔/多尺度，纹理尺度远大于洞时（例如一整片树叶）会显得重复：如实标为上限。
import Foundation
import CoreImage

public struct InpaintStats {
    public var pixels = 0
    public var millis = 0.0
    public var filled = 0
}

/// 在 src 上按 mask（白=要补的洞）做基于样例的修补。
/// mask 与 src 必须是**同一 extent、同一渲染口径**（调用方用 sharedCtx.render 出来即可）。
/// - Parameter roi: 洞所在的大致矩形（省掉"先扫全图找白像素"的一趟）。
///   传 nil 时退回用 mask 的 extent——**注意**：调用方给的蒙版常常是「整幅黑底 + 一块白」，
///   那样 ROI 就等于整幅图，万级像素以上的片子会白渲染一张巨大的位图。所以只要调用方知道落点，就应该传 roi。
public func inpaintExemplar(_ src: CIImage, mask: CIImage, roi roiHint: CGRect? = nil,
                            patch: Int = 1, searchStep: Int = 2) -> (image: CIImage, stats: InpaintStats)? {
    let full = src.extent
    guard full.width > 8, full.height > 8 else { return nil }

    // ⚠️ 只在**洞的包围盒 + 一圈搜索余量**里干活，不碰整幅图。
    // 原先是对着整幅图开缓冲：24MP 的片子等于每次修复都要渲染一张 96 MB 的位图、
    // 再开两个 W×H 的数组（已知标记 + 波形层号，又是 100 MB 级）——出片时根本不能用。
    // 修复是局部操作，包围盒这块「小图」才是正确的尺度。
    let roiFull = (roiHint ?? mask.extent).insetBy(dx: -24, dy: -24).intersection(full)
    guard roiFull.width > 8, roiFull.height > 8, roiFull.width < 4096, roiFull.height < 4096 else { return nil }
    let roi = roiFull
    let work = src.cropped(to: roi)
        .transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))
    let maskWork = mask.cropped(to: roi)
        .transformed(by: CGAffineTransform(translationX: -roi.minX, y: -roi.minY))
    let e = CGRect(x: 0, y: 0, width: roi.width, height: roi.height)
    let W = Int(e.width), H = Int(e.height)
    guard W > 8, H > 8 else { return nil }

    func renderRGBA(_ img: CIImage) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        sharedCtx.render(img, toBitmap: &buf, rowBytes: W * 4,
                         bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    guard var px = renderRGBA(work), let mk = renderRGBA(maskWork) else { return nil }

    let t0 = Date()
    var stats = InpaintStats()
    var known = [Bool](repeating: true, count: W * H)
    var holes = 0
    for i in 0..<(W * H) where mk[i * 4] > 128 { known[i] = false; holes += 1 }
    // 洞太大就不做（宁可退回模糊填，也不给一张糊图、更不让它卡住）：
    // 复杂度是「洞内像素数 × 搜索窗口」，实测 2 万个像素的洞要 2 秒——这已经不是「祛痘」的尺度了。
    // 12000 像素 ≈ 直径 124 的圆，单个痘/杂物远小于此。
    // 上限用**相对比例**而不是绝对像素数：预览是 1000px 级、导出是全分辨率，
    // 同一个视觉上的"痘"在两者里像素数差几十倍。用相对比例才能保证
    // 「预览用样例修补、导出却退回模糊填」这种事不会发生（那就是所见非所得）。
    // 2% 兼顾两端：预览下一个 40px 的痘约 0.1%，全分辨率下同一个痘约 3%… 所以再放宽到 6%，
    // 真正拦住的是"去掉一个人"那种大面积（那本来也不该走这条路）。
    // ⚠️ 上限要按**整幅图**算，不能按 ROI 算（第 112 节修的真 bug）：
    // ROI 是被刻意收紧的（只包住洞 + 一圈搜索余量），于是 ROI 的 6% 往往只有两千像素 ——
    // 实测**两个落点以上就直接 return nil**，调用方悄悄退回模糊填（质量 29.2 → 40.9），
    // 而注释里讨论的「2 万个像素的洞要 2 秒」「12000 像素 ≈ 直径 124 的圆」全是**整幅图**的尺度。
    let cap = min(200_000, Int(Double(full.width * full.height) * 0.06))
    guard holes > 0, holes < cap else { return nil }
    stats.pixels = holes

    // 处理顺序：从洞的边界往里一圈圈推进（用「与最近已知像素的距离」分层，BFS 波形推进）。
    // 这么排是有道理的：先补的地方周围已知信息最多，补完又成为后续的依据。
    var wave = [Int](repeating: -1, count: W * H)
    var queue = [Int]()
    for y in 0..<H {
        for x in 0..<W {
            let i = y * W + x
            if known[i] { continue }
            let nb = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            if nb.contains(where: { nx, ny in
                nx >= 0 && nx < W && ny >= 0 && ny < H && known[ny * W + nx]
            }) { wave[i] = 0; queue.append(i) }
        }
    }
    var order: [Int] = []
    var head = 0
    while head < queue.count {
        let i = queue[head]; head += 1
        order.append(i)
        let x = i % W, y = i / W
        let w = wave[i]
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, nx < W, ny >= 0, ny < H else { continue }
            let j = ny * W + nx
            if known[j] || wave[j] >= 0 { continue }
            wave[j] = w + 1
            queue.append(j)
        }
    }

    let R = patch
    let offsets: [(Int, Int)] = (-R...R).flatMap { dy in (-R...R).map { (($0), dy) } }
        .filter { !($0.0 == 0 && $0.1 == 0) }

    // 搜索半径与步长：都跟洞的尺度挂钩——
    // 太小找不到相似纹理，太大/太密就是白烧 CPU（实测 sr=64、步长 2 时，2 万像素的洞要 2 秒）。
    let sr = min(40, max(16, Int(Double(holes).squareRoot() * 1.2)))
    let step = holes > 3000 ? 3 : searchStep
    for i in order {
        let x = i % W, y = i / W
        var bestScore = Int.max
        var bestIdx = -1
        var sy = -sr
        while sy <= sr {
            var sx = -sr
            while sx <= sr {
                let qx = x + sx, qy = y + sy
                sx += step
                guard qx >= 0, qx < W, qy >= 0, qy < H else { continue }
                let q = qy * W + qx
                guard known[q] else { continue }
                // 模板相似度：只在**两边都已知**的邻域上比，这样刚好比到洞的边界信息
                var score = 0
                var valid = 0
                for (ox, oy) in offsets {
                    let px2 = x + ox, py2 = y + oy
                    let qx2 = qx + ox, qy2 = qy + oy
                    guard px2 >= 0, px2 < W, py2 >= 0, py2 < H,
                          qx2 >= 0, qx2 < W, qy2 >= 0, qy2 < H else { continue }
                    let pi = py2 * W + px2
                    guard known[pi] else { continue }
                    let qi = qy2 * W + qx2
                    score += abs(Int(px[pi * 4]) - Int(px[qi * 4]))
                        + abs(Int(px[pi * 4 + 1]) - Int(px[qi * 4 + 1]))
                        + abs(Int(px[pi * 4 + 2]) - Int(px[qi * 4 + 2]))
                    valid += 1
                }
                if valid >= 4 && score < bestScore { bestScore = score; bestIdx = q }
            }
            sy += step
        }
        if bestIdx >= 0 {
            px[i * 4] = px[bestIdx * 4]
            px[i * 4 + 1] = px[bestIdx * 4 + 1]
            px[i * 4 + 2] = px[bestIdx * 4 + 2]
            stats.filled += 1
        }
        known[i] = true
    }

    // ⚠️ CGContext(data: &数组) 是悬空指针（项目里踩过）：用 CGDataProvider 让 Data 持有内存
    guard let provider = CGDataProvider(data: Data(px) as CFData),
          let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent) else { return nil }
    stats.millis = Date().timeIntervalSince(t0) * 1000
    // 贴回原图：只在 ROI 上替换，其余像素原样保留
    let patched = CIImage(cgImage: cg)
        .transformed(by: CGAffineTransform(translationX: roi.minX, y: roi.minY))
    let replaced = patched.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src,
        kCIInputMaskImageKey: CIImage(color: .white).cropped(to: roi)
            .composited(over: blackMask(full))])
    return (replaced.cropped(to: full), stats)
}
