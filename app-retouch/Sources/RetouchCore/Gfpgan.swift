// §427：GFPGAN（人脸修复，Apache-2.0，可选下载）—— 接口与探针。
// 做法完全沿用 Colorizer 的样板（§402/§407）：
//   1) 从注册表槽位 gfpgan 取目录（装了没装 与 用不用 分开 ✓）
//   2) .mlpackage 先编译成 .mlmodelc，输入尺寸按模型声明（不写死 ✓）
//   3) **先打印模型的真实 I/O 描述**（§407 的教训：猜形态会白跑 ✗）
//   4) 支持图像进出；若模型是多数组形态，探针会打印出来，下一轮据此适配 ✓
import Foundation
import CoreImage
import CoreML

public final class Gfpganer {
    public static let shared = Gfpganer()
    private let lock = NSLock()
    private var model: MLModel?
    private var inputKey = ""
    private var outputKey = ""
    private var side: CGFloat = 512

    public static func installedDir() -> URL? {
        guard let e = ModelRegistry.load().first(where: { $0.slot == "gfpgan" }) else { return nil }
        let u = ModelRegistry.rootDir.appendingPathComponent(e.dir, isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    public static func modelDir() -> URL? { ModelRegistry.activeDir(slot: "gfpgan") }
    public var isAvailable: Bool { Gfpganer.installedDir() != nil }
    public var isEnabled: Bool { Gfpganer.modelDir() != nil }
    private var trace: Bool { ProcessInfo.processInfo.environment["CR_GFPGAN"] == "1" }
    private func say(_ s: String) { if trace { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

    private func loadIfNeeded() {
        lock.lock(); let loaded = model != nil; lock.unlock()
        if loaded { return }
        guard let dir = Gfpganer.installedDir(),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
              var resolved = items.first(where: { ["mlmodelc", "mlpackage"].contains($0.pathExtension.lowercased()) })
        else { say("GFPGAN 找不到模型目录或包"); return }
        if resolved.pathExtension.lowercased() == "mlpackage", let compiled = try? MLModel.compileModel(at: resolved) {
            let dst = dir.appendingPathComponent(compiled.lastPathComponent)
            try? FileManager.default.removeItem(at: dst); try? FileManager.default.copyItem(at: compiled, to: dst)
            if FileManager.default.fileExists(atPath: dst.path) { resolved = dst }
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        guard let m = try? MLModel(contentsOf: resolved, configuration: cfg) else { say("GFPGAN 载入失败"); return }
        say("GFPGAN 载入 " + resolved.lastPathComponent)
        for (n, d) in m.modelDescription.inputDescriptionsByName {
            let img = d.imageConstraint.map { "图像 " + String($0.pixelsWide) + "x" + String($0.pixelsHigh) } ?? ""
            let arr = d.multiArrayConstraint?.shape.map { String($0.intValue) }.joined(separator: "x") ?? ""
            say("GFPGAN 输入 " + n + " 类型 " + String(describing: d.type.rawValue) + " " + (img.isEmpty ? arr : img))
        }
        for (n, d) in m.modelDescription.outputDescriptionsByName {
            let img = d.imageConstraint.map { "图像 " + String($0.pixelsWide) + "x" + String($0.pixelsHigh) } ?? ""
            let arr = d.multiArrayConstraint?.shape.map { String($0.intValue) }.joined(separator: "x") ?? ""
            say("GFPGAN 输出 " + n + " 类型 " + String(describing: d.type.rawValue) + " " + (img.isEmpty ? arr : img))
        }
        var ik = "", ok = ""
        for (n, d) in m.modelDescription.inputDescriptionsByName where d.type == .image {
            ik = n; if let c = d.imageConstraint { side = CGFloat(c.pixelsWide) }
        }
        for (n, d) in m.modelDescription.outputDescriptionsByName where d.type == .image { ok = n }
        guard !ik.isEmpty, !ok.isEmpty else { say("GFPGAN 不是图像进出 ⇒ 需按探针输出另行适配"); return }
        lock.lock(); model = m; inputKey = ik; outputKey = ok; lock.unlock()
    }

    /// 修复；模型不可用或形态不符时返回 nil（调用方保持原图 ✓）。
    public func restore(_ src: CIImage) -> CIImage? {
        loadIfNeeded()
        lock.lock(); let m = model; let ik = inputKey; let ok = outputKey; let n = Int(side); lock.unlock()
        guard let m else { return nil }
        let e = src.extent
        let scale = CGFloat(n) / max(1, max(e.width, e.height))
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let pb = pixelBuffer(small, size: CGFloat(n)) else { return nil }
        let t0 = Date()
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: [ik: MLFeatureValue(pixelBuffer: pb)]) else { return nil }
        let out: MLFeatureProvider
        do { out = try m.prediction(from: provider) } catch { say("GFPGAN 推理失败: " + String(describing: error)); return nil }
        let ms = Date().timeIntervalSince(t0) * 1000
        guard let ob = out.featureValue(for: ok)?.imageBufferValue else { say("GFPGAN 取不到 " + ok); return nil }
        say("GFPGAN 完成 模型 " + String(n) + "x" + String(n) + " ｜ 耗时 " + String(format: "%.0f", ms) + " ms")
        let up = CIImage(cvPixelBuffer: ob).transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        return up.cropped(to: e)
    }

    private func pixelBuffer(_ img: CIImage, size: CGFloat) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size), Int(size),
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        let e = img.extent
        let s = min(size / max(1, e.width), size / max(1, e.height))
        let scaled = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: (size - e.width * s) / 2, y: (size - e.height * s) / 2))
        sharedCtx.render(scaled, to: pb, bounds: CGRect(x: 0, y: 0, width: size, height: size),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pb
    }

    /// §443：同上（GFPGAN 首载约 11 秒 ⇒ 装完预热 ✓）。
    public func warmUp() { loadIfNeeded() }
}
