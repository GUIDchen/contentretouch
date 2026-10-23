// §354：模型开关「真的被门控读到」的断言（五条）。
// 关键：结束必须**复位键与环境变量** ✓，否则会污染后续断言（§286 那类教训 ✗）。
import Foundation
import RetouchCore

func runSections62() {
    head("62. 模型开关：门控是否真的生效（含环境变量优先与复位）")
    let d = UserDefaults.standard
    let oldSAM = d.object(forKey: "model_use_sam"), oldLAMA = d.object(forKey: "model_use_lama")
    defer {
        if let o = oldSAM { d.set(o, forKey: "model_use_sam") } else { d.removeObject(forKey: "model_use_sam") }
        if let o = oldLAMA { d.set(o, forKey: "model_use_lama") } else { d.removeObject(forKey: "model_use_lama") }
    }
    d.removeObject(forKey: "model_use_sam"); d.removeObject(forKey: "model_use_lama")
    unsetenv("CR_HEAL_SAM"); unsetenv("CR_LAMA_PREFER")
    check("默认：SAM 开、LaMa 关（与已发布默认一致）", samPreferred() && !laMaPreferred(),
          "sam=" + String(samPreferred()) + " lama=" + String(laMaPreferred()))
    d.set(false, forKey: "model_use_sam")
    check("界面开关：关掉 SAM ⇒ samPreferred() 为 false", !samPreferred(), "sam=" + String(samPreferred()))
    d.set(true, forKey: "model_use_lama")
    check("界面开关：打开 LaMa ⇒ laMaPreferred() 为 true", laMaPreferred(), "lama=" + String(laMaPreferred()))
    d.set(true, forKey: "model_use_sam")
    setenv("CR_HEAL_SAM", "0", 1)
    check("环境变量优先：CR_HEAL_SAM=0 覆盖界面开关", !samPreferred(), "sam=" + String(samPreferred()))
    unsetenv("CR_HEAL_SAM")
    d.removeObject(forKey: "model_use_sam"); d.removeObject(forKey: "model_use_lama")
    check("复位：清掉键与 env 后回到默认", samPreferred() && !laMaPreferred(),
          "sam=" + String(samPreferred()) + " lama=" + String(laMaPreferred()))
}
