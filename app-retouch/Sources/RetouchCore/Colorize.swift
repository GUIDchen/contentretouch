// §408：上色（DDColor Tiny，Apache-2.0）—— 按 §407 查明的真实形态实现：
//   输入 image        MultiArray 1x3x512x512（RGB，0 到 1）
//   输出 ab_channels  MultiArray 1x2x512x512（Lab 的 a、b，量纲按 -1 到 1 近似 ✓）
// 合成：用输入的 L（灰度归一化）与 a、b 做 Lab→sRGB，再按比例放回原图 ✓。
// 说明：a、b 的量纲是**近似假设**（多种 DDColor 导出把 ab 映射到 -1 到 1）⇒
//      若颜色偏淡或溢出，调 abScale 即可（探针会打印 ab 的实际范围 ✓）。
import Foundation
import CoreImage
import CoreML

public final class Colorizer {
    public static let shared = Colorizer()
    private let lock = NSLock()
    private var model: MLModel?
    private var inputKey = ""
    private var outputKey = ""
    private var side = 512
    // §409：反推量纲 —— 实测原始值范围约 -55 到 94（把打印的 -7089…12024 除以旧的 128 得到）✓，
    // 而这正是真实 Lab 的 a、b 数量级（约 ±100）⇒ 模型输出的**就是** Lab 的 a、b ⇒ 缩放应为 1 ✓。
    private var abScale: Float = 1

    public static func installedDir() -> URL? {
        guard let e = ModelRegistry.load().first(where: { $0.slot == "ddcolor" }) else { return nil }
        let u = ModelRegistry.rootDir.appendingPathComponent(e.dir, isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    public static func modelDir() -> URL? { ModelRegistry.activeDir(slot: "ddcolor") }
    public var isAvailable: Bool { Colorizer.installedDir() != nil }
    public var isEnabled: Bool { Colorizer.modelDir() != nil }
    private var trace: Bool { ProcessInfo.processInfo.environment["CR_COLORIZE"] == "1" }
    private func say(_ s: String) { if trace { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

    private func loadIfNeeded() {
        lock.lock(); let loaded = model != nil; lock.unlock()
        if loaded { return }
        guard let dir = Colorizer.installedDir(),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              var resolved = items.first(where: { ["mlmodelc", "mlpackage"].contains($0.pathExtension.lowercased()) })
        else { say("COLORIZE 找不到模型目录或包"); return }
        if resolved.pathExtension.lowercased() == "mlpackage", let compiled = try? MLModel.compileModel(at: resolved) {
            let dst = dir.appendingPathComponent(compiled.lastPathComponent)
            try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: compiled, to: dst)
            if FileManager.default.fileExists(atPath: dst.path) { resolved = dst }
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        guard let m = try? MLModel(contentsOf: resolved, configuration: cfg) else { say("COLORIZE 载入失败"); return }
        var ik = "", ok = ""
        for (n, d) in m.modelDescription.inputDescriptionsByName where d.type == .multiArray || d.type == .image { ik = n }
        for (n, d) in m.modelDescription.outputDescriptionsByName where d.type == .multiArray || d.type == .image { ok = n }
        say("COLORIZE 输入=" + ik + " 输出=" + ok)
        guard !ik.isEmpty, !ok.isEmpty else { return }
        lock.lock(); model = m; inputKey = ik; outputKey = ok; lock.unlock()
    }

    /// 上色；模型不可用或形态不符时返回 nil（调用方保持原图 ✓）。
    public func colorize(_ src: CIImage) -> CIImage? {
        loadIfNeeded()
        lock.lock(); let m = model; let ik = inputKey; let ok = outputKey; let n = Int(side); lock.unlock()
        guard let m else { return nil }
        let e = src.extent
        let scale = CGFloat(n) / max(1, max(e.width, e.height))
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let px = rgba(small, side: CGFloat(n)) else { return nil }   // 512x512 RGBA8
        // 1) 组 RGB 的 CHW MultiArray（0 到 1）
        guard let input = try? MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32) else { return nil }
        _ = m
        for y in 0..<n { for x in 0..<n {
            let i = (y * n + x) * 4
            let r = Float(px[i]) / 255, g = Float(px[i+1]) / 255, b = Float(px[i+2]) / 255
            input[[0, 0, y, x] as [NSNumber]] = NSNumber(value: r)
            input[[0, 1, y, x] as [NSNumber]] = NSNumber(value: g)
            input[[0, 2, y, x] as [NSNumber]] = NSNumber(value: b)
        } }
        let t0 = Date()
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [ik: MLFeatureValue(multiArray: input)]) else { return nil }
        let out: MLFeatureProvider
        do { out = try m.prediction(from: provider) } catch { say("COLORIZE 推理失败: " + String(describing: error)); return nil }
        guard let ab = out.featureValue(for: ok)?.multiArrayValue else { say("COLORIZE 取不到 " + ok); return nil }
        let ms = Date().timeIntervalSince(t0) * 1000
        // 2) 用 L 与 a、b 合成（Lab→sRGB），写进 RGBA8 缓冲
        var minAB: Float = 9, maxAB: Float = -9
        var out8 = [UInt8](repeating: 255, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let i = (y * n + x) * 4
            let r = Float(px[i]) / 255, g = Float(px[i+1]) / 255, b = Float(px[i+2]) / 255
            // sRGB → 线性 → XYZ → Lab 的 L（只需 L ✓）
            func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            let Y = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
            let fy = Y > 0.008856 ? pow(Y, 1.0 / 3.0) : (7.787 * Y + 16.0 / 116.0)
            let L = 116 * fy - 16
            let a = Float(truncating: ab[[0, 0, y, x] as [NSNumber]]) * abScale
            let bb = Float(truncating: ab[[0, 1, y, x] as [NSNumber]]) * abScale
            minAB = min(minAB, min(a, bb)); maxAB = max(maxAB, max(a, bb))
            // Lab → sRGB（D65）
            let fy2 = (L + 16) / 116, fx = fy2 + a / 500, fz = fy2 - bb / 200
            func inv(_ t: Float) -> Float { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16.0 / 116.0) / 7.787 }
            let X = 0.95047 * inv(fx), Y2 = Y, Z = 1.08883 * inv(fz)
            var rr = 3.2406 * X - 1.5372 * Y2 - 0.4986 * Z
            var gg = -0.9689 * X + 1.8758 * Y2 + 0.0415 * Z
            var bl = 0.0557 * X - 0.2040 * Y2 + 1.0570 * Z
            func gam(_ c: Float) -> Float { let v = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(0, c), 1 / 2.4) - 0.055; return min(1, max(0, v)) }
            rr = gam(rr); gg = gam(gg); bl = gam(bl)
            out8[i] = UInt8(rr * 255); out8[i+1] = UInt8(gg * 255); out8[i+2] = UInt8(bl * 255)
        } }
        say("COLORIZE 完成 模型 " + String(n) + "x" + String(n) + " ｜ 耗时 " + String(format: "%.0f", ms) + " ms ｜ ab 范围 " + String(format: "%.2f", minAB) + " 到 " + String(format: "%.2f", maxAB))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let dp = CGDataProvider(data: Data(out8) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: dp, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let up = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        return up.cropped(to: e)
    }

    private func rgba(_ img: CIImage, side n: CGFloat) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: Int(n) * Int(n) * 4)
        let e = img.extent
        let s = min(n / max(1, e.width), n / max(1, e.height))
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: Int(n) * 4,
                         bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }

    /// §443（方向 5 后半）：预热加载 —— 装完模型后调一次，
    /// 把首载（1.9 到 13 秒，含编译缓存检查与 ANE 预热）挪到后台，用户拖滑块时只剩推理的 400 ms ✓。
    public func warmUp() { loadIfNeeded() }
}
