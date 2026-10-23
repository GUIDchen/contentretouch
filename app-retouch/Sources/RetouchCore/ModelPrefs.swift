// §354：模型开关的**可测**门控 —— 从内联表达式抽成纯函数，好让 coretest 直接验证「开关真的被读到」。
// 优先级：环境变量 > 界面开关（@AppStorage 写的同一 UserDefaults 键）。
// 为什么 env 优先：coretest 的「状态无关」契约（§286/§287）依赖它 ✓，不能被 UI 开关覆盖 ✗。
import Foundation

/// SAM（精细分割 / 智能消除圈选）是否启用。默认**开**（§315 由正结果翻默认 ✓）。
public func samPreferred() -> Bool {
    if let v = ProcessInfo.processInfo.environment["CR_HEAL_SAM"], v == "0" { return false }
    if UserDefaults.standard.object(forKey: "model_use_sam") == nil { return true }
    return UserDefaults.standard.bool(forKey: "model_use_sam")
}

/// LaMa（生成式修补）是否启用。默认**关**（§289 由负结果撤回优先 ✓）。
public func laMaPreferred() -> Bool {
    if ProcessInfo.processInfo.environment["CR_LAMA_PREFER"] == "1" { return true }
    if UserDefaults.standard.object(forKey: "model_use_lama") == nil { return false }
    return UserDefaults.standard.bool(forKey: "model_use_lama")
}
