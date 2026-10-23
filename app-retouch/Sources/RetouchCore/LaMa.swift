// LaMaStore + LaMaInpainter：把「生成式修复」做成**可选下载**，不装则退回已有的样例修补
import Foundation
import CoreImage
import CoreML
import Vision

public final class LaMaStore {
    public static let shared = LaMaStore()
    /// 与 SAM 同一套 coreml-zoo 镜像。
    /// ⚠️ §268：原地址写的是 `lama/LaMa.zip`，实测 **HTTP 404**（仓库里真实文件名是 `lama/LaMa.mlpackage.zip`）——
    /// 也就是「下载 LaMa」这个按钮**必然失败**，而当时的注释就写着「我无法在本环境验证该地址」。
    /// 本会话已打通 hf-mirror（**必须带 `-L`**，否则 302 后只有空响应），据此核对并改正为真实文件名。
    public static let defaultURL = "https://hf-mirror.com/mlboydaisuke/coreml-zoo/resolve/main/lama/LaMa.mlpackage.zip"

    public static var installDir: URL {
        // §271：与 ProjectStore 的 CR_PROJECTS_PATH 同一套约定 —— 测试要能把它指到临时目录，
        // 否则「未安装时…」这类断言会依赖**开发机上装没装模型**（§270 就是这么红的）。
        if let p = ProcessInfo.processInfo.environment["CR_LAMA_DIR"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        // §366：先问注册表（用户需求：一个功能下挂多个候选、逐个开关）—— 有启用项就用它 ✓；
        // 没有则回退到旧的固定目录 ⇒ **已发布行为不变** ✓。env 仍最优先（coretest 的
        // 状态无关契约依赖它 ✓，见 §286/§287）。
        if let active = ModelRegistry.activeDir(slot: "lama") { return active }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ContentRetouch/Models/LaMa")
    }

    public var installedModelURL: URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: LaMaStore.installDir,
                                                      includingPropertiesForKeys: nil) else { return nil }
        if let c = items.first(where: { $0.pathExtension == "mlmodelc" }) { return c }
        if let p = items.first(where: { $0.pathExtension == "mlpackage" }) { return p }
        return nil
    }
    public var isInstalled: Bool { installedModelURL != nil }

    public var installedBytes: Int {
        guard let e = FileManager.default.enumerator(at: LaMaStore.installDir,
                                                     includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return total
    }

    public func remove() { try? FileManager.default.removeItem(at: LaMaStore.installDir) }

    public func install(from src: URL, completion: @escaping (Result<String, Error>) -> Void) {
        let fm = FileManager.default
        try? fm.createDirectory(at: LaMaStore.installDir, withIntermediateDirectories: true)
        if src.pathExtension.lowercased() == "zip" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-o", "-q", src.path, "-d", LaMaStore.installDir.path]
            do { try p.run(); p.waitUntilExit() } catch { completion(.failure(error)); return }
            guard p.terminationStatus == 0 else {
                completion(.failure(NSError(domain: "LaMaStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "解压失败（unzip 退出码 " + String(p.terminationStatus) + "）"])))
                return
            }
        } else {
            let dst = LaMaStore.installDir.appendingPathComponent(src.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            do { try fm.copyItem(at: src, to: dst) } catch { completion(.failure(error)); return }
        }
        guard isInstalled else {
            completion(.failure(NSError(domain: "LaMaStore", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "装完没找到 .mlpackage/.mlmodelc（检查压缩包结构）"])))
            return
        }
        LaMaInpainter.shared.reload()
        completion(.success(String(format: "已安装 %.0f MB 到 %@",
                                   Double(installedBytes) / 1_048_576, LaMaStore.installDir.path)))
    }

    public func download(_ urlString: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        let s = (urlString?.isEmpty == false ? urlString! : LaMaStore.defaultURL)
        guard let url = URL(string: s) else {
            completion(.failure(NSError(domain: "LaMaStore", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "下载地址不合法"]))); return
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("LaMa.zip")
        try? FileManager.default.removeItem(at: tmp)
        URLSession.shared.downloadTask(with: url) { loc, _, err in
            if let err {
                DispatchQueue.main.async {
                    let tip = "下载失败：" + err.localizedDescription
                        + "。如果镜像不可用，请用「选择本地模型文件…」安装已下载好的模型。"
                    completion(.failure(NSError(domain: "LaMaStore", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: tip])))
                }
                return
            }
            guard let loc else {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "LaMaStore", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "下载失败（没有临时文件）"]))) }
                return
            }
            try? FileManager.default.moveItem(at: loc, to: tmp)
            DispatchQueue.main.async { self.install(from: tmp, completion: completion) }
        }.resume()
    }
}

/// Core ML 推理：按模型自描述适配输入（不写死输入名）
public final class LaMaInpainter {
    public static let shared = LaMaInpainter()
    private var model: MLModel?
    private var imageKey = ""
    private var maskKey = ""
    private let lock = NSLock()

    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return model != nil }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        model = nil; imageKey = ""; maskKey = ""
        var resolved = LaMaStore.shared.installedModelURL
        // §271：`.mlpackage` 是**源码形态**，Core ML 运行时必须先编译成 `.mlmodelc` 才能 `MLModel(contentsOf:)`。
        // 这正是「装了 216 MB 却 isReady=false」的根因（§270）：下载来的就是 .mlpackage，
        // 而上面 `try?` 把加载失败吞成 nil ⇒ isInstalled=true 与 isReady=false 两个状态不一致 ✗。
        // 这里编译一次并**持久化到安装目录**（编译要几秒，绝不能每次推理都做），
        // 之后 installedModelURL 会直接优先取到 .mlmodelc ✓。
        if let p = resolved, p.pathExtension == "mlpackage" {
            let dst = LaMaStore.installDir.appendingPathComponent(
                p.deletingPathExtension().lastPathComponent + ".mlmodelc")
            if !FileManager.default.fileExists(atPath: dst.path),
               let compiled = try? MLModel.compileModel(at: p) {
                try? FileManager.default.removeItem(at: dst)
                try? FileManager.default.copyItem(at: compiled, to: dst)
            }
            if FileManager.default.fileExists(atPath: dst.path) { resolved = dst }
        }
        guard let u = resolved else { return }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        guard let m = try? MLModel(contentsOf: u, configuration: cfg) else { return }
        for (name, d) in m.modelDescription.inputDescriptionsByName {
            if name.lowercased().contains("mask") { maskKey = name }
            else if d.type == .image || name.lowercased().contains("image") { imageKey = name }
        }
        guard !imageKey.isEmpty else { return }
        model = m
        if ProcessInfo.processInfo.environment["CR_HEALTRACE"] == "1" {
            for (n, d) in m.modelDescription.inputDescriptionsByName {
                FileHandle.standardError.write(("HEALIN " + n + " " + String(describing: d.type.rawValue)).data(using: .utf8)!)
            }
            for (n, d) in m.modelDescription.outputDescriptionsByName {
                FileHandle.standardError.write(("HEALOUT " + n + " " + String(describing: d.type.rawValue)).data(using: .utf8)!)
            }
        }
    }

    public func inpaint(_ src: CIImage, mask: CIImage, hole: CGRect) -> CIImage? {
        if model == nil { reload() }
        lock.lock(); let m = model; let ik = imageKey; let mk = maskKey; lock.unlock()
        guard let m else { return nil }
        // §283：**不要写死 512** —— 实测该 LaMa 模型拒绝 512x512，Core ML 报
        // Image size 512 x 512 not in allowed set of image sizes ⇒ prediction 每次抛错
        // ⇒ inpaint 恒返回 nil ⇒ 祛瑕一路退回样例修补（LaMa 装了却从没起过作用 ✗）。
        // 改成用**模型自己声明的输入尺寸**，这样换任何修补候选都不用改代码 ✓。
        var side: CGFloat = 512
        if let c = m.modelDescription.inputDescriptionsByName[ik]?.imageConstraint {
            side = CGFloat(c.pixelsWide > 0 ? c.pixelsWide : Int(side))
        }
        if ProcessInfo.processInfo.environment["CR_HEALTRACE"] == "1" {
            FileHandle.standardError.write(("HEALSIZE 用 " + String(Int(side)) + " 推理").data(using: .utf8)!)
        }
        let center = CGPoint(x: hole.midX, y: hole.midY)
        var crop = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        crop = crop.intersection(src.extent)
        guard crop.width > 32, crop.height > 32 else { return nil }
        guard let pb = pixelBuffer(src.cropped(to: crop), size: side),
              let mb = pixelBuffer(mask.cropped(to: crop), size: side,
                                   format: kCVPixelFormatType_OneComponent8) else { return nil }
        var input: [String: MLFeatureValue] = [:]
        input[ik] = MLFeatureValue(pixelBuffer: pb)
        if !mk.isEmpty { input[mk] = MLFeatureValue(pixelBuffer: mb) }
        guard let provider = try? MLDictionaryFeatureProvider(dictionary: input) else { return nil }
        let out: MLFeatureProvider
        do {
            out = try m.prediction(from: provider)
        } catch {
            if ProcessInfo.processInfo.environment["CR_HEALTRACE"] == "1" {
                FileHandle.standardError.write(("HEALERR " + String(describing: error)).data(using: .utf8)!)
            }
            return nil
        }
        guard let name = out.featureNames.first(where: { n in
            m.modelDescription.outputDescriptionsByName[n]?.type == .image
        }) ?? out.featureNames.first, let ob = out.featureValue(for: name)?.imageBufferValue else { return nil }
        let outImage = CIImage(cvPixelBuffer: ob)
        let scaled = outImage.transformed(by: CGAffineTransform(scaleX: crop.width / side, y: crop.height / side))
            .transformed(by: CGAffineTransform(translationX: crop.minX, y: crop.minY))
        return scaled.cropped(to: crop)
    }

    // §284：mask 输入要求单通道 OneComponent8（Core ML 报错原文：Image is not expected type
    // OneComponent8, instead is 32BGRA），所以这里必须能按格式建缓冲；图像输入仍是 32BGRA。
    private func pixelBuffer(_ img: CIImage, size: CGFloat,
                             format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size), Int(size),
                            format, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        let scale = min(size / max(1, img.extent.width), size / max(1, img.extent.height))
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        sharedCtx.render(scaled, to: pb, bounds: CGRect(x: 0, y: 0, width: size, height: size),
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pb
    }
}