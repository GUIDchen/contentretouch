// Presets.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    // MARK: 逻辑
    var currentStyle: StylePreset {
        // ⚠️ styleIdx = -1 表示"没有预设被选中"（用户要求别默认停在第 1 条），
        // 所以这里**不能直接 styles[styleIdx]** —— 越界会 SIGTRAP。
        // 这个崩溃是 preflight 的多图冒烟抓出来的（0/6 通过），崩溃报告指向 currentStyle。
        if styles.isEmpty { return StylePreset(index: 0, name: "未载入", target: Stats(), params: Params()) }
        guard styles.indices.contains(styleIdx) else {
            return StylePreset(index: 0, name: "未选预设", target: target, params: params)
        }
        return styles[styleIdx]
    }

    /// 把当前参数存成预设文件（像素蛋糕的「预设管理：新建/导入/管理」）
    /// 预设置信目录：自己存的预设统一放这儿，「我的」页签直接从这儿读
    var myPresetDir: String {
        let d = NSHomeDirectory() + "/Library/Application Support/ContentRetouch/presets"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// 载入风格库 = 收藏库聚类组 + 内置预设分类 + 我自己存的预设。
    /// 三者都塞进同一个 styles 数组，选中靠下标（这样预览与导出走的是同一条路，不会两套）。
    func reloadStyles() {
        var all = (try? loadStyles(stylesPath)) ?? []
        presetGroups = builtinPresetGroups(startIndex: 1000)
        for g in presetGroups { all += g.items }
        myPresets = []
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: myPresetDir)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
        for (i, f) in files.enumerated() {
            let path = (myPresetDir as NSString).appendingPathComponent(f)
            guard let pf = try? loadPreset(path) else { continue }
            let sp = StylePreset(index: 2000 + i, name: pf.name,
                                 target: pf.target ?? Stats(), params: RetouchCore.params(from: pf.style))
            myPresets.append(sp)
            all.append(sp)
        }
        styles = all
    }

    /// 套用一条预设：参数 + 目标一起换（目标换了，导出时闭环追的也就是它了）
    func applyPreset(_ s: StylePreset) {
        guard let i = styles.firstIndex(where: { $0.index == s.index && $0.name == s.name }) else { return }
        // 再点一次已经套用的预设 = **取消应用**，回到套用它之前的状态（用户要求：
        // "点击任意预设应用后再次点击取消应用"）。预设之间互相切换不受影响。
        // 判据用"当前参数 == 这条预设的参数"，而不是 styleIdx：
        // styleIdx 是预设列表里的下标，用户在分类页签之间来回切、或者预设列表重排之后它就不再可靠，
        // 于是"再点一次"被当成"又套了一遍"（用户报的"仍未实现"就是这个）。
        // 判据用"**上一次套用的就是这条预设**"，而不是 styleIdx：
        // styleIdx 是预设列表里的下标，用户在分类页签之间来回切、或列表重排之后它就不再可靠，
        // 于是"再点一次"被当成"又套了一遍"（用户报的"仍未实现"就是这个）。
        let key = "\(s.index)|\(s.name)"
        if appliedPresetKey == key, let prev = prePresetSnapshot {
            styleIdx = 0
            apply(prev)            // apply 内部会 refresh
            styleIdx = -1          // 取消后不保留任何预设的高亮（用户要求：别默认停在第一个）
            prePresetSnapshot = nil
            appliedPresetKey = nil
            pushHistory("取消预设：" + s.name)      // ⚠️ 必须在 apply 之后：历史一律记"改动后的状态"
            status = "已取消预设「" + s.name + "」，回到套用之前的状态"
            return
        }
        // ⚠️ 每次套用都要**重拍**快照（原来只在"当前没有预设"时拍）：
        // 套 P 之后再套 Q，取消 Q 应该回到 **P 的状态**（"回到套用它之前"），
        // 而旧写法会拿第一次套用前的快照 → 取消 Q 同时把 P 也丢了（实测取消后 vs P 峰值 30、vs 基线 0，第 144 节）。
        prePresetSnapshot = snapshot("套预设前")
        appliedPresetKey = key
        styleIdx = i
        // 尊重面板上的"叠加 / 替换"：叠加 = 只覆盖这条预设动过的项（原来列表里用的是 mergeParams）
        params = (applyMode == 1) ? s.params : mergeParams(s.params)
        target = s.target
        refresh()
        // ⚠️ pushHistory 必须在改完之后：它自己只是 commitHistory(snapshot(label))，
        // 写在前面记到的就是**改之前**的状态 —— 于是"撤销套用预设"会原地不动
        //（与第 142 节笔触那个 bug 同型：一套数组里混了两种语义）。
        pushHistory("预设：" + s.name)
        status = String(format: "已套用预设「%@」（%@）：目标 q50 %.2f · 饱和 %.0f%% · 阴影暖冷 %+.0f",
                        s.name, applyMode == 1 ? "替换" : "叠加", s.target.q50, s.target.sat, s.target.warmSh)
    }

    func savePresetFile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (currentStyle.name.isEmpty ? "preset" : currentStyle.name) + ".json"
        guard p.runModal() == .OK, let u = p.url else { return }
        var pf = RetouchCore.preset(from: currentStyle, name: u.deletingPathExtension().lastPathComponent)
        pf.style = .init(levelsIn: params.levelsIn, levelsOut: params.levelsOut, gamma: params.gamma,
                         brightness: params.brightness, contrast: params.contrast, desat: params.desat,
                         cbShadow: params.cbSh, cbMid: params.cbMid, cbHigh: params.cbHi)
        pf.notes = "含人像参数的调色预设（人像参数另见界面）"
        do {
            try savePreset(pf, to: u.path)
            reloadStyles()
            status = "预设已保存：\(u.path)（「预设 → 我的」里能直接点到）"
        } catch {
            status = "预设保存失败：\(error.localizedDescription)"
        }
    }

    /// 载入预设文件并套用
    func loadPresetFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            let pf = try loadPreset(u.path)
            pushHistory("载入预设 \(pf.name)")
            params = RetouchCore.params(from: pf.style)
            refresh()
            status = "已套用预设 \(pf.name)（来源：\(pf.source.kind)）"
        } catch {
            status = "预设载入失败：\(error.localizedDescription)"
        }
    }

    /// 批量应用效果至选中的图片（像素蛋糕底栏的「同步到选中图片」）
    func applyToSelected() {
        let targets = selectedStrip.isEmpty ? strip : Array(selectedStrip)
        guard !targets.isEmpty else { status = "先在底部缩略图条上选几张"; return }
        var outDir = (targets.first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        outDir = outDir.deletingLastPathComponent().appendingPathComponent("synced")
        busy = true; progress = 0
        let files = targets.map { $0.path }
        let style = currentStyle
        let port = portrait
        let sk = (skinGrade, skinStrength, skinTone, texturePreserve)
        let extras = (sharpenAmount, denoiseAmount, vignetteAmount, grainAmount, lightAmount,
                      bgBlur, edgeRefine, clothesStrength, petStrength, slimWaist, wideShoulders)
        let settings = export
        let localWarmV = localWarm, localBrightV = localBright
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let res = exportBatch(files: files, outDir: outDir.path, settings, makeImage: { path in
                guard let ci = loadAnyImage(path, maxDim: 0) else { return nil }
                let s0 = measure(ci)
                var pr = style.params
                let over = max(0, s0.p50 - 120)
                pr.gamma = max(1.0, pr.gamma - over * 0.001)
                pr.brightness = max(0, 5 - over * 0.10)
                let (bp, _, _, _) = closedLoop(ci, base: pr, target: style.target, iterations: 3)
                var out = render(ci, bp)
                var o = SkinOptions()
                o.grade = sk.0; o.strength = sk.1; o.unifyTone = sk.2; o.texturePreserve = sk.3
                o.deltaWarm = style.target.warmHi * 0.25
                out = applySkin(out, o)
                if port.anyEnabled { out = applyPortrait(out, port) }
                if extras.9 > 0.5 || extras.10 > 0.5 {
                    out = reshapeBody(out, slimWaist: extras.9, wideShoulders: extras.10)
                }
                if extras.5 > 0.5 { out = backgroundBlur(out, radius: 24, strength: extras.5) }
                if extras.6 > 0.5 { out = refineEdges(out, amount: extras.6) }
                if extras.7 > 0.5 { out = smoothClothes(out, strength: extras.7) }
                if extras.8 > 0.5 { out = smoothAnimals(out, strength: extras.8) }
                if extras.1 > 0.5 { out = denoise(out, amount: extras.1) }
                if extras.0 > 0.5 { out = sharpen(out, amount: extras.0) }
                if abs(extras.2) > 0.5 { out = vignette(out, amount: extras.2) }
                if extras.3 > 0.5 { out = grain(out, amount: extras.3) }
                if extras.4 > 0.5 {
                    out = addLight(out, strength: extras.4,
                                   at: CGPoint(x: out.extent.midX, y: out.extent.minY + out.extent.height * 0.68),
                                   radiusRatio: 0.75)
                }
                _ = (localWarmV, localBrightV)
                return out
            }, workers: exportWorkers, progress: { done, total in
                DispatchQueue.main.async {
                    progress = Double(done) / Double(max(1, total))
                    status = "同步中 \(done)/\(total)"
                }
            })
            let dt = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                busy = false
                exportStats = String(format: "同步 %d 张 %.2f s（%.2f 张/秒）", res.written, dt, Double(res.written) / max(0.001, dt))
                projects = ProjectStore.upsert(ProjectRecord(path: outDir.path, done: res.written, total: files.count))
                status = "已把当前效果同步到 \(res.written) 张 → \(outDir.path)"
                pushHistory("同步到 \(res.written) 张")
            }
        }
    }

    /// 把当前整套参数打包（核心参数强类型、其余滑杆按名字进 extras）
    func currentEditState() -> EditState {
        var st = EditState()
        st.params = params
        st.portrait = portrait
        st.skinGrade = skinGrade
        st.skinStrength = skinStrength
        st.skinTone = skinTone
        st.texturePreserve = texturePreserve
        st.extras = [
            "slimWaist": slimWaist, "wideShoulders": wideShoulders, "bgPurify": bgPurify,
            "clothes": clothesStrength, "pet": petStrength, "liquifyAmount": liquifyAmount,
            "sharpen": sharpenAmount, "denoise": denoiseAmount, "vignette": vignetteAmount,
            "grain": grainAmount, "light": lightAmount, "lightWarm": lightWarm,
            "bgBlur": bgBlur, "edgeRefine": edgeRefine,
            "lensDistortion": lensDistortion, "lensVignette": lensVignette, "lensCA": lensCA,
            "perspH": perspH, "perspV": perspV
        ]
        return st
    }

    func applyEditState(_ st: EditState) {
        params = st.params
        portrait = st.portrait
        skinGrade = st.skinGrade
        skinStrength = st.skinStrength
        skinTone = st.skinTone
        texturePreserve = st.texturePreserve
        let g = st.extras
        slimWaist = g["slimWaist"] ?? 0
        wideShoulders = g["wideShoulders"] ?? 0
        bgPurify = g["bgPurify"] ?? 0
        clothesStrength = g["clothes"] ?? 0
        petStrength = g["pet"] ?? 0
        liquifyAmount = g["liquifyAmount"] ?? 0
        sharpenAmount = g["sharpen"] ?? 0
        denoiseAmount = g["denoise"] ?? 0
        vignetteAmount = g["vignette"] ?? 0
        grainAmount = g["grain"] ?? 0
        lightAmount = g["light"] ?? 0
        lightWarm = g["lightWarm"] ?? 0
        bgBlur = g["bgBlur"] ?? 0
        edgeRefine = g["edgeRefine"] ?? 0
        lensDistortion = g["lensDistortion"] ?? 0
        lensVignette = g["lensVignette"] ?? 0
        lensCA = g["lensCA"] ?? 0
        perspH = g["perspH"] ?? 0
        perspV = g["perspV"] ?? 0
    }

    func saveVersion() {
        guard let u = srcURL else { status = "先选一张原片"; return }
        let name = versionName.trimmingCharacters(in: .whitespaces)
        versions = VersionStore.save(path: u.path, name: name.isEmpty ? "版本 \(versions.count + 1)" : name,
                                    state: currentEditState())
        versionName = ""
        status = "已存版本（共 \(versions.count) 个），原图没动过"
    }

    func switchToVersion(_ v: VersionRecord) {
        pushHistory("切到版本 \(v.name)")
        applyEditState(v.state)
        refresh()
        status = "已切到版本「\(v.name)」"
    }

    func deleteVersion(_ v: VersionRecord) {
        guard let u = srcURL else { return }
        versions = VersionStore.remove(path: u.path, id: v.id)
    }

    func reloadTrash() { trashItems = LocalTrash.list() }

    /// 把底部选中的片子移进本地回收站（不是真删，能恢复）
    func moveSelectedToTrash() {
        let targets = selectedStrip.isEmpty ? [] : Array(selectedStrip)
        guard !targets.isEmpty else { status = "先在底部缩略图条上选几张"; return }
        let n = LocalTrash.move(targets.map { $0.path })
        selectedStrip.removeAll()
        reloadTrash()
        let kept = strip.filter { !targets.contains($0) }
        strip = kept
        if let f = kept.first { srcURL = f; refresh() } else { srcURL = nil }
        status = "已把 \(n) 张移入本地回收站（可恢复）"
    }

    func restoreFromTrash(_ item: TrashItem) {
        let ok = LocalTrash.restore(item.id)
        reloadTrash()
        status = ok ? "已恢复到 \(item.originalPath)" : "恢复失败"
    }

    func emptyTrash() {
        let n = LocalTrash.empty()
        reloadTrash()
        status = "回收站已清空（真删 \(n) 个）"
    }

    /// 选片交付：按星级把要交的片子挑出来，拷到交付目录 + 写清单
    func deliverPicked() {
        guard !picks.isEmpty else { status = "先跑一次「AI 挑图」，再按星级交付"; return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "选交付目录（会拷进子目录「交付」）"
        guard p.runModal() == .OK, let dir = p.url else { return }
        let out = dir.appendingPathComponent("交付")
        let base = stripDir ?? dir
        let rows = picks.map { sc -> SelectionRow in
            let stars = max(1, min(5, Int((sc.total / 60.0 * 5).rounded())))
            return SelectionRow(file: base.appendingPathComponent(sc.file).path, stars: stars, flags: sc.flags)
        }
        let res = deliverSelection(rows, minStars: deliverStars, to: out)
        deliverStats = String(format: "≥%d 星 %d 张，拷贝 %.1f MB → %@", deliverStars, res.count,
                              Double(res.bytes) / 1_048_576, out.path)
        status = "选片交付完成：\(res.count) 张（清单：选片清单.csv）"
    }
}
