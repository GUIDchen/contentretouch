// CoreIO.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

public struct Stats: Codable {
    public var p5 = 0.0, p25 = 0.0, p50 = 0.0, p75 = 0.0, p95 = 0.0, p99 = 0.0
    public var sat = 0.0, warmSh = 0.0, warmHi = 0.0
    public var q5 = 0.0, q50 = 0.0, q95 = 0.0
    public init() {}
    public var vec: [Double] { [q5, q50, q95, sat / 100.0, warmSh / 30.0, warmHi / 30.0] }
    public func distance(to o: Stats) -> Double {
        let a = vec, b = o.vec
        var s = 0.0
        for i in 0..<min(a.count, b.count) { s += (a[i] - b[i]) * (a[i] - b[i]) }
        return s.squareRoot()
    }
}

/// 统一读图入口：用 ImageIO 读进一张**显式 sRGB 标签**的位图再交给 Core Image。
/// 内嵌 P3/AdobeRGB 的图会被 Core Graphics 正确转换到 sRGB；没有剖面的按 sRGB 解释。
public func loadImage(_ path: String) -> CIImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // ⚠️ 位深要跟着源片走：界面文案写着「16bit AI Raw 引擎」、导出也提供 16 位 TIFF/PNG，
    // 但这里以前**写死 8 位** —— 于是"导进 16bit、导出 16bit"中间被悄悄压成 8 位。
    // 实测（2026-09-26）：512px 宽的 16 位灰阶渐变（65536 级）经这里只剩 **183 个不同取值**，
    // 强调整后会在天空这类渐变上变成可见台阶。coretest 第 6h2 节盯着这件事。
    let deep = cg.bitsPerComponent > 8
    let bpc = deep ? 16 : 8
    let bmi = deep ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                              bitsPerComponent: bpc, bytesPerRow: 0, space: space,
                              bitmapInfo: bmi) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let out = ctx.makeImage() else { return nil }
    // ⚠️ EXIF 方向必须在这里应用。`CGImageSourceCreateImageAtIndex` **不会**替你转像素，
    // 而本仓库另外两条读图路（缩略图条、导出小图）都带了 kCGImageSourceCreateThumbnailWithTransform ——
    // 于是出现"缩略图条是正的、预览与导出却是躺倒的"这种自相矛盾。
    // 2026-09-26 实测（400x200 的图 + 方向 6）：导出的像素仍是 400x200，且方向被写成 1 ——
    // 等于把手机竖拍的照片**永久转躺**。手机照片里方向 3/6/8 极常见，所以这不是边角情况。
    let orient = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let img = CIImage(cgImage: out)
    return orient == 1 ? img : img.oriented(forExifOrientation: Int32(orient))
}

/// 读**带透明通道**的素材（水印 LOGO 这类）。
///
/// ⚠️ **它的来历要说清楚**（§181 更正）：当初加它是因为"透明 LOGO 叠成了黑板"这个观察 ——
/// 而那个观察**是错的**（错在夹具：magick 的"灰度"没生成灰度图，读数被我误读成了黑块）。
/// 突变测试把这一行换回 `loadImage` 后重新编译：两次导出只差 **510 个像素**（羽化边），透明区正常。
///
/// 那它为什么还留着？因为它把**意图**写明白了：照片走 `loadImage`（不透明、不需要 alpha），
/// 素材走这条（保 alpha、位深跟着源片走）。两者对 8 位 PNG 的实际效果几乎一样，
/// 但"几乎一样"不该成为把两类素材塞进同一条路线的理由。
/// 判据留在导出门（"透明区不许变黑块"）与 coretest 第 6i 节。
public func loadImageWithAlpha(_ path: String) -> CIImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let space = cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let bpc = cg.bitsPerComponent > 8 ? 16 : 8
    guard let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: bpc,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    guard let out = ctx.makeImage() else { return nil }
    let img = CIImage(cgImage: out)
    let orient = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32 ?? 1
    return orient == 1 ? img : img.oriented(forExifOrientation: Int32(orient))
}

/// 降采样读图：界面预览与交互式参数调整用（全分辨率留给导出/批量）。
/// 这是「滑杆一拖就卡」的根因修法：整条链路的 Vision 请求与 Core Image 渲染量都随像素数平方增长。
public func loadImage(_ path: String, maxDim: Int) -> CIImage? {
    // 预览路径：先查解码缓存（webp 解码 82ms/张，且换路径没用——见 DecodeCache 里的说明）
    if maxDim > 0 {
        return DecodeCache.shared.image(path, maxDim: maxDim) { loadImageUncached(path, maxDim: maxDim) }
    }
    return loadImageUncached(path, maxDim: maxDim)
}

/// 不走缓存的解码（供缓存回填/内部调用）
public func loadImageUncached(_ path: String, maxDim: Int) -> CIImage? {
    guard let full = loadImage(path) else { return nil }
    guard maxDim > 0 else { return full }
    let m = max(full.extent.width, full.extent.height)
    guard m > CGFloat(maxDim) else { return full }
    let s = CGFloat(maxDim) / m
    let scaled = full.transformed(by: CGAffineTransform(scaleX: s, y: s))
    let w = (scaled.extent.width).rounded(.down), h = (scaled.extent.height).rounded(.down)
    return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

/// 量一张图：分位亮度、饱和度、阴影/高光暖冷，并算出与曝光无关的形状量 q5/q50/q95
/// - Parameter mask: 只统计蒙版内（>128）的像素。供分区追色用：肤色/人物/背景各自量各自的分布。
public func measure(_ img: CIImage, mask: CIImage? = nil, work: Int = 256) -> Stats {
    // 先把图挪到原点：裁剪过的图 extent.origin 不为 0，直接按 0 起点渲染会得到全黑（实测踩到）
    let normalized = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    let scale = Double(work) / max(normalized.extent.width, normalized.extent.height)
    let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    // 色彩空间必须与 write() 完全一致：之前这里用 deviceRGB、写盘用 sRGB，
    // 结果「量的」和「写的」不是同一个渲染，成片整体比原图亮 ~13 级（实测踩到）。
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    // 蒙版（可选）：只统计蒙版内的像素。分区追色靠它把"皮肤"和"背景"分开量。
    var keep = [Bool](repeating: true, count: w * h)
    if let mask {
        let mSmall = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var mbuf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(mSmall, toBitmap: &mbuf, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for i in 0..<(w * h) { keep[i] = mbuf[i * 4] > 128 }
    }
    var hist = [Int](repeating: 0, count: 256)
    var satSum = 0.0
    let n = w * h
    var counted = 0
    var lums = [Double](repeating: 0, count: n)
    for i in 0..<n {
        let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
        lums[i] = l
        guard keep[i] else { continue }
        counted += 1
        hist[Int(max(0, min(255, l)))] += 1
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        satSum += mx <= 0 ? 0 : (mx - mn) / mx
    }
    // 统计口径：分位数用**被保留的像素数**做分母（原来是整幅的像素数）
    let total = max(1, counted)
    _ =  n
    func pct(_ q: Double) -> Double {
        var acc = 0
        for v in 0..<256 { acc += hist[v]; if Double(acc) >= Double(total) * q { return Double(v) } }
        return 255
    }
    let p1 = pct(0.01), p5 = pct(0.05), p25 = pct(0.25), p50 = pct(0.5), p75 = pct(0.75), p95 = pct(0.95), p99 = pct(0.99)
    var shR = 0.0, shB = 0.0, shN = 0.0, hiR = 0.0, hiB = 0.0, hiN = 0.0
    for i in 0..<n {
        let r = Double(buf[i * 4]), b = Double(buf[i * 4 + 2])
        if lums[i] < p25 { shR += r; shB += b; shN += 1 }
        if lums[i] >= p75 { hiR += r; hiB += b; hiN += 1 }
    }
    var s = Stats()
    s.p5 = p5; s.p25 = p25; s.p50 = p50; s.p75 = p75; s.p95 = p95; s.p99 = p99
    s.sat = satSum / Double(total) * 100
    s.warmSh = shN > 0 ? (shR - shB) / shN : 0
    s.warmHi = hiN > 0 ? (hiR - hiB) / hiN : 0
    let span = max(1.0, p99 - p1)
    s.q5 = (p5 - p1) / span; s.q50 = (p50 - p1) / span; s.q95 = (p95 - p1) / span
    return s
}

public struct StylePreset {
    public var index: Int
    public var name: String
    public var target: Stats
    public var params: Params
    public init(index: Int, name: String, target: Stats, params: Params) {
        self.index = index; self.name = name; self.target = target; self.params = params
    }
}

public func loadStyles(_ path: String) throws -> [StylePreset] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    let clusters = (json["clusters"] as? [[String: Any]]) ?? []
    func d(_ v: Any?) -> Double { (v as? Double) ?? Double(v as? Int ?? 0) }
    func arr(_ v: Any?) -> [Double] {
        if let a = v as? [Double] { return a }
        if let a = v as? [Int] { return a.map(Double.init) }
        return [0, 0, 0]
    }
    return clusters.compactMap { c in
        guard let center = c["center"] as? [String: Any], let base = c["params"] as? [String: Any] else { return nil }
        var t = Stats()
        t.q5 = d(center["q5"]); t.q50 = d(center["q50"]); t.q95 = d(center["q95"])
        t.sat = d(center["sat"]) * 100
        t.warmSh = d(center["warm_sh"]); t.warmHi = d(center["warm_hi"])
        t.p5 = d(center["lift"]); t.p50 = d(center["p50"])
        var p = Params()
        p.levelsIn = arr(base["levelsIn"]); p.levelsOut = arr(base["levelsOut"])
        p.gamma = d(base["gamma"]); p.contrast = d(base["contrast"]); p.desat = d(base["desat"])
        p.cbSh = arr(base["cbShadow"]); p.cbMid = arr(base["cbMid"]); p.cbHi = arr(base["cbHigh"])
        return StylePreset(index: (c["index"] as? Int) ?? 0, name: (c["name"] as? String) ?? "?", target: t, params: p)
    }
}

public struct IndexEntry {
    public var file: String
    public var group: String
    public var vector: [Float]
}

public func loadIndex(_ path: String) -> [IndexEntry] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [IndexEntry] = []
    for line in text.split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let f = o["f"] as? String, let b64 = o["fp"] as? String,
              let raw = Data(base64Encoded: b64) else { continue }
        var v = [Float](repeating: 0, count: raw.count / 4)
        _ = v.withUnsafeMutableBytes { raw.copyBytes(to: $0) }
        let parts = f.split(separator: "_")
        out.append(IndexEntry(file: f, group: parts.count >= 2 ? String(parts[1]) : f, vector: v))
    }
    return out
}

public func featurePrint(_ path: String) -> [Float]? {
    guard let full = loadImage(path) else { return nil }
    let scale = min(1.0, 768.0 / max(full.extent.width, full.extent.height))
    let ci = scale < 1.0 ? full.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : full
    guard let cg = sharedCtx.createCGImage(ci, from: ci.extent) else { return nil }
    let req = VNGenerateImageFeaturePrintRequest()
    do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { return nil }
    guard let fp = req.results?.first as? VNFeaturePrintObservation else { return nil }
    var v = [Float](repeating: 0, count: fp.elementCount)
    fp.data.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Float.self)
        for i in 0..<min(fp.elementCount, p.count) { v[i] = p[i] }
    }
    return v
}

/// 一组参考图（同一场拍摄）
public struct RefGroup {
    public var noteId: String
    public var files: [(file: String, distance: Float)]
    public var best: Float { files.first?.distance ?? 0 }
}

/// 按作品聚组推荐（M4a 的逻辑）
public func recommend(query: [Float], index: [IndexEntry], groups: Int = 3, perGroup: Int = 6) -> [RefGroup] {
    var rows: [(String, String, Float)] = []
    for e in index where e.vector.count == query.count {
        var s: Float = 0
        for i in 0..<query.count { let d = e.vector[i] - query[i]; s += d * d }
        rows.append((e.file, e.group, s.squareRoot()))
    }
    rows.sort { $0.2 < $1.2 }
    var out: [RefGroup] = []
    var seen = Set<String>()
    for r in rows where !seen.contains(r.1) {
        seen.insert(r.1)
        let members = rows.filter { $0.1 == r.1 }.prefix(perGroup).map { (file: $0.0, distance: $0.2) }
        out.append(RefGroup(noteId: r.1, files: Array(members)))
        if out.count >= groups { break }
    }
    return out
}
