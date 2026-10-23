// §403：上色模型（ddcolor）能不能出图 —— 先把调用点跑起来，探针才有意义。
// 做法：临时启用 ddcolor 槽位（用完复原 ✓）⇒ 调 Colorizer.colorize ⇒ 断言有输出且画面确实变了 ✓。
import Foundation
import CoreImage
import RetouchCore

func runSections65() {
    head("65. 上色模型（ddcolor）：接口能否出图")
    guard Colorizer.shared.isAvailable else {
        skip("上色出图", "未安装 ddcolor（可选下载，见挑图面板的可下载目录）"); return
    }
    let backup = ModelRegistry.load()
    var list = backup
    for i in list.indices where list[i].slot == "ddcolor" { list[i].enabled = true }
    _ = ModelRegistry.save(list)
    defer { _ = ModelRegistry.save(backup) }
    setenv("CR_COLORIZE", "1", 1)
    defer { unsetenv("CR_COLORIZE") }
    guard let img = loadFixture(wedding, maxDim: 600) else { skip("上色出图", "夹具缺失"); return }
    let t0 = Date()
    let out = Colorizer.shared.colorize(img)
    let ms = Date().timeIntervalSince(t0) * 1000
    check("上色能出图", out != nil && renderable(out!), "耗时 " + String(format: "%.0f ms", ms))
    if let o = out {
        let d = diffMap(img, o)
        check("上色确实改变了画面（不是原样返回）", d.maxValue > 0.02,
              "峰值变化 " + fmt(d.maxValue, 4))
    }
}

// §410：颜色质量量化 —— 上色的本意是「给灰度图上色」，所以判据应当是：
//   灰度输入 ⇒ 上色输出的**色度**显著高于灰度输入本身（方向明确 ✓，不用猜阈值 ✓）。
// 色度用「每像素 max(R,G,B) - min(R,G,B) 的均值」近似（0 表示纯灰 ✓）。
func meanChroma(_ img: CIImage) -> Double {
    let w = 64
    let h = max(1, Int(Double(w) * img.extent.height / max(1, img.extent.width)))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let s = CGAffineTransform(scaleX: CGFloat(w) / max(1, img.extent.width), y: CGFloat(h) / max(1, img.extent.height))
    sharedCtx.render(img.transformed(by: s), toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var sum = 0.0
    for i in 0..<(w * h) {
        let r = Double(buf[i * 4]), g = Double(buf[i * 4 + 1]), b = Double(buf[i * 4 + 2])
        sum += max(r, max(g, b)) - min(r, min(g, b))
    }
    return sum / Double(w * h)
}

func runSections66() {
    head("66. 上色：颜色质量量化（灰度输入应当被上色）")
    guard Colorizer.shared.isAvailable else {
        skip("上色质量", "未安装 ddcolor（可选下载）"); return
    }
    let backup = ModelRegistry.load()
    var list = backup
    for i in list.indices where list[i].slot == "ddcolor" { list[i].enabled = true }
    _ = ModelRegistry.save(list)
    defer { _ = ModelRegistry.save(backup) }
    guard let img = loadFixture(wedding, maxDim: 600) else { skip("上色质量", "夹具缺失"); return }
    let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
    let c0 = meanChroma(gray)
    guard let colored = Colorizer.shared.colorize(gray) else { skip("上色质量", "colorize 返回 nil"); return }
    let c1 = meanChroma(colored)
    check("灰度输入上色后色度显著提高（≥ 3 级）", c1 > c0 + 3,
          "灰度 " + fmt(c0, 2) + " → 上色 " + fmt(c1, 2))
}
