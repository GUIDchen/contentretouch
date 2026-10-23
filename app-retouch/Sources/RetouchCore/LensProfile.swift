// LensProfile：镜头配置文件（**不内置数据库**，由用户放入自己的配置）
//
// 为什么这样做：镜头数据库要么内置几十 MB 的厂商数据（授权有问题），要么得联网查。
// 而相机自己就会在 RAW/JPEG 里写镜头型号（实测用户的 CR3 写着「50mm F1.4 DG HSM | Art 014」），
// 所以做成：**用户放配置 → 按 EXIF 镜头型号自动匹配 → 套用畸变/暗角/色差校正**。
//
// 配置放这里：~/Library/Application Support/ContentRetouch/LensProfiles/*.json
// 格式见 README（每个文件一个镜头，字段与正确的校正函数一一对应）。
import Foundation
import CoreImage
import ImageIO

public struct LensProfile: Codable {
    public var name: String              // 显示名，如 "Sigma 50mm F1.4 DG HSM Art"
    public var match: [String]           // 匹配关键词（对 EXIF LensModel 做包含匹配，不区分大小写）
    public var distortion = 0.0          // 畸变校正量 -100~100（正 = 桶形校正）
    public var vignette = 0.0            // 暗角校正量 0~100
    public var chromaticAberration = 0.0 // 横向色差校正量 -100~100
    public var note = ""                 // 备注（比如「本机实测」/「抄自厂商白皮书」）
    public init(name: String, match: [String], distortion: Double = 0, vignette: Double = 0,
                chromaticAberration: Double = 0, note: String = "") {
        self.name = name; self.match = match
        self.distortion = distortion; self.vignette = vignette
        self.chromaticAberration = chromaticAberration; self.note = note
    }
}

public final class LensProfileStore {
    public static let shared = LensProfileStore()
    private var cache: [LensProfile]?
    private let lock = NSLock()

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("ContentRetouch/LensProfiles", isDirectory: true)
    }

    /// 目录里还能通过环境变量覆盖（CI / 命令行测试用）
    public static var searchDirs: [URL] {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CONTENTRETOUCH_LENS_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env))
        }
        dirs.append(directory)
        // 工作目录与可执行文件位置**都往上找几级**：coretest 从 app-retouch/ 跑、命令行从仓库根跑，
        // 只查「当前目录/lens_profiles」会让其中一条路径找不到（实测 coretest 里就匹配不到）。
        var roots: [URL] = []
        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<4 {
            roots.append(cwd)
            let parent = cwd.deletingLastPathComponent()
            if parent.path == cwd.path { break }
            cwd = parent
        }
        var exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<4 {
            roots.append(exe)
            let parent = exe.deletingLastPathComponent()
            if parent.path == exe.path { break }
            exe = parent
        }
        for r in roots {
            let cand = r.appendingPathComponent("lens_profiles")
            if !dirs.contains(cand) { dirs.append(cand) }
        }
        return dirs
    }

    public func profiles() -> [LensProfile] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var out: [LensProfile] = []
        for dir in LensProfileStore.searchDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension.lowercased() == "json" {
                guard let d = try? Data(contentsOf: f),
                      let p = try? JSONDecoder().decode(LensProfile.self, from: d) else { continue }
                out.append(p)
            }
        }
        cache = out
        return out
    }

    public func reload() {
        lock.lock(); cache = nil; lock.unlock()
    }

    /// 按 EXIF 镜头型号匹配（包含匹配，取命中最长关键词的那个 —— 越具体越优先）
    public func match(_ lensModel: String) -> LensProfile? {
        guard !lensModel.isEmpty else { return nil }
        let hay = lensModel.lowercased()
        var best: (LensProfile, Int)?
        for p in profiles() {
            for k in p.match {
                let key = k.lowercased()
                if hay.contains(key) && key.count > (best?.1 ?? 0) {
                    best = (p, key.count)
                }
            }
        }
        return best?.0
    }
}

/// 从文件读 EXIF 镜头型号（RAW 与 JPEG 都在 EXIF/TIFF 里写，取值路径不同）
public func readLensModel(_ path: String) -> String {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return "" }
    if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
       let m = exif[kCGImagePropertyExifLensModel] as? String, !m.isEmpty {
        return m
    }
    if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
       let m = tiff[kCGImagePropertyTIFFModel] as? String, !m.isEmpty {
        return m
    }
    return ""
}

/// 按 EXIF 自动套用镜头校正。返回 (结果, 命中的配置名) —— 没命中就原样返回。
public func autoLensCorrect(_ src: CIImage, path: String) -> (image: CIImage, profile: String) {
    let model = readLensModel(path)
    guard let p = LensProfileStore.shared.match(model) else { return (src, "") }
    var out = src
    if abs(p.distortion) > 0.01 { out = correctLensDistortion(out, amount: p.distortion) }
    if p.vignette > 0.01 { out = correctVignetting(out, amount: p.vignette) }
    if abs(p.chromaticAberration) > 0.01 { out = correctChromaticAberration(out, amount: p.chromaticAberration) }
    return (out, p.name)
}
