// CoreTestSections16.swift：逐脸掩膜质量扫描（按脸的朝向分桶：正脸 / 半侧 / 大侧）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections16() {
// MARK: - 52. 逐脸掩膜：按朝向分桶量覆盖率与越界
head("52. 逐脸掩膜质量（正脸 / 半侧 / 大侧）")
do {
    // 用 Vision 的 yaw 给脸分桶；掩膜用生产路径那份（faceMask → 轮廓优先、没有关键点退椭圆）
    func yawOf(_ cg: CGImage, _ box: CGRect) -> Double {
        let req = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil else { return 0 }
        // 找与检测框最接近的那张脸（面积最接近）
        var best = 0.0; var bestD = Double.infinity
        for o in req.results ?? [] {
            let d = abs(o.boundingBox.midX - box.midX) + abs(o.boundingBox.midY - box.midY)
            if d < bestD { bestD = d; best = Double(o.yaw?.doubleValue ?? 0) }
        }
        return best
    }
    func sample(_ mask: CIImage, _ e: CGRect, _ sx: Double, _ sy: Double) -> Double {
        var b = [UInt8](repeating: 0, count: 4)
        let p = CGPoint(x: e.minX + sx * e.width, y: e.minY + sy * e.height)
        sharedCtx.render(mask, toBitmap: &b, rowBytes: 4,
                         bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return Double(b[0]) / 255.0
    }
    var buckets: [String: [(Double, Double)]] = [:]   // 桶 -> [(覆盖率, 越界率)]
    var scanned = 0, noContour = 0, loaded = 0, facesFound = 0
    // 扫一个目录而非固定几张：侧脸/半侧需要有足够的样本才会出现在桶里（上一版只扫到 3 张正脸）
    let dir = root + "/douyin_favorites/images"
    // 扫 400 张去找侧脸（第一版只扫 40 张，只检出 2 张正脸 —— 素材库有 13485 张，量太少）
    let scanN = (Int(ProcessInfo.processInfo.environment["CR_FACESCAN"] ?? "0") ?? 0) > 0 ? 400 : 40
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".webp") || $0.hasSuffix(".jpg") }.sorted().prefix(scanN)
    for name in names {
        guard let img = loadFixture(name, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        loaded += 1; facesFound += geos.count
        for g in geos where g.box.width > e.width * 0.08 {
            scanned += 1
            let fi = FaceInfo(index: g.index,
                              rect: CGRect(x: g.box.minX / e.width, y: g.box.minY / e.height,
                                           width: g.box.width / e.width, height: g.box.height / e.height),
                              quality: g.quality, geo: g)
            if g.faceContour.count < 5 { noContour += 1 }
            let mask = faceMask(extent: e, face: fi)
            // 覆盖率：脸框内 5x5 采样里 mask>0.5 的比例
            var inside = 0, total = 0
            for i in 1...5 { for j in 1...5 {
                let x = g.box.minX + g.box.width * Double(i) / 6
                let y = g.box.minY + g.box.height * Double(j) / 6
                total += 1; if sample(mask, e, x / e.width, y / e.height) > 0.5 { inside += 1 }
            } }
            // 越界率：脸框外一圈（±0.6 倍脸宽/高）里 mask>0.5 的比例 —— "提亮糊到头发/背景"就是这个
            var outside = 0, outTotal = 0
            for (dx, dy) in [(-0.7, 0.0), (0.7, 0.0), (0.0, 0.75), (0.0, -0.75)] {
                let x = g.box.midX + g.box.width * dx
                let y = g.box.midY + g.box.height * dy
                outTotal += 1
                if (0...1).contains(x / e.width) && (0...1).contains(y / e.height),
                   sample(mask, e, x / e.width, y / e.height) > 0.5 { outside += 1 }
            }
            let yaw = yawOf(cg, g.box)
            let key = abs(yaw) < 0.35 ? "正脸" : (abs(yaw) < 0.8 ? "半侧" : "大侧")
            if key != "正脸" && ProcessInfo.processInfo.environment["CR_FACESCAN"] != nil {
                print(String(format: "  [侧脸样本] %@ yaw=%.2f 脸宽 %.0f px 覆盖率 %.0f%%", name, yaw, g.box.width, Double(inside) / Double(max(1, total)) * 100))
            }
            buckets[key, default: []].append((Double(inside) / Double(max(1, total)),
                                              Double(outside) / Double(max(1, outTotal))))
        }
    }
    for key in ["正脸", "半侧", "大侧"] {
        let v = buckets[key] ?? []
        guard !v.isEmpty else { print("  [实测] \(key)：本批没有这样的脸"); continue }
        let cov = v.map { $0.0 }.reduce(0, +) / Double(v.count)
        let spill = v.map { $0.1 }.reduce(0, +) / Double(v.count)
        print(String(format: "  [实测] %@：%d 张脸 ｜ 脸内覆盖率 %.0f%% ｜ 脸外越界率 %.0f%%", key, v.count, cov * 100, spill * 100))
    }
    print("  [实测] 读了 \(loaded)/\(names.count) 张图，检出 \(facesFound) 张脸，其中 \(scanned) 张够大（>8% 图宽）被统计；\(noContour) 张没有关键点轮廓（退回椭圆）")
    let all = buckets.values.flatMap { $0 }
    if !all.isEmpty {
        let cov = all.map { $0.0 }.reduce(0, +) / Double(all.count)
        let spill = all.map { $0.1 }.reduce(0, +) / Double(all.count)
        check("逐脸掩膜：脸内覆盖率 ≥60%", cov >= 0.60, String(format: "%.0f%%", cov * 100))
        check("逐脸掩膜：脸外越界率 ≤10%", spill <= 0.10, String(format: "%.0f%%", spill * 100))
        // 三档**分级**锁住（第 127 节实测基线：正脸 77% / 半侧 72% / 大侧 65%，越界 0/2/4%）。
        // 留了约 7 个百分点的余量：既不让它悄悄变差，也不至于因为换了一批素材就红。
        let floors: [(String, Double, Double)] = [("正脸", 0.70, 0.08), ("半侧", 0.65, 0.08), ("大侧", 0.58, 0.10)]
        for (key, covFloor, spillCap) in floors {
            let v = buckets[key] ?? []
            guard v.count >= 5 else { continue }   // 样本太少不判（避免偶然）
            let c = v.map { $0.0 }.reduce(0, +) / Double(v.count)
            let s = v.map { $0.1 }.reduce(0, +) / Double(v.count)
            check("逐脸掩膜·\(key)：覆盖率 ≥\(Int(covFloor * 100))%、越界 ≤\(Int(spillCap * 100))%（\(v.count) 张脸）",
                  c >= covFloor && s <= spillCap,
                  String(format: "覆盖 %.0f%% ｜ 越界 %.0f%%", c * 100, s * 100))
        }
        check("逐脸掩膜：几乎不退回椭圆（轮廓可用率）", Double(noContour) / Double(max(1, scanned)) <= 0.05,
              "\(noContour)/\(scanned) 张脸没有关键点轮廓")
    }
}
}
