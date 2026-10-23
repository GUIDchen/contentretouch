// §428：GFPGAN 能不能出图 —— 先跑起来并让探针打印真实 I/O（§407 的教训 ✓）。
import Foundation
import CoreImage
import RetouchCore

func runSections68() {
    head("68. 人脸修复模型（GFPGAN）：接口能否出图")
    guard Gfpganer.shared.isAvailable else {
        skip("GFPGAN 出图", "未安装 gfpgan（可选下载）"); return
    }
    let backup = ModelRegistry.load()
    var list = backup
    for i in list.indices where list[i].slot == "gfpgan" { list[i].enabled = true }
    _ = ModelRegistry.save(list)
    defer { _ = ModelRegistry.save(backup) }
    setenv("CR_GFPGAN", "1", 1)
    defer { unsetenv("CR_GFPGAN") }
    guard let img = loadFixture(wedding, maxDim: 600) else { skip("GFPGAN 出图", "夹具缺失"); return }
    let t0 = Date()
    let out = Gfpganer.shared.restore(img)
    let ms = Date().timeIntervalSince(t0) * 1000
    check("GFPGAN 能出图", out != nil && renderable(out!), "耗时 " + String(format: "%.0f ms", ms))
    if let o = out {
        let d = diffMap(img, o)
        check("修复确实改变了画面", d.maxValue > 0.002, "峰值变化 " + fmt(d.maxValue, 4))
    }
}
