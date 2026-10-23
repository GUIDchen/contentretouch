// §433 方向 9：AI 点修命中率**多夹具复测**（原来只有一张夹具，0.76 ⇒ 结论太薄 ⬜）。
// 做法：运行时扫描夹具目录取前 N 张，逐张按脸框内网格采样点问 aiFixDecision，
//       报每张的可修覆盖率并断言**平均覆盖率**不低于阈值（可失败 ✓）。
import Foundation
import CoreImage
import RetouchCore

func runSections70() {
    head("70. AI 点修命中率：多夹具复测（原来只有 1 张）")
    // §331 的教训：loadFixture 会**前置 root** ⇒ 必须传**相对路径** ✗（这次又踩了一次，已修 ✓）。
    let relDirs = ["../douyin_favorites/images", "douyin_favorites/images"]
    var files: [String] = []
    for d in relDirs {
        if let xs = try? FileManager.default.contentsOfDirectory(atPath: d) {
            let imgs = xs.filter { $0.hasSuffix(".webp") || $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted()
            if !imgs.isEmpty {
                files = imgs.map { (d as NSString).appendingPathComponent($0) }
                break
            }
        }
    }
    guard !files.isEmpty else { skip("AI 点修多夹具", "找不到夹具目录"); return }
    var coverages: [Double] = []
    for path in files.prefix(4) {
        guard let img = loadFixture(path, maxDim: 600),
              let cg = sharedCtx.createCGImage(img, from: img.extent),
              let face = detectFaceGeos(cg, size: img.extent.size).first else { continue }
        var hit = 0, total = 0
        let steps = 5
        for i in 0..<steps { for j in 0..<steps {
            let x = face.box.minX + face.box.width * (CGFloat(i) + 0.5) / CGFloat(steps)
            let y = face.box.minY + face.box.height * (CGFloat(j) + 0.5) / CGFloat(steps)
            let p = CGPoint(x: x, y: y)
            total += 1
            if aiFixDecision(at: p, image: img, faceBox: face.box) != nil { hit += 1 }
        } }
        let cov = total > 0 ? Double(hit) / Double(total) : 0
        coverages.append(cov)
        print(String(format: "  · %@：可修覆盖率 %.2f（%d/%d）", (path as NSString).lastPathComponent, cov, hit, total))
    }
    guard !coverages.isEmpty else { skip("AI 点修多夹具", "无可用人脸样本"); return }
    let avg = coverages.reduce(0, +) / Double(coverages.count)
    check("多夹具平均可修覆盖率 ≥ 0.40", avg >= 0.40,
          String(format: "%d 张，平均 %.2f，逐张 ", coverages.count) + coverages.map { String(format: "%.2f", $0) }.joined(separator: "/"))
}
