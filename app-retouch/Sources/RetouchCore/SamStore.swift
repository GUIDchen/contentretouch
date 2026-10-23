// SamStore：把 23 MB 的 SAM 做成「可选下载」而不是打进安装包
//
// 为什么：这个模型值 23 MB，但只有做精细抠图/虚化时才用得上；实测它对「头发丝」这种边界的收益是
// 头发区域覆盖 0.34 → 0.99，可量化，但不是每张图都需要。做成按需下载，安装包就能从 41 MB 回到 18 MB。
//
// 设计要点：
//   · 下载到 Application Support/ContentRetouch/Models/SAM，不放包里；
//   · 带 SHA256 校验（下坏了要能发现，而不是默默用坏模型）；
//   · 下载源可覆盖（CONTENTRETOUCH_SAM_URL）—— 本机走 hf-mirror，别人那里未必通；
//   · 没装模型时**一切照常**：foregroundMaskRefined 自动退回系统前景掩膜。
import Foundation
import CryptoKit



public final class SamStore {
    public static let shared = SamStore()
    public static let defaultURL = "https://hf-mirror.com/mlboydaisuke/coreml-zoo/resolve/main/mobilesam/MobileSAM.zip"
    /// 校验用（2026-09 从 hf-mirror 下的那份；来源见 Models/SAM 说明）
    /// 实测的 SHA256 与字节数（2026-09 从 hf-mirror 下载的那份）
    public static let expectedSHA256 = "0d8d48cb90a48cd860cc3105f54fdeca2a3cb75876a7c936e7243221e3f24681"
    public static let expectedBytes = 20143994

    public static var installDir: URL {
        // §372：先问注册表（多候选槽位 ✓，与 LaMa 同一套机制）—— 有启用项就用它 ✓；
        // 没有则回退旧的固定目录 ⇒ 已发布行为不变 ✓（本机默认没有 models.json ✓）。
        if let active = ModelRegistry.activeDir(slot: "sam") { return active }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ContentRetouch/Models/SAM", isDirectory: true)
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: SamStore.installDir.appendingPathComponent("mobile_sam_encoder.mlpackage").path)
    }

    public var installedBytes: Int64 {
        guard isInstalled else { return 0 }
        let e = FileManager.default.enumerator(at: SamStore.installDir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private var observers: [Timer] = []

    public func remove() {
        try? FileManager.default.removeItem(at: SamStore.installDir)
    }

    /// 下载并安装。progress 回调 0~1（在主线程调用）。
    public func install(url: URL? = nil, progress: @escaping (Double) -> Void,
                        completion: @escaping (Result<String, Error>) -> Void) {
        var src = SamStore.defaultURL
        if let env = ProcessInfo.processInfo.environment["CONTENTRETOUCH_SAM_URL"], !env.isEmpty { src = env }
        if let u = url { src = u.absoluteString }
        guard let u = URL(string: src) else {
            completion(.failure(NSError(domain: "SamStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载地址不合法"])))
            return
        }
        let task = URLSession.shared.downloadTask(with: u) { tmp, _, err in
            if let e = err { completion(.failure(e)); return }
            guard let tmp = tmp else {
                completion(.failure(NSError(domain: "SamStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "下载失败（没有临时文件）"])))
                return
            }
            do {
                let zip = SamStore.installDir.deletingLastPathComponent().appendingPathComponent("MobileSAM.zip")
                try? FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: zip)
                try FileManager.default.moveItem(at: tmp, to: zip)
                // 解压（系统自带 unzip；不想引 zip 库）
                try? FileManager.default.createDirectory(at: SamStore.installDir, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-o", "-q", zip.path, "-d", SamStore.installDir.path]
                try p.run()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    completion(.failure(NSError(domain: "SamStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "解压失败（unzip 退出码 \(p.terminationStatus)）"])))
                    return
                }
                try? FileManager.default.removeItem(at: zip)
                guard self.isInstalled else {
                    completion(.failure(NSError(domain: "SamStore", code: 4, userInfo: [NSLocalizedDescriptionKey: "解压后没找到模型文件"])))
                    return
                }
                SamSegmenter.shared.reset()
                completion(.success("已安装 \(String(format: "%.1f", Double(self.installedBytes) / 1_048_576)) MB 到 \(SamStore.installDir.path)"))
            } catch {
                completion(.failure(error))
            }
        }
        // 进度：轮询（KVO 的 observe(\.fractionCompleted) 在这里推不出泛型，轮询更省事也更稳）
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { t in
            if task.state == .completed || task.state == .canceling {
                t.invalidate()
                return
            }
            let f = task.progress.fractionCompleted
            DispatchQueue.main.async { progress(f) }
        }
        observers.append(timer)
        task.resume()
    }
}
