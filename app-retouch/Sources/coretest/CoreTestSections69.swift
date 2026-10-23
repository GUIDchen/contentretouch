// §431 方向 5 第一步：先量「过度上色」是否存在 —— 再决定要不要加低饱和掩膜。
// 判据：对**本来就有色**的图与对**灰度**图分别上色，比较色度改变量。
//   若两者相当 ⇒ 说明模型会强行重上色（可能破坏原有色调）⇒ 加掩膜有意义 ✓；
//   若彩色图的改变明显小 ⇒ 说明模型自适应 ⇒ 不加多余复杂度 ✓（本会话一贯：量不出收益不留复杂度）。
import Foundation
import CoreImage
import RetouchCore

func meanChroma2(_ img: CIImage) -> Double {
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

func runSections69() {
    head("69. 上色是否过度（彩色图 vs 灰度图的色度改变对比）")
    guard Colorizer.shared.isAvailable else {
        skip("上色过度检验", "未安装 ddcolor（可选下载）"); return
    }
    let backup = ModelRegistry.load()
    var list = backup
    for i in list.indices where list[i].slot == "ddcolor" { list[i].enabled = true }
    _ = ModelRegistry.save(list)
    defer { _ = ModelRegistry.save(backup) }
    guard let img = loadFixture(wedding, maxDim: 600) else { skip("上色过度检验", "夹具缺失"); return }
    let gray = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
    let c0 = meanChroma2(gray)
    guard let coloredGray = Colorizer.shared.colorize(gray) else { skip("上色过度检验", "colorize 返回 nil"); return }
    let c1 = meanChroma2(coloredGray)
    // §432：走**管线**量（用户实际路径 ✓）；直接调 Colorizer 会绕过低饱和掩膜 ✗。
    var o = PortraitOptions()
    o.colorize = 100
    let k0 = meanChroma2(img)
    guard let coloredColor = applyPortrait(img, o) as CIImage? else { skip("上色过度检验", "管线返回 nil"); return }
    let k1 = meanChroma2(coloredColor)
    check("灰度图上色：色度提高（≥ 3 级）", c1 > c0 + 3,
          "灰度 " + fmt(c0, 2) + " -> " + fmt(c1, 2) + "（差 " + fmt(c1 - c0, 2) + "）")
    // 这一条只报数、不设阈值：先量出"彩色图上色是否也大幅改变色度"，再决定要不要加掩膜 ✓
    check("彩色图上色：色度改变量（报数，用于决定是否加低饱和掩膜）", true,
          "原色度 " + fmt(k0, 2) + " -> " + fmt(k1, 2) + "（差 " + fmt(k1 - k0, 2) + "）；灰度情形差 " + fmt(c1 - c0, 2))
}
