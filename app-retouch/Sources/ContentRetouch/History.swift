// History.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 精修页底部的历史回滚条：撤销 / 重做 + 最近三步（点一下就回滚到那一步）。
    /// 完整的步骤列表仍在「历史」面板里，这里给的是**手边就够得到**的那一份。
    @ViewBuilder var historyStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 8) {
                Button { undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward").font(.system(size: 10)) }
                    .disabled(history.isEmpty)
                Button { redo() } label: { Label("重做", systemImage: "arrow.uturn.forward").font(.system(size: 10)) }
                    .disabled(redoStack.isEmpty)
                Spacer()
                Text("\(history.count) 步").font(.system(size: 9)).foregroundColor(.secondary)
                Button("全部步骤") { panel = 2 }.font(.system(size: 10))
            }
            if history.isEmpty {
                Text("还没有可回滚的步骤").font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                let start = max(0, history.count - 3)
                HStack(spacing: 4) {
                    ForEach(Array((start..<history.count).reversed()), id: \.self) { i in
                        Button {
                            jumpToHistory(i)
                        } label: {
                            Text(String(i + 1) + ". " + history[i].label)
                                .font(.system(size: 9)).lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(i == history.count - 1 ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 历史列：与预设列同宽同位置，列出所有步骤，点哪一步就回到哪一步。
    /// 和右侧「历史」面板内容一致，区别是可以**常驻在画布旁边**，改一下看一眼改一步。
    @ViewBuilder var historyColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("历史步骤").font(.headline)
                Spacer()
                Button { showHistoryColumn = false } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                Button { undo() } label: { Label("撤销", systemImage: "arrow.uturn.backward").font(.system(size: 10)) }
                    .disabled(history.isEmpty)
                Button { redo() } label: { Label("重做", systemImage: "arrow.uturn.forward").font(.system(size: 10)) }
                    .disabled(redoStack.isEmpty)
                Spacer()
                Button("清空") { history = []; redoStack = [] }.font(.system(size: 10))
            }
            Text("点某一步 = 回到那一步（之后的会被丢弃，可用重做恢复）")
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if history.isEmpty {
                        Text("还没有步骤：拖滑杆、套预设、跑批量都会记一条")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    ForEach(Array(history.enumerated().reversed()), id: \.offset) { i, h in
                        Button { jumpToHistory(i) } label: {
                            HStack(spacing: 4) {
                                Text(String(i + 1)).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 18, alignment: .trailing)
                                Text(h.label).font(.system(size: 10)).lineLimit(1)
                                Spacer()
                                Text(h.date.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(i == historyCursor ? Color.accentColor.opacity(0.22) : Color.clear))
                            // 光标之后的步骤**标灰但仍可点**（点过去就再回到那一步）
                            .opacity(i > historyCursor ? 0.35 : 1)
                        }.buttonStyle(.plain)
                    }
                }
            }
            Divider()
            Text("虚拟副本").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            HStack(spacing: 6) {
                TextField("版本名", text: $versionName).textFieldStyle(.roundedBorder).font(.system(size: 10))
                Button("存") { saveVersion() }.font(.system(size: 10))
            }
            // 版本列表与批量结果原来只在右侧「历史」面板里有，而那个面板与这条历史列**其余部分完全一样**
            //（撤销/重做/清空 + 步骤列表）。按要求只保留上方这一份，于是把这两段搬过来，右侧入口去掉。
            ForEach(versions) { v in
                HStack(spacing: 4) {
                    Button(v.name) { switchToVersion(v) }.font(.system(size: 10)).lineLimit(1)
                    Spacer()
                    Text(v.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 8)).foregroundColor(.secondary)
                    Button { deleteVersion(v) } label: { Image(systemName: "trash").font(.system(size: 8)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            Divider()
            Text("批量结果").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
            if records.isEmpty {
                Text("还没有跑过批量").font(.system(size: 9)).foregroundColor(.secondary)
            }
            ForEach(records) { r in
                HStack(spacing: 4) {
                    Text(r.file).font(.system(size: 9)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f→%.2f", r.errBefore, r.errAfter))
                        .font(.system(size: 8)).monospacedDigit().foregroundColor(.secondary)
                }
            }
        }
        .padding(10).frame(width: 215)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 历史与撤销
    func snapshot(_ label: String) -> HistoryEntry {
        HistoryEntry(label: label, params: params, portrait: portrait, skinGrade: skinGrade,
                     skinStrength: skinStrength, skinTone: skinTone, texturePreserve: texturePreserve,
                     slimWaist: slimWaist, wideShoulders: wideShoulders, bgPurify: bgPurify,
                     clothes: clothesStrength, pet: petStrength, liquifyAmount: liquifyAmount,
                     crop: cropRect, cropApplied: cropApplied,
                     rotateDeg: rotateDeg, flipH: flipH, quarterTurns: quarterTurns,
                     spotPoints: spotPoints, clonePoints: clonePoints, patchPoints: patchPoints,
                     cloneEpochs: cloneEpochs, cloneSource: cloneSource,
                     warp: warpStrokes, freeze: freezeStrokes, sky: sky, regions: regions)
    }

    /// 把一个离散操作记进历史（滑杆拖动结束时调，不是每帧调）
    func pushHistory(_ label: String = "调整") {
        commitHistory(snapshot(label))
    }

    /// 落一条历史（快照由调用方给，便于"拖动开始时拍、拖动结束时落"）
    func commitHistory(_ s: HistoryEntry) {
        // 光标不在末尾时又做了新操作：后面那几步已经不可达，丢掉并在状态栏说明
        //（这是**唯一**会删历史的地方；单纯"点回前面某一步"**不删**，只把它们变灰）
        if historyCursor >= 0 && historyCursor < history.count - 1 {
            _ = historyCursor
            history.removeSubrange((historyCursor + 1)...)
        }
        history.append(s)
        if history.count > 100 { history.removeFirst() }
        historyCursor = history.count - 1
        redoStack.removeAll()
    }

    /// 起笔：**只记标签**，真正的快照在收笔时拍。
    /// ⚠️ 这里原来是"起笔拍快照、收笔入库"，于是笔触记的是**笔前**状态，
    /// 而滑杆走 pushHistory 记的是**笔后**状态 —— 两套语义混在一个数组里，
    /// 结果"撤销一次"会跳过一整步（体检量出来：撤销 1 次后画面既不是上一步也不是当前步，第 142 节）。
    /// 现在统一成"一律记改动后的状态"。
    func beginStrokeHistory(_ label: String) {
        if dragStartSnapshot == nil { dragStartSnapshot = snapshot(label) }
    }

    /// 收笔：把**笔后**状态入库
    func endStrokeHistory() {
        if let s = dragStartSnapshot { commitHistory(snapshot(s.label)) }
        dragStartSnapshot = nil
        // ⚠️ 收笔要把修复**按批量语义重算一遍**：
        // 拖动中走的是**增量**路径（每个新落点只修新增那一个，为了跟手），
        // 而导出（repairStage）与撤销/重做（apply → 缓存清空）走的是**批量**路径
        // （所有落点一次算并集蒙版）。相邻落点下两者结果不同 —— 实测同一状态差 5 级，
        // 也就是"预览看到的"和"导出的"对不上、撤销一下画面还会轻微变（第 142 节）。
        // 收笔时用批量路径定稿，三条路就一致了；拖动中仍然是增量的，手感不变。
        if !spotPoints.isEmpty || !patchPoints.isEmpty || !clonePoints.isEmpty {
            repairCacheKey = ""
            refresh()
        }
    }

    /// 叠加：只把「新方案里明确改过」的项盖上去，其余保持你当前调的。
    /// 替换：整块换掉（像素蛋糕点预设就是这种行为）。
    /// 为什么要有这两种：预设/场景推荐一上来就整块覆盖，用户前面手动微调的全部白调；
    /// 而有些时候又确实想「一键全换」。两种都留着，让人自己选。
    func mergeParams(_ new: Params) -> Params {
        if applyMode == 1 { return new }
        var p = params
        // 中性判定要和 Params 的默认值一致：levelsIn 默认 [0,255]，levelsOut 默认 [0,250]
        if abs(new.levelsIn[0]) > 0.5 || abs(new.levelsIn[1] - 255) > 0.5 { p.levelsIn = new.levelsIn }
        if abs(new.levelsOut[0]) > 0.5 || abs(new.levelsOut[1] - 250) > 0.5 { p.levelsOut = new.levelsOut }
        if abs(new.gamma - 1) > 0.005 { p.gamma = new.gamma }
        if abs(new.brightness) > 0.01 { p.brightness = new.brightness }
        if abs(new.contrast) > 0.01 { p.contrast = new.contrast }
        if abs(new.desat) > 0.01 { p.desat = new.desat }
        if abs(new.cbSh[0]) > 0.01 { p.cbSh = new.cbSh }
        if abs(new.cbMid[0]) > 0.01 { p.cbMid = new.cbMid }
        if abs(new.cbHi[0]) > 0.01 { p.cbHi = new.cbHi }
        return p
    }

    func mergePortrait(_ new: PortraitOptions) -> PortraitOptions {
        if applyMode == 1 { return new }
        var p = portrait
        for (_, kp) in Self.portraitKeys where abs(new[keyPath: kp]) > 0.01 { p[keyPath: kp] = new[keyPath: kp] }
        return p
    }

    /// 滑杆类操作的历史：拖一次要记一条，但不能每一帧都记（拖一下能产生几百个事件）。
    /// 做法是防抖 0.8 秒——手停下来就落一条，标签用参数名，这样历史里能看出「哪一步改了什么」。
    /// 早先只有显式按钮才记历史，拖滑杆完全没有记录，「回退到某一步」自然是残缺的。
    func sliderHistory(_ label: String) {
        pendingHistory?.cancel()
        let item = DispatchWorkItem { [self] in
            if let last = history.last, last.label == label,
               Date().timeIntervalSince(last.date) < 3 { return }   // 连着调同一个参数只记一条
            pushHistory(label)
        }
        pendingHistory = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// 回到某一步：把当前状态压进重做栈，并把这一步之后的都丢掉。
    /// 早先只 apply 不截断，于是「回到第 3 步」之后第 4~10 步还在列表里，再点撤销会跳到莫名其妙的地方。
    func jumpToHistory(_ index: Int) {
        guard index >= 0, index < history.count else { return }
        let target = history[index]
        historyCursor = index
        apply(target)
        let later = history.count - 1 - index
        status = later > 0
            ? "已回到第 \(index + 1) 步：\(target.label)（后面 \(later) 步保留着，点它们可以再过去）"
            : "已回到第 \(index + 1) 步：\(target.label)"
    }

    func apply(_ h: HistoryEntry) {
        // ⚠️ 预设的中间状态必须跟着失效：撤销/重做/跳步之后，界面上的参数已经不由那条预设决定了，
        // 但 appliedPresetKey 还留着 → 再点同一条预设会被当成"取消"，于是 apply(prePresetSnapshot)
        // 把画面拍回陈旧快照（用户视角：撤销一次预设之后，再点那条预设没反应，要点两次）。
        appliedPresetKey = nil
        prePresetSnapshot = nil
        params = h.params; portrait = h.portrait
        skinGrade = h.skinGrade; skinStrength = h.skinStrength
        skinTone = h.skinTone; texturePreserve = h.texturePreserve
        slimWaist = h.slimWaist; wideShoulders = h.wideShoulders
        bgPurify = h.bgPurify; clothesStrength = h.clothes; petStrength = h.pet
        liquifyAmount = h.liquifyAmount
        cropRect = h.crop; cropApplied = h.cropApplied
        rotateDeg = h.rotateDeg; flipH = h.flipH; quarterTurns = h.quarterTurns
        spotPoints = h.spotPoints; clonePoints = h.clonePoints; patchPoints = h.patchPoints; cloneSource = h.cloneSource
        cloneEpochs = h.cloneEpochs
        warpStrokes = h.warp; freezeStrokes = h.freeze
        sky = h.sky
        regions = h.regions
        // 修复有缓存：回到历史状态时必须让缓存失效，否则画面还是旧的那一份
        repairCacheKey = ""; repairCacheImage = nil
        bakedSpotCount = 0; bakedSpotRadius = -1; bakedSpotPoints = []
        refresh()
    }

    /// 撤销 = 回到**上一步**。
    /// ⚠️ 这里原来 apply 的是 `history[historyCursor]`（也就是**当前这一步**）：
    /// 第一次按撤销画面纹丝不动（只是把游标退了一格），每一步都滞后一格，
    /// 而且游标退到 -1 后历史里最早那一步永远回不去（第 142 节，体检抓出来的）。
    func undo() {
        guard historyCursor > 0, historyCursor < history.count else {
            status = history.isEmpty ? "没有可撤销的步骤" : "已经是最初的状态（\(history[0].label)）"
            return
        }
        historyCursor -= 1
        apply(history[historyCursor])
        status = "已撤销到：\(history[historyCursor].label)"
    }

    func redo() {
        let next = historyCursor + 1
        guard next >= 0, next < history.count else { status = "没有可重做的步骤"; return }
        historyCursor = next
        apply(history[next])
        status = "已重做：\(history[next].label)"
    }

    func resetAll() {
        pushHistory("重置全部")
        // 重置也要把**这张图存下来的编辑状态**清掉：否则「重置 → 切到别的图 → 切回来」，
        // 又从 editStates 里把重置前的状态捞回来了（按图存状态之后新出现的一个坑）
        if let u = srcURL { editStates[u.path] = EditState() }
        styleIdx = 0
        params = currentStyle.params
        portrait = PortraitOptions()
        skinGrade = "off"; skinStrength = 0; skinTone = false
        slimWaist = 0; wideShoulders = 0; bgPurify = 0; clothesStrength = 0; petStrength = 0
        liquifyAmount = 0; lipReset()
        panOffset = .zero
        refresh()
    }

    // MARK: 历史面板（含批量结果）
    var historyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("历史记录").font(.headline)
            HStack {
                Button("撤销 ⌘Z") { undo() }.disabled(history.isEmpty)
                Button("重做 ⇧⌘Z") { redo() }.disabled(redoStack.isEmpty)
                Spacer()
                Button("清空") { history = []; redoStack = [] }.font(.system(size: 10))
            }
            if history.isEmpty {
                Text("还没有步骤。拖动滑杆、套预设、跑批量都会记一条。").font(.caption2).foregroundColor(.secondary)
            }
            ForEach(Array(history.enumerated().reversed()), id: \.offset) { i, h in
                Button {
                    jumpToHistory(i)
                } label: {
                    HStack {
                        Text("\(i + 1). \(h.label)").font(.system(size: 11)).lineLimit(1)
                        if i == historyCursor { Text("← 当前").font(.system(size: 9)).foregroundColor(.accentColor) }
                        Spacer()
                        Text(h.date.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                    .opacity(i > historyCursor ? 0.35 : 1)
                }.buttonStyle(.plain)
            }
            Divider()
            Text("虚拟副本（同一张原片的多版本）").font(.system(size: 11, weight: .medium))
            HStack {
                TextField("版本名", text: $versionName).textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("存为版本") { saveVersion() }.font(.system(size: 11))
            }
            if versions.isEmpty {
                Text("还没有版本。改完一套参数点「存为版本」，就能在原片不变的前提下多版对比。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            ForEach(versions) { v in
                HStack {
                    Button(v.name) { switchToVersion(v) }.font(.system(size: 11))
                    Spacer()
                    Text(v.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9)).foregroundColor(.secondary)
                    Button { deleteVersion(v) } label: { Image(systemName: "trash").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            Divider()
            Text("批量结果").font(.system(size: 11, weight: .medium))
            if records.isEmpty { Text("还没有跑过批量").font(.caption2).foregroundColor(.secondary) }
            ForEach(records) { r in
                HStack {
                    Text(r.file).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f→%.2f", r.errBefore, r.errAfter))
                        .font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
                    if r.alreadyClose { Text("未套用").font(.system(size: 9)).foregroundColor(.orange) }
                }
            }
        }
    }
}
