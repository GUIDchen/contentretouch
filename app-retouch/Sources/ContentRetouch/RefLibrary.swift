// RefLibrary.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    func pickRefs() {
        let p = NSOpenPanel()
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        var picked: [String] = []
        for u in p.urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                picked += indexableFiles(u.path).prefix(12)   // 目录最多取 12 张，参考不是越多越好
            } else {
                picked.append(u.path)
            }
        }
        for f in picked where !refPaths.contains(f) { refPaths.append(f) }
        refTargetStats = nil
        refInfo = "已选 \(refPaths.count) 张参考图，点「折算目标」"
    }

    func grabRefs() {
        let link = refURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        refInfo = "抓取中…"
        let dir = NSHomeDirectory() + "/Library/Application Support/ContentRetouch/refs"
        DispatchQueue.global(qos: .userInitiated).async {
            let got = fetchReferences(link, into: dir)
            DispatchQueue.main.async {
                for f in got where !refPaths.contains(f) { refPaths.append(f) }
                refTargetStats = nil
                // 抓不到就直说原因，不给「已抓取 0 张」这种废话
                refInfo = got.isEmpty
                    ? "没抓到图：前端渲染的分享页 HTML 里没有图片地址，或需要登录。可以直接给图片直链，或用「选择参考图」从本地挑。"
                    : "抓到 \(got.count) 张参考图"
            }
        }
    }

    func solveRef() {
        let imgs = loadReferences(refPaths)
        guard !imgs.isEmpty else { refInfo = "这些参考图读不出来（格式不支持？）"; return }
        let (t, n, sp, dropped) = referenceTargetRobust(imgs)
        // ⚠️ **纯色参考必须先挡掉**：纯色图的影调跨度是 0，所以 measure() 归一化出来的 q5/q50/q95
        // 会**全是 0**（`span = max(1.0, p99 - p1)`，p1 == p99 → 0/1）。
        // 而下面那条"白底文档"闸门判的是 `q50 > 0.6` —— 对纯白恰好**不成立**，于是闸门失效、
        // 追色朝"全黑"冲（实测：纯白/中灰/纯黑参考把画面峰值推到 170~237，照片直接毁掉）。
        // 判据改成"有没有影调分布"：跨度低于 8 级 = 一片纯色，没有可追的东西。
        if t.p95 - t.p5 < 8 {
            refTargetStats = nil
            refInfo = String(format: "拒绝：参考图是一片纯色（影调跨度仅 %.0f 级），没有可追的分布", t.p95 - t.p5)
            return
        }
        // 白底文档/截图在统计上就是「很亮 + 几乎无饱和 + 无暖冷层次」，当参考只会把照片冲成一片白
        if t.sat < 8 && t.q50 > 0.6 && abs(t.warmHi) < 2 && abs(t.warmSh) < 2 {
            refTargetStats = nil
            refInfo = String(format: "拒绝：参考图看着像白底文档/截图（亮度 %.2f、饱和 %.0f%%），不是照片风格", t.q50, t.sat)
            return
        }
        refTargetStats = t
        refInfo = "\(n) 张参考（剔除离群 \(dropped) 张）折算出目标"
            + (sp > 0.25 ? String(format: "；注意：参考之间离散度 %.2f 偏高，追出来的是它们的共同点", sp) : "")
    }

    func applyRef() {
        guard let t = refTargetStats, let img = workImage() else { return }
        let (p, _, err, before, _) = matchToReference(img, target: t, iterations: 6)
        // 用户要求：**差得远也要照样应用**，只提示一句即可（以前是"保持原样不动"）。
        // 所以这里只记一句提示，不再提前返回。
        let farApart = before <= err
        // 记下追色前的状态，供「取消追色」一键还原
        preRefSnapshot = snapshot("追色前")
        pushHistory("参考追色")
        params = p
        // ── 分区追色：对每个勾选的区域，用「参考图在该区域的分布」当目标，单独解一次参数 ──
        regionMatches = []
        var notes: [String] = []
        if !refRegionSel.isEmpty {
            let refs = loadReferences(refPaths)
            for raw in refRegionSel {
                guard let region = ColorRegion(rawValue: raw) else { continue }
                guard let rt = referenceTargetByRegion(refs, region: region)?.target,
                      let src = measureRegion(img, region) else {
                    notes.append(region.rawValue + "（参考或本图这块不成立，跳过）")
                    continue
                }
                // 用同一个解算器：把这幅图该区域的分布搬到参考该区域的分布
                let lp = paramsFromStats(from: src, to: rt)
                regionMatches.append((region, lp))
                notes.append(String(format: "%@ p50 %.0f→%.0f", region.rawValue, src.p50, rt.p50))
            }
        }
        refRegionHint = notes.isEmpty
            ? "未勾选 = 只做全局追色；勾选后每一块单独算一次并贴在该区域里"
            : "分区：" + notes.joined(separator: "；")
        refInfo = String(format: "追色完成：与参考的误差 %.2f → %.2f（越小越像）%@%@",
                         before, err,
                         regionMatches.isEmpty ? "" : "；另做了 \(regionMatches.count) 个分区",
                         farApart ? "。⚠️ 这张图与参考差得比较远，结果可能不自然，可用旁边的「取消追色」还原" : "")
        status = refInfo
        refresh()
    }

    func defaultIndexPath(_ folder: String) -> String {
        let base = NSHomeDirectory() + "/Library/Application Support/ContentRetouch/index"
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let name = (folder as NSString).lastPathComponent
        return base + "/" + (name.isEmpty ? "index" : name) + ".jsonl"
    }

    func refLibIndexPath(_ dir: String) -> String { defaultIndexPath(dir) }

    func countIndexed(_ dir: String) -> Int {
        let store = ImageIndexStore()
        store.load(refLibIndexPath(dir))
        return store.records.count
    }

    /// #3 增量：只索引「索引里还没有的」和「改过的」文件，其他不动。
    func runRefLibIndex() {
        guard !refLibDir.isEmpty else { return }
        refLibBusy = true
        refLibProgress = "扫描中…"
        let dir = refLibDir
        let out = refLibIndexPath(dir)
        DispatchQueue.global(qos: .userInitiated).async {
            let all = indexableFiles(dir)
            let store = ImageIndexStore()
            store.load(out)
            var known = Set<String>()
            var mtime: [String: Date] = [:]
            for r in store.records {
                known.insert(r.path)
                mtime[r.path] = (try? FileManager.default.attributesOfItem(atPath: r.path)[.modificationDate] as? Date) ?? nil
            }
            let fm = FileManager.default
            let todo = all.filter { path in
                guard known.contains(path) else { return true }      // 新增
                let cur = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? nil
                return cur != mtime[path]                            // 改过
            }
            guard !todo.isEmpty else {
                DispatchQueue.main.async {
                    refLibBusy = false; refLibIndex = store.records.count
                    refLibProgress = "没有新增或改动，索引保持 \(store.records.count) 张"
                }
                return
            }
            var added: [ImageRecord] = []
            let lock = NSLock()
            var done = 0
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                autoreleasepool {
                    guard let r = indexImage(todo[i]) else { return }
                    lock.lock(); added.append(r); done += 1; let d = done; lock.unlock()
                    if d % 50 == 0 {
                        DispatchQueue.main.async { refLibProgress = "已解析 \(d)/\(todo.count)" }
                    }
                }
            }
            // 同一路径的新记录替换旧的（改过的图），其余追加
            let changed = Set(added.map { $0.path })
            var merged = store.records.filter { !changed.contains($0.path) }
            merged += added
            merged.sort { $0.path < $1.path }
            store.replaceAll(merged)
            try? store.save(out)
            DispatchQueue.main.async {
                refLibBusy = false
                refLibIndex = store.records.count
                refLibProgress = "增量完成：新增/更新 \(added.count) 张，索引共 \(store.records.count) 张"
                status = refLibProgress
            }
        }
    }

    var hasRefEmbeddings: Bool {
        guard !refLibDir.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: refLibIndexPath(refLibDir) + ".fp")
    }

    /// 在 App 里直接建 768 维嵌入表（原先只能靠命令行 --index-fp，普通用户根本不会去跑）。
    /// 与索引行序一一对应，所以整表重建而不是增量——表只有几 MB，重建一次几分钟的事。
    func runRefLibEmbeddings() {
        let jsonl = refLibIndexPath(refLibDir)
        let store = ImageIndexStore()
        store.load(jsonl)
        guard !store.records.isEmpty else { refLibProgress = "先点「增量更新索引」"; return }
        let paths = store.records.map { $0.path }
        let out = jsonl + ".fp"
        refLibBusy = true
        refLibProgress = "开始建嵌入表 0/\(paths.count)"
        DispatchQueue.global(qos: .userInitiated).async {
            var rows = [[Float]?](repeating: nil, count: paths.count)
            let lock = NSLock()
            var done = 0
            let t0 = Date()
            let sem = DispatchSemaphore(value: 4)
            let grp = DispatchGroup()
            for (i, p) in paths.enumerated() {
                sem.wait(); grp.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { sem.signal(); grp.leave() }
                    // 逐张排空自动释放池：这一万多次推理不排池就会一路堆到几个 G
                    autoreleasepool {
                        var v: [Float]? = nil
                        if let img = loadAnyImage(p, maxDim: 700),
                           let cg = sharedCtx.createCGImage(img, from: img.extent) {
                            v = featurePrint(cg)
                        }
                        lock.lock(); rows[i] = v; done += 1; let d = done; lock.unlock()
                        if d % 100 == 0 {
                            let dt = max(0.1, Date().timeIntervalSince(t0))
                            DispatchQueue.main.async {
                                refLibProgress = String(format: "建嵌入表 %d/%d　%.1f 张/s", d, paths.count, Double(d) / dt)
                            }
                        }
                    }
                }
            }
            grp.wait()
            let es = EmbeddingStore()
            es.build(rows)
            try? es.save(out)
            let okCount = rows.compactMap { $0 }.count
            DispatchQueue.main.async {
                refLibBusy = false
                refLibProgress = "嵌入表完成：\(okCount)/\(paths.count) 张（找相似参照图现在走嵌入）"
                status = refLibProgress
            }
        }
    }

    /// #2 推荐参照图：拿当前照片的嵌入在图库里找最像的几张
    func recommendRefs() {
        guard let u = srcURL, let img = loadAnyImage(u.path, maxDim: 700),
              let cg = sharedCtx.createCGImage(img, from: img.extent),
              let q = featurePrint(cg) else { status = "读不到当前照片"; return }
        let out = refLibIndexPath(refLibDir)
        let es = EmbeddingStore()
        es.load(out + ".fp")
        let store = ImageIndexStore()
        store.load(out)
        if es.count > 0 {
            let hits = es.search(q, topK: 12)
            recRefs = hits.compactMap { h in
                guard h.index < store.records.count else { return nil }
                return (path: store.records[h.index].path, distance: h.distance)
            }
            status = String(format: "推荐参照图：在 %d 条嵌入里取前 %d（%.0f ms）", es.count, recRefs.count, 0)
        } else {
            // 没有嵌入表：退回按色调统计粗排（如实说明，不假装是同一个东西）
            let s = measure(img)
            recRefs = store.records
                .map { (path: $0.path, distance: abs($0.luma - s.p50 / 255) * 2 + abs($0.warm / 60)) }
                .sorted { $0.distance < $1.distance }
                .prefix(12).map { $0 }
            status = "没有嵌入表（命令行跑 --index-fp 生成）：已退回按亮度/暖冷粗排 (recRefs.count) 张"
        }
        refLibProgress = status
    }

    /// 把推荐出来的这几张当参考图，折算目标色并追色（复用参考图追色的那套）
    func applyRefsAsTarget() {
        guard !recRefs.isEmpty, let img = workImage() else { return }
        let paths = recRefs.prefix(6).map { $0.path }
        let imgs = loadReferences(paths)
        guard !imgs.isEmpty else { status = "参照图读不出来"; return }
        let (t, n, sp, _) = referenceTargetRobust(imgs)
        let (p, _, err, before, _) = matchToReference(img, target: t, iterations: 6)
        if before <= err {
            status = String(format: "这组参照与原片差得较远（误差 %.2f → %.2f），没有更接近的解法，保持原样", before, err)
            return
        }
        pushHistory("参照图库追色")
        params = mergeParams(p)
        target = t
        status = String(format: "已用 %d 张参照图追色：误差 %.2f → %.2f（离散度 %.2f）", n, before, err, sp)
        refresh()
    }

    func findSimilar() {
        guard let u = srcURL, let q = featurePrint(u.path) else { return }
        busy = true; status = "正在检索 13,484 张参考库…"
        DispatchQueue.global(qos: .userInitiated).async {
            let idx = loadIndex(indexPath)
            let groups = recommend(query: q, index: idx, groups: 3, perGroup: 6)
            DispatchQueue.main.async {
                records = groups.map { g in
                    BatchRow(file: "参考组 \(g.noteId.prefix(8))…  \(g.files.count) 张  最近 \(String(format: "%.3f", g.best))",
                             errBefore: 0, errAfter: Double(g.best), params: Params(), alreadyClose: false)
                }
                panel = 2
                busy = false
                status = "找到 \(groups.count) 组相似参考（见右侧「历史/队列」）"
            }
        }
    }
}
