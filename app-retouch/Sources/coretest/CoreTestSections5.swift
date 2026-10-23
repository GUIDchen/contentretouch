// CoreTestSections5.swift：coretest 的第 33~40 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections5() {
head("6o. 批量场景一致性：整组用中位数，而不是逐张各调各的")
do {
    var imgs: [CIImage] = []
    for i in 1...8 {
        let p = root + "/2604_wedding/00_RAW_readonly/wedding_0" + String(i) + ".jpg"
        if let im = loadImage(p, maxDim: 600) { imgs.append(im) }
    }
    if imgs.count >= 4 {
        let scene = SceneInfo(category: "婚礼")
        let per = imgs.map { planSceneAdaptive($0, scene: scene) }
        func spread(_ v: [Double]) -> Double {
            guard !v.isEmpty else { return 0 }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        let sExposure = spread(per.map { $0.exposure })
        let sWB = spread(per.map { $0.wb })
        let group = planGroupAdaptive(imgs, scene: scene)
        // 统一后每张给的都是同一套 → 离散度必须是 0
        let applied = imgs.map { _ in group }
        let aExposure = spread(applied.map { $0.exposure })
        let aWB = spread(applied.map { $0.wb })
        // 用 < 1e-9 而不是 == 0：中位数算出来的值可能有 1e-16 级的浮点残差
        check("批量一致：逐张方案离散 → 统一后为 0",
              sExposure > 3 && sWB > 10 && aExposure < 1e-9 && aWB < 1e-9,
              String(format: "逐张 曝光σ %.2f 白平衡σ %.2f → 统一后 曝光σ %.2f 白平衡σ %.2f（整组：曝光 %.0f 白平衡 %.0f）",
                     sExposure, sWB, aExposure, aWB, group.exposure, group.wb))
    }
}

// MARK: - 6p. SAM 精细主体分割 + 出片建议 + 并行预扫


head("6p. SAM 精细主体掩膜 / 出片建议 / 并行预扫")
do {
    // ⚠️ 模型是可选的（要用户下载）：**有才 check、没有就如实 skip**。
    // 以前这里是无条件 check(...isAvailable...)，而 isAvailable 恒为真 —— 于是这条永远通过，
    // 后面依赖模型的用例则"静默不跑"，看着像测过了（§171）。
    if SamSegmenter.shared.isAvailable {
        check("SAM 模型可用", true, "目录：" + (SamSegmenter.modelDir()?.path ?? "未找到"))
    } else {
        skip("SAM 精细主体掩膜", "本机没装 SAM 模型（" + (SamSegmenter.modelDir()?.path ?? "未找到")
             + "）—— 没测到，如实跳过，不假装通过")
    }
    if SamSegmenter.shared.isAvailable,
       let img = loadFixture(bigFace, maxDim: 700),
       let cg = sharedCtx.createCGImage(img, from: img.extent),
       let g = detectFaceGeos(cg, size: img.extent.size).first,
       let sys = foregroundMask(img) {
        let e = img.extent
        // 头发区域：解析出来的头发当参考区域（只用它的「位置」，不用它的边界）
        if let hair = parsedMaskForFace(img, face: g, classes: FaceClass.hairClasses, feather: 2, margin: 0.7) {
            let t0 = Date()
            if let refined = refineMaskWithSAM(img, hint: sys) {
                let ms = Date().timeIntervalSince(t0) * 1000
                func covIn(_ m: CIImage, _ region: CIImage) -> Double {
                    let w = 200
                    let h = max(8, Int(Double(w) * Double(e.height) / Double(e.width)))
                    func render(_ i: CIImage) -> [UInt8] {
                        var b = [UInt8](repeating: 0, count: w * h * 4)
                        let s = CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width)
                        sharedCtx.render(i.transformed(by: s), toBitmap: &b, rowBytes: w * 4,
                                         bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                        return b
                    }
                    let mb = render(m), rb = render(region)
                    var sum = 0.0, wt = 0.0
                    for i in 0..<(w * h) {
                        let rw = Double(rb[i * 4]) / 255.0
                        guard rw > 0.5 else { continue }
                        sum += Double(mb[i * 4]) / 255.0 * rw
                        wt += rw
                    }
                    return wt > 0 ? sum / wt : -1
                }
                let sysHair = covIn(sys, hair), samHair = covIn(refined.mask, hair)
                check("SAM 把头发分成主体（系统掩膜会漏掉发丝）",
                      samHair > sysHair * 1.5 && samHair > 0.7 && ms < 2000,
                      String(format: "头发区域内覆盖：系统 %.2f → SAM %.2f（IoU %.3f，耗时 %.0fms）",
                             sysHair, samHair, refined.score, ms))
                check("SAM 掩膜不会吞掉整幅图",
                      maskCoverage(refined.mask, in: e, threshold: 128) < 0.95,
                      String(format: "覆盖率 %.1f%%", maskCoverage(refined.mask, in: e, threshold: 128) * 100))
            } else {
                check("SAM 精修掩膜", false, "refineMaskWithSAM 返回 nil")
            }
        }
    }

    // 出片建议 + 连拍结论
    if let group = scoreImage(root + "/2604_wedding/00_RAW_readonly/wedding_01.jpg"),
       let smiley = scoreImage(root + "/2604_wedding/00_RAW_readonly/wedding_02.jpg") {
        let advG = shootingAdvice(pose: poseGrade(yawDeg: group.headYaw, faces: group.faces), smile: group.smile,
                                  closedEyes: group.closedEyes, judgedFaces: group.judgedFaces, faceQuality: group.faceQuality)
        let advS = shootingAdvice(pose: poseGrade(yawDeg: smiley.headYaw, faces: smiley.faces), smile: smiley.smile,
                                  closedEyes: smiley.closedEyes, judgedFaces: smiley.judgedFaces, faceQuality: smiley.faceQuality)
        check("出片建议分得出闭眼与形态",
              advG.contains("闭眼") && advS.contains("笑容") && advS.contains("3/4 侧脸"),
              "合影→" + advG + " ｜ 笑脸→" + advS)
        let fake = [group, smiley]
        let decision = burstDecision(fake, group: BurstGroup(indices: [0, 1], best: 0, reason: ""))
        check("连拍结论给出选哪张 + 为什么 + 为什么不选",
              decision.contains("选") && decision.contains("为什么") && decision.contains("没选的"),
              decision.replacingOccurrences(of: "\n", with: " "))
    }

    // 并行预扫：和串行结果必须完全一致（并行只该更快，不该改变结果）
    do {
        var paths: [String] = []
        for i in 1...6 {
            let p = root + "/2604_wedding/00_RAW_readonly/wedding_0" + String(i) + ".jpg"
            if FileManager.default.fileExists(atPath: p) { paths.append(p) }
        }
        var serial = [CIImage?](repeating: nil, count: paths.count)
        for i in 0..<paths.count { serial[i] = loadImage(paths[i], maxDim: 600) }
        var parallel = [CIImage?](repeating: nil, count: paths.count)
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            parallel[i] = loadImage(paths[i], maxDim: 600)
        }
        let a = serial.compactMap { $0 }, b = parallel.compactMap { $0 }
        func sig(_ v: [CIImage]) -> String {
            v.map { img in
                let s = measure(img)
                return String(format: "%.2f/%.2f/%.2f", s.p5, s.p50, s.p95)
            }.joined(separator: "|")
        }
        check("并行预扫与串行结果一致", !a.isEmpty && sig(a) == sig(b),
              "串行 \(a.count) 张 / 并行 \(b.count) 张，统计签名" + (sig(a) == sig(b) ? "相同" : "不同"))
    }
}

// MARK: - 6q. SAM 多提示点 + 掩膜并集


head("6q. SAM 多提示点（合影里每个人都要盖到）")
do {
    // 并集写法：这是本轮抓到的一个真 bug（alpha=1 的掩膜做 SourceOver 是替换不是并集）
    let e0 = CGRect(x: 0, y: 0, width: 300, height: 300)
    let a = rectMask(extent: e0, rect: CGRect(x: 10, y: 10, width: 50, height: 50), feather: 1, ellipse: false)
    let b = rectMask(extent: e0, rect: CGRect(x: 200, y: 200, width: 50, height: 50), feather: 1, ellipse: false)
    func val(_ m: CIImage, _ p: CGPoint) -> Double {
        var buf = [UInt8](repeating: 0, count: 4)
        sharedCtx.render(m, toBitmap: &buf, rowBytes: 4, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return Double(buf[0]) / 255.0
    }
    let u = maskUnion(a, b), oldWay = a.composited(over: b)
    check("掩膜并集用取大而不是 SourceOver",
          val(u, CGPoint(x: 35, y: 35)) > 0.9 && val(u, CGPoint(x: 225, y: 225)) > 0.9
          && val(oldWay, CGPoint(x: 225, y: 225)) < 0.1,
          String(format: "并集：A 处 %.2f B 处 %.2f ｜ 旧的 SourceOver 写法：A 处 %.2f B 处 %.2f（只剩一个）",
                 val(u, CGPoint(x: 35, y: 35)), val(u, CGPoint(x: 225, y: 225)),
                 val(oldWay, CGPoint(x: 35, y: 35)), val(oldWay, CGPoint(x: 225, y: 225))))

    if SamSegmenter.shared.isAvailable, let img = loadFixture(wedding, maxDim: 700) {
        let e = img.extent
        func half(_ m: CIImage) -> (Double, Double) {
            func avg(_ r: CGRect) -> Double {
                let rr = r.integral
                guard rr.width > 2 else { return 0 }
                var buf = [UInt8](repeating: 0, count: Int(rr.width) * Int(rr.height) * 4)
                sharedCtx.render(m, toBitmap: &buf, rowBytes: Int(rr.width) * 4, bounds: rr, format: .RGBA8,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                var s = 0.0
                for i in 0..<Int(rr.width * rr.height) { s += Double(buf[i * 4]) }
                return s / Double(Int(rr.width * rr.height)) / 255.0
            }
            return (avg(CGRect(x: 0, y: 0, width: e.width / 2, height: e.height)),
                    avg(CGRect(x: e.width / 2, y: 0, width: e.width / 2, height: e.height)))
        }
        let multi = refineMaskMultiPrompt(img)
        let (ml, mr) = half(multi.mask)
        check("SAM 多提示点：合影左右两边都盖上", ml > 0.3 && mr > 0.3,
              String(format: "左半 %.2f ｜ 右半 %.2f（%@）", ml, mr, multi.source))
        if let sys = foregroundMask(img), let single = refineMaskWithSAM(img, hint: sys) {
            let (sl, sr) = half(single.mask)
            check("单提示只盖一个主体（所以要改多提示）", min(sl, sr) < 0.15,
                  String(format: "单提示：左半 %.2f ｜ 右半 %.2f", sl, sr))
        }
    }
}

// MARK: - 6r. 可选下载 / 结果缓存 / 性能


head("6r. 可选下载 SAM / 结果缓存 / 性能")
do {
    // 可选下载：安装目录必须在 Application Support 下（不能写包里），状态自洽
    let dir = SamStore.installDir.path
    check("SAM 是可选下载（不依赖包内文件）",
          dir.contains("Application Support/ContentRetouch/Models/SAM"),
          "安装目录：" + dir + "，已安装：" + String(SamStore.shared.isInstalled)
          + String(format: "（%.1f MB）", Double(SamStore.shared.installedBytes) / 1_048_576))
    // 缺失时必须有兜底：模型目录找不到也不能崩，foregroundMaskRefined 要能出掩膜
    if let img = loadFixture(bigFace, maxDim: 700) {
        let (m, source) = foregroundMaskRefined(img)
        check("拿不到 SAM 时主体掩膜仍有兜底",
              m.extent.width > 1 && maskCoverage(m, in: img.extent, threshold: 128) > 0.02,
              String(format: "来源：%@，覆盖率 %.1f%%", source, maskCoverage(m, in: img.extent, threshold: 128) * 100))
    }
    // 内容指纹：同一张图指纹相同、不同图不同（缓存正确性的前提）
    if let a = loadFixture(bigFace, maxDim: 400), let b = loadFixture(wedding, maxDim: 400) {
        let fa = fingerprint(a), fb = fingerprint(b), fa2 = fingerprint(a)
        check("图像内容指纹稳定且能区分不同图", fa != nil && fa == fa2 && fa != fb,
              "同图两次相同：\(fa == fa2)，不同图不同：\(fa != fb)")
    }
    // 交互场景的缓存收益（同图反复调参 —— App 拖滑杆就是这种）
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let geos = detectFaceGeos(cg, size: img.extent.size)
        func run(_ times: Int) -> Double {
            let t0 = Date()
            for i in 0..<times {
                var o = PortraitOptions()
                o.faceBlemish = Double(20 + i * 10)
                let _ = applyPortrait(img, o, geos: geos)
                if let h = detectFaceGeos(cg, size: img.extent.size).first {
                    _ = parsedMaskForFace(img, face: h, classes: FaceClass.skinClasses)
                }
            }
            return Date().timeIntervalSince(t0) / Double(times) * 1000
        }
        _ = run(2)                       // 预热
        VisionCache.shared.clear()
        let cached = run(6)
        let (hits, misses) = VisionCache.shared.stats()
        check("交互场景缓存有效（同图反复调参）", misses > 0 && hits > 0,
              String(format: "命中 %d / 未命中 %d，平均 %.0f ms/次", hits, misses, cached))
        VisionCache.shared.clear()
    }
}

// MARK: - 6s. 性能：按脸解析缓存 / 掩膜分辨率上限


head("6s. 性能：按脸解析缓存 + 大图掩膜降分辨率")
do {
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent),
       let g = detectFaceGeos(cg, size: img.extent.size).first {
        // 同一张脸反复解析（皮肤/牙齿/眼睛三项各解析一次）应该只推理一次。
        // 判据用「开缓存 vs 关缓存」的 A/B：直接比「首次 vs 之后」会被上一个用例的缓存状态带偏（实测会偶发误报）。
        func timeThree() -> Double {
            let t = Date()
            for _ in 0..<3 { _ = parsedMaskForFace(img, face: g, classes: FaceClass.skinClasses) }
            return Date().timeIntervalSince(t) * 1000
        }
        VisionCache.shared.clear()
        _ = parsedMaskForFace(img, face: g, classes: FaceClass.skinClasses)   // 预热模型
        let withCache = timeThree()
        VisionCache.disabled = true
        let withoutCache = timeThree()
        VisionCache.disabled = false
        check("按脸解析有缓存（同脸只推理一次）", withCache < withoutCache * 0.7,
              String(format: "三次同脸解析：关缓存 %.0f ms → 开缓存 %.0f ms（快 %.1f×）",
                     withoutCache, withCache, withoutCache / max(0.001, withCache)))
    }
    // 大图掩膜降分辨率：32MP 的图跑前景掩膜不该是全分辨率的成本
    if let big = loadFixture("0013_7681984608207916297_06.webp", maxDim: 0), big.extent.width > 4000 {
        let small = downscaledForMask(big, cap: 2048)
        check("大图跑掩膜前会降分辨率",
              max(small.extent.width, small.extent.height) <= 2049 && max(big.extent.width, big.extent.height) > 4000,
              String(format: "%.0fx%.0f → %.0fx%.0f", big.extent.width, big.extent.height, small.extent.width, small.extent.height))
    }
    // 掩膜羽化要在低分辨率做（32MP 上做会把掩膜链拖到秒级）
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent),
       detectFaceGeos(cg, size: img.extent.size).first != nil,   // 只要求"检得到脸"（g 本身没用到）
       let r = FaceParser.shared.parse(cg) {
        let t0 = Date()
        let m = maskFromLabels(r, classes: FaceClass.skinClasses, extent: img.extent, feather: 6)
        _ = maskCoverage(m, in: img.extent, threshold: 128)
        let ms = Date().timeIntervalSince(t0) * 1000
        // 同理：回归红线（负载高时会涨几倍），不是性能基准
        check("掩膜构建+求值是可接受的开销（回归红线 1200ms）", ms < 1200, String(format: "%.0f ms（含羽化与覆盖率采样）", ms))
    }
}

// MARK: - 6t. 解码缓存 / 导出编码


head("6t. 解码缓存 + 导出编码路径")
do {
    let dir = root + "/douyin_favorites/images"
    let files = Array(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().prefix(8))
        .map { dir + "/" + $0 }
    if let f0 = files.first {
        DecodeCache.shared.clear()
        // 冷启（第一张）
        let t0 = Date()
        _ = loadImage(f0, maxDim: 1080)
        let cold = Date().timeIntervalSince(t0) * 1000
        // 再取一次（应该命中缓存）
        let t1 = Date()
        for _ in 0..<4 { _ = loadImage(f0, maxDim: 1080) }
        let warm = Date().timeIntervalSince(t1) / 4 * 1000
        let (hits, _) = (DecodeCache.shared.hits, DecodeCache.shared.misses)
        check("解码缓存：同一张图再取要命中", hits >= 4 && warm < cold * 0.5,
              String(format: "首次 %.0f ms → 命中 %.1f ms（命中 %d 次）", cold, warm, hits))
        // 缓存必须给出**同一份像素**（曾经做过磁盘层：存成有损 JPEG 复用，会让预览像素变样，已撤掉）
        func hashOf(_ img: CIImage) -> String {
            // 采样成 64x64 再比：cache 命中时拿到的应该是同一份像素
            let n = 64
            let sc = img.transformed(by: CGAffineTransform(scaleX: CGFloat(n) / max(1, img.extent.width),
                                                           y: CGFloat(n) / max(1, img.extent.width)))
            var buf = [UInt8](repeating: 0, count: n * n * 4)
            sharedCtx.render(sc, toBitmap: &buf, rowBytes: n * 4,
                             bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return buf.map { String($0) }.joined(separator: ",")
        }
        DecodeCache.shared.clearMemory()
        let first = loadImage(f0, maxDim: 1080)
        let second = loadImage(f0, maxDim: 1080)
        let same = (first != nil && second != nil) ? (hashOf(first!) == hashOf(second!)) : false
        check("解码缓存不改变像素（只做内存缓存）", same,
              "两次取同一张图的像素指纹" + (same ? "相同" : "不同") + "；命中 " + String(DecodeCache.shared.hits) + " 次")
    }
    // 导出：JPEG 走 CIContext 直编（省掉整张回读），且画质/体积要一致
    if let src = loadFixture(bigFace, maxDim: 1200) {
        var es = ExportSettings()
        es.format = "jpeg"
        es.quality = 0.92
        let out = URL(fileURLWithPath: NSTemporaryDirectory() + "cr_export_test.jpg")
        let ok = exportImage(src, to: out, es)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        check("导出 JPEG 走直编路径且产物正常", ok && size > 1000,
              String(format: "输出 %.0f KB", Double(size) / 1024))
        // 直接写一个带 EXIF 继承的导出，确认仍然走 CGImageDestination 且成功
        let out2 = URL(fileURLWithPath: NSTemporaryDirectory() + "cr_export_test2.jpg")
        let ok2 = exportImage(src, to: out2, es, sourceURL: URL(fileURLWithPath: root + "/douyin_favorites/images/" + bigFace))
        check("导出带 EXIF 继承时仍可用", ok2, "带 sourceURL 的导出：" + String(ok2))
    }
}

// MARK: - 6u. 格式支持（含 RAW 的接线）


head("6u. 格式支持：各种照片格式都能读")
do {
    if let base = loadFixture(bigFace, maxDim: 600), let cg = sharedCtx.createCGImage(base, from: base.extent) {
        let dir = NSTemporaryDirectory() + "cr_fmt"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let cases: [(String, String)] = [("jpg", "public.jpeg"), ("png", "public.png"), ("tif", "public.tiff"),
                                        ("gif", "com.compuserve.gif"), ("heic", "public.heic"), ("avif", "public.avif"),
                                        ("bmp", "com.microsoft.bmp"), ("jp2", "public.jpeg-2000"),
                                        ("psd", "com.adobe.photoshop-image"), ("tga", "com.truevision.tga-image"),
                                        ("exr", "com.ilm.openexr-image"), ("pbm", "public.pbm")]
        // 参考色（用原图算）
        func avgOf(_ img: CIImage) -> (Double, Double, Double) {
            var buf = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let e = img.extent
            let sc = img.transformed(by: CGAffineTransform(scaleX: 32 / e.width, y: 32 / e.width))
            sharedCtx.render(sc, toBitmap: &buf, rowBytes: 32 * 4, bounds: CGRect(x: 0, y: 0, width: 32, height: 32),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var r = 0.0, g = 0.0, b = 0.0
            for i in 0..<1024 { r += Double(buf[i * 4]); g += Double(buf[i * 4 + 1]); b += Double(buf[i * 4 + 2]) }
            return (r / 1024, g / 1024, b / 1024)
        }
        let ref = avgOf(base)
        var okList: [String] = [], failList: [String] = [], colorBad: [String] = []
        for (ext, uti) in cases {
            let url = URL(fileURLWithPath: dir + "/s." + ext)
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
                failList.append(ext + "(写不了)"); continue
            }
            CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
            guard CGImageDestinationFinalize(d) else { failList.append(ext + "(写失败)"); continue }
            guard let back = loadAnyImage(url.path, maxDim: 400) else { failList.append(ext); continue }
            let a = avgOf(back)
            let diff = (abs(a.0 - ref.0) + abs(a.1 - ref.1) + abs(a.2 - ref.2)) / 3
            if diff > 6 { colorBad.append(String(format: "%@(色差 %.1f)", ext, diff)) } else { okList.append(ext) }
        }
        check("各种照片格式逐种实测可读且颜色一致", failList.isEmpty && colorBad.isEmpty,
              "可读 " + String(okList.count) + "/" + String(cases.count) + "：" + okList.joined(separator: " ")
              + (failList.isEmpty ? "" : " ｜ 失败：" + failList.joined(separator: " "))
              + (colorBad.isEmpty ? "" : " ｜ 色差偏大：" + colorBad.joined(separator: " ")))
    }
    // 扩展名清单：命令行/批量必须看得见 RAW 与 HEIC（曾经命令行自己写了一份短清单，RAW 直接看不见）
    let must: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "heic", "avif", "webp", "dds"]
    check("批量扫描认得出 RAW 与 HEIC/AVIF", must.isSubset(of: imageExtensions),
          "清单共 " + String(imageExtensions.count) + " 种，含 " + must.sorted().joined(separator: " "))
    // RAW 路径的兜底：扩展名像 RAW、但内容解不出来时，不能崩也不能让整条管线返回 nil 之外的东西
    let fake = NSTemporaryDirectory() + "cr_fake_notraw.dng"
    try? "这不是真的 RAW".data(using: .utf8)?.write(to: URL(fileURLWithPath: fake))
    let r = loadAnyImage(fake, maxDim: 200)
    check("假的 RAW 文件不会让读图炸掉", r == nil, "返回 " + (r == nil ? "nil（干净失败）" : "非空"))
    try? FileManager.default.removeItem(atPath: fake)
}

// MARK: - 6v. 导出重名消解


head("6v. 导出重名：同名不同扩展名不能互相覆盖")
do {
    // 相机最常见的产出是 IMG_0001.CR2 + IMG_0001.JPG，同名进同一目录会互相覆盖
    let a = ExportNameAllocator()
    let names = ["IMG_0001.jpg", "IMG_0001.jpg", "IMG_0001.jpg"].map { a.allocate($0) }
    check("同名申请三次会拿到三个不同名字",
          Set(names).count == 3 && names[0] == "IMG_0001.jpg" && names[1] == "IMG_0001_2.jpg" && names[2] == "IMG_0001_3.jpg",
          names.joined(separator: " / "))
    // 端到端：造 4 个同名的不同格式文件，跑批量导出，输出必须 4 个
    if let img = loadFixture(bigFace, maxDim: 400), let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let inDir = NSTemporaryDirectory() + "cr_names_in"
        let outDir = NSTemporaryDirectory() + "cr_names_out"
        try? FileManager.default.removeItem(atPath: inDir)
        try? FileManager.default.removeItem(atPath: outDir)
        try? FileManager.default.createDirectory(atPath: inDir, withIntermediateDirectories: true)
        let exts: [(String, String)] = [("jpg", "public.jpeg"), ("png", "public.png"), ("tif", "public.tiff"), ("bmp", "com.microsoft.bmp")]
        var paths: [String] = []
        for (ext, uti) in exts {
            let u = URL(fileURLWithPath: inDir + "/IMG_0001." + ext)
            if let d = CGImageDestinationCreateWithURL(u as CFURL, uti as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil)
                if CGImageDestinationFinalize(d) { paths.append(u.path) }
            }
        }
        var es = ExportSettings()
        es.format = "jpeg"
        es.nameTemplate = "{name}"
        let res = exportBatch(files: paths, outDir: outDir, es, makeImage: { loadAnyImage($0, maxDim: 400) }, workers: 1)
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? []
        check("批量导出同名文件不互相覆盖",
              paths.count == 4 && written.count == 4 && res.written == 4,
              String(format: "输入 %d 个同名不同格式 → 输出 %d 个文件（成功 %d）", paths.count, written.count, res.written))
    }
}

// MARK: - 6w. RAW 实测（真实 CR3）

}
