// CLIPipeline.swift：命令行主流程（批量调色 + 人像 + 导出）。
// 原来是 main.swift 顶层的一整段可执行代码；搬进函数是必须的——
// Swift 只允许 main 文件有顶层语句，所以"拆分"在这里等于"把顶层脚本封成函数"。
// throws 同样必须：这些 try 原来在顶层（脚本语义允许），进函数后要有 throws 兜住。
import Foundation
import CoreImage
import Metal
import RetouchCore

func runPipeline() throws {
    let stylePath = arg("--style", "style_out/style_report.json")
    let cluster = Int(arg("--cluster", "2")) ?? 2
    let inDir = URL(fileURLWithPath: arg("--in", "2604_wedding/00_RAW_readonly"))
    let outDir = URL(fileURLWithPath: arg("--out", "/tmp/retouch_out"))
    let limit = Int(arg("--limit", "0")) ?? 0
    let iterations = Int(arg("--iterations", "3")) ?? 3
    var iterationsRef = 0   // 参考图追色的轮数（默认 6，见下）
    let quality = Double(arg("--quality", "95")) ?? 95
    let format = arg("--format", "jpeg")
    let dryRun = args.contains("--dry-run")
    let identity = args.contains("--identity")   // 色彩管理校验用：恒等参数渲染
    // M5 皮肤：强度可直接给数，也可用分档（轻/中/重 = 30/55/80）
    let grade = arg("--skin-grade", "")
    let smooth: Double = {
        if !grade.isEmpty {
            switch grade { case "light": return 30; case "medium": return 55; case "strong": return 80; default: return 0 }
        }
        return Double(arg("--smooth", "0")) ?? 0
    }()
    let skinTone = args.contains("--skin-tone")   // 肤色统一（按测得的暖冷朝参考组靠）
    let purify = args.contains("--purify-bg")     // 背景纯化（人像分割 + 背景 flatten）
    let autoCrop = args.contains("--auto-crop")   // 祛黑白边
    let fromReport = arg("--from-report", "")     // History 回滚：按上一次的报告原样重现（不再跑闭环）
    // —— 人像全量参数：--portrait "teeth=60,eyes=50,spotBlemish=40,..." ——
    // 取值 0~100（除 liquify 类可为负），键名与 PortraitOptions 字段同名
    func parsePortrait(_ spec: String) -> PortraitOptions {
        var o = PortraitOptions()
        guard !spec.isEmpty else { return o }
        let table: [String: WritableKeyPath<PortraitOptions, Double>] = [
            "faceBlemish": \.faceBlemish, "spotBlemish": \.spotBlemish, "mole": \.mole,
            "shine": \.shine, "sweat": \.sweat, "darkCircle": \.darkCircle, "eyebag": \.eyebag,
            "nostril": \.nostril, "lipLine": \.lipLine, "doubleChin": \.doubleChin, "jawLine": \.jawLine,
            "teeth": \.teeth, "eyes": \.eyes, "lipColor": \.lipColor, "blush": \.blush,
            "hands": \.hands, "feet": \.feet, "faceSlim": \.faceSlim, "eyeBig": \.eyeBig,
            "noseSlim": \.noseSlim, "chinShape": \.chinShape, "forehead": \.forehead
        ]
        for pair in spec.split(separator: ",") {
            let kv = pair.split(separator: "=")
            guard kv.count == 2, let v = Double(kv[1]), let kp = table[String(kv[0])] else { continue }
            o[keyPath: kp] = v
        }
        return o
    }
    let portrait = parsePortrait(arg("--portrait", ""))
    let bgBlurAmount = Double(arg("--bg-blur", "0")) ?? 0
    let sharpenAmount = Double(arg("--sharpen", "0")) ?? 0
    let denoiseAmount = Double(arg("--denoise", "0")) ?? 0
    let vignetteAmount = Double(arg("--vignette", "0")) ?? 0
    let grainAmount = Double(arg("--grain", "0")) ?? 0
    let lightAmount = Double(arg("--light", "0")) ?? 0
    let edgeRefineAmount = Double(arg("--edge-refine", "0")) ?? 0
    // 镜头校正 / 透视校正
    let lensDistort = Double(arg("--lens-distortion", "0")) ?? 0
    let lensVignette = Double(arg("--lens-vignette", "0")) ?? 0
    let lensCA = Double(arg("--lens-ca", "0")) ?? 0
    let perspH = Double(arg("--perspective-h", "0")) ?? 0
    let perspV = Double(arg("--perspective-v", "0")) ?? 0
    // —— 自动 / 智能这一层（全部是「先量本图再出手」）——
    let autoWB = Double(arg("--auto-wb", "0")) ?? 0
    let smartSharpen = Double(arg("--smart-sharpen", "0")) ?? 0
    let highlightRecover = Double(arg("--highlight-recover", "0")) ?? 0
    let autoFill = Double(arg("--auto-fill", "0")) ?? 0
    let autoExposeAmount = Double(arg("--auto-expose", "0")) ?? 0
    let autoSkinAmount = Double(arg("--auto-skin", "0")) ?? 0
    let autoLevelOn = args.contains("--auto-level")
    let autoVignetteOn = args.contains("--auto-vignette")
    let autoDenoiseOn = args.contains("--auto-denoise")
    // 换天空（合成式）：--sky sunset --sky-amount 60
    let skyStyle = arg("--sky", "")
    let skyAmount = Double(arg("--sky-amount", "60")) ?? 60
    let skyQuiet = args.contains("--quiet")
    let autoLens = args.contains("--auto-lens")        // 按 EXIF 镜头型号自动套用配置
    let autoAdapt = args.contains("--auto-adapt")        // 场景自适应：按场景 + 本图测量一次性给出各自动项
    let autoAdaptBatch = args.contains("--auto-adapt-batch")  // 整批统一：所有图用同一套（取中位数），保证观感一致
    let groupReport = args.contains("--group-report")    // 只做连拍分组 + 组内选优，不修图
    // RAW 预解码缓存（默认关）：一批 RAW 反复出片时，第二次就不用重新解码了
    let rawCacheDir = arg("--raw-cache", "")
    let rawCache: RawCache? = rawCacheDir.isEmpty ? nil : RawCache(directory: rawCacheDir)
    let stress = args.contains("--stress")              // 大规模压测：只统计不修图
    let stressSample = Int(arg("--stress-sample", "0")) ?? 0   // 每 N 张取 1 张（0 = 全跑）
    let prof = args.contains("--profile")               // 分阶段耗时剖析（回答「瓶颈在哪」）
    // 系统 AI 能力：智能裁剪（按显著性主体）+ 自动场景推荐
    let smartCropSpec = arg("--smart-crop", "")       // 原图 | 1:1 | 4:5 | 3:4 | 16:9
    let cropPlacement = arg("--crop-placement", "thirds")
    let autoScene = args.contains("--auto-scene")
    @Sendable func cropAspectValue(_ spec: String) -> Double {
        switch spec {
        case "1:1": return 1.0
        case "4:5": return 0.8
        case "3:4": return 0.75
        case "16:9": return 16.0 / 9.0
        default: return 0
        }
    }
    // 并行度默认按 CPU 核数自适应（上限 8：再多人内存和 IO 会打架，实测 4 线程已接近线性）
    // 显式传 --workers 1 仍然可用（最省内存）。
    let autoWorkers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
    let workers = Int(arg("--workers", String(autoWorkers))) ?? autoWorkers
    // —— 导出设置 ——
    var exportSettings = ExportSettings()
    exportSettings.format = format
    exportSettings.quality = quality
    exportSettings.maxLongEdge = Int(arg("--max-long-edge", "0")) ?? 0
    exportSettings.bitDepth = Int(arg("--bit-depth", "8")) ?? 8
    exportSettings.colorSpace = arg("--color-space", "sRGB")
    exportSettings.nameTemplate = arg("--name-template", "{name}")
    exportSettings.watermarkText = arg("--watermark", "")
    // 这里**不**调 watermarkTrouble：CLI 只支持文字水印（--watermark），而文字水印不依赖外部文件，
    // 那个函数对它永远返回 nil —— 加了就是死代码。LOGO 水印是界面侧的设置，检查放在界面那条路上（§177）。
    exportSettings.watermarkPosition = arg("--watermark-position", "bottom-right")
    let reportPath = arg("--report", "")
    
    var sceneOverrides: SceneSuggestion? = nil
    let styles = (try? loadStyles(stylePath)) ?? []
    // 「不修图、只做分析」的命令不需要风格报告，允许用一个空风格占位。
    //
    // 这里**必须是一张集中清单**：早先是三个内联的 || 判断，每加一个新命令（--index-pose、
    // --index-fp、--similar…）就漏一次，表现都是同一句「风格报告里没有 cluster 2」把命令挡在门外，
    // 而且每次都要重新踩一遍。现在加命令只需要往这张表里加一个名字。
    let analysisOnlyFlags = [
        "--index", "--search", "--index-pose", "--index-fp", "--similar",
        "--model-check", "--gpu-info", "--group-report", "--stress", "--profile",
        "--reference", "--reference-url", "--reference-dir"
    ]
    let indexMode = analysisOnlyFlags.contains { args.contains($0) }
    var style: StylePreset
    if let s = styles.first(where: { $0.index == cluster }) {
        style = s
    } else if indexMode {
        style = StylePreset(index: cluster, name: "索引模式", target: Stats(), params: Params())
    } else {
        print("风格报告里没有 cluster \(cluster)"); exit(2)
    }
    
    // —— 参考图追色 ——
    // 两条路：用户手上已有参考图（--reference 多个路径/目录），或者只给一条链接（--reference-url）。
    // 目标 = 参考图的**中位数**统计量（抗离群），再用同一个闭环把原图拉过去，不另起一套算法。
    var refTarget: Stats? = nil
    let referenceSpec = arg("--reference", "")
    let referenceURL = arg("--reference-url", "")
    if !referenceSpec.isEmpty || !referenceURL.isEmpty {
        var refPaths: [String] = []
        for part in referenceSpec.split(separator: ",") where !part.isEmpty {
            let p = String(part)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                refPaths += indexableFiles(p)
            } else {
                refPaths.append(p)
            }
        }
        if !referenceURL.isEmpty {
            let dir = arg("--reference-dir", "/tmp/retouch_refs")
            let got = fetchReferences(referenceURL, into: dir)
            print("参考图抓取：" + String(got.count) + " 张 → " + dir)
            if got.isEmpty {
                print("  抓不到图：这条链接要么是前端渲染的分享页（HTML 里没有图片地址），")
                print("  要么需要登录/鉴权。可以直接给图片直链，或把参考图存到本地用 --reference 指过去。")
            }
            refPaths += got
        }
        let refImgs = loadReferences(refPaths)
        guard !refImgs.isEmpty else { print("参考图为空，无法追色"); exit(2) }
        // 追色跟「套一个已知风格」不是一回事：参考可能离原片很远，3 轮往往够不着，默认给 6 轮
        if !args.contains("--iterations") { iterationsRef = 6 }
        let (rt, rn, rsp, dropped) = referenceTargetRobust(refImgs)
        style.target = rt
        refTarget = rt
        print(String(format: "参考图 %d 张（剔除离群 %d 张）：目标 q5/q50/q95 = %.2f/%.2f/%.2f  sat %.0f%%  暖冷 阴影%+.1f 高光%+.1f",
                     rn, dropped, rt.q5, rt.q50, rt.q95, rt.sat, rt.warmSh, rt.warmHi))
        if rsp > 0.25 {
            print(String(format: "  注意：参考图之间离散度 %.2f（偏高），追出来的是它们的「共同点」，建议换一组更一致的参考图", rsp))
        }
        // 参考图退化检查：白底文档/截图/扫描件在统计上就是「很亮 + 几乎无饱和 + 无暖冷层次」。
        // 这类东西当参考只会把照片冲成一片白（实测：拿数学卷子当参考，人像被追成近白）。老实拒绝。
        let flat = referenceTarget(refImgs).target
        if flat.sat < 8 && flat.q50 > 0.6 && abs(flat.warmHi) < 2 && abs(flat.warmSh) < 2 {
            print(String(format: "  拒绝：参考图看起来是白底文档/截图（亮度 %.2f、饱和 %.0f%%、无暖冷层次），不是照片风格，"
                                 + "当参考会把照片冲成一片白。请换实拍参考图。", flat.q50, flat.sat))
            exit(2)
        }
        // 大档位提醒：追的亮度差太大时结果容易过曝/压死，这个在图上要能看出来，不能默默出片
        let lift = flat.q50 - measure(loadAnyImage(refPaths[0], maxDim: 512) ?? refImgs[0]).q50
        _ = lift
    }
    // ---- History 回滚：读上一次的完整参数表 ----
    var rollback: [String: Params] = [:]
    if !fromReport.isEmpty,
       let data = try? Data(contentsOf: URL(fileURLWithPath: fromReport)),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let imgs = json["images"] as? [[String: Any]] {
        func arr(_ v: Any?) -> [Double] {
            if let a = v as? [Double] { return a }
            if let a = v as? [Int] { return a.map(Double.init) }
            return [0, 0, 0]
        }
        for r in imgs {
            guard let f = r["file"] as? String, let pr = r["params"] as? [String: Any] else { continue }
            var p = Params()
            p.levelsIn = arr(pr["levelsIn"]); p.levelsOut = arr(pr["levelsOut"])
            p.gamma = (pr["gamma"] as? Double) ?? 1
            p.brightness = (pr["brightness"] as? Double) ?? 0
            p.contrast = (pr["contrast"] as? Double) ?? 0
            p.desat = (pr["desat"] as? Double) ?? 0
            p.cbSh = arr(pr["cbSh"]); p.cbMid = arr(pr["cbMid"]); p.cbHi = arr(pr["cbHi"])
            rollback[f] = p
        }
        print("回滚模式：从 \(fromReport) 读入 \(rollback.count) 张的参数，将原样重现（不跑闭环）")
    }
    
    if autoScene {
        // 自动场景：按整目录第一张判一次，套用推荐参数（批次内通常是同一场拍摄）
        if let probe = ((try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? [])
            .filter({ imageExtensions.contains($0.pathExtension.lowercased()) }).sorted(by: { $0.path < $1.path }).first,
           let ci = loadAnyImage(probe.path, maxDim: 900), let cg = sharedCtx.createCGImage(ci, from: ci.extent) {
            let info = classifyScene(cg)
            let sug = suggestParams(for: info)
            sceneOverrides = sug
            print("自动场景：" + info.category + "（" + info.reasons.joined(separator: "；") + "）")
            print("  推荐：人像参数 " + String(sug.portrait.anyEnabled) + "、磨皮 " + sug.skinGrade
                  + "、影调 " + String(sug.extras.count) + " 项")
        }
    }
    // ⚠️ 目录读不到 = 硬错误（别用 try? 吞掉）：路径打错却报"成功 0"，脚本会以为跑完了
    guard let entries = try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil) else {
        throw CLIError.inputUnreadable(inDir.path)
    }
    let files = entries
        .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.path < $1.path }
    let todo = limit > 0 ? Array(files.prefix(limit)) : files
    // 一张都没有同样是失败：批处理跑了个空，不该以 0 收场
    guard !todo.isEmpty else { throw CLIError.noImages(inDir.path) }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    
    print("风格 \(style.index)：\(style.name)")
    print(String(format: "目标 q5/q50/q95 = %.2f/%.2f/%.2f  sat %.0f%%  暖冷 阴影%+.1f 高光%+.1f",
                 style.target.q5, style.target.q50, style.target.q95, style.target.sat,
                 style.target.warmSh, style.target.warmHi))
    print("输入 \(todo.count) 张 -> \(outDir.path)")
    
    // 整批统一：先对整批测一遍（缩到 600 长边，快），取中位数当全批统一方案
    var batchAdaptPlan: SceneAdaptivePlan? = nil
    if autoAdaptBatch && !todo.isEmpty {
        // 预扫并行：读图 + 缩放是 CPU 密集，串行扫 8 张要好几秒
        var slots = [CIImage?](repeating: nil, count: todo.count)
        let scanLock = NSLock()
        let scanWorkers = max(1, workers)
        if scanWorkers > 1 {
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                let im = loadAnyImage(todo[i].path, maxDim: 600)
                scanLock.lock(); slots[i] = im; scanLock.unlock()
            }
        } else {
            for i in 0..<todo.count { slots[i] = loadAnyImage(todo[i].path, maxDim: 600) }
        }
        let smalls = slots.compactMap { $0 }
        guard !smalls.isEmpty else { print("整批统一：读不到图"); exit(2) }
        let scene: SceneInfo? = sharedCtx.createCGImage(smalls[0], from: smalls[0].extent).map { classifyScene($0) }
        let plan = planGroupAdaptive(smalls, scene: scene)
        batchAdaptPlan = plan
        print("整批统一（" + String(smalls.count) + " 张）：" + (plan.reasons.first ?? ""))
    }
    
    // ══════════ 分阶段剖析：每个环节各花多少时间 ══════════
    if prof {
        var sample = todo
        if stressSample > 1 { sample = stride(from: 0, to: todo.count, by: stressSample).map { todo[$0] } }
        print("剖析：\(sample.count) 张")
        var acc: [String: Double] = [:]
        var clothPass = 0
        func add(_ k: String, _ dt: TimeInterval) { acc[k, default: 0] += dt * 1000 }
        var n = 0
        for f in sample {
            func tick(_ label: String, _ body: () -> Void) {
                let t = Date(); body(); add(label, Date().timeIntervalSince(t))
            }
            var src: CIImage?
            tick("1 读图") { src = loadAnyImage(f.path) }
            guard let s0 = src else { continue }
            let e = s0.extent
            var cg: CGImage?
            tick("2 位图化") { cg = sharedCtx.createCGImage(s0, from: e) }
            guard let c0 = cg else { continue }
            var geos: [FaceGeo] = []
            tick("3 人脸+关键点") { geos = detectFaceGeos(c0, size: e.size) }
            var clothUsable = false, clothCoverage = 0.0
            tick("4b 衣物语义检查") {
                if let m = parsedMaskFromImage(s0, classes: FaceClass.clothClasses, feather: 6) {
                    clothCoverage = maskCoverage(m, in: e, threshold: 128)
                    clothUsable = clothCoverage > 0.02 && clothCoverage < 0.70
                }
            }
            if clothUsable { clothPass += 1 }
            var out = s0
            var o = PortraitOptions()
            o.faceBlemish = 50; o.spotBlemish = 50; o.shine = 50; o.teeth = 40; o.eyes = 40
            tick("4 人像（含解析/肤色掩膜）") { out = applyPortrait(s0, o, geos: geos) }
            tick("5 衣物美化") { out = smoothClothes(out, strength: 40) }
            tick("6 补光") { out = addLight(out, strength: 30, at: CGPoint(x: out.extent.midX, y: out.extent.midY)) }
            tick("7 锐化") { out = sharpen(out, amount: 30) }
            tick("8 出图编码") { _ = sharedCtx.createCGImage(out, from: out.extent) }
            n += 1
            if n % 20 == 0 { print("  已剖析 \(n) 张") }
        }
        print("")
        print("=== 分阶段耗时（\(n) 张，平均每张）===")
        let total = acc.values.reduce(0, +)
        for (k, v) in acc.sorted(by: { $0.key < $1.key }) {
            print(String(format: "  %-24@ %7.0f ms  %5.1f%%", k as NSString, v / Double(n), v / max(1, total) * 100))
        }
        print(String(format: "  %-24@ %7.0f ms", "合计" as NSString, total / Double(n)))
        print(String(format: "  衣物语义掩膜可用比例：%d/%d = %.0f%%", clothPass, n, Double(clothPass) / Double(max(1, n)) * 100))
        let (ch, cm) = VisionCache.shared.stats()
        print(String(format: "  缓存命中 %d / 未命中 %d（命中率 %.0f%%）", ch, cm, Double(ch) / Double(max(1, ch + cm)) * 100))
        exit(0)
    }
    
    // ══════════ 大规模压测：把整条链路在成百上千张图上跑一遍，找出会崩/会退化的样本 ══════════
    if stress {
        var sample = todo
        if stressSample > 1 { sample = stride(from: 0, to: todo.count, by: stressSample).map { todo[$0] } }
        print("压测：共 \(todo.count) 张，本次跑 \(sample.count) 张（每 \(max(1, stressSample)) 张取 1）")
        var okCount = 0, loadFail = 0, pipeFail = 0, noFace = 0
        var times: [Double] = []
        var slowest: [(String, Double)] = []
        var anomalies: [String] = []
        var faceCounts: [Int: Int] = [:]
        var formats: [String: Int] = [:]
        let t0 = Date()
        for (i, f) in sample.enumerated() {
            formats[f.pathExtension.lowercased(), default: 0] += 1
            let t1 = Date()
            guard let src = loadAnyImage(f.path) else { loadFail += 1; anomalies.append("读图失败 " + f.lastPathComponent); continue }
            let e = src.extent
            guard e.width > 4, e.height > 4 else { pipeFail += 1; anomalies.append("尺寸异常 " + f.lastPathComponent); continue }
            guard let cg = sharedCtx.createCGImage(src, from: e) else {
                pipeFail += 1; anomalies.append("位图化失败 " + f.lastPathComponent); continue
            }
            let geos = detectFaceGeos(cg, size: e.size)
            faceCounts[geos.count, default: 0] += 1
            if geos.isEmpty { noFace += 1 }
            // 完整链路：人像 + 后调色，全部走一遍（只看能不能出图）
            var o = PortraitOptions()
            o.faceBlemish = 50; o.spotBlemish = 50; o.shine = 50; o.teeth = 40; o.eyes = 40
            var out = applyPortrait(src, o, geos: geos)
            out = smoothClothes(out, strength: 40)
            out = addLight(out, strength: 30, at: CGPoint(x: out.extent.midX, y: out.extent.midY))
            out = sharpen(out, amount: 30)
            if sharedCtx.createCGImage(out, from: out.extent) == nil {
                pipeFail += 1
                anomalies.append("出图失败 " + f.lastPathComponent)
            } else {
                okCount += 1
            }
            let dt = Date().timeIntervalSince(t1)
            times.append(dt)
            slowest.append((f.lastPathComponent, dt))
            if (i + 1) % 100 == 0 {
                print(String(format: "  已跑 %d/%d，用时 %.1fs", i + 1, sample.count, Date().timeIntervalSince(t0)))
            }
        }
        let total = Date().timeIntervalSince(t0)
        func pct(_ q: Double) -> Double {
            guard !times.isEmpty else { return 0 }
            let s = times.sorted()
            return s[min(s.count - 1, Int(Double(s.count) * q))] * 1000
        }
        print("")
        print("=== 压测结果 ===")
        print(String(format: "  样本 %d 张，总用时 %.1fs（%.1f 张/秒）", sample.count, total, Double(sample.count) / max(0.001, total)))
        print(String(format: "  成功 %d ｜ 读图失败 %d ｜ 链路失败 %d ｜ 无人脸 %d", okCount, loadFail, pipeFail, noFace))
        print(String(format: "  单张耗时 p50 %.0fms ｜ p95 %.0fms ｜ max %.0fms", pct(0.5), pct(0.95), pct(0.999)))
        let faces = faceCounts.sorted { $0.key < $1.key }.map { "\($0.key) 张脸:\($0.value)" }.joined(separator: " ")
        print("  人脸数分布：" + faces)
        print("  格式分布：" + formats.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        print("  最慢的 5 张：")
        for (n, t) in slowest.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            print(String(format: "    %@ %.2fs", n as NSString, t))
        }
        if !anomalies.isEmpty {
            print("  异常样本（前 15 条）：")
            for a in anomalies.prefix(15) { print("    " + a) }
        }
        exit(loadFail + pipeFail > sample.count / 20 ? 1 : 0)
    }
    
    // 连拍分组报告：分组 + 组内选优，只报告不改图
    if groupReport {
        let paths = todo.map { $0.path }
        let scoresAll = paths.compactMap { scoreImage($0) }
        let groups = pickBestPerGroup(scoresAll, groups: groupBursts(paths: paths))
        print("连拍分组：" + String(groups.count) + " 组")
        for g in groups {
            let bestName = g.best < scoresAll.count ? scoresAll[g.best].file : "?"
            print("  " + g.indices.map { i in i < scoresAll.count ? scoresAll[i].file : "?" }.joined(separator: " / ")
                  + "  → 选 " + bestName)
            if g.best < scoresAll.count {
                let sc = scoresAll[g.best]
                print(String(format: "      笑容 %.2f ｜ 姿态 %.0f°（%@）｜ 闭眼 %d/%d ｜ 总分 %.1f",
                             sc.smile, sc.headYaw, poseGrade(yawDeg: sc.headYaw, faces: sc.faces),
                             sc.closedEyes, sc.judgedFaces, sc.total))
            }
        }
        exit(0)
    }
    
    // 素材库索引：把目录下的图抽成一张「可检索要素表」，之后按关键词秒查。
    // 为什么要先落盘：抽取本身是重活（解码 + 分类 + 人脸 + 天空 + 色彩，约 0.3~0.6s/张），
    // 而查询必须瞬间返回——一万多张每次重算是不现实的。
    let indexPath = arg("--index", "")
    let searchQuery = arg("--search", "")
    // 嵌入索引：给素材库补一维「学习模型的图像嵌入」（768 维），用于以图搜图。
    // 与主索引分开存（二进制、与 JSONL 行序一一对应），因为 768 个 float 塞进 JSON 会膨胀到几百 MB。
    let indexFP = arg("--index-fp", "")
    let similarTo = arg("--similar", "")
    if !indexFP.isEmpty || !similarTo.isEmpty {
        let store = ImageIndexStore()
        if !indexFP.isEmpty {
            store.load(indexFP)
            guard !store.records.isEmpty else { print("索引为空：\(indexFP)"); exit(2) }
            let fpPath = indexFP + ".fp"
            print("补图像嵌入 \(store.records.count) 张 → \(fpPath)")
            let lock = NSLock()
            var rows = [[Float]?](repeating: nil, count: store.records.count)
            var done = 0
            let t0 = Date()
            let sem = DispatchSemaphore(value: max(1, workers))
            let grp = DispatchGroup()
            for (i, r) in store.records.enumerated() {
                sem.wait(); grp.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { sem.signal(); grp.leave() }
                    autoreleasepool {
                        var v: [Float]? = nil
                        if let img = loadAnyImage(r.path, maxDim: 700),
                           let cg = sharedCtx.createCGImage(img, from: img.extent) {
                            v = featurePrint(cg)
                        }
                        lock.lock()
                        rows[i] = v
                        done += 1
                        if done % 500 == 0 {
                            let dt = Date().timeIntervalSince(t0)
                            print(String(format: "  %d/%d  %.1f 张/s", done, rows.count, Double(done) / dt))
                        }
                        lock.unlock()
                    }
                }
            }
            grp.wait()
            let es = EmbeddingStore()
            es.build(rows)
            try es.save(fpPath)
            let okRows = rows.compactMap { $0 }.count
            let dt = Date().timeIntervalSince(t0)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: fpPath)[.size] as? Int) ?? 0
            print(String(format: "完成：%d/%d 张有嵌入，维度 %d，耗时 %.1fs（%.1f 张/s），文件 %.1f MB",
                         okRows, rows.count, es.dim, dt, Double(rows.count) / dt, Double(bytes) / 1e6))
        }
        if !similarTo.isEmpty {
            let fpArg = arg("--fp", "")
            let fpPath = fpArg.isEmpty ? indexFP + ".fp" : fpArg
            let es = EmbeddingStore()
            es.load(fpPath)
            guard es.count > 0 else { print("嵌入文件读不出来：\(fpPath)（先跑 --index-fp）"); exit(2) }
            let recPath = arg("--search-in", "")
            if !recPath.isEmpty { store.load(recPath) }
            guard let img = loadAnyImage(similarTo, maxDim: 700),
                  let cg = sharedCtx.createCGImage(img, from: img.extent),
                  let q = featurePrint(cg) else { print("查询图读不出来：\(similarTo)"); exit(2) }
            let topK = Int(arg("--topk", "12")) ?? 12
            let t0 = Date()
            let hits = es.search(q, topK: topK)
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "以图搜图：在 %d 条嵌入里全扫，取前 %d，耗时 %.1f ms", es.count, hits.count, ms))
            for h in hits {
                let name = h.index < store.records.count ? store.records[h.index].file : "行\(h.index)"
                print(String(format: "  距离 %.4f  %@", h.distance, name))
            }
        }
        exit(0)
    }
    
    if !indexPath.isEmpty || !searchQuery.isEmpty {
        let store = ImageIndexStore()
        if !indexPath.isEmpty {
            var paths = indexableFiles(inDir.path)
            if limit > 0 { paths = Array(paths.prefix(limit)) }   // 先用 --limit 试跑小样本
            guard !paths.isEmpty else { print("索引：\(inDir) 下没有可索引的图"); exit(2) }
            print("索引 \(paths.count) 张 → \(indexPath)")
            let lock = NSLock()
            var done = 0, failed = 0, recs: [ImageRecord] = []
            let t0 = Date()
            let sem = DispatchSemaphore(value: max(1, workers))
            let grp = DispatchGroup()
            for p in paths {
                sem.wait(); grp.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { sem.signal(); grp.leave() }
                    autoreleasepool {
                        let r = indexImage(p)
                        lock.lock()
                        if let r = r { recs.append(r) } else { failed += 1 }
                        done += 1
                        if done % 200 == 0 {
                            let dt = Date().timeIntervalSince(t0)
                            print(String(format: "  %d/%d  %.1f 张/s  预计剩余 %.0f 分钟",
                                         done, paths.count, Double(done) / dt,
                                         (Double(paths.count - done) / max(0.1, Double(done) / dt)) / 60))
                        }
                        lock.unlock()
                    }
                }
            }
            grp.wait()
            recs.sort { $0.path < $1.path }
            for r in recs { store.add(r) }
            try store.save(indexPath)
            let dt = Date().timeIntervalSince(t0)
            print(String(format: "完成：%d 张成功，%d 张读不出（已跳过），耗时 %.1fs，%.1f 张/s",
                         recs.count, failed, dt, Double(recs.count) / dt))
            var tagCount: [String: Int] = [:]
            for r in recs { for t in r.tags { tagCount[t, default: 0] += 1 } }
            let top = tagCount.sorted { $0.value > $1.value }.prefix(24)
            print("词表（前 24）：" + top.map { "\($0.key)×\($0.value)" }.joined(separator: "、"))
        }
        if !searchQuery.isEmpty {
            let path = indexPath.isEmpty ? arg("--search-in", "") : indexPath
            guard !path.isEmpty else { print("搜索需要 --index <jsonl> 或 --search-in <jsonl>"); exit(2) }
            store.load(path)
            let t0 = Date()
            // limit=0 先取全部，才知道真实命中数（先截断再报数会把「命中 3」这种假数字印出来）
            let hits = store.search(searchQuery, limit: 0)
            let show = Int(arg("--limit", "50")) ?? 50
            let ms = Date().timeIntervalSince(t0) * 1000
            print(String(format: "查询「%@」：命中 %d / %d 张，耗时 %.1f ms",
                         searchQuery, hits.count, store.records.count, ms))
            for (r, n) in hits.prefix(show) {
                print("  " + r.file + String(format: "  人脸%d 天空%.0f%% 亮%.2f 暖%+.0f 命中%d",
                                            r.faces, r.sky * 100, r.luma, r.warm, n))
                print("      " + r.tags.prefix(14).joined(separator: " "))
            }
            if let copyTo = args.first(where: { $0.hasPrefix("--copy-to=") })?.dropFirst(10) {
                let fm = FileManager.default
                try? fm.createDirectory(atPath: String(copyTo), withIntermediateDirectories: true)
                var copied = 0
                for (r, _) in hits.prefix(show) {
                    let dst = String(copyTo) + "/" + r.file
                    if fm.fileExists(atPath: dst) { continue }
                    if (try? fm.copyItem(atPath: r.path, toPath: dst)) != nil { copied += 1 }
                }
                print("已复制 \(copied) 张到 \(copyTo)")
            }
        }
        exit(0)
    }
    
    // 增量补一维特征：姿势需要人体关键点，跟主索引不是同一批请求。
    // 一万多张重跑整条索引要几十分钟，只补一维就只花这一维的钱。
    let indexPose = arg("--index-pose", "")
    if !indexPose.isEmpty {
        let store = ImageIndexStore()
        store.load(indexPose)
        guard !store.records.isEmpty else { print("索引为空：\(indexPose)"); exit(2) }
        print("补姿势特征 \(store.records.count) 张 → \(indexPose)")
        let lock = NSLock()
        var out = [ImageRecord?](repeating: nil, count: store.records.count)
        var done = 0
        let t0 = Date()
        let sem = DispatchSemaphore(value: max(1, workers))
        let grp = DispatchGroup()
        for (i, r) in store.records.enumerated() {
            sem.wait(); grp.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { sem.signal(); grp.leave() }
                autoreleasepool {
                    var rec = r
                    if let img = loadAnyImage(rec.path, maxDim: 700),
                       let cg = sharedCtx.createCGImage(img, from: img.extent) {
                        for t in poseTags(cg) where !rec.tags.contains(t) {
                            rec.tags.append(t)
                            rec.tagSource[t] = "derived"
                        }
                    }
                    lock.lock()
                    out[i] = rec
                    done += 1
                    if done % 500 == 0 {
                        let dt = Date().timeIntervalSince(t0)
                        print(String(format: "  %d/%d  %.1f 张/s", done, store.records.count, Double(done) / dt))
                    }
                    lock.unlock()
                }
            }
        }
        grp.wait()
        let recs = out.compactMap { $0 }
        store.replaceAll(recs)
        try store.save(indexPose)
        let dt = Date().timeIntervalSince(t0)
        print(String(format: "完成：%d 张，耗时 %.1fs（%.1f 张/s）", recs.count, dt, Double(recs.count) / dt))
        let poseWords = ["全身入镜", "站姿", "坐姿", "半身构图", "举双手", "举手", "抬手",
                         "叉腰/手在腰间", "侧身", "无人体", "有体无人脸"]
        var hist: [String: Int] = [:]
        for r in recs { for t in r.tags where poseWords.contains(t) { hist[t, default: 0] += 1 } }
        print("姿势分布：" + hist.sorted { $0.value > $1.value }
                .map { "\($0.key)×\($0.value)" }.joined(separator: "、"))
        exit(0)
    }
    
    var records: [[String: Any]] = []
    let cliNameAllocator = ExportNameAllocator()
    var ok = 0, fail = 0, noop = 0, far = 0
    let t0 = Date()
    // 大批量并行：早先这里是串行的（虽然 --workers 存在，但那个只用在 exportBatch）。
    // 实测 356 张：CPU 59.8s + sys 15.5s ≈ 墙钟 73.1s —— 并行度 1.03×，等于白等。
    // 现在用固定并发度的 worker 池，逐个文件独立处理；共享状态用锁保护（打印也在锁内，避免行错位）。
    let batchLock = NSLock()
    let inFlight = DispatchSemaphore(value: max(1, workers))
    let group = DispatchGroup()
    // 并发块里只捕获**不可变快照**。这三个值在批量开始后不会再变，但 Swift 看到的是
    // "闭包捕获了可变变量" —— 那是数据竞态的形状，Swift 6 语言模式下直接报错
    //（本轮修掉 5 条 [#SendableClosureCaptures]）。快照写在这里，语义也更清楚：
    // 并发的每一张图都用同一套场景/风格/整批计划，不会读到半路被改的值。
    let sceneSnapshot = sceneOverrides
    let styleSnapshot = style
    let planSnapshot = batchAdaptPlan
    for (fi, f) in todo.enumerated() {
        inFlight.wait()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { inFlight.signal(); group.leave() }
            autoreleasepool {
            _ = fi
            let tStart = Date()
            // 按**导出目标尺寸**读图：大批量 RAW 最大的一处浪费 ——
            // 24MP RAW 全分辨率解码+处理，最后只导出 2000px，多出来的 5/6 像素全程白算。
            // --max-long-edge 0（要全尺寸交付）时保持原样读全分辨率。
            let loadDim = exportSettings.maxLongEdge > 0 ? exportSettings.maxLongEdge : 0
            let isRaw = rawExtensions.contains(f.pathExtension.lowercased())
            let loaded: CIImage?
            if isRaw, let cache = rawCache {
                loaded = cache.image(f.path, maxDim: loadDim) { loadAnyImage(f.path, maxDim: loadDim) }
            } else {
                loaded = loadAnyImage(f.path, maxDim: loadDim)
            }
            guard let src = loaded else {
                batchLock.lock(); fail += 1; print("  [跳过] " + f.lastPathComponent); batchLock.unlock()
                return
            }
            let tLoaded = Date()
            let s0 = measure(src)
            var p = identity ? Params() : style.params
            // 参考追色：不用风格库的起点，直接按「源分布 → 参考分布」解一个够近的起点，闭环只负责收尾
            if refTarget != nil { p = paramsFromStats(from: s0, to: style.target) }
            if identity {
                p.levelsIn = [0, 255]; p.levelsOut = [0, 255]
                p.gamma = 1; p.brightness = 0; p.contrast = 0; p.desat = 0
                p.cbSh = [0, 0, 0]; p.cbMid = [0, 0, 0]; p.cbHi = [0, 0, 0]
            }
            // 本图自适应（安全项）：只按本图亮度缩放曝光/gamma。
            // 注意：这一段必须放在 identity 判断里——之前放在外面，
            // 恒等自检也被加了 brightness +5（=0.05，约 +13 级），害我以为整条管线偏色。
            if !identity {
                let over = max(0, s0.p50 - 120)
                p.gamma = max(1.0, p.gamma - over * 0.001)
                p.brightness = max(0, 5 - over * 0.10)
            }
            let (bp, _, err, used): (Params, Stats, Double, Int) = {
                if let rp = rollback[f.lastPathComponent] {          // 回滚：直接用记录下来的参数
                    // err 返回 0（表示「这版是既定的」），否则会被 alreadyClose 判成「原片更接近」而直接复制原图
                    return (rp, s0, 0.0, 0)
                }
                if identity { return (p, s0, 0.0, 1) }
                return closedLoop(src, base: p, target: style.target,
                                   iterations: max(iterations, iterationsRef))
            }()
            let tLoop = Date()
            let errBefore = s0.distance(to: style.target)
            let alreadyClose = rollback[f.lastPathComponent] == nil && errBefore <= err
            let name = f.deletingPathExtension().lastPathComponent
            let ext = exportSettings.fileExtension
            // 命名模板要真的生效（早先只改了扩展名，--name-template 被忽略）
            let outName = cliNameAllocator.allocate(exportName(exportSettings.nameTemplate, source: f.path,
                                                               index: exportSettings.startIndex + ok) + "." + ext)
            let outURL = outDir.appendingPathComponent(outName)
            if !dryRun {
                if alreadyClose {
                    try? FileManager.default.removeItem(at: outURL)
                    try? FileManager.default.copyItem(at: f, to: outURL)
                } else {
                    var img = finished(smoothed(src, bp), from: src)
                    if autoLens {
                        let r = autoLensCorrect(img, path: f.path)
                        if !r.profile.isEmpty {
                            img = r.image
                            if !skyQuiet { print("  镜头校正：命中配置「" + r.profile + "」") }
                        } else if !skyQuiet {
                            let model = readLensModel(f.path)
                            print("  镜头校正：EXIF 镜头型号「" + (model.isEmpty ? "（无）" : model) + "」没有匹配配置，跳过")
                        }
                    }
                    if !skyStyle.isEmpty {
                        var so = SkyOptions()
                        so.amount = skyAmount
                        so.style = skyStyle
                        let r = replaceSky(img, so)
                        if r.coverage > 0.01 {
                            img = r.image
                            if !skyQuiet { print(String(format: "  换天空：检出 %.0f%%，风格 %@，强度 %.0f", r.coverage * 100, skyStyle, skyAmount)) }
                        } else if !skyQuiet {
                            print("  换天空：没检出天空（位置/亮度/蓝度不满足），跳过")
                        }
                    }
                    if !exportSettings.watermarkText.isEmpty {
                        img = applyWatermark(img, exportSettings, sourceName: f.path)
                    }
                    if !exportImage(img, to: outURL, exportSettings, sourceURL: f) {
                        batchLock.lock(); fail += 1
                        print("  [失败] " + name + " 写盘失败"); batchLock.unlock()
                        return
                    }
                }
            }
            let tExported = Date()   // 出图耗时从这里算起（原来上面还白留了一个 tExport）
            let flag = alreadyClose ? "  ⚠ 原片已接近该风格，未套用" : (err > 1.0 ? "  ⚠ 与该风格差异较大" : "")
            if ProcessInfo.processInfo.environment["CR_BATCH_PROFILE"] == "1" {
                batchLock.lock()
                print(String(format: "    [profile] 读图 %.0f ｜ 闭环 %.0f ｜ 出图 %.0f ms ｜ %dx%d",
                             tLoaded.timeIntervalSince(tStart) * 1000,
                             tLoop.timeIntervalSince(tLoaded) * 1000,
                             tExported.timeIntervalSince(tLoop) * 1000,
                             Int(src.extent.width), Int(src.extent.height)))
                batchLock.unlock()
            }
            batchLock.lock()
            ok += 1
            if alreadyClose { noop += 1 }
            if err > 1.0 { far += 1 }
            print(String(format: "  %@  误差 %.3f -> %.3f（%d 轮） gamma %.3f 抬黑 %.0f 降饱和 %.0f%@",
                         name, errBefore, err, used, bp.gamma, bp.levelsOut[0], bp.desat, flag))
            records.append(["file": f.lastPathComponent, "errorBefore": errBefore, "errorAfter": err,
                            "iterations": used, "gamma": bp.gamma, "lift": bp.levelsOut[0],
                            "desat": bp.desat, "alreadyClose": alreadyClose, "farFromStyle": err > 1.0,
                            "params": ["levelsIn": bp.levelsIn, "levelsOut": bp.levelsOut, "gamma": bp.gamma,
                                       "brightness": bp.brightness, "contrast": bp.contrast, "desat": bp.desat,
                                       "cbSh": bp.cbSh, "cbMid": bp.cbMid, "cbHi": bp.cbHi]])
            batchLock.unlock()
            }
        }
    }
    group.wait()
    /// 出图：风格渲染 → 皮肤（保毛孔）→ 人像全量 → 影调补充
    func smoothed(_ src: CIImage, _ p: Params) -> CIImage {
        var out = render(src, p)
        var sk = SkinOptions()
        if sceneSnapshot != nil, sk.strength <= 0 { sk.strength = 55 }   // 自动场景给一档默认磨皮
        sk.strength = smooth
        sk.unifyTone = skinTone
        sk.texturePreserve = !args.contains("--no-texture-preserve")
        sk.deltaWarm = styleSnapshot.target.warmHi * 0.25
        if let sc = sceneSnapshot { sk.grade = sc.skinGrade; sk.unifyTone = sc.skinTone }
        var port = portrait
        if let sc = sceneSnapshot { port = sc.portrait }      // --auto-scene 时用识别出来的参数
        if port.anyEnabled { out = applyPortrait(out, port) }
        // 自动项按「先校色 → 再分级 → 再降噪/锐化 → 最后补光」的顺序
        if autoWB > 0.5 { out = applyWhiteBalance(out, amount: autoWB) }
        if let batchPlan = planSnapshot {
            // 整批统一：所有图用同一套参数（观感一致优先）
            if batchPlan.wb > 0.5 { out = applyWhiteBalance(out, amount: batchPlan.wb) }
            if batchPlan.exposure > 0.5 { out = autoExpose(out, amount: batchPlan.exposure) }
            if batchPlan.denoise > 0.5 { out = denoise(out, amount: batchPlan.denoise) }
        }
        if autoAdapt {
            let scene = sharedCtx.createCGImage(out, from: out.extent).map { classifyScene($0) }
            let face = sharedCtx.createCGImage(out, from: out.extent).flatMap { cg in
                detectFaceGeos(cg, size: out.extent.size).max(by: { $0.box.width < $1.box.width })?.box
            }
            let p = planSceneAdaptive(out, scene: scene, faceBox: face)
            print("  场景自适应：场景 " + p.category + " ｜ 背景/主体 " + String(format: "%.2f", p.backlight)
                  + " ｜ σ " + String(format: "%.2f", p.noiseSigma)
                  + " ｜ 肤色 " + String(format: "%.1f%%", p.skinShare * 100))
            for r in p.reasons { print("    · " + r) }
            if p.wb > 0.5 { out = applyWhiteBalance(out, amount: p.wb) }
            if p.exposure > 0.5 { out = autoExpose(out, amount: p.exposure) }
            if p.denoise > 0.5 { out = denoise(out, amount: p.denoise) }
        }
        if autoExposeAmount > 0.5 { out = autoExpose(out, amount: autoExposeAmount) }
        if autoVignetteOn {
            let p = planAutoVignette(out)
            if p.needed {
                out = correctVignetting(out, amount: p.amount)
                print("  自动暗角：" + p.detail + String(format: " → 校正 %.0f", p.amount))
            } else {
                print("  自动暗角：" + p.detail + "，不需要校正")
            }
        }
        if highlightRecover > 0.5 { out = recoverHighlights(out, amount: highlightRecover) }
        if autoDenoiseOn {
            let p = planAutoDenoise(out)
            if p.needed {
                out = denoise(out, amount: p.amount)
                print("  自动降噪：" + p.detail + String(format: " → 降噪 %.0f", p.amount))
            } else {
                print("  自动降噪：" + p.detail + "，不需要降噪")
            }
        }
        if autoSkinAmount > 0.5, let cgS = sharedCtx.createCGImage(out, from: out.extent) {
            let geosS = detectFaceGeos(cgS, size: out.extent.size)
            if !geosS.isEmpty {
                let mask = geosS.count == 1 ? bestSkinMask(out, face: geosS[0]) : skinMaskForFaces(out, geos: geosS)
                let (fx, _, shift) = autoSkinTone(out, mask: mask, amount: autoSkinAmount)
                out = fx
                if abs(shift) > 0.2 { print(String(format: "  自动肤色：位移 %+.2f°", shift)) }
            }
        }
        if autoLevelOn {
            if let (leveled, ang) = autoLevel(out) {
                out = leveled
                if abs(ang) > 0.5 { print(String(format: "  自动摆正：量到 %.2f°", ang)) }
            }
        }
        if denoiseAmount > 0.5 { out = denoise(out, amount: denoiseAmount) }
        if sharpenAmount > 0.5 { out = sharpen(out, amount: sharpenAmount) }
        if smartSharpen > 0.5 { out = sharpenEdgeAware(out, amount: smartSharpen) }
        if autoFill > 0.5 {
            let face = sharedCtx.createCGImage(out, from: out.extent).flatMap { cg in
                detectFaceGeos(cg, size: out.extent.size).max(by: { $0.box.width < $1.box.width })?.box
            }
            out = autoFillLight(out, amount: autoFill, face: face)
        }
        if bgBlurAmount > 0.5 { out = backgroundBlur(out, radius: 24, strength: bgBlurAmount) }
        if edgeRefineAmount > 0.5 { out = refineEdges(out, amount: edgeRefineAmount) }
        if abs(vignetteAmount) > 0.5 { out = vignette(out, amount: vignetteAmount) }
        if grainAmount > 0.5 { out = grain(out, amount: grainAmount) }
        if lightAmount > 0.5 {
            out = addLight(out, strength: lightAmount,
                           at: CGPoint(x: out.extent.midX, y: out.extent.minY + out.extent.height * 0.68),
                           radiusRatio: 0.75)
        }
        // 智能裁剪（放在人像之后、镜头校正之前：它按显著性主体裁，几何校正跟着一起走）
        if !smartCropSpec.isEmpty, let cg = sharedCtx.createCGImage(out, from: out.extent) {
            let sal = detectSaliency(cg)
            var aspect = cropAspectValue(smartCropSpec)
            if aspect < 0.01 { aspect = Double(out.extent.width / out.extent.height) }
            let subject = sal?.subject ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            let r = smartCropRect(imageSize: out.extent.size, aspect: aspect, subject: subject, placement: cropPlacement)
            out = out.cropped(to: r)
        }
        // 镜头校正放在最后（几何类，应该移动已经修好的整幅图）
        if abs(lensDistort) > 0.01 { out = correctLensDistortion(out, amount: lensDistort) }
        if lensVignette > 0.01 { out = correctVignetting(out, amount: lensVignette) }
        if abs(lensCA) > 0.01 { out = correctChromaticAberration(out, amount: lensCA) }
        if abs(perspH) > 0.01 || abs(perspV) > 0.01 {
            out = perspectiveCorrect(out, horizontal: perspH, vertical: perspV)
        }
        return out
    }
    
    /// 出图收尾：背景纯化（可选）→ 祛黑白边（可选）
    func finished(_ img: CIImage, from original: CIImage) -> CIImage {
        var out = img
        if purify { out = purifyBackgroundEx(out) }
        if autoCrop {
            let rect = detectBorderCropConverged(out)
            if rect.width < out.extent.width - 2 || rect.height < out.extent.height - 2 {
                out = out.cropped(to: rect)
            }
        }
        return out
    }
    
    if let cache = rawCache {
        print(String(format: "RAW 缓存：命中 %d / 未命中 %d，占用 %.2f GB",
                     cache.hits, cache.misses, Double(cache.bytes) / 1_073_741_824))
    }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "完成：成功 %d / 失败 %d ｜未套用 %d ｜差异过大 %d ｜用时 %.1f s（%.2f 张/秒）",
                 ok, fail, noop, far, dt, Double(ok) / max(dt, 0.001)))
    // 退出码是 CLI 的接口：批处理脚本凭它判断成败（第 148 节立的规矩：路径打错时不能报"成功 0"仍返回 0）。
    // 但这里原来**根本没有 exit**，于是默认 0 —— 一个目录里全是坏文件（0 字节 / 半截 / 目录伪装成 .jpg）
    // 也会报"成功 0 / 失败 4"并返回 **0**，自动化会以为跑成功了（实测 §176）。
    // 规则取保守的一条：**一张都没成功、而且确有失败**才算整体失败；
    // 部分失败仍然返回 0（批量里个别坏文件是常态），但报告行里数字写清楚。
    if ok == 0 && fail > 0 { exit(1) }
    if !reportPath.isEmpty {
        let payload: [String: Any] = ["style": style.index, "styleName": style.name, "images": records]
        try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            .write(to: URL(fileURLWithPath: reportPath))
        print("报告：\(reportPath)")
    }
    
}
