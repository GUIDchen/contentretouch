// 参考图追色：给我几张「想要的样子」，把它折成一个目标统计量，再用闭环把原图拉过去。
//
// 关键取舍：**用中位数，不用平均**。
// 参考图集是用户随手给的——里面常混进一张夜景、一张黑白、一张过曝。平均值会被这几张
// 拖偏，中位数天然抗离群（坏点最多占到一半之前都拉不动它）。
// 同时回报「参考图之间有多不一致」(spread)：这叫诚实——如果用户给的 5 张参考本身就风格
// 打架，那不是一个可追的目标，该说清楚而不是硬平均出一个谁都不像的结果。
import Foundation
import CoreImage

public func medianDouble(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// 参考图 → 目标统计量。返回 (目标, 用了多少张, 离散度)。
/// 离散度 = 参考图各自 vec 到中位目标的距离中位数；越大说明这批参考本身就不是一个风格，
/// 追色结果「平均值感」越强，界面/命令行应当提示换一组更一致的参考。
public func referenceTarget(_ imgs: [CIImage]) -> (target: Stats, used: Int, spread: Double) {
    let stats = imgs.map { measure($0) }
    guard !stats.isEmpty else { return (Stats(), 0, 0) }
    var t = Stats()
    t.p5  = medianDouble(stats.map { $0.p5 })
    t.p25 = medianDouble(stats.map { $0.p25 })
    t.p50 = medianDouble(stats.map { $0.p50 })
    t.p75 = medianDouble(stats.map { $0.p75 })
    t.p95 = medianDouble(stats.map { $0.p95 })
    t.p99 = medianDouble(stats.map { $0.p99 })
    t.q5  = medianDouble(stats.map { $0.q5 })
    t.q50 = medianDouble(stats.map { $0.q50 })
    t.q95 = medianDouble(stats.map { $0.q95 })
    t.sat = medianDouble(stats.map { $0.sat })
    t.warmSh = medianDouble(stats.map { $0.warmSh })
    t.warmHi = medianDouble(stats.map { $0.warmHi })
    let spread = medianDouble(stats.map { $0.distance(to: t) })
    return (t, stats.count, spread)
}

/// 直接解出「一步到位」的参数：源的三级分位点搬到目标的三级分位点。
///
/// 为什么需要它：闭环是**爬坡**，起点离目标太远时几轮根本爬不到——实测原图 q50 0.13 去追
/// q50 0.51 的参考，6 轮后误差反而从 1.74 涨到 1.80，命令行按「原片更接近」放弃套用，
/// 用户看到的就是「追色没反应」。按分布直接算出够近的起点，再让闭环收尾，才是追色该有的做法。
public func paramsFromStats(from s: Stats, to t: Stats) -> Params {
    var p = Params()
    // 1) 色阶：源的黑/白点抬到目标的黑/白点（p5/p95，0~255 原始级）
    let loS = max(0, min(250, s.p5)), hiS = min(255, max(loS + 2, s.p95))
    let loT = max(0, min(250, t.p5)), hiT = min(255, max(loT + 2, t.p95))
    p.levelsIn = [loS, hiS]
    p.levelsOut = [loT, hiT]
    // 2) 中间调用 gamma 补：色阶拉伸后，源中位要落在目标中位上。
    //    render 里是 pow(t, 1/gamma)，所以 g = ln(m_src) / ln(m_dst)。
    let m = (s.p50 - loS) / (hiS - loS)
    let m2 = (t.p50 - loT) / (hiT - loT)
    if m > 0.03, m < 0.97, m2 > 0.03, m2 < 0.97, abs(log(m)) > 1e-6 {
        p.gamma = min(1.6, max(0.55, log(m) / log(m2)))
    }
    // 3) 饱和度按比例（render 里 saturation = 1 - desat/100）
    if s.sat > 1 {
        p.desat = min(80, max(0, (1 - min(1, max(0, t.sat / s.sat))) * 100))
    }
    // 4) 阴影/高光的暖冷差：按 R−B 差值给偏色。
    //    两个换算坑：(a) cbGain=26 → 参数 100 对应 26 级；(b) tint 是「给 R 加、给 B 减」，
    //    同样的参数会把 R−B 拉大**两倍**，所以要除以 2，否则一上手就过冲一倍。
    let k = 100.0 / cbGain / 2
    let dSh = t.warmSh - s.warmSh
    let dHi = t.warmHi - s.warmHi
    p.cbSh = [dSh * k, 0, -dSh * k]
    p.cbHi = [dHi * k, 0, -dHi * k]
    return p
}

/// 追色的完整一步：先按分布直解一个够近的起点，再让闭环收尾。
/// 返回 (参数, 追色后的统计, 追色后误差, 原图误差, 轮数)。命令行与界面共用这一个入口，避免两边各写一套。
public func matchToReference(_ src: CIImage, target: Stats, iterations: Int = 6)
    -> (params: Params, stats: Stats, error: Double, before: Double, rounds: Int) {
    let s0 = measure(src)
    let base = paramsFromStats(from: s0, to: target)
    let (p, st, e, used) = closedLoop(src, base: base, target: target, iterations: iterations)
    return (p, st, e, s0.distance(to: target), used)
}

/// 从一批参考图文件读图（按长边 900 缩放即可：追色只需要分布，不需要全分辨率）
public func loadReferences(_ paths: [String], maxDim: Int = 900) -> [CIImage] {
    paths.compactMap { loadAnyImage($0, maxDim: maxDim) }
}

/// 兜底保护：如果参考图集离散度过大，就砍掉离中位目标最远的那几张再算一次。
/// 一次剔除 1/4 的离群点，至少留 1 张。
public func referenceTargetRobust(_ imgs: [CIImage], maxSpread: Double = 0.25)
    -> (target: Stats, used: Int, spread: Double, dropped: Int) {
    var cur = imgs
    var dropped = 0
    // 样本太少时「剔除离群」没有意义：3 张里剔掉 2 张，剩下的那 1 张就等于随机挑了一张，
    // 还不如老老实实用 3 张的中位数 + 把离散度报给用户。所以 5 张以下只报不剔。
    guard imgs.count >= 5 else {
        let (t, n, sp) = referenceTarget(cur)
        return (t, n, sp, 0)
    }
    for _ in 0..<3 {
        let (t, n, sp) = referenceTarget(cur)
        if sp <= maxSpread || cur.count <= 1 { return (t, n, sp, dropped) }
        let stats = cur.map { measure($0) }
        let keep = stats.count - max(1, stats.count / 4)
        let order = stats.enumerated().sorted { $0.element.distance(to: t) < $1.element.distance(to: t) }
        cur = order.prefix(keep).map { cur[$0.offset] }
        dropped = imgs.count - cur.count
    }
    let (t, n, sp) = referenceTarget(cur)
    return (t, n, sp, dropped)
}

// MARK: - 分区追色（#4：按肤色 / 环境 / 背景 / 人物 分别追）

/// 追色的作用区域。
///
/// 为什么需要分区：一张婚礼照里，"肤色要暖一点"和"背景要冷一点"是两个完全不同的诉求，
/// 全局追色只能把它们平均掉——最后皮肤不够暖、背景又跟着一起被推暖。
/// 分区之后每一块各自朝参考的**同一块**看齐。
public enum ColorRegion: String, CaseIterable {
    case all = "整体"
    case skin = "肤色"
    case person = "人物"
    case background = "背景"
    case environment = "环境"

    /// 该区域对应的蒙版（nil = 整幅 / 该图不适用）
    public func mask(_ img: CIImage) -> CIImage? {
        switch self {
        case .all: return nil
        case .skin:
            // 皮肤：优先按脸解析，没有解析就走肤色检测；都没有就返回 nil（这张图不适用）
            guard let cg = sharedCtx.createCGImage(img, from: img.extent) else { return nil }
            let geos = detectFaceGeos(cg, size: img.extent.size)
            guard !geos.isEmpty else { return nil }
            return geos.count == 1 ? skinMaskForFace(img, face: geos[0]) : skinMaskForFaces(img, geos: geos)
        case .person:
            return personMask(img)
        case .background:
            guard let pm = personMask(img) else { return nil }
            return invertedMask(pm, extent: img.extent)
        case .environment:
            // 环境 = 除皮肤之外的一切（含背景、衣物、天空），用来单独调"环境色"
            guard let cg = sharedCtx.createCGImage(img, from: img.extent) else { return nil }
            let geos = detectFaceGeos(cg, size: img.extent.size)
            guard !geos.isEmpty else { return nil }
            let sk = geos.count == 1 ? skinMaskForFace(img, face: geos[0]) : skinMaskForFaces(img, geos: geos)
            return invertedMask(sk, extent: img.extent)
        }
    }
}

/// 蒙版取反（白↔黑），并保证仍是整幅的一张蒙版
public func invertedMask(_ m: CIImage, extent: CGRect) -> CIImage {
    let white = CIImage(color: .white).cropped(to: extent)
    return m.applyingFilter("CIColorInvert").composited(over: blackMask(extent)).cropped(to: extent)
        .composited(over: white.composited(over: blackMask(extent)))
}

/// 按区域量统计：只统计蒙版内的像素。蒙版不可用（该图没有脸/没有人物）时返回 nil。
public func measureRegion(_ img: CIImage, _ region: ColorRegion) -> Stats? {
    guard let mask = region.mask(img) else {
        return region == .all ? measure(img) : nil
    }
    let cov = maskCoverage(mask, in: img.extent, threshold: 128)
    guard cov > 0.01, cov < 0.98 else { return nil }   // 覆盖太稀/几乎全中 → 这个区域在这张图上不成立
    return measure(img, mask: mask)
}

/// 一批参考图在**同一区域**上的目标统计（中位数聚合）
public func referenceTargetByRegion(_ imgs: [CIImage], region: ColorRegion) -> (target: Stats, used: Int)? {
    let stats = imgs.compactMap { measureRegion($0, region) }
    guard !stats.isEmpty else { return nil }
    var t = Stats()
    t.p5 = medianDouble(stats.map { $0.p5 }); t.p25 = medianDouble(stats.map { $0.p25 })
    t.p50 = medianDouble(stats.map { $0.p50 }); t.p75 = medianDouble(stats.map { $0.p75 })
    t.p95 = medianDouble(stats.map { $0.p95 }); t.p99 = medianDouble(stats.map { $0.p99 })
    t.q5 = medianDouble(stats.map { $0.q5 }); t.q50 = medianDouble(stats.map { $0.q50 })
    t.q95 = medianDouble(stats.map { $0.q95 })
    t.sat = medianDouble(stats.map { $0.sat })
    t.warmSh = medianDouble(stats.map { $0.warmSh }); t.warmHi = medianDouble(stats.map { $0.warmHi })
    return (t, stats.count)
}
