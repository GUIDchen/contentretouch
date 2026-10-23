// ImportExport.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 自检参数的取值：支持 --flag=value（**推荐**）与 --flag value 两种写法。
    /// 用 = 形式是为了让值变成同一个 token，AppKit 就不会把它当「要打开的文件」——
    /// 否则传一个额外裸参数会让窗口根本不出现（见 10.x 那条记录）。
    /// ⚠️ 自检参数**优先走环境变量**（--import → CR_IMPORT），argv 只作兜底。
    ///
    /// 原因是这轮实测出来的一条硬事实：**只要多一个 "--flag=value" 形式的 argv，
    /// 窗口就完全不会被创建**（NSApp.windows 恒为 0，自截图一路刷「没有可截的窗口」）。
    /// 对照实验：不额外传参数 2/2 成功；传 --foo=bar（一个根本没人读的假参数）照样必失败；
    /// 而 "--flag 值" 的空格形式没问题。这是 AppKit/SwiftUI 启动时的参数处理，跟业务代码无关，
    /// 我们改不动它——那就绕开它：环境变量不经过 argv，稳定可用。
    func selfCheckValue(_ name: String) -> String? {
        let envKey = "CR_" + name.dropFirst(2).replacingOccurrences(of: "-", with: "_").uppercased()
        if let v = ProcessInfo.processInfo.environment[envKey], !v.isEmpty { return v }
        let a = CommandLine.arguments
        if let hit = a.first(where: { $0.hasPrefix(name + "=") }) {
            return String(hit.dropFirst(name.count + 1))
        }
        if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
        return nil
    }

    var currentIndex: Int {
        guard let u = srcURL else { return 0 }
        return strip.firstIndex(of: u) ?? 0
    }

    /// **所有切图都走这里**：存下当前这张的状态、取出目标那张的状态（没见过的 = 干净状态）。
    func switchToImage(_ u: URL) {
        // 分步 RSS 探针（CR_MEMTRACE=1）：把"换图会涨内存"这件事从"感觉"压到"哪一步"
        // （§198-§199 已把范围压到"每次加载留下的全分辨率级缓冲"，但还差一层）。
        let mt = ProcessInfo.processInfo.environment["CR_MEMTRACE"] == "1"
        // ⚠️ m0 必须从**当前** RSS 起算：从 0 起算时第一行永远是绝对值
        //（实测把"进入"的累计报成 +17296 MB，看着像天大的泄漏，其实是探针自己的瑕疵）
        var m0 = mt ? auditRSSMB() : 0
        func mtStep(_ tag: String) {
            guard mt else { return }
            let now = auditRSSMB()
            FileHandle.standardError.write(String(format: "MEMTRACE %@ %.0f %+.0f\n", tag, now, now - m0).data(using: .utf8)!)
            m0 = now
        }
        mtStep("进入")
        if let old = srcURL, old.path != u.path {
            editStates[old.path] = currentEditState()
        }
        mtStep("存旧状态")
        srcURL = u
        // 换图必须清掉这些按图缓存，否则人脸/关键点会用上一张的
        cachedURL = nil; cachedFaceURL = nil; cachedGeos = []
        personCache = []; personCacheURL = nil; personRects = []; personSkin = []
        hoverPoint = nil
        mtStep("清按图缓存")
        applyEditState(editStates[u.path] ?? EditState())
        mtStep("套新图状态")
        refresh()
        mtStep("首帧刷新")
        // ⚠️ 历史栈必须跟着图重建：
        //   ① 不重建 → 在 A 图编辑后切到 B 图按撤销，会把 **A 图的编辑**套到 B 图上
        //      （EditState 里只有参数，没有历史栈，所以切图时它是唯一被漏掉的状态）；
        //   ② 顺带解决"回不到原图"：把这次打开的状态作为 history[0] 压进去，
        //      撤销到底就是这张图刚打开的样子（见第 142 节）。
        history = [snapshot("打开")]
        historyCursor = 0
        redoStack.removeAll()
        mtStep("重建历史")
    }

    func stepImage(_ d: Int) {
        guard !strip.isEmpty else { return }
        let n = strip.count
        switchToImage(strip[((currentIndex + d) % n + n) % n])
    }

    /// 再点同一颗星 = 取消（照像素蛋糕的星级习惯）
    func setStar(_ s: Int) {
        guard let u = srcURL else { return }
        stars[u] = (stars[u] == s) ? 0 : s
    }

    func measureExportSize() {
        estimateWork?.cancel()
        guard let u = srcURL, let img = workImage() else { exportSizeEstimate = ""; return }
        let settings = export
        let item = DispatchWorkItem { [self] in
            guard let n = measureExportBytes(img, settings, sourceURL: u) else {
                exportSizeEstimate = "体积：测不了（这种设置下编码失败）"
                return
            }
            let mb = Double(n) / 1_048_576
            let px = Int(img.extent.width) * Int(img.extent.height)
            exportSizeEstimate = String(format: "当前设置下这张图约 %.2f MB（%@ %@，%.0f 万像素，真实编码量得）",
                                        mb, settings.format.uppercased(),
                                        settings.format == "jpeg" ? String(format: "质量 %.0f", settings.quality) : "",
                                        Double(px) / 10000)
        }
        estimateWork = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// 裁剪旋转：自动祛黑白边 + 旋转 + 翻转（纯几何，Core Image 直接做）。
    /// 预览走这个薄包装；导出走 applyGeometry(_:_:)（拿的是值快照，可以在后台线程调用）。
    func applyEdits(_ img: CIImage) -> CIImage {
        var m = ManualEditSet()
        m.autoCrop = autoCropOn; m.rotateDeg = rotateDeg; m.flipH = flipH; m.quarterTurns = quarterTurns
        return applyGeometry(img, m)
    }

    func runIndex() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        guard p.runModal() == .OK, let dir = p.url else { return }
        runIndex(dir: dir)
    }

    /// 以图搜图：用**学习模型的 768 维图像嵌入**找相似，而不是比色调统计。
    /// 嵌入表是离线建好的（命令行 --index-fp，13529 张约 4 分钟），查询是全库暴力扫，实测 20 ms 级。
    func runSimilar() {
        guard let u = srcURL, let img = loadAnyImage(u.path, maxDim: 700),
              let cg = sharedCtx.createCGImage(img, from: img.extent),
              let q = featurePrint(cg) else { simInfo = "读不到当前图"; return }
        let fpPath = indexPathHint + ".fp"
        let es = EmbeddingStore()
        es.load(fpPath)
        guard es.count > 0 else {
            simInfo = "还没有嵌入表：先点「建索引…」，再用命令行跑一次 --index-fp（(fpPath)）"
            return
        }
        let store = ImageIndexStore()
        let jsonl = indexPathHint
        if FileManager.default.fileExists(atPath: jsonl) { store.load(jsonl) }
        let t0 = Date()
        let hits = es.search(q, topK: 24)
        let ms = Date().timeIntervalSince(t0) * 1000
        simHits = hits.map { h in
            let name = h.index < store.records.count ? store.records[h.index].file : "行(h.index)"
            let p = h.index < store.records.count ? store.records[h.index].path : ""
            return (p.isEmpty ? name : p, h.distance)
        }
        simInfo = String(format: "以图搜图：%d 条嵌入里全扫，取前 %d，%.1f ms", es.count, hits.count, ms)
        status = simInfo
    }

    func runSearch() {
        let path = indexPathHint.isEmpty
            ? defaultIndexPath(srcURL?.deletingLastPathComponent().path ?? NSHomeDirectory())
            : indexPathHint
        guard FileManager.default.fileExists(atPath: path) else {
            searchHits = []
            indexPathHint = path
            status = "还没有索引文件，先点「建索引…」选一次素材目录"
            return
        }
        let store = ImageIndexStore()
        store.load(path)
        let t0 = Date()
        searchHits = store.search(searchQuery).map { $0.0 }   // 全量，显示时再截前 60
        indexPathHint = path
        status = String(format: "检索「%@」命中 %d/%d 张，耗 %.0f ms",
                        searchQuery, searchHits.count, store.records.count, Date().timeIntervalSince(t0) * 1000)
    }

    /// 诊断信息：只放**本机真的读得到**的东西，不塞猜测
    func diagnostics() -> String {
        var s = "ContentRetouch 诊断信息\n"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版（SPM 直跑）"
        s += "版本: \(ver)\n"
        s += "系统: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        s += "CPU 核: \(ProcessInfo.processInfo.activeProcessorCount)\n"
        s += "项目根: \(projectRoot)\n"
        s += "当前图: \(srcURL?.path ?? "未载入")\n"
        s += "预设: \(styles.count) 条（内置分类 \(presetGroups.count) 组、我的 \(myPresets.count) 条）\n"
        s += String(format: "预览尺寸: %d px，并行度: %d\n", previewMaxDim, exportWorkers)
        let (h, m) = VisionCache.shared.stats()
        s += "Vision 缓存: 命中 \(h) / 未命中 \(m)\n"
        s += "人脸解析模型: \(FaceParser.shared.isAvailable ? "可用" : "不可用（退回肤色阈值）")\n"
        s += "精细分割(SAM): \(SamStore.shared.isInstalled ? "已安装" : "未安装")\n"
        s += "素材索引: \(indexPathHint.isEmpty ? "未设置" : indexPathHint)\n"
        if !indexProgress.isEmpty { s += "上次索引: \(indexProgress)\n" }
        s += "状态栏: \(status)\n"
        return s
    }

    /// 连拍分组选优：按时间/文件名分组，组内最高分的打 5 星、其余 3 星。
    /// 交付时只勾 5 星，就等于「每个连拍只交一张最好的」。
    func burstPick() {
        guard !picks.isEmpty, let base = stripDir ?? Optional(URL(fileURLWithPath: NSTemporaryDirectory())) else {
            status = "先跑一次 AI 挑图"; return
        }
        let paths = picks.map { base.appendingPathComponent($0.file).path }
        let groups = pickBestPerGroup(picks, groups: groupBursts(paths: paths))
        for (gi, g) in groups.enumerated() {
            for idx in g.indices where idx < picks.count {
                let url = base.appendingPathComponent(picks[idx].file)
                stars[url] = idx == g.best ? 5 : 3
                _ = gi
            }
        }
        let chosen = groups.compactMap { g -> String? in
            g.best < picks.count ? picks[g.best].file : nil
        }
        // 每组的建议都列出来（之前只显示首组，组多的时候等于没结论）
        var advice = ""
        burstGroups = groups.enumerated().map { (i, g) in
            guard g.best < picks.count else { return "第 \(i + 1) 组：没有可用分数" }
            let b = picks[g.best]
            let a = shootingAdvice(pose: poseGrade(yawDeg: b.headYaw, faces: b.faces), smile: b.smile,
                                   closedEyes: b.closedEyes, judgedFaces: b.judgedFaces, faceQuality: b.faceQuality)
            return "第 \(i + 1) 组（\(g.indices.count) 张）→ 选 \(b.file)：\(a)"
        }
        if let first = burstGroups.first { advice = "\n" + first }
        burstStats = "共 " + String(groups.count) + " 组；每组选 1 张共 " + String(chosen.count) + " 张，已打 5 星："
            + chosen.prefix(3).joined(separator: "、") + (chosen.count > 3 ? " …" : "") + advice
        status = burstStats
    }

    /// 挑图结果导出 CSV（格式与 pick-cli 一致，便于互相校验）
    func exportPickCSV() {
        guard !picks.isEmpty else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = "pick.csv"
        guard p.runModal() == .OK, let u = p.url else { return }
        var csv = "file,score,sharpness,faces,face_quality,eye_openness,composition,smile,head_yaw_deg,closed_eyes,judged_faces,flags\n"
        for r in picks {
            csv += "\(r.file),\(String(format: "%.2f", r.total)),\(String(format: "%.2f", r.sharpness)),"
                + "\(r.faces),\(String(format: "%.3f", r.faceQuality)),"
                + "\(String(format: "%.3f", r.eyeOpenness)),\(String(format: "%.3f", r.composition)),"
                + "\(String(format: "%.3f", r.smile)),\(String(format: "%.1f", r.headYaw)),"
                + "\(r.closedEyes),\(r.judgedFaces),"
                + "\(r.flags.joined(separator: "|"))\n"
        }
        do {
            try csv.write(to: u, atomically: true, encoding: .utf8)
            status = "挑图 CSV 已导出：\(u.path)（\(picks.count) 行）"
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }

    func runPick() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        guard p.runModal() == .OK, let dir = p.url else { return }
        runPick(dir: dir)
    }

    /// 选目录时顺带把缩略图条建起来（像素蛋糕底部那条）
    func loadSample() {
        reloadStyles()          // 聚类组 + 内置预设分类 + 我的预设，一次装齐
        styleIdx = 0
        let u = URL(fileURLWithPath: projectRoot + "/2604_wedding/00_RAW_readonly/wedding_01.jpg")
        if FileManager.default.fileExists(atPath: u.path) {
            switchToImage(u)
            params = currentStyle.params
            target = currentStyle.target
            personCache = []; personCacheURL = nil; personRects = []; personSkin = []
            refresh()
        } else {
            status = "示例原片不存在，请用「导入照片」"
        }
    }

    /// 导入照片：**照片和文件夹都能选，照片可以多选**。
    ///
    /// 早先这里是「选择原片…」只能一张、「选择整个文件夹…」只能文件夹——用户想一次挑几张照片
    /// 根本做不到，只能先把照片归到一个文件夹里再导。现在合成一个入口：
    /// 混选「几张照片 + 一个文件夹」也行，导进来统一建缩略图条。
    func importItems() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        // 不设 allowedContentTypes：各家 RAW 的 UTType 不一定都挂在 public.image 下，
        // 设了就可能在选择框里灰掉；格式过滤我们自己按扩展名做（imageExtensions 一份清单）。
        p.prompt = "导入"
        p.message = "可以选多张照片，也可以选文件夹（或两者混选）"
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        importURLs(p.urls)
    }

    /// 当前界面状态 → 快照（必须在主线程调用）
    func pipelineConfigNow() -> PipelineConfig {
        var c = PipelineConfig()
        c.params = params; c.target = target
        c.faces = faces; c.perFace = perFaceParams()
        c.cachedGeos = cachedGeos
        c.personSkin = personSkin
        c.portrait = portrait
        var sk = SkinOptions()
        sk.grade = skinGrade; sk.strength = skinStrength
        sk.unifyTone = skinTone; sk.texturePreserve = texturePreserve
        sk.deltaWarm = target.warmHi * 0.25
        c.skin = sk
        c.autoSkinAmount = autoSkinAmount
        c.slimWaist = slimWaist; c.wideShoulders = wideShoulders; c.bodyK = bodyDeformFactor
        c.localWarm = localWarm; c.localBright = localBright
        c.pet = petStrength; c.bgPurify = bgPurify; c.clothes = clothesStrength
        c.petOptions = petOptions
        c.autoWB = autoWB; c.autoExpose = autoExposeAmount; c.highlightRecover = highlightRecover
        c.denoise = denoiseAmount; c.sharpen = sharpenAmount; c.smartSharpen = smartSharpen
        c.autoFill = autoFill; c.bgBlur = bgBlur; c.edgeRefine = edgeRefine
        c.vignette = vignetteAmount; c.grain = grainAmount
        c.light = lightAmount; c.lightWarm = lightWarm
        c.lensDistortion = lensDistortion; c.lensVignette = lensVignette; c.lensCA = lensCA
        c.perspH = perspH; c.perspV = perspV
        c.manual = manualEditsNow()
        c.regions = regions
        c.regionMatches = regionMatches
        c.parts = partAdjusts
        return c
    }

    /// 自检：用代码模拟一次工具操作（落点都是归一化坐标，取画面中部）
    func simulateTool(_ tool: String) {
        guard srcURL != nil else { return }
        let mid = CGPoint(x: 0.5, y: 0.5)
        switch tool {
        case "spotline":
            // 长笔触的性能测试：25 个点连成一条（模拟"拖着涂一整条"）
            spotActive = true; brushActive = false; cropMode = false; patchActive = false; cloneActive = false
            spotPoints = (0..<25).map { CGPoint(x: 0.35 + Double($0) * 0.012, y: 0.45) }
            status = "自检：污点修复长笔触 25 点"
        case "spot":
            spotActive = true; brushActive = false; cropMode = false; patchActive = false; cloneActive = false
            spotPoints = [CGPoint(x: 0.42, y: 0.45), CGPoint(x: 0.46, y: 0.47), CGPoint(x: 0.50, y: 0.49)]
            status = "自检：污点修复落了 3 个点"
        case "patch":
            // ⚠️ 这里以前写的是 `clonePoints` —— 而管线里"修补"读的是 **patchPoints**
            //（Pipeline.swift:189；交互路径也写 patchPoints，见 Canvas.swift:449）。
            // 于是 --simulate=patch 打印了"修补落了 3 个点"、画面**一像素都没动**，
            // 是个"自检说做了、实际没做"的钩子（第 140 节）。
            patchActive = true; spotActive = false; brushActive = false; cropMode = false; cloneActive = false
            patchPoints = [CGPoint(x: 0.40, y: 0.42), CGPoint(x: 0.44, y: 0.44), CGPoint(x: 0.48, y: 0.46)]
            status = "自检：修补落了 3 个点"
        case "clone":
            cloneActive = true; cloneSource = CGPoint(x: 0.62, y: 0.5)
            clonePoints = [CGPoint(x: 0.42, y: 0.45), CGPoint(x: 0.46, y: 0.47), CGPoint(x: 0.50, y: 0.49)]
            spotActive = false; brushActive = false; cropMode = false; patchActive = false
            status = "自检：仿制图章取样点 + 3 个落点"
        case "crop":
            cropMode = true
            cropRect = CGRect(x: 0.15, y: 0.15, width: 0.5, height: 0.5)
            cropApplied = true
            status = "自检：裁剪框 0.15~0.65"
        case "pinch":
            brushActive = true; liquifyMode = .pinch; brushRadius = 4
            warpStrokes = [WarpStroke(mode: .pinch, center: CGPoint(x: 0.5, y: 0.5), radius: 4,
                                      strength: 0.8, density: 0.6)]
            cropMode = false; spotActive = false; patchActive = false; cloneActive = false
            status = "自检：收缩一笔"
        case "liquify":
            brushActive = true; liquifyMode = .push; brushRadius = 12
            warpStrokes = [WarpStroke(mode: .push, center: CGPoint(x: 0.42, y: 0.45), radius: 12,
                                      delta: CGPoint(x: 0.03, y: 0.02)),
                           WarpStroke(mode: .push, center: CGPoint(x: 0.46, y: 0.47), radius: 12,
                                      delta: CGPoint(x: 0.03, y: 0.02)),
                           WarpStroke(mode: .push, center: CGPoint(x: 0.50, y: 0.49), radius: 12,
                                      delta: CGPoint(x: 0.03, y: 0.02))]
            cropMode = false; spotActive = false; patchActive = false; cloneActive = false
            status = "自检：液化刷了 3 笔"
        case "border":
            autoCropOn = true
            status = "自检：祛边已开"
        default:
            status = "自检：未知工具 " + tool
        }
        _ = mid
        refresh()
        FileHandle.standardError.write(("自检 --simulate " + tool + "：" + status + "\n").data(using: .utf8)!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let s = srcImage?.size ?? .zero, o = outImage?.size ?? .zero
            FileHandle.standardError.write(String(format: "DIAG 图尺寸 原=%.0fx%.0f 出=%.0fx%.0f zoom=%.0f 平移=(%.0f,%.0f)\n",
                s.width, s.height, o.width, o.height, zoom, panOffset.width, panOffset.height).data(using: .utf8)!)
            // 把「修后」那张图原样写到文件：这样能直接比像素，而不是隔着界面的缩放去猜
            if let oi = outImage, let tiff = oi.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/out_" + tool + ".png"))
            }
            if let si = srcImage, let tiff = si.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "/tmp/src_" + tool + ".png"))
            }
        }
    }

    /// 把拖进来的东西交给同一个导入入口（macOS 上拖照片进窗口是标准操作，像素蛋糕也支持）
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL? = nil
                if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let s = item as? String { url = URL(string: s) }
                if let u = url { lock.lock(); urls.append(u); lock.unlock() }
            }
        }
        group.notify(queue: .main) { importURLs(urls) }
        return true
    }

    /// 统一导入入口（拖拽进来也走这里）
    func importURLs(_ urls: [URL]) {
        let fm = FileManager.default
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                files += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [])
                    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            } else if imageExtensions.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        // 去重 + 按文件名排序（同一批导入里连拍是挨着的，方便比对）
        var seen = Set<String>()
        files = files.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
        guard !files.isEmpty else {
            status = "这批里没有支持的图片（支持 jpg/heic/webp/avif/tiff/png/psd 与各家 RAW）"
            return
        }
        strip = files
        stripDir = files[0].deletingLastPathComponent()
        selectedStrip = Set(files.prefix(1))
        // 导入走统一切图入口：没见过的图 = **干净状态**（不套任何预设，见 #6），
        // 见过的图恢复它自己的编辑（见 #7）
        switchToImage(files[0])
        status = "已导入 \(files.count) 张" + (files.count > 1 ? "，底部缩略图条已建（← → 翻页）" : "")
            + "（未套预设，从右侧面板或预设栏开始调）"
        refresh()
    }

    /// 建索引主体（不带选择框）
    func runIndex(dir: URL) {
        let paths = indexableFiles(dir.path)
        guard !paths.isEmpty else { indexProgress = "这个目录下没有可索引的图"; return }
        let out = defaultIndexPath(dir.path)
        indexPathHint = out
        indexBusy = true
        indexProgress = "索引 0/\(paths.count)"
        DispatchQueue.global(qos: .userInitiated).async {
            let lock = NSLock()
            var recs: [ImageRecord] = []
            var done = 0
            let t0 = Date()
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                // 逐张排空自动释放池：concurrentPerform 的 worker 线程也要等整块跑完才排池，
                // 一万多张的索引会一路堆到几个 G（挑图那次就是这个原因）
                autoreleasepool {
                guard let r = indexImage(paths[i]) else { return }
                lock.lock(); recs.append(r); done += 1; let d = done; lock.unlock()
                if d % 100 == 0 {
                    let dt = Date().timeIntervalSince(t0)
                    DispatchQueue.main.async {
                        indexProgress = String(format: "索引 %d/%d　%.1f 张/s", d, paths.count, Double(d) / max(0.1, dt))
                    }
                }
                }   // autoreleasepool
            }
            // 存盘前先把重复路径去掉：同一个目录被索引两次（或子目录重叠）会产生重复记录，
            // 检索时会看到同一张图出现两遍
            var seen = Set<String>()
            recs = recs.filter { seen.insert($0.path).inserted }
            recs.sort { $0.path < $1.path }
            let store = ImageIndexStore()
            for r in recs { store.add(r) }
            try? store.save(out)
            DispatchQueue.main.async {
                indexBusy = false
                indexProgress = "索引完成：\(recs.count) 张 → \(out)"
                status = indexProgress
            }
        }
    }

    // MARK: 参照图库的实现
    func pickRefLibrary() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "选一个目录当参照对照图库（原图不动，只读）"
        guard p.runModal() == .OK, let dir = p.url else { return }
        refLibDir = dir.path
        UserDefaults.standard.set(refLibDir, forKey: "CR_REF_LIB")   // 记住：下次打开还在
        refLibIndex = countIndexed(refLibDir)
        refLibProgress = refLibIndex > 0 ? "图库里有 \(refLibIndex) 张已索引，点「增量更新索引」补新增的" : "还没索引，点「增量更新索引」"
        status = "参照图库已设为 " + dir.lastPathComponent
    }

    /// 挑图主体（不带选择框，方便自检与复用）
    ///
    /// ⚠️ 这版修的是「挑图跑一会儿就卡死」：
    ///  1) 每张外面套 `autoreleasepool`。GCD 的 worker 线程要等整个 block 返回才排空自动释放池，
    ///     而挑图一次要过几千上万张、每张都产生一堆 CGImage/Vision 结果 —— 不逐张排空就会一路堆到几个 G
    ///     （实测峰值 3.96 GB，且看着像「内存泄漏」其实不是）。
    ///  2) 并行度**限死**，不再串行也不再放任：串行时一张接一张占满 CPU，界面卡到像死机。
    ///  3) 进度 + 可取消：几万张要跑很久，没有进度和取消按钮，用户只能强杀。
    func runPick(dir: URL) {
        pickBusy = true
        pickCancel = false
        pickProgress = 0
        DispatchQueue.global(qos: .userInitiated).async {
            // 格式清单统一走 imageExtensions：这里原来自己写了一份只认 4 种的，
            // RAW / HEIC / AVIF 在挑图里直接不见了（和缩略图条那次是同一个病）
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.path < $1.path }
            var out: [ImageScore] = []
            let lock = NSLock()
            var done = 0
            let total = files.count
            let sem = DispatchSemaphore(value: 4)
            let grp = DispatchGroup()
            for f in files {
                if pickCancel { break }
                sem.wait(); grp.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { sem.signal(); grp.leave() }
                    autoreleasepool {
                        if let s = scoreImage(f.path) {
                            lock.lock(); out.append(s); lock.unlock()
                        }
                        lock.lock(); done += 1; let d = done; lock.unlock()
                        if d % 20 == 0 {
                            DispatchQueue.main.async { pickProgress = Double(d) / Double(max(1, total)) }
                        }
                    }
                }
            }
            grp.wait()
            out.sort { $0.total > $1.total }
            let cancelled = pickCancel
            DispatchQueue.main.async {
                picks = out; pickBusy = false; panel = 5
                status = cancelled
                    ? "挑图已取消：已看完 \(out.count)/\(total) 张（结果照常可用）"
                    : "挑图完成：\(out.count) 张（按总分排序）"
            }
        }
    }
}
