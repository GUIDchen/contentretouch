// §313：SAM 版智能消除的收益量测（单点 vs SAM，在同一掩膜区内的改动覆盖差）。
// 口径见账本 §299 第 2 条与 §310：同一夹具、同一个落点，比较两者在 SAM 掩膜区内的改动像素比例。
import Foundation
import CoreImage
import RetouchCore

func runSections60() {
    head("60. 智能消除：单点 vs SAM 圈选的覆盖差")
    guard SamSegmenter.shared.isAvailable else { skip("单点 vs SAM", "本机没装 SAM"); return }
    guard let path = ProcessInfo.processInfo.environment["CR_SAMTEST_FIXTURE"], !path.isEmpty,
          let ci = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
        skip("单点 vs SAM", "没给 CR_SAMTEST_FIXTURE（或图读不出来）"); return
    }
    let ctx = CIContext(options: [.useSoftwareRenderer: false])
    let e = ci.extent
    let p = CGPoint(x: e.midX, y: e.midY)
    let hint = healHintMask(at: p, radius: max(20, e.width * 0.06), in: e)
    guard let res = refineMaskWithSAM(ci, hint: hint) else { skip("单点 vs SAM", "SAM 没圈出东西"); return }
    let pts = healSamplePoints(in: res.mask, extent: e)
    guard !pts.isEmpty else { skip("单点 vs SAM", "掩膜取不到点"); return }
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
        ctx.render(d.transformed(by: sc), toBitmap: &db, rowBytes: w * 4,
                   bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        ctx.render(res.mask.transformed(by: sc), toBitmap: &mb, rowBytes: w * 4,
                   bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var inMask = 0, changed = 0
        for i in 0..<(w * h) where mb[i * 4] > 128 {
            inMask += 1
            if max(db[i * 4], max(db[i * 4 + 1], db[i * 4 + 2])) > 6 { changed += 1 }
        }
        return inMask > 0 ? Double(changed) / Double(inMask) : 0
    }
    let c1 = covered(a)
    let c2 = covered(b)
    check("SAM 圈选在同掩膜区内的覆盖不低于单点", c2 >= c1 * 1.05,
          String(format: "单点 %.3f ｜ SAM %.3f（掩膜取点 %d 个，落点半径 %.0f）", c1, c2, pts.count, rad))
}
