// §365：模型注册表 —— 支撑用户需求「一个功能下挂多个候选，逐个开关，可增可删」。
// 设计（详见账本 §364）：存储改成子目录、注册表记录候选、解析返回被启用者；
// 与偏好开关（samPreferred/laMaPreferred）**正交**：那个管「用不用」，这里管「用哪个」✓。
// 兼容：注册表缺失时 activeDir 返回 nil，调用方回退旧布局（Models/LaMa/ 直接放包）✓。
import Foundation

public struct ModelEntry: Codable, Equatable {
    public var slot: String      // 功能槽：lama / sam …
    public var name: String      // 展示名
    public var dir: String       // 相对 Models 根目录的子目录
    public var enabled: Bool     // 同一 slot 里最多一个为 true
    public init(slot: String, name: String, dir: String, enabled: Bool) {
        self.slot = slot; self.name = name; self.dir = dir; self.enabled = enabled
    }
}

public enum ModelRegistry {
    /// 与现有 LaMa/SAM 的安装根保持一致：Application Support/ContentRetouch/Models
    public static var rootDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("ContentRetouch/Models", isDirectory: true)
    }
    public static var registryURL: URL { rootDir.appendingPathComponent("models.json") }

    /// 读注册表；文件不存在或解析失败一律返回空数组（等价于旧布局 ✓，不抛错 ✗）。
    public static func load() -> [ModelEntry] {
        guard let d = try? Data(contentsOf: registryURL),
              let list = try? JSONDecoder().decode([ModelEntry].self, from: d) else { return [] }
        return list
    }

    /// 写注册表；写入前强制「同 slot 最多一个 enabled」✓（避免出现两个启用项的说不清状态 ✗）。
    @discardableResult
    public static func save(_ list: [ModelEntry]) -> Bool {
        var fixed = list
        var seen = Set<String>()
        for i in fixed.indices where fixed[i].enabled {
            if seen.contains(fixed[i].slot) { fixed[i].enabled = false } else { seen.insert(fixed[i].slot) }
        }
        guard let d = try? JSONEncoder().encode(fixed) else { return false }
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        return (try? d.write(to: registryURL)) != nil
    }

    /// 该功能当前应使用的模型目录。
    /// 没有启用项 / 目录不存在 ⇒ nil ⇒ 调用方回退旧布局 ✓（不静默用错 ✗）。
    public static func activeDir(slot: String) -> URL? {
        guard let e = load().first(where: { $0.slot == slot && $0.enabled }) else { return nil }
        let u = rootDir.appendingPathComponent(e.dir, isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 列出某 slot 的全部候选（供界面列表用 ✓）。
    public static func entries(slot: String) -> [ModelEntry] {
        load().filter { $0.slot == slot }
    }
}

// §369：扫描并登记 —— 用户需求里的「将已经下载的模型加载显示出来」。
// 为什么需要它：列表只读注册表 ⇒ 用户自己下载的候选（例如 big-lama）不写进注册表就看不到 ✗。
// 设计：扫描「Models/<功能名>/」这一层（含旧布局本身）⇒ 幂等登记 ✓，新条目默认 enabled=false ✓。
public extension ModelRegistry {
    /// 该目录里是否含模型包（.mlmodelc / .mlpackage / .mlmodel）。
    static func containsModel(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return false }
        for u in items {
            let ext = u.pathExtension.lowercased()
            if ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel" { return true }
        }
        return false
    }

    /// 扫描某功能的候选目录，返回相对 Models 根的路径（先顶层旧布局，再子目录 ✓）。
    static func scan(slot: String, topLevel: String) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        let top = rootDir.appendingPathComponent(topLevel, isDirectory: true)
        if containsModel(top) { found.append(topLevel) }
        if let subs = try? fm.contentsOfDirectory(at: top, includingPropertiesForKeys: [.isDirectoryKey]) {
            for s in subs {
                let isDir = (try? s.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir, containsModel(s) else { continue }
                found.append(topLevel + "/" + s.lastPathComponent)
            }
        }
        return found
    }

    /// 把扫描结果登记进注册表：已存在的 dir 跳过 ✓（幂等），新加的 enabled=false ✓。返回新增条数。
    @discardableResult
    static func registerScanned(slot: String, topLevel: String) -> Int {
        var list = load()
        var added = 0
        for dir in scan(slot: slot, topLevel: topLevel) {
            if list.contains(where: { $0.slot == slot && $0.dir == dir }) { continue }
            let name = dir.split(separator: "/").last.map(String.init) ?? dir
            list.append(ModelEntry(slot: slot, name: name, dir: dir, enabled: false))
            added += 1
        }
        if added > 0 { _ = save(list) }
        return added
    }
}

