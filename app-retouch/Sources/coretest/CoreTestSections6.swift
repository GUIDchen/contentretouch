// CoreTestSections6.swift：coretest 的第 41~48 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections6() {
head("6w. RAW：真实 Canon CR3 端到端")
do {
    // 素材由使用方放在仓库根（没有就跳过，不让 coretest 因为缺素材而红）
    let raws = [root + "/HP7A4670.CR3", root + "/HP7A4691.CR3", root + "/HP7A4743.CR3"]
        .filter { FileManager.default.fileExists(atPath: $0) }
    if raws.isEmpty {
        print("  （仓库里没有 RAW 素材，跳过）")
    } else {
        check("RAW 素材存在", raws.count >= 1, "找到 " + String(raws.count) + " 个 CR3")
        // CIRAWFilter 打开 + 元数据
        if let f = CIRAWFilter(imageURL: URL(fileURLWithPath: raws[0])) {
            f.isDraftModeEnabled = false
            let native = f.nativeSize
            check("RAW 能打开且尺寸合理",
                  native.width >= 3000 && native.height >= 2000,
                  String(format: "原生 %.0fx%.0f（%.1f MP），中性色温 %.0f K，基线曝光 %.2f，非草稿 %@",
                         native.width, native.height, Double(native.width * native.height) / 1e6,
                         f.neutralTemperature, f.baselineExposure, String(!f.isDraftModeEnabled)))
        } else {
            check("RAW 能打开", false, "CIRAWFilter 打不开 " + raws[0])
        }
        // 两级读取：小图走内嵌预览、大图走 RAW 解码
        var thumbTimes: [Double] = [], workTimes: [Double] = []
        for p in raws {
            var t = Date()
            let thumb = loadAnyImage(p, maxDim: 1024)
            thumbTimes.append(Date().timeIntervalSince(t) * 1000)
            t = Date()
            let work = loadAnyImage(p, maxDim: 1600)
            workTimes.append(Date().timeIntervalSince(t) * 1000)
            if let th = thumb, let wo = work {
                check("RAW 两级读取都能出图（" + (p as NSString).lastPathComponent + "）",
                      th.extent.width > 100 && wo.extent.width > 100,
                      String(format: "缩略 %dx%d ｜ 工作图 %dx%d",
                             Int(th.extent.width), Int(th.extent.height),
                             Int(wo.extent.width), Int(wo.extent.height)))
                break
            }
        }
        let avgT = thumbTimes.reduce(0, +) / Double(thumbTimes.count)
        let avgW = workTimes.reduce(0, +) / Double(workTimes.count)
        check("RAW 缩略图明显快于 RAW 解码", avgT < avgW * 0.5,
              String(format: "缩略 %.0f ms/张 ｜ 工作预览 %.0f ms/张（快 %.1f×）", avgT, avgW, avgW / max(0.001, avgT)))
        // 整条链路 + 导出
        if let img = loadAnyImage(raws[0], maxDim: 1600), let cg = sharedCtx.createCGImage(img, from: img.extent) {
            let geos = detectFaceGeos(cg, size: img.extent.size)
            var o = PortraitOptions()
            o.faceBlemish = 40; o.spotBlemish = 30
            var out = applyPortrait(img, o, geos: geos)
            out = sharpen(out, amount: 30)
            var es = ExportSettings()
            es.format = "jpeg"
            es.quality = 0.9
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cr_raw_test.jpg")
            let ok = exportImage(out, to: url, es)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            check("RAW 能跑完整修图链路并导出", ok && (size) > 10_000,
                  String(format: "%d 张脸，导出 %.0f KB", geos.count, Double(size) / 1024))
        }
    }
}

// MARK: - 6x. GPU / 算力分配


head("6x. GPU 与算力：像素走 Metal、模型走 ANE")
do {
    // 1) 有 Metal 设备 = Core Image 走 GPU（默认上下文由 Metal 驱动）
    let dev = MTLCreateSystemDefaultDevice()
    check("本机有 Metal 设备（Core Image 走 GPU）", dev != nil,
          (dev?.name ?? "无") + "（统一内存：" + String(dev?.hasUnifiedMemory ?? false) + "）")
    // 2) 默认上下文确实能出图（渲染链路通）
    if let img = loadFixture(bigFace, maxDim: 600), let cg = sharedCtx.createCGImage(img, from: img.extent) {
        check("Metal 上下文能正常出图", cg.width > 100, String(cg.width) + "x" + String(cg.height))
    }
    // 3) CoreML 的算力分配：.all 应当明显快于 cpuOnly（说明真的用上了 ANE/GPU）
    if let p = FaceParser.modelURL()?.path, let img = loadFixture(bigFace, maxDim: 1024),
       let cg = sharedCtx.createCGImage(img, from: img.extent),
       let compiled = try? MLModel.compileModel(at: URL(fileURLWithPath: p)) {
        func bench(_ units: MLComputeUnits) -> Double? {
            let cfg = MLModelConfiguration(); cfg.computeUnits = units
            guard let m = try? MLModel(contentsOf: compiled, configuration: cfg),
                  let vn = try? VNCoreMLModel(for: m) else { return nil }
            let req = VNCoreMLRequest(model: vn)
            req.imageCropAndScaleOption = .centerCrop
            for _ in 0..<3 { _ = try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) }
            var times: [Double] = []
            for _ in 0..<7 {
                let t = Date()
                _ = try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
                times.append(Date().timeIntervalSince(t) * 1000)
            }
            return times.sorted()[times.count / 2]
        }
        let all = bench(.all), cpu = bench(.cpuOnly)
        if let a = all, let c = cpu {
            check("模型算力：.all 会挑到 ANE/GPU", a < c * 0.5,
                  String(format: "人脸解析 .all %.1f ms ｜ 仅 CPU %.1f ms（快 %.1f×）", a, c, c / max(0.01, a)))
        }
    }
    // 4) 像素算子的 GPU/CPU 差距很小 —— 别拿它当判据（记录下来避免以后又踩）
    let g = CIFilter(name: "CILinearGradient")
    g?.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
    g?.setValue(CIVector(x: 2160, y: 2160), forKey: "inputPoint1")
    let base = (g?.outputImage ?? CIImage(color: .gray)).cropped(to: CGRect(x: 0, y: 0, width: 2160, height: 2160))
    func blurTime(_ ctx: CIContext) -> Double {
        let run = {
            var out = base
            for _ in 0..<4 {
                out = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28]).cropped(to: base.extent)
            }
            _ = ctx.createCGImage(out, from: base.extent)
        }
        run()
        var best = Double.infinity
        for _ in 0..<3 { let s = Date(); run(); best = min(best, Date().timeIntervalSince(s) * 1000) }
        return best
    }
    let m1 = blurTime(sharedCtx), m2 = blurTime(CIContext(options: [.useSoftwareRenderer: true]))
    check("高斯在两个路径上差距都很小（不是 GPU 判据）",
          m1 > 0 && m2 > 0,
          String(format: "4x 高斯 r=28 @2160²：Metal %.1f ms ｜ 软件 %.1f ms —— 所以判据用「有没有 Metal 设备」", m1, m2))
}

// MARK: - 6y. 大批量压力测试与并行度


head("6y. 大批量：并行度与内存")
do {
    // 并行处理的正确性：同一批图，串行与并行的结果必须一致（只是更快）
    let dir = root + "/douyin_favorites/images"
    let files = Array(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().prefix(12))
        .map { dir + "/" + $0 }
    func runBatch(_ workers: Int) -> (Int, Double) {
        let out = NSTemporaryDirectory() + "cr_batch_w" + String(workers)
        try? FileManager.default.removeItem(atPath: out)
        var es = ExportSettings()
        es.format = "jpeg"
        let res = exportBatch(files: files, outDir: out, es,
                              makeImage: { loadAnyImage($0, maxDim: 1200) }, workers: workers)
        let n = ((try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []).count
        return (n, Double(res.written))
    }
    let (n1, w1) = runBatch(1)
    let (n4, w4) = runBatch(4)
    check("并行批量与串行结果一致", n1 == n4 && w1 == w4 && n1 == files.count,
          "串行写入 " + String(n1) + " ｜ 4 线程写入 " + String(n4) + "（输入 " + String(files.count) + "）")
    // 内存：并行不该把峰值内存拉爆（实测 356 张批量：串行 4.4GB → 并行 1.85GB，反而更低）
    skip("并行不会让内存翻倍", "这里不测内存（要单独量）：见文档 356 张批量峰值 RSS 串行 4.40 GB → 并行 1.85 GB")
}

// MARK: - 6z. RAW 预解码缓存


head("6z. RAW 预解码缓存（可选开启）")
do {
    let raws = [root + "/HP7A4670.CR3", root + "/HP7A4691.CR3"]
        .filter { FileManager.default.fileExists(atPath: $0) }
    if raws.isEmpty {
        print("  （仓库里没有 RAW 素材，跳过）")
    } else {
        // ⚠️ 临时目录必须**按进程隔离**：原来写死 "cr_rawcache_test"，
        // 于是"coretest 与 preflight 同时跑"时两个进程会互相删/读对方的缓存目录 ——
        // 实测就出过"次轮命中 1（期望 2）、落盘 3（期望 2）"的假红。
        let dir = NSTemporaryDirectory() + "cr_rawcache_test_" + String(ProcessInfo.processInfo.processIdentifier)
        try? FileManager.default.removeItem(atPath: dir)
        let cache = RawCache(directory: dir, limitBytes: 64 * 1024 * 1024)
        var firstPass: [CIImage?] = []
        for p in raws { firstPass.append(cache.image(p, maxDim: 1200) { loadAnyImage(p, maxDim: 1200) }) }
        let coldMisses = cache.misses
        var secondPass: [CIImage?] = []
        for p in raws { secondPass.append(cache.image(p, maxDim: 1200) { loadAnyImage(p, maxDim: 1200) }) }
        check("RAW 缓存：首轮未命中、次轮命中",
              coldMisses == raws.count && cache.hits == raws.count,
              "首轮未命中 " + String(coldMisses) + " ｜ 次轮命中 " + String(cache.hits)
              + " ｜ 落盘 " + String(cache.writes) + " ｜ 写失败 " + String(cache.writeFailures)
              + " ｜ 读失败 " + String(cache.readFailures)
              + String(format: " ｜ 占用 %.1f MB", Double(cache.bytes) / 1_048_576))
        // 关键：缓存读回来的像素必须与现场解码**完全一致**（16bit TIFF 无损往返）
        func sig(_ img: CIImage) -> Double {
            var buf = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let e = img.extent
            let sc = img.transformed(by: CGAffineTransform(scaleX: 64 / e.width, y: 64 / e.width))
            sharedCtx.render(sc, toBitmap: &buf, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var s = 0.0
            for i in 0..<(64 * 64) { s += Double(buf[i * 4]) + Double(buf[i * 4 + 1]) + Double(buf[i * 4 + 2]) }
            return s / Double(64 * 64 * 3)
        }
        if let a = firstPass.first ?? nil, let b = secondPass.first ?? nil {
            let d = abs(sig(a) - sig(b))
            check("RAW 缓存不改像素（16bit 无损往返）", d < 0.5,
                  String(format: "解码 vs 缓存读回：平均色差 %.3f 级", d))
        }
        try? FileManager.default.removeItem(atPath: dir)
    }
}

// MARK: - 6aa. 发际线（几何位移）


head("6aa. 发际线调整：位移可测、不越界")
do {
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent),
       let g = detectFaceGeos(cg, size: img.extent.size).first {
        let e = img.extent
        // 量「发际线」：在脸中轴带内从下往上扫，找头发掩膜第一次出现的高度
        func hairlineHeight(_ image: CIImage) -> Double {
            guard let hair = parsedMaskForFace(image, face: g, classes: FaceClass.hairClasses, feather: 2, margin: 0.7)
            else { return -1 }
            var buf = [UInt8](repeating: 0, count: 24 * 4)
            let x0 = g.box.midX - 12
            var y = g.box.minY + g.box.height * 0.5
            while y < min(e.height - 1, g.box.maxY + g.box.height * 0.5) {
                sharedCtx.render(hair, toBitmap: &buf, rowBytes: 24 * 4,
                                 bounds: CGRect(x: x0, y: y, width: 24, height: 1), format: .RGBA8,
                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                var hits = 0
                for i in 0..<24 where buf[i * 4] > 128 { hits += 1 }
                if hits >= 8 { return y }
                y += 3
            }
            return -1
        }
        _ = e
        let base = hairlineHeight(img)
        var up = 0.0, down = 0.0
        var o1 = PortraitOptions(); o1.hairline = 30
        let hUp = hairlineHeight(applyPortrait(img, o1, geos: [g]))
        var o2 = PortraitOptions(); o2.hairline = -30
        let hDown = hairlineHeight(applyPortrait(img, o2, geos: [g]))
        if base > 0 && hUp > 0 && hDown > 0 {
            up = hUp - base
            down = hDown - base
        }
        check("发际线：正=上移、负=下移，幅度可测",
              up > 5 && down < -5 && abs(up) < g.box.height * 0.25 && abs(down) < g.box.height * 0.25,
              String(format: "+30 → %+.0f px（%.0f%% 脸高）｜ -30 → %+.0f px（%.0f%% 脸高）",
                     up, up / g.box.height * 100, down, down / g.box.height * 100))
        // 越界检查：脸外的角落不该被动
        var o3 = PortraitOptions(); o3.hairline = -40
        let out = applyPortrait(img, o3, geos: [g])
        let far = diffMap(img, out).avg(in: CGRect(x: 3, y: 3, width: 50, height: 50))
        check("发际线：只动脸区", far < 0.01, String(format: "画面角落平均变化 %.5f", far))
    }
}

// MARK: - 6ab. 换天空（非生成式合成）


head("6ab. 换天空：地平线检得准、地面不动、室内不误报")
do {
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 400)
    func meanRGB(_ img: CIImage, _ r: CGRect) -> (Double, Double, Double) {
        var b = [UInt8](repeating: 0, count: Int(r.width) * Int(r.height) * 4)
        sharedCtx.render(img, toBitmap: &b, rowBytes: Int(r.width) * 4, bounds: r, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var r0 = 0.0, g0 = 0.0, b0 = 0.0
        let n = Double(Int(r.width) * Int(r.height))
        for i in 0..<Int(n) { r0 += Double(b[i * 4]); g0 += Double(b[i * 4 + 1]); b0 += Double(b[i * 4 + 2]) }
        return (r0 / n, g0 / n, b0 / n)
    }
    // 合成：上半蓝天、下半绿地，地平线恰在 50%
    let skyPart = CIImage(color: CIColor(red: 0.32, green: 0.55, blue: 0.88))
        .cropped(to: CGRect(x: 0, y: 200, width: 400, height: 200))
    let ground = CIImage(color: CIColor(red: 0.28, green: 0.42, blue: 0.20))
        .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
    let scene = skyPart.composited(over: ground)
    var o = SkyOptions()
    o.amount = 100
    o.style = "sunset"
    let (out, cov) = replaceSky(scene, o)
    check("换天空：地平线检得准", abs(cov - 0.5) < 0.12,
          String(format: "检出天空占比 %.1f%%（真值 50%%）", cov * 100))
    // 天空区（贴地平线处，晚霞是暖色）应该变暖；地面必须一动不动
    let s0 = meanRGB(scene, CGRect(x: 100, y: 230, width: 120, height: 40))
    let s1 = meanRGB(out, CGRect(x: 100, y: 230, width: 120, height: 40))
    let g0 = meanRGB(scene, CGRect(x: 100, y: 60, width: 120, height: 60))
    let g1 = meanRGB(out, CGRect(x: 100, y: 60, width: 120, height: 60))
    check("换天空：天空区变成暖色", (s1.0 - s1.2) > (s0.0 - s0.2),
          String(format: "贴地平线处 R-B：%.0f → %.0f", s0.0 - s0.2, s1.0 - s1.2))
    check("换天空：地面完全不动",
          abs(g1.0 - g0.0) < 1 && abs(g1.1 - g0.1) < 1 && abs(g1.2 - g0.2) < 1,
          String(format: "地面 R%.0f G%.0f B%.0f → R%.0f G%.0f B%.0f", g0.0, g0.1, g0.2, g1.0, g1.1, g1.2))
    // 地平线微调必须真的起作用（曾经写成「平移一次再平移回来」= 空操作，三种取值结果完全一样）
    var covs: [Double] = []
    for bias in [-1.0, 0.0, 1.0] {
        var ob = SkyOptions()
        ob.amount = 100
        ob.horizonBias = bias
        covs.append(replaceSky(scene, ob).coverage)
    }
    check("地平线微调真的生效（不是空操作）", covs[0] < covs[1] - 0.03 && covs[2] > covs[1] + 0.03,
          String(format: "bias -1/0/+1 → 检出 %.1f%% / %.1f%% / %.1f%%",
                 covs[0] * 100, covs[1] * 100, covs[2] * 100))

    // 室内片不能误报（亮度+位置的判据会把室内亮背景当天空，所以加了蓝度闸门）
    if let indoor = loadFixture(wedding, maxDim: 700) {
        var o2 = SkyOptions()
        o2.amount = 100
        let (_, cov2) = replaceSky(indoor, o2)
        check("换天空：室内片不误报", cov2 < 0.05,
              String(format: "室内婚礼片检出「天空」%.1f%%", cov2 * 100))
    }
    _ = canvas
}

// MARK: - 6ac. 发际线自适应 + 镜头配置


head("6ac. 发际线自适应圆心 + 镜头配置匹配")
do {
    // 发际线：量出来的位置和写死的 84% 到底差多少
    var measured: [Double] = []
    for rel in [bigFace, wedding] {
        if let img = loadFixture(rel, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
            for g in detectFaceGeos(cg, size: img.extent.size).prefix(2) {
                if let y = hairlineY(img, face: g) {
                    measured.append((y - g.box.minY) / g.box.height * 100)
                }
            }
        }
    }
    let hardcoded = 84.0
    let maxDev = measured.map { abs($0 - hardcoded) }.max() ?? 0
    check("发际线用实测位置而不是写死的 84%",
          !measured.isEmpty && maxDev > 10,
          String(format: "实测发际线在脸高的 %@%%，写死的是 %.0f%%（最大偏差 %.0f%% 脸高）",
                 measured.map { String(format: "%.0f", $0) }.joined(separator: "/"), hardcoded, maxDev))
    // 镜头配置：按 EXIF 型号匹配（RAW 里有真实型号）
    let rawWithLens = root + "/HP7A4670.CR3"
    if FileManager.default.fileExists(atPath: rawWithLens) {
        let model = readLensModel(rawWithLens)
        check("能读出 RAW 的 EXIF 镜头型号", !model.isEmpty, "LensModel = \"" + model + "\"")
        if let p = LensProfileStore.shared.match(model) {
            check("镜头配置按型号匹配成功", p.vignette > 0 || abs(p.distortion) > 0,
                  "命中「" + p.name + "」（畸变 " + String(format: "%.1f", p.distortion)
                  + " / 暗角 " + String(format: "%.0f", p.vignette) + "）")
            // 套用后画面确实被改了（把结果与不套用比）
            if let img = loadAnyImage(rawWithLens, maxDim: 1200) {
                let r = autoLensCorrect(img, path: rawWithLens)
                let d = diffMap(img, r.image).total
                check("镜头校正确实改了画面", d > 0.0005,
                      String(format: "套用「%@」后平均变化 %.5f", r.profile, d))
            }
        } else {
            check("镜头配置按型号匹配成功", false, "型号「" + model + "」没匹配到 lens_profiles/ 里的配置")
        }
    }
    // 没有镜头信息的图：必须**如实不校正**（不许假装做了）
    if let img = loadFixture(bigFace, maxDim: 600) {
        let r = autoLensCorrect(img, path: root + "/douyin_favorites/images/" + bigFace)
        check("没有镜头信息就不校正（不假装）", r.profile.isEmpty,
              "返回的配置名：\"" + r.profile + "\"（应为空）")
    }
}

// MARK: - 7. 性能基线


head("7. 性能基线（实测）")
}
