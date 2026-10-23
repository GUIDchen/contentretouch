// §444 方向 9 后半：SAM 收益**换落点**复测。
// 原§60 只测过图心；这里换成**脸框中心**（产品里最常见的人工落点），判据同 §60：
//   同掩膜区内，SAM 圈选覆盖 ≥ 单点覆盖 × 1.05。
import Foundation
import CoreImage
import RetouchCore

func runSections72() {
    head("72. SAM 收益换落点复测（图心 ⇒ 脸框中心）")
    guard SamStore.shared.isInstalled else { skip("SAM 换落点", "未安装 SAM"); return }
    setenv("CR_HEAL_SAM", "1", 1)
    defer { unsetenv("CR_HEAL_SAM") }
    guard let img = loadFixture(wedding, maxDim: 600),
          let cg = sharedCtx.createCGImage(img, from: img.extent),
          let face = detectFaceGeos(cg, size: img.extent.size).first else {
        skip("SAM 换落点", "夹具或人脸缺失"); return
    }
    let e = img.extent
    let ci = img
    let p = CGPoint(x: face.box.midX, y: face.box.midY)      // 落点 = 脸框中心
    let radius = max(20, e.width * 0.06)
    let hint = healHintMask(at: p, radius: radius, in: e)
    guard let res = refineMaskWithSAM(ci, hint: hint) else { skip("SAM 换落点", "SAM 没圈出东西"); return }
    let pts = healSamplePoints(in: res.mask, extent: e)
    guard !pts.isEmpty else { skip("SAM 换落点", "掩膜取不到点"); return }
    let rad = max(8, e.width * 0.02)
    let a = healSpots(ci, points: [p], radius: rad)
    let b = healSpots(ci, points: pts, radius: rad)
    func covered(_ after: CIImage) -> Double {
        let w = 128
        let h = max(1, Int(Double(w) * e.height / max(1, e.width)))
        let sc = CGAffineTransform(scaleX: CGFloat(w) / max(1, e.width), y: CGFloat(h) / max(1, e.height))
        let d = after.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: ci])
        var db = [UInt8](repeating: 0, count: w * h * 4)
        var mb = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(d.transformed(by: sc), toBitmap: &db, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        sharedCtx.render(res.mask.transformed(by: sc), toBitmap: &mb, rowBytes: w * 4,
                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var inMask = 0, changed = 0
        for i in 0..<(w * h) where mb[i * 4] > 128 {
            inMask += 1
            if max(db[i * 4], max(db[i * 4 + 1], db[i * 4 + 2])) > 6 { changed += 1 }
        }
        return inMask > 0 ? Double(changed) / Double(inMask) : 0
    }
    let ca = covered(a), cb = covered(b)
    let ratio = ca > 0.0001 ? cb / ca : 0
    check("脸框中心落点：SAM 覆盖 ≥ 单点 × 1.05", ratio >= 1.05,
          String(format: "单点 %.3f ｜ SAM %.3f ｜ 倍数 %.2fx ｜ 落点(%.0f,%.0f)", ca, cb, ratio, p.x, p.y))
}
