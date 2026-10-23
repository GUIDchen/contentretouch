// §391：模型商店清单（coreml-zoo 的 models.json）—— 支撑用户需求「第三方模型自动下载」。
// 关键：清单里自带 files[].url（不用猜地址 ✓）与 license.name（许可红线可自动判 ✓）。
// 设计：纯数据结构 + 一个 isShippable 判定；拉取失败一律回落 nil ⇒ 不影响现有行为 ✓。
import Foundation

public struct CatalogFile: Codable, Equatable {
    public var name: String
    public var url: String
}

public struct CatalogLicense: Codable, Equatable {
    public var name: String?
}

public struct CatalogRequirements: Codable, Equatable {
    public var minRamMB: Int?
    enum CodingKeys: String, CodingKey { case minRamMB = "min_ram_mb" }
}

public struct CatalogModel: Codable, Equatable {
    public var id: String
    public var name: String
    public var subtitle: String?
    public var categoryId: String?
    public var descriptionMd: String?
    public var thumbnailUrl: String?
    public var files: [CatalogFile]?
    public var license: CatalogLicense?
    public var requirements: CatalogRequirements?
    enum CodingKeys: String, CodingKey {
        case id, name, subtitle, files, license, requirements
        case categoryId = "category_id"
        case descriptionMd = "description_md"
        case thumbnailUrl = "thumbnail_url"
    }
}

public struct CatalogCategory: Codable, Equatable {
    public var id: String
    public var name: String
    public var icon: String?
    public var order: Int?
}

public struct CatalogManifest: Codable {
    public var manifestVersion: Int?
    public var categories: [CatalogCategory]?
    public var models: [CatalogModel]?
    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case categories, models
    }
}

public enum ModelCatalog {
    /// 镜像上的清单（本会话已验证 hf-mirror 可用；HTTP 需带 -L，但 URLSession 会自动跟随 ✓）。
    public static let defaultURL = "https://hf-mirror.com/mlboydaisuke/coreml-zoo/resolve/main/models.json"

    public static func decode(_ data: Data) -> CatalogManifest? {
        try? JSONDecoder().decode(CatalogManifest.self, from: data)
    }

    /// 拉取并解析；任何失败都返回 nil（界面据此显示"清单不可用"✓，不影响其它功能 ✓）。
    public static func load() -> CatalogManifest? {
        guard let u = URL(string: defaultURL), let d = try? Data(contentsOf: u) else { return nil }
        return decode(d)
    }

    /// 许可把关（红线：查不到或不明 ⇒ 不可入库 ✓）。
    /// 不可入库仍可用于**评测**，但不会进产品默认路径 ✓。
    public static func isShippable(_ m: CatalogModel) -> Bool {
        guard let raw = m.license?.name?.lowercased(), !raw.isEmpty else { return false }
        for bad in ["non-commercial", "noncommercial", "nc", "research", "agpl", "gpl"] {
            if raw.contains(bad) { return false }
        }
        for good in ["apache", "mit", "bsd", "cc by", "cc-by"] {
            if raw.contains(good) { return true }
        }
        return false
    }
}

// §393：从清单安装 —— 目录与注册表之间缺的那一环。
// 流程：取 files[].url（清单自带 ✓，不猜地址 ✓）→ 下载 → 解压到 Models/<槽位>/<id>/
//       → 调 registerScanned 登记（幂等 ✓）。
// 复用：解压沿用 SamStore 的做法（调系统 /usr/bin/unzip ✓，本会话已验证可用 ✓）。
public extension ModelCatalog {
    /// 安装清单里的某个模型。返回展示名（成功）或 nil（失败 ✓，调用方给提示）。
    /// - slot: 功能槽位名（与注册表 slot 对应，例如 faceparse / lama / sam）
    /// - topLevel: Models 下的目录名（例如 FaceParsing / LaMa / SAM）
    @discardableResult
    static func install(_ m: CatalogModel, slot: String, topLevel: String,
                        progress: @escaping (Double) -> Void = { _ in }) -> String? {
        guard let f = m.files?.first, let u = URL(string: f.url) else { return nil }
        let dest = ModelRegistry.rootDir
            .appendingPathComponent(topLevel, isDirectory: true)
            .appendingPathComponent(m.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        progress(0.1)
        // §425（方向 8 下载健壮性）：整包 Data(contentsOf:) 无续传、无重试、无校验 ✗，
        // 而大模型有 200 到 400 MB ⇒ 网络一断就整包重来。改用系统 curl：
        //   -C - 断点续传（.part）｜ --retry 3 重试 ｜ -f 失败即非零 ｜ -L 跟随跳转；
        // 下完再用 unzip -t 做**完整性校验**（比只看大小可靠 ✓），通过后才解压 ✓。
        let zip = dest.appendingPathComponent(f.name)
        let part = dest.appendingPathComponent(f.name + ".part")
        let dl = Process()
        dl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        dl.arguments = ["-L", "-f", "-C", "-", "--retry", "3", "--retry-delay", "2",
                        "-o", part.path, u.absoluteString]
        guard (try? dl.run()) != nil else { return nil }
        dl.waitUntilExit()
        guard dl.terminationStatus == 0, FileManager.default.fileExists(atPath: part.path) else { return nil }
        progress(0.7)
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-t", "-q", part.path]
        guard (try? test.run()) != nil else { return nil }
        test.waitUntilExit()
        guard test.terminationStatus == 0 else { return nil }
        try? FileManager.default.removeItem(at: zip)
        guard (try? FileManager.default.moveItem(at: part, to: zip)) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-o", "-q", zip.path, "-d", dest.path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: zip)
        progress(0.95)
        _ = ModelRegistry.registerScanned(slot: slot, topLevel: topLevel)
        // §443：装完就预热（复用 §434 的槽位推断 ✓），把首载耗时挪到后台，
        // 用户第一次拖上色滑块或点修复时不必等 1.9 到 13 秒 ✓。
        switch ModelCatalog.inferPlacement(m)?.slot {
        case "ddcolor": Colorizer.shared.warmUp()
        case "gfpgan":  Gfpganer.shared.warmUp()
        default: break
        }
        progress(1.0)
        return m.name + "（已登记，默认未启用）"
    }
}


// §434（方向 6）：按清单信息推断该模型该落到哪个功能槽位。
// 原来的界面逻辑是「category == segmentation ⇒ sam，其余 ⇒ faceparse」✗ —— 太粗，
// 会把 gfpgan（restoration）或 ddcolor（enhancement）错归到解析槽位。
// 这里改成：**按 id 与 category 的关键词**判定（可测 ✓，且与许可证把关同处一层 ✓）。
public extension ModelCatalog {
    /// 返回该模型应装入的（功能槽位 slot, Models 下顶层目录名）。
    /// 判不出来就返回 nil ⇒ 界面提示用户手动选择，而不是猜一个错的 ✗。
    static func inferPlacement(_ m: CatalogModel) -> (slot: String, topLevel: String)? {
        let s = ((m.id) + " " + (m.categoryId ?? "")).lowercased()
        if s.contains("gfpgan") || s.contains("restoration") { return ("gfpgan", "GFPGAN") }
        if s.contains("ddcolor") || s.contains("coloriz") { return ("ddcolor", "DDColor") }
        if s.contains("lama") || s.contains("inpaint") { return ("lama", "LaMa") }
        if s.contains("parsing") { return ("faceparse", "FaceParsing") }
        if s.contains("sam") || s.contains("segmentation") { return ("sam", "SAM") }
        if s.contains("face") { return ("faceparse", "FaceParsing") }
        return nil
    }
}

