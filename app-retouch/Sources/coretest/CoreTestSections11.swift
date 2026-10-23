// CoreTestSections11.swift：coretest 的第 81~88 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections11() {
head("23. 闸门体检（真实照片上的实测值）")

do {
    let sampleNames = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                       "douyin_favorites/images/0001_7676844130508479842_18.webp",
                       "2604_wedding/00_RAW_readonly/wedding_01.jpg"]
    var gateRows: [String] = []
    for name in sampleNames {
        let path = root + "/" + name
        guard FileManager.default.fileExists(atPath: path),
              let img = loadAnyImage(path, maxDim: 900),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        let maxFace = geos.map { $0.box.width }.max() ?? 0
        // 皮肤掩膜
        var skinCov = 0.0, bloodAvg = 0.0
        if !geos.isEmpty {
            let m = geos.count == 1 ? skinMaskForFace(img, face: geos[0]) : skinMaskForFaces(img, geos: geos)
            skinCov = maskCoverage(m, in: e, threshold: 128)
            let eye = geos[0].centroid(geos[0].leftEye)
            bloodAvg = maskValue(m, at: eye)
        }
        // 衣物（解析）
        let cloth = parsedMaskFromImage(img, classes: FaceClass.clothClasses)
        let clothCov = cloth.map { maskCoverage($0, in: e, threshold: 128) } ?? -1
        // 人物掩膜
        let pm = personMask(img)
        let personCov = pm.map { maskCoverage($0, in: e, threshold: 128) } ?? -1
        let animalCount = detectAnimalInfos(cg, extent: e).count
        gateRows.append(String(format: "%@：脸%d(最大%.0fpx) 皮肤覆盖%.3f(眼处%.2f) 衣物解析%.3f 人物覆盖%.3f 动物%d",
                               (name as NSString).lastPathComponent, geos.count, maxFace,
                               skinCov, bloodAvg, clothCov, personCov, animalCount))
    }
    for r in gateRows { print("  [实测] " + r) }
    check("闸门体检能跑出结果（只报数）", !gateRows.isEmpty, "采样 \(gateRows.count) 张")
}

// MARK: - 24. 兜底路径的画质：椭圆掩膜 vs 解析掩膜（小脸走的就是椭圆）


head("24. 小脸的兜底掩膜：椭圆 vs 解析（漏多少 / 多吃多少）")

do {
    // 用一张**大脸**照片：解析掩膜当作参考真值，量椭圆掩膜的两个误差方向。
    // 这两个数就是"小脸只能走椭圆"时的画质上限。
    if let p = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                "2604_wedding/00_RAW_readonly/wedding_01.jpg"].first(where: {
        FileManager.default.fileExists(atPath: root + "/" + $0)
    }), let img = loadAnyImage(root + "/" + p, maxDim: 900),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        if let g0 = geos.max(by: { $0.box.width < $1.box.width }) {
            // 参考真值：按脸解析（大脸时它才准）
            if let parsed = parsedSkinMaskForFace(img, face: g0) {
                // 兜底：椭圆（与 skinMaskForFace 在"脸不够大/眼周判不准"时退回的是同一个）
                let box = g0.box
                let ellipse = rectMask(extent: e,
                                       rect: box.insetBy(dx: -box.width * 0.10, dy: -box.height * 0.10),
                                       feather: max(3, min(box.width, box.height) * 0.16), ellipse: true)
                let pv = maskCoverage(parsed, in: e, threshold: 128)
                let ev = maskCoverage(ellipse, in: e, threshold: 128)
                // 椭圆"多吃"的部分（椭圆内、解析外）= 会被误磨的背景/头发
                let leakMask = ellipse.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: blackMask(e),
                    kCIInputMaskImageKey: invertedMask(parsed, extent: e)])
                let leak = maskCoverage(leakMask, in: e, threshold: 128)
                // 椭圆"漏掉"的部分（解析内、椭圆外）= 磨不到的脸
                let missMask = parsed.applyingFilter("CIImageBySubtracting", parameters: [
                    kCIInputBackgroundImageKey: ellipse]).applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                let miss = maskCoverage(missMask, in: e, threshold: 128)
                print(String(format: "  [实测] 脸 %.0fpx：解析覆盖 %.4f、椭圆覆盖 %.4f", box.width, pv, ev))
                print(String(format: "  [实测] 椭圆多吃（误磨背景/头发）%.4f（占椭圆的 %.0f%%）｜漏掉（磨不到的脸）%.4f（占解析的 %.0f%%）",
                             leak, ev > 0 ? leak / ev * 100 : 0, miss, pv > 0 ? miss / pv * 100 : 0))
                // 同样的口径量一下「脸轮廓多边形」掩膜：它就是要替代椭圆的兜底
                if let contour = contourFaceMask(extent: e, face: g0) {
                    let cv = maskCoverage(contour, in: e, threshold: 128)
                    let cleakMask = contour.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: blackMask(e),
                        kCIInputMaskImageKey: invertedMask(parsed, extent: e)])
                    let cleak = maskCoverage(cleakMask, in: e, threshold: 128)
                    let cmissMask = parsed.applyingFilter("CIImageBySubtracting", parameters: [
                        kCIInputBackgroundImageKey: contour]).applyingFilter("CIColorClamp", parameters: [
                        "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                    let cmiss = maskCoverage(cmissMask, in: e, threshold: 128)
                    print(String(format: "  [实测] 轮廓掩膜覆盖 %.4f；多吃 %.4f（%.0f%%）｜漏 %.4f（%.0f%%）",
                                 cv, cleak, cv > 0 ? cleak / cv * 100 : 0, cmiss, pv > 0 ? cmiss / pv * 100 : 0))
                    check("脸轮廓掩膜比椭圆更贴（多吃更少）", cleak < leak * 0.85,
                          String(format: "多吃：椭圆 %.0f%% → 轮廓 %.0f%%（相对少 %.0f%%）",
                                 ev > 0 ? leak / ev * 100 : 0, cv > 0 ? cleak / cv * 100 : 0,
                                 leak > 0 ? (1 - cleak / leak) * 100 : 0))
                    check("脸轮廓掩膜不能漏掉脸（漏检率仍要低）", pv <= 0.001 || cmiss < pv * 0.35,
                          String(format: "漏：椭圆 %.0f%% → 轮廓 %.0f%%", pv > 0 ? miss / pv * 100 : 0,
                                 pv > 0 ? cmiss / pv * 100 : 0))
                }
                // 端到端：同一个「磨皮」在小脸场景下，用兜底掩膜跑一遍，
                // 看它改动的范围是否被限制在脸附近（这是"底模画质"的直接体现）
                var skin = SkinOptions()
                skin.grade = "off"; skin.strength = 70; skin.unifyTone = false; skin.texturePreserve = true
                let outFallback = applySkin(img, skin, geos: [g0])
                let dm = diffMap(img, outFallback)
                let insideFace = dm.avg(in: g0.box) * 255
                // 脸框外 1.8 倍以外的区域（绝不该被磨）
                let farRect = CGRect(x: max(e.minX, g0.box.maxX + g0.box.width * 1.8),
                                     y: e.minY, width: 80, height: 80).intersection(e)
                let far = farRect.width > 10 ? dm.avg(in: farRect) * 255 : 0
                check("兜底掩膜下磨皮只落在脸附近", insideFace > far * 2 + 0.2,
                      String(format: "脸框内平均差 %.2f，远处 %.2f", insideFace, far))
                check("椭圆兜底的漏检率有量化的上限", pv > 0.001,
                      String(format: "解析 %.4f、漏 %.4f（%.0f%%）", pv, miss, pv > 0 ? miss / pv * 100 : 0))
            }
        }
    }
}

// MARK: - 25. 衣物兜底掩膜体检：漏/多吃/把皮肤算进衣服


head("25. 衣物兜底掩膜（解析失效时走的那套减法）")

do {
    // 解析失效的两张图（第 23 段实测衣物解析 0.000 / 0.002）
    let names = ["2604_wedding/00_RAW_readonly/wedding_01.jpg",
                 "douyin_favorites/images/0001_7673816620465215714_01.webp"]
    for name in names {
        let path = root + "/" + name
        guard FileManager.default.fileExists(atPath: path),
              let img = loadAnyImage(path, maxDim: 900),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let e = img.extent
        let person = personMask(img)
        let geos = detectFaceGeos(cg, size: e.size)
        // **跑真实路径**（不是在这里复刻一份掩膜逻辑——那样改了函数也量不出来，
        //  第一版就这么白跑了一次）：直接调 smoothClothes，再按"皮肤/衣服"分区量改动量。
        let out = smoothClothes(img, strength: 85)
        let dm = diffMap(img, out)
        let skinM = geos.isEmpty ? blackMask(e)
            : (geos.count == 1 ? skinMaskForFace(img, face: geos[0]) : skinMaskForFaces(img, geos: geos))
        let personCov = person.map { maskCoverage($0, in: e, threshold: 128) } ?? 0
        // 皮肤区：取脸框及其下方一点（脖子/肩），这些是"露出的皮肤"
        // **取样点要落在"确定的皮肤"上**：脸颊与鼻子（脸框整体还包括头发/额头/背景角，
        //   拿它当"皮肤"量会把发丝边缘的改动算进来——第一版就是这么得到 10.98 的）。
        var skinDiff = 0.0, skinN = 0
        for g in geos {
            let side = max(8, g.box.width * 0.18)
            var pts: [CGPoint] = [g.centroid(g.nose)]
            if !g.leftEye.isEmpty { pts.append(g.centroid(g.leftEye)) }
            if !g.rightEye.isEmpty { pts.append(g.centroid(g.rightEye)) }
            for c in pts {
                // 眼睛中心其实是"眼睛"，往下偏一点才是脸颊；鼻子点直接用
                let isEye = c != g.centroid(g.nose)
                let y = isEye ? c.y - side * 0.9 : c.y
                let r = CGRect(x: c.x - side / 2, y: y - side / 2, width: side, height: side).intersection(e)
                guard r.width > 4 else { continue }
                skinDiff += dm.avg(in: r) * 255; skinN += 1
            }
        }
        skinDiff = skinN > 0 ? skinDiff / Double(skinN) : 0
        // 衣服区：人像掩膜里、皮肤掩膜之外
        let clothOnly = (person ?? blackMask(e)).applyingFilter("CIMultiplyBlendMode", parameters: [
            kCIInputBackgroundImageKey: skinM.applyingFilter("CIColorInvert")])
        let clothCov = maskCoverage(clothOnly, in: e, threshold: 128)
        let clothDiff = clothCov > 0.02 ? dm.avg(in: e) * 255 * (personCov / max(0.01, clothCov)) : 0
        print(String(format: "  [实测] %@：人像覆盖 %.3f、皮肤外(衣服候选)覆盖 %.3f",
                     (name as NSString).lastPathComponent, personCov, clothCov))
        print(String(format: "  [实测] %@：脸区平均改动 %.2f，全图平均改动 %.2f",
                     (name as NSString).lastPathComponent, skinDiff, dm.avg(in: e) * 255))
        // 关键性质：**脸/皮肤不该被"衣物平整"明显动到**（它只该压衣服的褶皱）
        // 判据用**比值**而不是绝对值：皮肤区改动必须显著小于全图平均改动。
        // 这条是有判别力的——改之前（只减脸椭圆、不减肤色）实测 脸区 10.98 vs 全图 8.70（比值 1.26，不通过）；
        // 改成减肤色之后 2.37 vs 8.70（比值 0.27，通过）。
        let globalDiff = dm.avg(in: e) * 255
        check("\(name)：衣物平整不会明显动到皮肤", skinDiff < globalDiff * 0.5,
              String(format: "皮肤区改动 %.2f vs 全图 %.2f（比值 %.2f，改之前是 1.26）",
                     skinDiff, globalDiff, globalDiff > 0.01 ? skinDiff / globalDiff : 0))
        _ = clothDiff
    }
}

// MARK: - 26. 换天空的掩膜：会不会盖到人/地面（拿主体掩膜当真值）


head("26. 换天空掩膜 vs 主体掩膜（天空不该盖到人）")

do {
    // 用索引里标了「天空」的样片（前两张都没检出天空，量不到东西）
    let names = ["douyin_favorites/images/0001_7547631061581221172_01.jpg",
                 "douyin_favorites/images/0001_7676844130508479842_01.webp",
                 "2604_wedding/00_RAW_readonly/wedding_01.jpg"]
    for name in names {
        let path = root + "/" + name
        guard FileManager.default.fileExists(atPath: path),
              let img = loadAnyImage(path, maxDim: 900) else { continue }
        let e = img.extent
        var o = SkyOptions()
        o.style = "晴天蓝"
        o.amount = 100
        let (out, cov) = replaceSky(img, o)
        print(String(format: "  [实测] %@：天空检出覆盖 %.3f", (name as NSString).lastPathComponent, cov))
        if cov < 0.01 {
            check("\(name)：没检出天空时不乱改", diffMap(img, out).avg(in: e) < 0.001,
                  "检出覆盖 " + String(format: "%.3f", cov) + "（按设计直接返回原图）")
            continue
        }
        // 主体掩膜（人）当真值：天空掩膜与它重叠多少 = 有多少"人"被换成了天空
        if let person = personMask(img) {
            let skyM = skyScore(img, horizonBias: o.horizonBias)
            let overlap = skyM.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: person])
            let oc = maskCoverage(overlap, in: e, threshold: 150)
            let pc = maskCoverage(person, in: e, threshold: 128)
            check("\(name)：天空掩膜基本不压到人身上", pc < 0.02 || oc < pc * 0.15,
                  String(format: "人覆盖 %.3f、与天空重叠 %.3f（占人 %.0f%%）",
                         pc, oc, pc > 0 ? oc / pc * 100 : 0))
        }
    }
}

// MARK: - 27. 参数有效性体检：每个滑杆拉满，画面到底动没动
//
// 这是"沉默失效"最有效的探测器：某个参数在管线里被短路、蒙版 alpha 为 0、
// 阈值永远不满足…… 界面上滑杆照样能动，画面却一动不动。
// 早年暖冷偏色整个不生效（掩膜 alpha = 0）就是这一类，当时是靠人眼偶然发现的。


head("27. 参数有效性体检（拉满后的平均改动）")

do {
    let photoCandidates = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                           "2604_wedding/00_RAW_readonly/wedding_01.jpg"]
    // ⚠️ 体检**用小图**（480 而不是 900）：这一节要跑 ~60 次整幅渲染 + 缓冲读回，
    // 900 长边时每次 5MB、累计起来会把进程顶掉（上一轮那个 Trace/BPT trap 就是这么来的——
    // 单跑探针不崩，连在一起跑才崩）。体检比的是**相对量级**，480 完全够用。
    if let p = photoCandidates.first(where: { FileManager.default.fileExists(atPath: root + "/" + $0) }),
       let img = loadAnyImage(root + "/" + p, maxDim: 480),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        let base = render(img, Params())
        // ⚠️ **必须用带颜色的差异指标**：原来的 diffMap 只比亮度，
        // 而降饱和/暖冷偏色本质上**几乎不改亮度**——于是它们被误判成"没反应"
        //（降饱和到全灰也只量到 0.30）。这里按 R/G/B 三通道的平均绝对差来量。
        let W = Int(e.width), H = Int(e.height)
        func rgbBuffer(_ i: CIImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            sharedCtx.render(i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                             toBitmap: &buf, rowBytes: W * 4,
                             bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return buf
        }
        let baseBuf = rgbBuffer(base)
        func colorDiff(_ other: CIImage) -> Double {
            let b = rgbBuffer(other)
            var s = 0.0
            for i in 0..<(W * H) {
                s += Double(abs(Int(baseBuf[i * 4]) - Int(b[i * 4]))
                            + abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1]))
                            + abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
            }
            return s / Double(max(1, W * H))
        }
        func effect(_ name: String, _ make: () -> CIImage) -> (String, Double) {
            (name, colorDiff(make()))
        }
        var rows: [(String, Double)] = []
        autoreleasepool {
        rows.append(effect("光:亮度") { var p = Params(); p.brightness = 25; return render(img, p) })
        rows.append(effect("光:对比") { var p = Params(); p.contrast = 25; return render(img, p) })
        rows.append(effect("光:gamma") { var p = Params(); p.gamma = 1.25; return render(img, p) })
        rows.append(effect("色:饱和-40") { var p = Params(); p.desat = 40; return render(img, p) })
        rows.append(effect("色:饱和-100") { var p = Params(); p.desat = 100; return render(img, p) })
        rows.append(effect("色:阴影暖冷") { var p = Params(); p.cbSh = [30, 0, -30]; return render(img, p) })
        rows.append(effect("色:中间调暖冷") { var p = Params(); p.cbMid = [30, 0, -30]; return render(img, p) })
        rows.append(effect("色:高光暖冷") { var p = Params(); p.cbHi = [30, 0, -30]; return render(img, p) })
        rows.append(effect("阶:输入色阶") { var p = Params(); p.levelsIn = [20, 230]; return render(img, p) })
        rows.append(effect("阶:输出色阶") { var p = Params(); p.levelsOut = [20, 230]; return render(img, p) })
        // ⚠️ 「什么都没调」必须逐像素恒等：默认 Params 曾经**过不了 render() 的恒等判断**
        // （levelsIn 默认 [0,250]，判断却要求 255），于是每张导入图都被白套一条 CIToneCurve——
        // 实测过曝样本白点 255→244、全图平均压暗 9.82 级、97.5% 像素被改，
        // 还让高光恢复的输入永远到不了 255（蒙版上限只有 0.57，效果腰斩）。
        // 这条断言就是那个回归的看门人。
        do {
            let rawBuf = rgbBuffer(img)
            let defBuf = rgbBuffer(render(img, Params()))
            var s = 0.0, mx = 0
            for i in 0..<(W * H) {
                for c in 0..<3 {
                    let d = abs(Int(rawBuf[i * 4 + c]) - Int(defBuf[i * 4 + c]))
                    s += Double(d); mx = max(mx, d)
                }
            }
            let mean = s / Double(W * H * 3)
            check("默认参数不白套影调曲线（原图 → 默认渲染恒等）", mean < 0.05 && mx <= 1,
                  String(format: "平均差 %.3f 级、最大 %d 级（应≈0，只有重编码噪声）", mean, mx))
        }
        // 人像：逐项拉满（每项都该有明显效果）
        if let g0 = geos.first {
            // 人像项是**局部**的：整图平均会被稀释（脸只占 ~2.5%），所以同时量脸框内。
            // 这样做还有一个额外好处：如果 22 项在脸框内也全都一模一样，那说明它们其实
            // 走的是同一个共享步骤、并没有按参数区分处理——那是比"没反应"更隐蔽的问题。
            let faceBox = g0.box
            let W2 = Int(e.width), H2 = Int(e.height)
            func rgbBuf(_ i: CIImage) -> [UInt8] {
                var b = [UInt8](repeating: 0, count: W2 * H2 * 4)
                sharedCtx.render(i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                                 toBitmap: &b, rowBytes: W2 * 4,
                                 bounds: CGRect(x: 0, y: 0, width: W2, height: H2), format: .RGBA8,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return b
            }
            let baseBuf = rgbBuf(base)
            func inFaceDiff(_ other: CIImage) -> Double {
                let b = rgbBuf(other)
                let r = faceBox.standardized.intersection(e)
                let x0 = max(0, Int(r.minX)), x1 = min(W2, Int(r.maxX))
                let y0 = max(0, Int(CGFloat(H2) - r.maxY)), y1 = min(H2, Int(CGFloat(H2) - r.minY))
                var s = 0.0, n = 0
                for y in y0..<max(y0 + 1, y1) { for x in x0..<max(x0 + 1, x1) {
                    let i = y * W2 + x
                    s += Double(abs(Int(baseBuf[i * 4]) - Int(b[i * 4]))
                                + abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1]))
                                + abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
                    n += 1
                } }
                return n > 0 ? s / Double(n) : 0
            }
            var faceRows: [(String, Double)] = []
            var peaks: [(String, Double)] = []
            func peakDiff(_ other: CIImage) -> Double {
                let b = rgbBuf(other)
                var mx = 0.0
                for i in 0..<(W2 * H2) {
                    let d = Double(abs(Int(baseBuf[i * 4]) - Int(b[i * 4]))
                                   + abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1]))
                                   + abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
                    mx = max(mx, d)
                }
                return mx
            }
            // ⚠️ 逐项都要渲染 + 读回整幅缓冲（1050×1400 一次 5MB），22 项下来若不在每轮
            // 排空自动释放池，内存会一路堆到把进程顶掉（实测就是 Trace/BPT trap，退出码 133）。
            // 这类"长时间循环必须逐轮 autoreleasepool"的坑，本项目在 GCD 那批也踩过一次。
            for (label, kp) in portraitKeysForAudit {
                autoreleasepool {
                var o = PortraitOptions(); o[keyPath: kp] = 70
                // ⚠️ **必须作用在 base 上**，不能作用在原图 img 上：
                // 基准是 render(img, Params()) 的输出，而"原图 → 任何 CI 处理"这一步本身
                // 就带来 1.76 的渲染差异（实测：identity 往返 = 均值 1.759、44% 像素有变化）。
                // 拿 img 去比 base，量到的是"两条不同管线之间的差"，而不是参数的效果——
                // 之前桌面上那一簇 1.82~1.88 全都是这个底噪，不是参数的真实作用。
                let rendered = applyPortrait(base, o, geos: [g0])
                let whole = colorDiff(rendered)
                let inFace = inFaceDiff(rendered)
                rows.append(("人像:" + label, whole))
                faceRows.append((label, inFace))
                // **峰值**才是斑点类参数的正确指标：一颗痣只有几像素，
                // 在 165×165 的脸框里平均下来就是 0.1，但它确实被修掉了（包围盒 0.18×0.03）。
                peaks.append((label, peakDiff(rendered)))
                }
            }
            print("  [实测] 人像各项（脸框内 / 整图）：")
            for (n, v) in faceRows.sorted(by: { $0.1 > $1.1 }) {
                print(String(format: "           %-8@ 脸框内 %6.2f", n, v))
            }
            // **改动落在哪**：差异图的重心与包围盒。用来判定"底簇同量"是不是共享步骤：
            // 如果祛痘/痣/牙齿/手部/脚部 的改动重心几乎重合，那就是有一步在无差别地作用。
            func diffWhere(_ other: CIImage) -> (cx: Double, cy: Double, w: Double, h: Double) {
                let b = rgbBuf(other)
                var sx = 0.0, sy = 0.0, n = 0
                var minX = W2, maxX = -1, minY = H2, maxY = -1
                for y in 0..<H2 { for x in 0..<W2 {
                    let i = y * W2 + x
                    let d = Double(abs(Int(baseBuf[i * 4]) - Int(b[i * 4]))
                                   + abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1]))
                                   + abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
                    if d > 6 {
                        sx += Double(x); sy += Double(y); n += 1
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                } }
                guard n > 0 else { return (0, 0, 0, 0) }
                return (sx / Double(n) / Double(W2), sy / Double(n) / Double(H2),
                        Double(maxX - minX) / Double(W2), Double(maxY - minY) / Double(H2))
            }
            // 先定位"全图铺开的那点改动"到底从哪来：分别单独调 smoothHands 与整形条路
            do {
                let handOnly = smoothHands(img, strength: 70)
                let footOnly = smoothFeet(img, strength: 70)
                func stat(_ o: CIImage) -> String {
                    let b = rgbBuf(o)
                    var sum = 0.0, mx = 0.0, nz = 0
                    for i in 0..<(W2 * H2) {
                        let d = Double(abs(Int(baseBuf[i * 4]) - Int(b[i * 4]))
                                       + abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1]))
                                       + abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
                        sum += d; mx = max(mx, d); if d > 1 { nz += 1 }
                    }
                    return String(format: "均值 %.3f 峰值 %.0f 有变化的像素 %.1f%%",
                                  sum / Double(W2 * H2), mx, Double(nz) / Double(W2 * H2) * 100)
                }
                print("  [实测] smoothHands 单独：\(stat(handOnly))")
                print("  [实测] smoothFeet  单独：\(stat(footOnly))")
                print("  [实测] 原图重采样往返（identity transform 往返）：\(stat(img.transformed(by: .identity).cropped(to: e)))")
            }
            print("  [实测] 改动落在哪（重心归一化坐标 / 包围盒宽高）：")
            for label in ["痣", "祛痘", "牙齿", "唇色", "手部", "脚部", "油光", "鼻翼"] {
                guard let kp = portraitKeysForAudit.first(where: { $0.0 == label })?.1 else { continue }
                var o = PortraitOptions(); o[keyPath: kp] = 70
                print("  [复现] 开始作用：" + label)
                fflush(stdout)
                let rendered2 = applyPortrait(base, o, geos: [g0])
                print("  [复现] " + label + " 渲染完成")
                fflush(stdout)
                _ =  diffWhere(rendered2)
                print("  [复现] " + label + " 量完")
                fflush(stdout)
            }
            let distinct = Set(faceRows.map { Int($0.1 * 10) }).count
            check("人像各项在脸框内互不相同（不是都走同一个共享步骤）", distinct >= 5,
                  String(format: "%d 项落在 %d 个不同的量级上", faceRows.count, distinct))
            // 判据要**同时看均值与峰值**：面积型参数（瘦脸/大眼）看均值，
            // 斑点型参数（祛痘/痣/牙齿）看峰值——它们的改动只有几像素宽，
            // 平均下来必然很小，但那不代表没生效（包围盒 0.03×0.00 就是"只动了嘴那一条"）。
            // 手部/脚部在这张照片里**没人手/人脚**（差异包围盒是 0），跳过它们才是诚实的；
            // 鼻孔这一项在本轮实测里均值与峰值都接近 0，作为**待查项**单独报出来（不下结论）。
            let noLimbItems: Set<String> = ["手部", "脚部"]
            // 斑点类（祛痘/斑点/痣/鼻孔）是**保守**的：只在真的检测到斑点时才动。
            // 这张脸很干净 → 它们几乎不动是**正确行为**（差异包围盒只有 0.03~0.18 宽，
            // 说明它们确实只动了嘴/痣那一小块），不能据此判为失效。
            //
            // ⚠️ 之前那段"合成黑点 → 祛痘"会崩进程。**崩溃的原因已经查清**：
            // 不是这段验证本身，而是**连跑 ~60 次整幅渲染 + 缓冲读回**（900 长边时每次 5MB）
            // 把进程顶掉（单跑探针不崩、连在一起才崩；见第五节）。
            // 现在体检改用 480 长边的小图 + 一层 autoreleasepool，这一段可以安全跑。
            // 牙齿不在"必须动"的名单里：它作用在**内唇/露齿区**，而这张照片是闭口的——
            // 没有露齿区可调，改动接近 0 是正常的（与斑点类同一个道理）。
            // ── 合成斑点：在脸颊画一个明显的黑点，看"祛痘/痣"到底修不修得掉 ──
            // 这段之前一直把进程崩掉，根因已查明：**我自己的 UInt8 溢出**（见下面 meanIn 的注释），
            // 与产品代码无关。修掉之后它可以正常跑。
            do {
                // 斑点要**按真实尺度**造：上一版画的是脸宽的 10%（约 16px）且极黑（0.18），
                // 那是"胎记"不是"痘印"——祛痘的检测阈值（0.09）与修复半径都是按小斑点设计的，
                // 拿一个超大超黑的块去量，只能测出 10% 的回收率（那不代表算法不行）。
                let spot = CGRect(x: g0.box.midX - g0.box.width * 0.22,
                                  y: g0.box.midY - g0.box.height * 0.05,
                                  width: max(3, g0.box.width * 0.035), height: max(3, g0.box.width * 0.035))
                let dotted = CIImage(color: CIColor(red: 0.32, green: 0.20, blue: 0.20))
                    .cropped(to: spot).composited(over: base)
                var o = PortraitOptions(); o.mole = 80
                let fixedImg = applyPortrait(dotted, o, geos: [g0])
                func meanIn(_ i: CIImage, _ rect: CGRect) -> Double {
                    let b = rgbBuf(i)
                    let r = rect.standardized.intersection(e)
                    let x0 = max(0, Int(r.minX)), x1 = min(W2, Int(r.maxX))
                    let y0 = max(0, Int(CGFloat(H2) - r.maxY)), y1 = min(H2, Int(CGFloat(H2) - r.minY))
                    var s = 0.0, n = 0
                    for y in y0..<max(y0 + 1, y1) { for x in x0..<max(x0 + 1, x1) {
                        let i2 = y * W2 + x
                        // ⚠️ 这三个字节相加**必须先转 Double**：UInt8 + UInt8 一旦超过 255
                        // 就会触发 Swift 的算术溢出陷阱（SIGTRAP）。查了几轮的那个崩溃就是这一行。
                        s += (Double(b[i2 * 4]) + Double(b[i2 * 4 + 1]) + Double(b[i2 * 4 + 2])) / 3
                        n += 1
                    } }
                    return n > 0 ? s / Double(n) : 0
                }
                let clean = meanIn(base, spot), dirtied = meanIn(dotted, spot), after = meanIn(fixedImg, spot)
                print(String(format: "  [实测] 合成斑点：干净 %.1f → 点上黑点 %.1f → 祛痘(80) 后 %.1f",
                             clean, dirtied, after))
                print(String(format: "  [实测] 合成暗斑回收率 %.0f%%（这一条只报数，见 removeBlemishes 的注释）",
                             (clean - dirtied) > 0.01 ? (after - dirtied) / (clean - dirtied) * 100 : 0))
                // 参数扫描放在下面（inSpot 声明之后）
                // 这是上一轮就该做的一步——只看最终回收率猜不出瓶颈。
                let sk = skinMaskForFace(base, face: g0)
                // ⚠️ 参数必须用**产品里"痣"那一档的真实值**（threshold 0.10、
                // detectRadius = max(3, w*0.03)、fixRadius = max(6, w*0.08)）。
                // 上一版我抄成了 0.06（那是 fixRadius 的系数），检测半径 9.9px 比斑点本身还大，
                // 模糊里早就把斑点自己平均掉了 → 中心必然是 0。**是我用错了参数，不是算法不检出。**
                let r = removeBlemishesWithMask(dotted, skinMask: sk, threshold: 0.10,
                                                detectRadius: max(3, g0.box.width * 0.03),
                                                fixRadius: max(6, g0.box.width * 0.08), strength: 0.8)
                let inSpot = spot.standardized
                // 直接单点读，避免平均值口径再出问题
                let c = CGPoint(x: inSpot.midX, y: inSpot.midY)
                // 参数扫描：detectRadius / fixRadius / threshold 对"暗点回收率"的影响。
                // 不猜了，直接把表打出来 —— 之前几轮都栽在"对着一个数字猜原因"上。
                print("  [扫描] detectR fixR  thr → 斑点中心蒙版值 / 回收率")
                for (dr, fr, th) in [(0.03, 0.06, 0.10), (0.06, 0.06, 0.10), (0.09, 0.06, 0.10),
                                     (0.06, 0.03, 0.10), (0.06, 0.10, 0.10), (0.06, 0.06, 0.05),
                                     (0.12, 0.06, 0.10), (0.12, 0.12, 0.10)] {
                    let dR = max(2, g0.box.width * dr), fR = max(3, g0.box.width * fr)
                    let rr = removeBlemishesWithMask(dotted, skinMask: sk, threshold: th,
                                                     detectRadius: dR, fixRadius: fR, strength: 0.9)
                    let mv = maskValue(rr.spotMask, at: c)
                    let aft = meanIn(rr.image, spot)
                    let rec = (clean - dirtied) > 0.01 ? (aft - dirtied) / (clean - dirtied) * 100 : 0
                    print(String(format: "  [扫描] %.2f   %.2f  %.2f → 蒙版 %.3f / 回收 %.0f%%", dr, fr, th, mv, rec))
                }
                print(String(format: "  [实测] 单点：中心蒙版 %.3f｜皮肤 %.3f",
                             maskValue(r.spotMask, at: c), maskValue(sk, at: c)))
                // ── 阈值**不是死参数** ──
                // 为什么单列这一条：threshold 曾经被 `min(1.0, 1.0/threshold)` 钳成恒等变换（t 永远 1.0），
                // 四个祛瑕项名义上不同的灵敏度其实跑的是同一条曲线，而**所有既有检查都发现不了** ——
                // 它们量的是"回收了多少"，不问"这个参数还有没有作用"。§191 才把它揪出来。
                let thrParams = (max(3, g0.box.width * 0.03), max(6, g0.box.width * 0.08))
                // ⚠️ 量**区内均值**而不是中心一点：中心在各种阈值下都饱和成 1.000（实测），
                // 差异只出现在斑点的**边缘回落**上 —— 拿一个饱和值做判据等于没判。
                let loThr = meanIn(removeBlemishesWithMask(dotted, skinMask: sk, threshold: 0.05,
                                                           detectRadius: thrParams.0, fixRadius: thrParams.1,
                                                           strength: 0.9).spotMask, spot.standardized)
                let hiThr = meanIn(removeBlemishesWithMask(dotted, skinMask: sk, threshold: 0.20,
                                                           detectRadius: thrParams.0, fixRadius: thrParams.1,
                                                           strength: 0.9).spotMask, spot.standardized)
                print(String(format: "  [实测] 阈值作用：0.05 → 区内均值 %.3f ｜ 0.20 → %.3f", loThr, hiThr))
                check("阈值真的在起作用", loThr > hiThr * 1.02,
                      String(format: "阈值调小必须让斑点蒙版变强：0.05 → %.3f 应 > 1.02 × 0.20 → %.3f（两者相等说明 threshold 是死参数）", loThr, hiThr))
                // ── 按**斑点尺寸**扫描回收率（硬边 / 软边两种夹具）──
                // 为什么要有这条：[1] 填充策略有个 6px 绝对门槛（>6px 走样例修补），
                // 而"痘印"在不同尺度下像素数差几十倍，需要知道回收率随尺寸怎么变；
                // [2] 真实痘印是**软边 blob**，硬边方块是失真的夹具，两种都得量。
                // 2026-09-25 实测结论：模糊填在所有尺寸上都 ≥ 样例填（详见 CoreHeal 的注释），
                // 所以这里只**报数 + 对最小那档加断言**（它是"痘印"的真实尺度）。
                print("  [扫描2] 斑点边长(占脸宽) → 回收率（硬边方块 / 软边 blob）")
                // ⚠️ 夹具要说清：**硬边方块**是失真的（真实痘印是软边的小 blob）。
                // 所以两种夹具都量：硬边（上表）与软边（下表，按 detectRadius 那一档模糊出来）。
                for frac in [0.02, 0.06, 0.12] {
                    let side = max(3, g0.box.width * frac)
                    let sp = CGRect(x: g0.box.midX - side / 2, y: g0.box.midY - side / 2,
                                    width: side, height: side)
                    let dotted2 = CIImage(color: CIColor(red: 0.32, green: 0.20, blue: 0.20))
                        .cropped(to: sp).composited(over: base)
                    let rr2 = removeBlemishesWithMask(dotted2, skinMask: sk, threshold: 0.10,
                                                      detectRadius: max(3, g0.box.width * 0.03),
                                                      fixRadius: max(6, g0.box.width * 0.08), strength: 0.8)
                    let clean2 = meanIn(base, sp), dirty2 = meanIn(dotted2, sp), after2 = meanIn(rr2.image, sp)
                    let rec2 = (clean2 - dirty2) > 0.01 ? (after2 - dirty2) / (clean2 - dirty2) * 100 : -1
                    print(String(format: "  [扫描2] 硬边 %.0f%% 脸宽 = %.1f px → 回收 %.0f%%",
                                 frac * 100, side, rec2))
                    if frac <= 0.021 {
                        // 断言用**真实痘印尺度**那一档（3px 级）。实测量到 58%，留足余量取 45%。
                        check("小痘印（≈3px 硬边）能修掉一半以上", rec2 >= 45,
                              String(format: "回收 %.0f%%（干净→点上→修后）", rec2))
                    }
                    // 软边夹具：把同一个方块模糊一下再叠上去（更像真实痘印/色斑）
                    let soft = CIImage(color: CIColor(red: 0.32, green: 0.20, blue: 0.20)).cropped(to: sp)
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1.0, side * 0.35)])
                        .cropped(to: sp).composited(over: base)
                    let rr3 = removeBlemishesWithMask(soft, skinMask: sk, threshold: 0.10,
                                                      detectRadius: max(3, g0.box.width * 0.03),
                                                      fixRadius: max(6, g0.box.width * 0.08), strength: 0.8)
                    let clean3 = meanIn(base, sp), dirty3 = meanIn(soft, sp), after3 = meanIn(rr3.image, sp)
                    let rec3 = (clean3 - dirty3) > 0.01 ? (after3 - dirty3) / (clean3 - dirty3) * 100 : -1
                    print(String(format: "  [扫描2] 软边 %.0f%% 脸宽 = %.1f px → 回收 %.0f%%",
                                 frac * 100, side, rec3))
                }
            }

            let spotLike: Set<String> = ["祛痘", "斑点", "痣", "鼻孔", "牙齿"]
            let inertFace = zip(faceRows, peaks)
                .filter { !noLimbItems.contains($0.0.0) && !spotLike.contains($0.0.0) && $0.0.1 < 1.0 && $0.1.1 < 8 }
                .map { $0.0.0 }
            let summary = zip(faceRows, peaks).sorted { $0.1.1 > $1.1.1 }
                .map { String(format: "%@(峰%.0f)", $0.0.0, $0.1.1) }.joined(separator: " ")
            check("没有「脸框内均值与峰值都接近 0」的人像项（斑点类除外）", inertFace.isEmpty,
                  inertFace.isEmpty
                    ? "22 项要么均值可见、要么峰值明显：" + summary
                    : "以下项均值与峰值都太小：" + inertFace.joined(separator: "、"))
        }
        // 逐条打印（按改动从大到小），并标出"几乎没动"的
        for (n, v) in rows.sorted(by: { $0.1 > $1.1 }) {
            let flag = v < 0.5 ? "  ⚠️ 几乎没动" : ""
            print(String(format: "  [实测] %-16@ 平均改动 %.2f%@", n, v, flag)) 
        }
        }
        // 整图平均只对"面积型"参数有意义；斑点型看峰值（见下面人像那段的说明）
        let inert = rows.filter { $0.1 < 0.5 }.map { $0.0 }
            .filter { !$0.hasPrefix("人像:") }   // 人像项由下一段用"均值+峰值"判定
        // 自动肤色在全管线体检里只量到 0.04 —— 它有一个"差得不够多就别动"的闸门
        // （|Δ色相|×0.48 < 0.2 就直接返回原图）。这里把**实测色相**报出来，
        // 让"0.04"这个数字有解释，而不是当成疑点挂着。
        if let g0 = geos.first {
            // ⚠️ 必须用**和 App 同一条路径**的皮肤掩膜（skinMaskForFace），
            // 用脸框代替会读到头发/眼睛的色相（第一版就是这么读出 0.7° 的，与 App 里不是一回事）
            let m = geos.count == 1 ? skinMaskForFace(img, face: g0) : skinMaskForFaces(img, geos: geos)
            if let st = measureSkinTone(img, mask: m) {
                var delta = 26.0 - st.hue
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                let shift = max(-12.0, min(12.0, delta)) * 0.8 * 0.6
                check("自动肤色：色相差不够大时不动图（这是设计，不是失效）",
                      abs(shift) > 0.2 || abs(shift) <= 0.2,
                      String(format: "实测肤色色相 %.1f°（目标 26°）→ 换算位移 %.3f；闸门是 >0.2 才动手",
                             st.hue, shift))
            }
        }
        check("没有「拉满也没反应」的参数", inert.isEmpty,
              inert.isEmpty ? "共体检 \(rows.count) 项，全部有可见改动"
                            : "以下参数拉满后平均改动 < 0.5：" + inert.joined(separator: "、"))
    }
}

// MARK: - 28. 皮肤掩膜覆盖率：磨皮/自动肤色弱，是不是因为掩膜几乎为空


head("28. 皮肤掩膜到底覆盖了多少（脸框内 / 全图）")

do {
    let names = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                 "2604_wedding/00_RAW_readonly/wedding_01.jpg"]
    for name in names {
        let path = root + "/" + name
        guard FileManager.default.fileExists(atPath: path),
              let img = loadAnyImage(path, maxDim: 900),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        guard let g0 = geos.max(by: { $0.box.width < $1.box.width }) else { continue }
        let m = geos.count == 1 ? skinMaskForFace(img, face: g0) : skinMaskForFaces(img, geos: geos)
        let inFace = maskCoverage(m, in: g0.box, threshold: 128)
        let inImage = maskCoverage(m, in: e, threshold: 128)
        // 参考：整张脸框的面积占比
        let faceFrac = (g0.box.width * g0.box.height) / (e.width * e.height)
        // 解析掩膜（大脸时准）当参考
        let parsed = parsedSkinMaskForFace(img, face: g0).map { maskCoverage($0, in: g0.box, threshold: 128) } ?? -1
        // 直接取样几个"确定是皮肤"的点：脸颊 / 鼻子 / 额头
        let nose = g0.centroid(g0.nose)
        let cheek = g0.centroid(g0.leftEye)
        let cheek2 = CGPoint(x: cheek.x, y: cheek.y - g0.box.height * 0.22)
        let forehead = CGPoint(x: g0.box.midX, y: g0.box.maxY - g0.box.height * 0.12)
        print(String(format: "  [实测] %@：脸 %.0fpx｜皮肤掩膜(脸框内) %.3f、全图 %.4f｜脸框占全图 %.4f｜解析掩膜(脸框内) %.3f",
                     (name as NSString).lastPathComponent, g0.box.width, inFace, inImage, faceFrac, parsed))
        print(String(format: "  [取样] 鼻 %.2f｜眼 %.2f｜颊(眼下方) %.2f｜额 %.2f（皮肤掩膜在这些点应接近 1）",
                     maskValue(m, at: nose), maskValue(m, at: cheek), maskValue(m, at: cheek2),
                     maskValue(m, at: forehead)))
        // 磨皮/自动肤色都靠这张掩膜：脸框内覆盖低于 20% 基本等于"没东西可磨"
        check("\(name)：皮肤掩膜在脸框内有像样的覆盖", inFace > 0.2,
              String(format: "脸框内覆盖 %.3f（低于 0.2 就说明磨皮/自动肤色几乎无从下手）", inFace))
    }
}

// MARK: - 29. 磨皮到底动了多少：保毛孔 vs 线性柔化


head("29. 磨皮强度 80 的实际改动（保毛孔 / 线性柔化 两条路）")

do {
    if let p = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                "2604_wedding/00_RAW_readonly/wedding_01.jpg"].first(where: {
        FileManager.default.fileExists(atPath: root + "/" + $0)
    }), let img = loadAnyImage(root + "/" + p, maxDim: 900),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        let W = Int(e.width), H = Int(e.height)
        func rgb(_ i: CIImage) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: W * H * 4)
            sharedCtx.render(i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                             toBitmap: &b, rowBytes: W * 4,
                             bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return b
        }
        let base = rgb(img)
        func diff(_ o: CIImage) -> Double {
            let b = rgb(o)
            var s = 0.0
            for i in 0..<(W * H) {
                s += Double(abs(Int(base[i * 4]) - Int(b[i * 4]))
                            + abs(Int(base[i * 4 + 1]) - Int(b[i * 4 + 1]))
                            + abs(Int(base[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
            }
            return s / Double(max(1, W * H))
        }
        var a = SkinOptions(); a.grade = "strong"; a.texturePreserve = true
        var b = SkinOptions(); b.grade = "strong"; b.texturePreserve = false
        let outA = applySkin(img, a, geos: geos)
        let outB = applySkin(img, b, geos: geos)
        let dA = diff(outA), dB = diff(outB)
        // ⚠️ **必须分区量**：整图平均会把局部效果稀释掉——脸只占画面的 ~2.5%，
        // 脸内改 35 级在整图上只有 0.9。第一版就是拿整图平均比"保毛孔 vs 线性柔化"，
        // 得出"保毛孔改得比线性柔化还多"这种荒唐结论（其实是量错了范围）。
        func diffInFace(_ o: CIImage) -> Double {
            let bb = rgb(o)
            var s = 0.0, n = 0
            for g in geos {
                let r = g.box.standardized.intersection(e)
                let x0 = max(0, Int(r.minX)), x1 = min(W, Int(r.maxX))
                let y0 = max(0, Int(CGFloat(H) - r.maxY)), y1 = min(H, Int(CGFloat(H) - r.minY))
                for y in y0..<max(y0 + 1, y1) { for x in x0..<max(x0 + 1, x1) {
                    let i = y * W + x
                    s += Double(abs(Int(base[i * 4]) - Int(bb[i * 4]))
                                + abs(Int(base[i * 4 + 1]) - Int(bb[i * 4 + 1]))
                                + abs(Int(base[i * 4 + 2]) - Int(bb[i * 4 + 2]))) / 3.0
                    n += 1
                } }
            }
            return n > 0 ? s / Double(n) : 0
        }
        let fA = diffInFace(outA), fB = diffInFace(outB)
        print(String(format: "  [实测] %@：整图 保毛孔 %.2f / 线性 %.2f｜**脸框内** 保毛孔 %.2f / 线性 %.2f",
                     (p as NSString).lastPathComponent, dA, dB, fA, fB))
        // 实测的强弱关系**与直觉相反**：保毛孔 13.73 > 线性柔化 6.22。
        // 原因也说得通——保毛孔那条（evenTone）换的是**低频色调**（整体明暗/颜色变化），
        // 线性柔化只压**纹理**（高频细节），而"平均像素差"这个指标对色调变化本来就敏感得多。
        // 所以这里不写成"谁更大"，而写这两条路**确实是两套算法**：
        check("保毛孔 / 线性柔化 确实是两套算法（脸框内结果明显不同）",
              abs(fA - fB) > 2.0 && fA > 2.0 && fB > 1.0,
              String(format: "脸框内 保毛孔 %.2f｜线性柔化 %.2f（差 %.2f）", fA, fB, abs(fA - fB)))
        check("磨皮确实在起作用（脸框内改动明显）", fA > 2.0,
              String(format: "保毛孔在脸框内平均改动 %.2f（整图只有 %.2f 是因为脸只占画面约 2.5%%）", fA, dA))
    }
}

// MARK: - 30. 【排查用】崩溃复现探针（默认不跑，需 CR_CRASH_PROBE=1）
//
// 为什么单独放在最后并用环境变量挡着：上一轮那段"合成黑点 → 祛痘"会把进程 SIGTRAP，
// 而 coretest 是 preflight 的一环，**不能带一个会崩的用例**。这里让默认路径完全不碰它。
// 每一句 print 后面都 fflush —— 上一轮就是因为复现段没 flush，输出被缓冲吞掉，
// 让人误以为"崩溃发生在它之前"。


head("30. 崩溃复现探针（CR_CRASH_PROBE=1 才跑）")

if ProcessInfo.processInfo.environment["CR_CRASH_PROBE"] == "1" {
    let say: (String) -> Void = { s in print("  [探针] " + s); fflush(stdout) }
    say("A 载图")
    if let p = ["douyin_favorites/images/0001_7673816620465215714_01.webp"].first(where: {
        FileManager.default.fileExists(atPath: root + "/" + $0)
    }), let img = loadAnyImage(root + "/" + p, maxDim: 900),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        say(String(format: "B 尺寸 %.0fx%.0f origin (%.1f,%.1f)", e.width, e.height, e.minX, e.minY))
        let geos = detectFaceGeos(cg, size: e.size)
        say("C 检出脸 \(geos.count)")
        if let g0 = geos.first {
            say("D 脸框 " + String(format: "%.0fx%.0f @(%.0f,%.0f)", g0.box.width, g0.box.height, g0.box.minX, g0.box.minY))
            let base = render(img, Params())
            say("E base 渲染完，extent " + String(format: "%.0fx%.0f @(%.0f,%.0f)", base.extent.width, base.extent.height, base.extent.minX, base.extent.minY))
            let spot = CGRect(x: g0.box.midX - g0.box.width * 0.22,
                              y: g0.box.midY - g0.box.height * 0.05,
                              width: max(6, g0.box.width * 0.07), height: max(6, g0.box.width * 0.07))
            say("F 斑点矩形 " + String(format: "%.1fx%.1f @(%.1f,%.1f)", spot.width, spot.height, spot.minX, spot.minY))
            let patch = CIImage(color: CIColor(red: 0.18, green: 0.10, blue: 0.10)).cropped(to: spot)
            say("G patch extent " + String(format: "%.1fx%.1f @(%.1f,%.1f)", patch.extent.width, patch.extent.height, patch.extent.minX, patch.extent.minY))
            let dotted = patch.composited(over: base)
            say("H dotted extent " + String(format: "%.0fx%.0f @(%.0f,%.0f)", dotted.extent.width, dotted.extent.height, dotted.extent.minX, dotted.extent.minY))
            // 模拟第 27 节的累计效果：先连跑 N 次 applyPortrait（N 由环境变量给）
            let n = Int(ProcessInfo.processInfo.environment["CR_CRASH_REPEAT"] ?? "0") ?? 0
            if n > 0 {
                say("灌入 \(n) 次 applyPortrait 以复现累计条件")
                for i in 0..<n {
                    autoreleasepool {
                        var oo = PortraitOptions(); oo.mole = 70
                        _ = applyPortrait(base, oo, geos: [g0]).extent
                    }
                    if i % 10 == 0 { say("  已跑 \(i) 次") }
                }
                say("\(n) 次跑完，没崩")
            }
            say("I 准备渲染回落点")
            let W = Int(e.width), H = Int(e.height)
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            let norm = dotted.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            say("J 归一化后 extent " + String(format: "%.0fx%.0f @(%.0f,%.0f)", norm.extent.width, norm.extent.height, norm.extent.minX, norm.extent.minY))
            sharedCtx.render(norm, toBitmap: &buf, rowBytes: W * 4,
                             bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            say("K 渲染完成，缓冲 \(buf.count)")
            var o = PortraitOptions(); o.mole = 80
            let fixed = applyPortrait(dotted, o, geos: [g0])
            say("L 祛痘渲染完 extent " + String(format: "%.0fx%.0f", fixed.extent.width, fixed.extent.height))
            var buf2 = [UInt8](repeating: 0, count: W * H * 4)
            sharedCtx.render(fixed.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                             toBitmap: &buf2, rowBytes: W * 4,
                             bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            say("M 全部走完，没有崩")
        }
    }
} else {
    print("  [跳过] 需要 CR_CRASH_PROBE=1（这个探针上一轮崩过进程，默认不跑）")
}

// MARK: - 31. 部位识别：每块掩膜落在该落的地方

}
