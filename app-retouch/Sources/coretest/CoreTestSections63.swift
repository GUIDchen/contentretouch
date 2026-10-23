// §367：多模型注册表的四条断言（互斥 / 回退 / 不静默用错 / 与偏好开关正交）。
// 为什么要测它：用户要的「多候选 + 逐个开关」全靠这层解析 ✓，它错了界面再好看也没用 ✗。
import Foundation
import RetouchCore

func runSections63() {
    head("63. 多模型注册表：互斥 / 回退 / 与偏好开关正交")
    let reg = ModelRegistry.registryURL
    let backup = try? Data(contentsOf: reg)
    defer {
        if let b = backup { try? b.write(to: reg) } else { try? FileManager.default.removeItem(at: reg) }
    }
    try? FileManager.default.removeItem(at: reg)
    check("注册表缺失 ⇒ activeDir 返回 nil（调用方回退旧布局）",
          ModelRegistry.activeDir(slot: "lama") == nil, "返回 nil ✓")
    let dirURL = ModelRegistry.rootDir.appendingPathComponent("T_multi", isDirectory: true)
    try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
    _ = ModelRegistry.save([ModelEntry(slot: "lama", name: "A", dir: "T_multi", enabled: true),
                            ModelEntry(slot: "lama", name: "B", dir: "T_multi", enabled: true)])
    let nTrue = ModelRegistry.load().filter { $0.slot == "lama" && $0.enabled }.count
    check("enabled 互斥：两个都写 true ⇒ 只保留一个", nTrue == 1, "启用数 = " + String(nTrue))
    check("activeDir 返回被启用且真实存在的目录", ModelRegistry.activeDir(slot: "lama") != nil, "非 nil ✓")
    _ = ModelRegistry.save([ModelEntry(slot: "lama", name: "A", dir: "T_missing", enabled: true)])
    check("启用项目录不存在 ⇒ 返回 nil（不静默用错）",
          ModelRegistry.activeDir(slot: "lama") == nil, "返回 nil ✓")
    UserDefaults.standard.removeObject(forKey: "model_use_lama")
    unsetenv("CR_LAMA_PREFER")
    check("正交：注册表里有启用项，偏好开关仍为默认关",
          !laMaPreferred(), "laMaPreferred = " + String(laMaPreferred()))
    try? FileManager.default.removeItem(at: dirURL)
    try? FileManager.default.removeItem(at: reg)
}
