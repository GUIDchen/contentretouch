// §331：AI 点修决策的命中率（多夹具）。非循环期望：脸框中心属鼻/嘴高度、图像角落属背景。
// 夹具列表：默认用项目里几张常用图（存在才跑），也可用 CR_AIFIX_FIXTURES 以冒号分隔覆盖。
import Foundation
import CoreImage
import RetouchCore

func runSections61() {
    head("61. AI 点修：决策命中率与边界（多夹具）")
    let env = ProcessInfo.processInfo.environment["CR_AIFIX_FIXTURES"] ?? ""
    var list = env.isEmpty ? [] : env.split(separator: ":").map { String($0) }
    if list.isEmpty {
        list = ["douyin_favorites/images/0001_7685743195553219813_01.webp",
                "douyin_favorites/images/0001_7673816620465215714_01.webp",
                "douyin_favorites/images/0001_7683848423867436657_01.webp",
                "2604_wedding/00_RAW_readonly/wedding_01.jpg"]
    }
    var coverages: [Double] = []
    var nFace = 0
    for rel in list {
        // §331：loadFixture 自己会拼 root ⇒ 必须传**相对路径** ✗（传绝对的会变成 root + 绝对 ⇒ 读不到 ⇒ 0 张脸）。
        let rel2 = rel.hasPrefix("/") ? String(rel.dropFirst(root.count + 1)) : rel
        guard let img = loadFixture(rel2, maxDim: 900),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        guard let f = detectFaceGeos(cg, size: img.extent.size).first else { continue }
        nFace += 1
        let box = f.box
        let name = (rel2 as NSString).lastPathComponent
        let d = aiFixDecision(at: CGPoint(x: box.midX, y: box.midY), image: img, faceBox: box)
        let corner = CGPoint(x: img.extent.minX + 8, y: img.extent.minY + 8)
        let cornerNil = aiFixDecision(at: corner, image: img, faceBox: box) == nil
        var hit = 0, total = 0
        for iy in 1...5 { for ix in 1...5 {
            let p = CGPoint(x: box.minX + box.width * Double(ix) / 6.0,
                            y: box.minY + box.height * Double(iy) / 6.0)
            total += 1
            if aiFixDecision(at: p, image: img, faceBox: box) != nil { hit += 1 }
        } }
        let rate = total > 0 ? Double(hit) / Double(total) : 0
        coverages.append(rate)
        print("  · " + name + "：覆盖率 " + fmt(rate) + "（" + String(hit) + "/" + String(total) + "）"
              + "，中心 " + (d?.label ?? "nil") + "，角落 " + (cornerNil ? "nil" : "非 nil"))
        check(name + "｜角落为 nil（背景不硬修）", cornerNil, "角落决策 " + (cornerNil ? "nil" : "非 nil"))
        check(name + "｜中心给出部位决策", d != nil, "得到 " + (d?.label ?? "nil"))
    }
    guard nFace >= 2 else { skip("AI 点修多夹具命中率", "有效夹具少于 2 张（检到脸 " + String(nFace) + " 张）"); return }
    let mean = coverages.reduce(0, +) / Double(coverages.count)
    check("多夹具平均可修覆盖率不低于 30%", mean >= 0.30,
          "均值 " + fmt(mean) + "（" + String(coverages.count) + " 张：" + coverages.map { fmt($0, 2) }.joined(separator: " / ") + "）")
}
