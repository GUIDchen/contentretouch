// CoreTestSections9.swift：coretest 的第 65~72 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections9() {
check("参考图折算用中位数抗离群",
      nAll == 4 && max(abs(tAll.p50 - tClean.p50), abs(tAll.sat - tClean.sat)) < 1.5,
      String(format: "%d 张（含 1 张异类）目标 p50 %.1f vs 干净组 %.1f", nAll, tAll.p50, tClean.p50))

// MARK: - 10. 手部美化：21 点轮廓 vs 包围框


head("10. 手部轮廓蒙版（21 点凸包）比包围框更贴合")

if let himg = loadFixture(handImg, maxDim: 1200),
   let hcg = sharedCtx.createCGImage(himg, from: himg.extent) {
    let hw = himg.extent.width, hh = himg.extent.height
    let polys = handPolygons(hcg, extent: himg.extent)
    let rects = detectHandInfos(hcg, extent: himg.extent).map { $0.rect }
    check("手部轮廓能检出", !polys.isEmpty && !rects.isEmpty,
          "轮廓 \(polys.count) 个，包围框 \(rects.count) 个")

    if let first = polys.first {
        var pm = first
        for m in polys.dropFirst() { pm = maskUnion(pm, m) }
        _ =  maskCoverage(pm, in: himg.extent, threshold: 60)
        let rectFrac = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
            / Double(hw * hh)
        // 两张蒙版都做同一套羽化，才能公平比面积
        let feathered = pm.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
            .cropped(to: himg.extent)
        let polyCovF = maskCoverage(feathered, in: himg.extent, threshold: 20)
        check("轮廓蒙版不是空的、也没盖满整张", polyCovF > 0.002 && polyCovF < 0.6,
              String(format: "轮廓覆盖 %.2f%%，包围框面积占 %.2f%%", polyCovF * 100, rectFrac * 100))
        // 这一条正是「升级」的意义：轮廓比包围框小一大截，说明包围框把周围背景也框进去磨了
        check("轮廓明显比包围框紧（少掉的正是会被误磨的背景）",
              polyCovF < rectFrac * 0.95,
              String(format: "轮廓 %.2f%% vs 包围框 %.2f%%（紧 %.0f%%）",
                     polyCovF * 100, rectFrac * 100,
                     rectFrac > 0 ? (1 - polyCovF / rectFrac) * 100 : 0))

        // 手部区内的确被改了；画面角落（远离任何手）几乎不动
        let before = himg
        let after = smoothHands(himg, strength: 60)
        let diff = after.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: before])
        let coreVal = maskCoverage(pm, in: himg.extent, threshold: 60)
        let cornerPx = 40
        let cornerRect = CGRect(x: 0, y: 0, width: CGFloat(cornerPx), height: CGFloat(cornerPx))
        let cornerDiff = diff.cropped(to: cornerRect)
        let cornerMean = measure(cornerDiff).p50
        // 注意别用全图的 p95 量「手有没有被改」：手只占 2.8% 的像素，全图 p95 一定是 0
        //（这条我自己先踩了一次，差点得出「手部没被柔化」的错误结论）。裁到手框里量。
        let handBox = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) ?? himg.extent
        let handDiff = diff.cropped(to: handBox.intersection(himg.extent))
        check("手部被柔化", coreVal > 0.002 && measure(handDiff).p95 > 0.5,
              String(format: "手区覆盖 %.2f%%，手框内差异 p95 %.2f（全图 p95 会是 0，因为手只占 %.1f%%）",
                     coreVal * 100, measure(handDiff).p95, coreVal * 100))
        check("画面角落不受影响", cornerMean < 1.0,
              String(format: "左上 %dx%d 角落差异 p50 %.3f（要求 < 1）", cornerPx, cornerPx, cornerMean))
    }
}

// MARK: - 11. 3D 人体姿态 → 身体朝向（全身美型的侧身折算）


head("11. 3D 人体姿态：身体朝向")

if let wimg = loadFixture(wedding, maxDim: 900),
   let wcg = sharedCtx.createCGImage(wimg, from: wimg.extent) {
    let y = bodyYaw3D(wcg)
    // 婚礼样片是站着的两个人：应该能判出朝向，且落在合理区间
    check("3D 姿态能给出朝向", y.ok, y.ok ? String(format: "朝向 %.1f°", y.yaw) : "没检出（接口或素材问题）")
    if y.ok {
        check("朝向落在合理区间", abs(y.yaw) <= 95,
              String(format: "%.1f°（超出 ±95° 说明左右肩取反或坐标搞错了）", y.yaw))
        let factor = max(0.25, abs(cos(y.yaw * .pi / 180)))
        check("侧身折算因子在 [0.25, 1] 内", factor >= 0.25 - 1e-6 && factor <= 1 + 1e-6,
              String(format: "朝向 %.0f° → 折算 %.2f", y.yaw, factor))
    }
}

// MARK: - 12. 逐脸提亮的范围（椭圆，不是内切圆）


head("12. 逐脸提亮/暖冷的范围：椭圆脸蒙版")

if let fimg = loadFixture(bigFace, maxDim: 900),
   let fcg = sharedCtx.createCGImage(fimg, from: fimg.extent) {
    let e = fimg.extent
    let geos = detectFaceGeos(fcg, size: e.size)
    if let g0 = geos.max(by: { $0.box.width < $1.box.width }) {
        let fi = FaceInfo(index: g0.index,
                          rect: CGRect(x: g0.box.minX / e.width, y: g0.box.minY / e.height,
                                       width: g0.box.width / e.width, height: g0.box.height / e.height),
                          quality: g0.quality)
        let m = faceMask(extent: e, face: fi)
        // 关键点：下巴/额头这两个「内切圆盖不到」的位置，现在必须被盖住
        // 下巴取轮廓最低点；轮廓取不到就用脸框下缘略上一点的位置
        let chin: CGPoint = g0.faceContour.min(by: { $0.y < $1.y })
            ?? CGPoint(x: g0.box.midX, y: g0.box.minY + g0.box.height * 0.08)
        let topY = g0.box.maxY - g0.box.height * 0.08
        let forehead = CGPoint(x: g0.box.midX, y: topY)
        let cheekL = CGPoint(x: g0.box.minX + g0.box.width * 0.12, y: g0.box.midY)
        let chinV = maskValue(m, at: chin)
        let foreV = maskValue(m, at: forehead)
        let cheekV = maskValue(m, at: cheekL)
        check("下巴在提亮范围内", chinV > 0.45, String(format: "下巴处蒙版 %.2f（要求 > 0.45）", chinV))
        check("额头在提亮范围内", foreV > 0.45, String(format: "额头处蒙版 %.2f（要求 > 0.45）", foreV))
        // 而脸框外侧（头发/背景）不该被大幅提亮
        let outside = CGPoint(x: g0.box.minX - g0.box.width * 0.25, y: g0.box.midY)
        let outV = maskValue(m, at: outside)
        check("脸框外基本不吃到", outV < 0.25,
              String(format: "脸框左侧 25%% 宽度处蒙版 %.2f（要求 < 0.25）；脸颊处 %.2f", outV, cheekV))
    }
}

// MARK: - 13. 直方图（合成图有已知答案）


head("13. 直方图：合成图验已知答案")

do {
    // 左半纯黑、右半纯白：直方图两端必须有计数，死黑/死白各占一半——这是能被证伪的
    let left = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
    let right = CIImage(color: .white).cropped(to: CGRect(x: 128, y: 0, width: 128, height: 64))
    let half = left.composited(over: right)
    let h = histogram(half)
    check("直方图两端都有计数", h.lum[0] > 0 && h.lum[255] > 0,
          "黑 bin \(h.lum[0])、白 bin \(h.lum[255])，共 \(h.samples) 个采样")
    check("死黑/死白比例各约一半",
          abs(h.clippedLow - 0.5) < 0.06 && abs(h.clippedHigh - 0.5) < 0.06,
          String(format: "死黑 %.3f、死白 %.3f（各应≈0.500）", h.clippedLow, h.clippedHigh))
    // 全灰图：不该出现死黑死白，且亮度的众数落在中段
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
        .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
    let hg = histogram(grey)
    let mid = 64..<192
    let midSum = mid.reduce(0) { $0 + hg.lum[$1] }
    check("全灰图：无死黑死白、亮度落在中段",
          hg.clippedLow < 0.001 && hg.clippedHigh < 0.001 && midSum > hg.samples / 2,
          String(format: "死黑 %.4f 死白 %.4f，中段占比 %.0f%%",
                 hg.clippedLow, hg.clippedHigh, Double(midSum) / Double(max(1, hg.samples)) * 100))
}


head("13b. EXIF 读取")

if let cr3 = ["HP7A4670.CR3", "HP7A4691.CR3", "HP7A4743.CR3"].first(where: {
    FileManager.default.fileExists(atPath: root + "/" + $0)
}) {
    let rows = exifSummary(root + "/" + cr3)
    let hasLens = rows.contains { $0.0 == "镜头" && !$0.1.isEmpty }
    let hasExposure = rows.contains { $0.0 == "光圈" } && rows.contains { $0.0 == "快门" }
    check("RAW 的 EXIF 能读出镜头与曝光三要素", hasLens && hasExposure,
          "\(rows.count) 项：" + rows.prefix(5).map { $0.0 }.joined(separator: "/"))
} else {
    skip("RAW 的 EXIF 能读出镜头与曝光三要素", "仓库根目录没有 CR3 样片")
}

// MARK: - 14. 批量导出的断点续跑


head("14. 批量导出：断点续跑（跳过已导出）")

if loadFixture(bigFace, maxDim: 0) != nil,      // 只要求夹具在（原来绑了个 one，谁也没用）
   let path = { () -> String? in
       for d in libDirs {
           let p = root + "/" + d + "/" + bigFace
           if FileManager.default.fileExists(atPath: p) { return p }
       }
       return nil
   }() {
    let tmp = NSTemporaryDirectory() + "/coretest_resume_\(UUID().uuidString.prefix(6))"
    var s = ExportSettings()
    s.format = "jpeg"
    s.quality = 70
    let files = [path, path]     // 同一个文件两次 → 名字消解器会给出两个名字
    let r1 = exportBatch(files: files, outDir: tmp, s, makeImage: { p in loadAnyImage(p, maxDim: 600) },
                         workers: 1, skipExisting: false)
    let r2 = exportBatch(files: files, outDir: tmp, s, makeImage: { p in loadAnyImage(p, maxDim: 600) },
                         workers: 1, skipExisting: true)
    check("第一次全出、第二次全跳过",
          r1.written == 2 && r2.written == 0 && r2.skippedExisting == 2,
          "第一次出 \(r1.written) 张；第二次出 \(r2.written) 张、跳过已有 \(r2.skippedExisting) 张")
    // 取消：一开始就取消 → 一张都不该出
    let tmp2 = tmp + "_cancel"
    let r3 = exportBatch(files: files, outDir: tmp2, s, makeImage: { p in loadAnyImage(p, maxDim: 600) },
                         workers: 1, skipExisting: false, shouldCancel: { true })
    check("取消后一张都不出", r3.cancelled && r3.written == 0,
          "cancelled=\(r3.cancelled)、出图 \(r3.written) 张")
    try? FileManager.default.removeItem(atPath: tmp)
    try? FileManager.default.removeItem(atPath: tmp2)
} else {
    skip("批量导出断点续跑", "找不到可用样片")
}

// MARK: - 15. 掩膜边缘：边缘保持放大 vs 普通放大


head("15. 掩膜边缘（CIEdgePreserveUpsample）")

if let aimg = loadFixture(bigFace, maxDim: 900),
   let acg = sharedCtx.createCGImage(aimg, from: aimg.extent) {
    let ageos = detectFaceGeos(acg, size: aimg.extent.size)
    if ageos.max(by: { $0.box.width < $1.box.width }) != nil,     // 要求"检得到脸"（g0 本身没用到）
       let res = FaceParser.shared.parse(acg) {
        // 按脸路径的形状来测：解析看到的是**中心正方形**，所以引导图也必须是同一块正方形，
        // 且移到原点（cropped 会保留原坐标，原点不一致引导滤波会崩）。
        let ae = aimg.extent
        let aside = min(ae.width, ae.height)
        let asq = CGRect(x: ae.midX - aside / 2, y: ae.midY - aside / 2, width: aside, height: aside)
        let sqZero = aimg.cropped(to: asq)
            .transformed(by: CGAffineTransform(translationX: -asq.minX, y: -asq.minY))
        let sqExtent = CGRect(x: 0, y: 0, width: aside, height: aside)
        let plain = maskFromLabels(res, classes: FaceClass.skinClasses, extent: sqExtent, feather: 3)
        _ = sqZero
        // 这里原本想断言「边缘保持放大让过渡带更窄」。实测结论是**这条路走不通**：
        // CIEdgePreserveUpsampleFilter 与 CIGuidedFilter 在本机都会把进程 abort（见 FaceParsing 里的记录），
        // 所以产品里退回了普通放大。这条断言就改成守「掩膜本身是有效的」——
        // 有覆盖、且过渡带不是一片糊（中间值像素别占太多）。
        // 「边缘宽度」= 处于中间值(0.2~0.8)的像素占比：糊出去的边缘这个数更大
        func edgeFraction(_ m: CIImage) -> Double {
            let e = m.extent
            let scale = 400.0 / max(1, max(e.width, e.height))
            let small = m.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let w = max(1, Int(small.extent.width)), h = max(1, Int(small.extent.height))
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                             bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var mid = 0
            for i in 0..<(w * h) {
                let v = Double(buf[i * 4]) / 255
                if v > 0.2 && v < 0.8 { mid += 1 }
            }
            return Double(mid) / Double(max(1, w * h))
        }
        let fp = edgeFraction(plain)        // fg 原来也在这一行、但没人用（2026-09-26 清警告时删掉）
        check("掩膜有效：有覆盖、过渡带不过宽", fp > 0.001 && fp < 0.35,
              String(format: "覆盖 %.2f%%、过渡带（中间值像素）%.2f%%", maskCoverage(plain, in: sqExtent, threshold: 100) * 100, fp * 100))
    }
}

// MARK: - 16. 祛痘/修补：样例修补 vs 模糊填（合成图有已知答案）

}
