// Tools.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    var hiddenTools: Set<String> {
        Set(hiddenToolsRaw.split(separator: ",").map(String.init))
    }

    /// 当前生效的「抢画布拖动」的工具。同一时刻只能有一个：
    /// 抓手 / 污点修复 / 修补 / 仿制图章 / 裁剪 / 液化笔刷，都靠拖动操作画布，
    /// 同时开两个只会打架（早先是每个工具各写一遍「关掉别人」，结果漏来漏去：
    /// 点污点不会关掉修补，点裁剪不会关掉仿制图章）。
    /// 而「看效果 / 单图对比 / 祛边 / 参考线 / 预设栏」是**显示开关**，可以同时开。
    var activeCanvasTool: String {
        if handTool { return "hand" }
        if spotActive { return "spot" }
        if patchActive { return "patch" }
        if cloneActive { return "clone" }
        if cropMode { return "crop" }
        if brushActive { return "brush" }
        return ""
    }

    /// 画布拖动统一入口（**AppKit 事件捕获视图**与监视器两条路都调它）。
    /// local = 左上原点的画布局部坐标；viewSize = 该坐标对应的画布尺寸。
    /// 计数器（evDown/evDrag/evUp）会显示在状态栏里，用来判断事件到底有没有到。
    func handleCanvasDrag(phase: Int, local: CGPoint, viewSize: CGSize,
                          modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        evCount(phase)
        // 每次交互开始就把"正在落笔"复位。**这是第 105 节找到的"一按下就满屏旧圈"的根因**：
        // 这个开关原来只在 default（phase 2 抬起）复位，而几乎没有位移的按下+抬起会被判成
        // tap（phase 3）—— 于是只要有一次"按下时手抖 >6px 走了拖动分支、抬起又被判成 tap"，
        // 开关就永远停在 true，此后**每次按下都把历史所有落点画出来**。
        // ② ⌥ + 点击/拖动 = **随时重新取样**（仿制图章的标准操作）。
        // 原来取样点只在"第一次点击"时落一次，之后没法换 —— 用户报的正是这个。
        if phase == 0 {
            strokeMarkLive = false
            // **这一笔的起点**：拖动中要画的是"当前这一笔"，而这三个数组都是历史累计的
            // （用户报的"拖动会出现之前操作的一系列圈"就是画了整个历史，见第 106 节）。
            strokeStartSpot = spotPoints.count
            strokeStartClone = clonePoints.count
            strokeStartPatch = patchPoints.count
            strokeStartWarp = warpStrokes.count
        }
        guard let img = srcImage else { return }
        let sizes = paneSizesForMonitor(local: local, imageSize: img.size)
        // ② ⌥ + 点击/拖动 = **随时重新取样**（仿制图章的标准操作）。
        // 原来取样点只在"第一次点击"时落一次，之后没法换 —— 用户报的正是这个。
        let optDown = modifiers.contains(.option)
        if cloneActive, optDown, let pt0 = imagePoint(local, viewSize: sizes, imageSize: img.size) {
            if phase == 0 {
                optSampling = true
                cloneSource = pt0
                cloneEpochs.append((at: clonePoints.count, source: pt0))
                status = String(format: "仿制图章：已重新取样 (%.2f, %.2f)（松开 ⌥ 就能从新位置复制）", pt0.x, pt0.y)
                refresh()
            }
            return          // 取样这一下不落点、不成笔
        }
        switch phase {
        case 0:
            panStartLocal = local
            if handTool { handDragging = true; panStart = panOffset }
            // 非拖动类液化模式（膨胀/收缩/褶皱/平滑）在按下就生效。
            // 之前只在“位移 < 4px 算点按”那条路处理，而真实点击常带 3~8px 抖动，
            // 于是被判成拖动，而拖动分支只处理向前变形/左推 -> 什么都不发生。
            // 现在按下即应用一笔：点一下、拖一下都是“在按下的位置来一下”，可预测且不叠加。
            if regionMode, let pt0 = imagePoint(local, viewSize: sizes, imageSize: img.size) {
                regionStart = pt0
                regions.append(RegionAdjust(shape: regionShape,
                                    rect: CGRect(x: pt0.x, y: pt0.y, width: 0.02, height: 0.02),
                                    feather: regionFeather))
                selectedRegion = regions.last?.id
                beginStrokeHistory("范围选择")
            }
            if maskBrushMode, let pt0 = imagePoint(local, viewSize: sizes, imageSize: img.size) {
                beginStrokeHistory(maskBrushAdd ? "蒙版·涂白" : "蒙版·涂黑")
                appendMaskDot(pt0)
            }
            if realBrushActive,
               liquifyMode == .expand || liquifyMode == .pinch || liquifyMode == .pucker || liquifyMode == .smooth,
               let p0 = imagePoint(local, viewSize: sizes, imageSize: img.size) {
                pushHistory("液化·" + liquifyMode.rawValue)
                // 程度收敛：膨胀/收缩是**径向缩放**，同样数值看起来比推动强得多
                //（用户反馈"生效了但程度比较严重"）。乘 0.4 作为这几个模式的增益；
                // 需要更猛时把「画笔压力」往上调即可。
                // ③ 再降一档：0.4 → 0.22（用户反馈"程度仍然比较重"）。0.22 × 默认压力 30 ≈ 0.066
                let gain = 0.22
                warpStrokes.append(WarpStroke(mode: liquifyMode, center: p0, radius: brushRadius,
                                              strength: brushPressure / 100 * gain, density: brushDensity / 100))
                dragStrokeIndex = warpStrokes.count - 1
                liquifyLastPoint = p0
                strokeMarkLive = true
                status = "液化：" + liquifyMode.rawValue + " 已作用（同一次拖动只算一笔）"
                refresh()
            }
            if realBrushActive, liquifyMode == .push || liquifyMode == .pushLeft {
                let p0 = imagePoint(local, viewSize: sizes, imageSize: img.size)
                lastStrokePoint = p0
                dragStartPoint = p0 ?? CGPoint(x: 0.5, y: 0.5)
                dragStrokeIndex = nil          // 新的一次拖动 = 新的一笔
                beginStrokeHistory("液化·" + liquifyMode.rawValue)
            }
            if cropMode {
                guard let pt = imagePoint(local, viewSize: sizes, imageSize: img.size) else { return }
                beginStrokeHistory("裁剪框")
                dragStart = pt
            }
            if spotActive || patchActive || cloneActive, let pt = imagePoint(local, viewSize: sizes, imageSize: img.size) {
                lastStrokePoint = pt
                beginStrokeHistory(spotActive ? "污点修复" : (patchActive ? "修补" : "仿制图章"))
            }
        case 3:
            // 点按（原来走 SwiftUI 的 SpatialTapGesture；现在由 AppKit 捕获层上报，见 mouseUp）
            // ⚠️ ⌥ 取样那一下，捕获层在 up 之后还会补报一个 tap（phase 3）——
            // 上一版没拦它，于是"取样"还是落了一个点（日志里落点数从 5 变 6 就是这个）。
            if cloneActive, modifiers.contains(.option) { return }
            guard let pt = imagePoint(local, viewSize: sizes, imageSize: img.size) else { return }
            if aiFixArmed {
                // §329：AI 点修（路径 B：点一下就修）。按钮只置位，这里消费并复位 ✓。
                aiFixArmed = false
                if let imgAI = workImage(), let d = aiFixDecision(at: pt, image: imgAI) {
                    applyPortraitItem(d.item, d.strength)
                    pushHistory("AI 点修")
                    status = "AI 点修：" + d.label
                } else {
                    status = "AI 点修：这里没识别出可修的部位（点脸内试试）"
                }
                refresh()
            } else if spotActive {
                // §305：智能消除的 SAM 版接线 —— 点一下让 SAM 圈出整个目标，再把掩膜转成一组点，
                // 交给**现有点笔画修复**（零新修复代码；历史与撤销都自动生效）。
                // 默认关：先用 CR_HEAL_SAM=1 量收益（改动是否落在 SAM 掩膜内、与单点的覆盖差），
                // 量出正向收益后才把默认翻过来（纪律：量得出才设为默认）。
                var didSAM = false
                // §315：默认**开**（证据：coretest 第 60 节实测 SAM 圈选在同掩膜区内的覆盖为单点的 7.8 到 9.0 倍，两个样本方向一致，§313/§314）。
                // 想要旧行为可设 CR_HEAL_SAM=0；SAM 未装/圈不出/掩膜取不到点仍自动退回单点分支 ✓。
                if samPreferred(), let img2 = workImage() {
                    let e2 = img2.extent
                    if let res = refineMaskWithSAM(img2, hint: healHintMask(at: pt, radius: CGFloat(spotRadius), in: e2)) {
                        let pts = healSamplePoints(in: res.mask, extent: e2)
                        if !pts.isEmpty {
                            pushHistory("智能消除")
                            spotPoints.append(contentsOf: pts)
                            status = String(format: "智能消除（SAM）：圈出目标并用 %d 个点覆盖", pts.count)
                            didSAM = true
                            refresh()
                        }
                    }
                }
                if !didSAM {
                    pushHistory("污点修复"); spotPoints.append(pt)
                    status = String(format: "污点修复：已点第 %d 处（拖动能连续涂）", spotPoints.count)
                    refresh()
                }
            } else if patchActive {
                pushHistory("修补"); patchPoints.append(pt)
                status = "修补：已涂 " + String(patchPoints.count) + " 处"
                refresh()
            } else if cloneActive {
                pushHistory("仿制图章")
                if cloneSource == nil {
                    cloneSource = pt
                    cloneEpochs.append((at: clonePoints.count, source: pt))
                    status = "仿制图章：取样点已落，再点别处就复制过去（⌥+点击 换取样点）"
                }
                else { clonePoints.append(pt) }
                refresh()
            } else if brushActive {
                strokeMarkLive = true
                liquifyLastPoint = pt
                if liquifyMode == .push || liquifyMode == .pushLeft {
                    status = "向前变形要按住拖动（跟着鼠标方向推）；点一下没有方向，不生效"
                } else {
                    pushHistory("液化·" + liquifyMode.rawValue)
                    warpStrokes.append(WarpStroke(mode: liquifyMode, center: pt, radius: brushRadius,
                                                  strength: brushPressure / 100, density: brushDensity / 100))
                    status = "液化：" + liquifyMode.rawValue + " 已点第 " + String(warpStrokes.count) + " 笔"
                    refresh()
                }
            }
            // 点按也走同一条"结束"语义：不留"正在进行中"，否则松手后仍画全部落点
            if !brushActive || liquifyMode == .push || liquifyMode == .pushLeft { strokeMarkLive = false }
        case 1:
            if handTool {
                let base = panStart ?? panOffset
                panOffset = CGSize(width: base.width + (local.x - (panStartLocal?.x ?? local.x)),
                                   height: base.height - (local.y - (panStartLocal?.y ?? local.y)))
                return
            }
            guard let pt = imagePoint(local, viewSize: sizes, imageSize: img.size) else { return }
            if regionMode, let s0 = regionStart, let idx = regions.indices.last {
                regions[idx].rect = CGRect(x: min(s0.x, pt.x), y: min(s0.y, pt.y),
                                 width: abs(pt.x - s0.x), height: abs(pt.y - s0.y))
                regions[idx].shape = regionShape
                selectedRegion = regions[idx].id
                status = "范围已画好：去右侧「工具属性」调这一块的增量"
                refresh()
                return
            }
            if maskBrushMode {
                appendMaskDot(pt)
                refresh()
                return
            }
            if cropMode, let s0 = dragStart {
                cropRect = CGRect(x: min(s0.x, pt.x), y: min(s0.y, pt.y),
                                  width: abs(pt.x - s0.x), height: abs(pt.y - s0.y))
                refresh()
                return
            }
            if spotActive || patchActive || cloneActive {
                let prev = lastStrokePoint ?? pt
                if hypot(pt.x - prev.x, pt.y - prev.y) >= spacing(spotActive ? spotRadius : cloneRadius) {
                    if spotActive { spotPoints.append(pt) }
                    else if patchActive { patchPoints.append(pt) }
                    else {
                        if cloneSource == nil { cloneSource = pt } else { clonePoints.append(pt) }
                    }
                    lastStrokePoint = pt
                    strokeMarkLive = true
                    refresh()
                }
                return
            }
            if realBrushActive, liquifyMode == .push || liquifyMode == .pushLeft {
                let prev = lastStrokePoint ?? pt
                // ③ 手感：原来把"鼠标这一小段位移"原样当成一次推挤的强度，快到 1.0 就非常夸张
                //（实测用户反馈"拖动程度太严重，几乎无法使用"）。三处一起收：
                //   · 位移按 30% 计；
                //   · 单笔位移封顶 1.2% 画面（快速划一下也不会一下推飞）；
                //   · 落笔间距放大到 0.6×半径（同样距离内笔数更少）。
                // ② **一次拖动 = 一笔**：拖动过程中只就地更新这一笔（起点→当前点），
                // 而不是"每移动一小段就追加一笔"。追加的那种写法会让同一次拖动里
                // 同一块区域被反复推挤 → 越拖越夸张（用户报的"累积之前所有的操作"就是这个）。
                if let idx = dragStrokeIndex, idx < warpStrokes.count,
                   warpStrokes[idx].mode == liquifyMode {
                    var dx = (pt.x - dragStartPoint.x) * 0.30, dy = (pt.y - dragStartPoint.y) * 0.30
                    let mag = hypot(dx, dy)
                    if mag > 0.05 { dx *= 0.05 / mag; dy *= 0.05 / mag }
                    warpStrokes[idx].center = pt
                    warpStrokes[idx].delta = CGPoint(x: dx, y: dy)
                } else {
                    var dx = (pt.x - prev.x) * 0.15, dy = (pt.y - prev.y) * 0.15
                    let mag = hypot(dx, dy)
                    if mag > 0.025 { dx *= 0.025 / mag; dy *= 0.025 / mag }
                    warpStrokes.append(WarpStroke(mode: liquifyMode, center: pt, radius: brushRadius,
                                                  delta: CGPoint(x: dx, y: dy),
                                                  strength: brushPressure / 100, density: brushDensity / 100))
                    dragStrokeIndex = warpStrokes.count - 1
                }
                lastStrokePoint = pt
                strokeMarkLive = true
                refresh()
            }
        default:
            handDragging = false; panStart = nil; lastStrokePoint = nil; strokeMarkLive = false
            if optSampling { optSampling = false; return }     // 取样那一下的抬起：不当作落点
            if regionMode, let idx = regions.indices.last, regions[idx].rect.width < 0.01 {
                regions.remove(at: idx)      // 只点了一下没拖出东西，不留空范围
            }
            regionStart = nil
            if cropMode { cropApplied = false }
            if handTool { status = "抓手：已平移" }
        }
    }

    /// 蒙版画笔落一个点（涂白/涂黑），带最小间距避免重点叠在一处。
    func appendMaskDot(_ pt: CGPoint) {
        guard let sid = selectedRegion ?? regions.last?.id,
              let idx = regions.firstIndex(where: { $0.id == sid }) else { return }
        let sp = spacing(maskBrushRadius)
        let dot = MaskStroke(x: Double(pt.x), y: Double(pt.y), r: maskBrushRadius)
        if maskBrushAdd {
            if let l = regions[idx].paintAdd.last, abs(l.x - dot.x) < sp, abs(l.y - dot.y) < sp { return }
            regions[idx].paintAdd.append(dot)
        } else {
            if let l = regions[idx].paintSub.last, abs(l.x - dot.x) < sp, abs(l.y - dot.y) < sp { return }
            regions[idx].paintSub.append(dot)
        }
    }

    /// 事件计数（显示在状态栏：用来判断"哪一层收到了什么"）
    func evCount(_ phase: Int) {
        switch phase { case 0: evDown += 1; case 1: evDrag += 1; default: evUp += 1 }
    }

    /// 鼠标监视器驱动的手势处理：**抓手平移 / 液化推动**（这两类都是"拖动型"，用户报过它们在大图上无效）。
    ///
    /// 为什么单独一条路：SwiftUI 在面板上的 `DragGesture` 在用户机器上不触发（我用合成鼠标事件复现：
    /// 事件到了窗口、工具状态也对，但回调一次没跑）。点按类工具走 `SpatialTapGesture`，所以那些是好的——
    /// 这与用户"点按能用、拖动不能用"的描述完全吻合。
    func handleMonitorDrag() {
        if ProcessInfo.processInfo.environment["CR_DIAG"] != nil {
            print("DIAG handleMonitorDrag phase=" + String(CanvasInput.shared.dragPhase))
            fflush(stdout)
        }
        let c = CanvasInput.shared
        guard c.canvasFrame.width > 10, let img = srcImage else { return }
        // 窗口坐标 → 画布局部坐标
        let local = CGPoint(x: c.dragPoint.x - c.canvasFrame.minX,
                            y: c.canvasFrame.maxY - c.dragPoint.y)   // AppKit y 自下而上 → SwiftUI 自上而下
        let sizes = paneSizesForMonitor(local: local, imageSize: img.size)
        switch c.dragPhase {
        case 0:
            panStartLocal = local
            if handTool { handDragging = true; panStart = panOffset }
            if brushActive, liquifyMode == .push || liquifyMode == .pushLeft {
                lastStrokePoint = imagePoint(local, viewSize: sizes, imageSize: img.size)
                beginStrokeHistory("液化·" + liquifyMode.rawValue)
            }
        case 1:
            // 抓手：按下点起算的位移（不是每次都累加总量，避免"越拖越快"）
            if handTool {
                let dx = Double(c.dragPoint.x - c.dragStart.x), dy = Double(c.dragStart.y - c.dragPoint.y)
                let base = panStart ?? panOffset
                panOffset = CGSize(width: base.width + dx, height: base.height + dy)
                return
            }
            // 液化：跟着走，按最小间距落笔
            if brushActive, liquifyMode == .push || liquifyMode == .pushLeft,
               let pt = imagePoint(local, viewSize: sizes, imageSize: img.size) {
                let prev = lastStrokePoint ?? pt
                if hypot(pt.x - prev.x, pt.y - prev.y) >= spacing(brushRadius) {
                    warpStrokes.append(WarpStroke(mode: liquifyMode, center: pt, radius: brushRadius,
                                                  delta: CGPoint(x: pt.x - prev.x, y: pt.y - prev.y),
                                                  strength: brushPressure / 100, density: brushDensity / 100))
                    lastStrokePoint = pt
                    strokeMarkLive = true
                    refresh()
                }
            }
        default:
            handDragging = false; panStart = nil; lastStrokePoint = nil; strokeMarkLive = false
            if handTool { status = "抓手：已平移（滚轮缩放，⌥拖动缩放）" }
        }
    }

    /// 监视器路径下"指针落在哪一栏"的尺寸（复用 paneFrames；找不到就退回整块画布）
    func paneSizesForMonitor(local: CGPoint, imageSize: CGSize) -> CGSize {
        if let hit = paneFrames.first(where: { $0.value.contains(local) }) {
            return CGSize(width: hit.value.width, height: max(1, hit.value.height - 16))
        }
        return CGSize(width: max(1, canvasInput.canvasFrame.width),
                      height: max(1, canvasInput.canvasFrame.height))
    }

    @ViewBuilder
    func maskDot(_ dot: MaskStroke, box: CGRect, white: Bool) -> some View {
        let d = max(4.0, dot.r / 100 * Double(box.width) * 2)
        Circle()
            .fill(white ? Color.white.opacity(0.6) : Color.black.opacity(0.6))
            .frame(width: d, height: d)
            .position(x: box.minX + dot.x * box.width, y: box.minY + (1 - dot.y) * box.height)
    }

    func maskPaintOverlay(_ r: RegionAdjust, box: CGRect) -> some View {
        ZStack {
            ForEach(Array(r.paintAdd.enumerated()), id: \.offset) { _, dot in
                maskDot(dot, box: box, white: true)
            }
            ForEach(Array(r.paintSub.enumerated()), id: \.offset) { _, dot in
                maskDot(dot, box: box, white: false)
            }
        }
    }

    @ViewBuilder
    func markers(_ pts: [CGPoint], from: Int = 0, box: CGRect, color: Color, dia: CGFloat) -> some View {
        // 拖动中 = **只画当前这一笔**（pts 是历史累计数组，从 from 起才是这一笔；
        // 上一版画的是整个数组 = 用户看到的"之前操作的一系列圈"）；
        // 停下 = 只画最后一个（用户原话："只看最新一次的操作圈"）。
        // 「显示全部落点」开关打开时才把历史全画出来（排查用）。
        if strokeMarkLive, from < pts.count {
            ForEach(Array(pts[from...].enumerated()), id: \.offset) { _, p in
                strokeDot(p, box: box, color: color, dia: dia)
            }
        } else if showStrokeMarks {
            ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                strokeDot(p, box: box, color: color, dia: dia)
            }
        } else if let last = pts.last {
            strokeDot(last, box: box, color: color, dia: dia)
        }
    }

    /// 只把「抢画布拖动」的开关清干净，不碰别的（给需要自己控制开关的入口用）
    func setCanvasToolDirect() {
        handTool = false; spotActive = false; patchActive = false
        cloneActive = false; cropMode = false; brushActive = false
        // 注意：regionMode / maskBrushMode 由调用方自己设
    }

    /// 切换互斥工具：先全部关掉，再开目标那个；点已经在用的那个 = 关掉。
    func setCanvasTool(_ tool: String) {
        if diagLog { FileHandle.standardError.write("DIAG 工具切换 → \(tool)\n".data(using: .utf8)!) }
        let was = activeCanvasTool
        handTool = false; spotActive = false; patchActive = false
        cloneActive = false; cropMode = false; brushActive = false
        regionMode = false                                 // 笔刷类工具与范围选择互斥
        maskBrushMode = false                              // 蒙版画笔同理
        if was == tool {                                  // 再点一次 = 关掉
            status = "已切回普通模式（不抢拖动）"
            refresh()
            return
        }
        switch tool {
        case "hand":
            handTool = true
            status = "抓手已开：拖动平移画布（滚轮/捏合缩放）"
        case "spot":
            spotActive = true
            status = "污点修复笔刷已开：在图上拖着涂（[ ] 调大小）"
        case "patch":
            // **绝不清空落点**：效果是编辑结果，关工具/切工具都不该把它抹掉（用户报的那条）。
            patchActive = true
            status = "修补已开：在图上涂，用旁边的纹理补上"
        case "clone":
            cloneActive = true      // 同样不清空；取样点也留着（换工具再回来还能接着盖）
            status = "仿制图章已开：先点一下落「取样点」，再去别处涂；**⌥+点击** 可随时换取样点"
        case "crop":
            cropMode = true
            status = "裁剪框已开：在图上拖一个矩形（可先选下方比例）"
        case "brush":
            brushActive = true
            status = "液化笔刷已开：在图上拖着涂（[ ] 调大小）"
        default:
            break
        }
        refresh()
    }

    func toggleTool(_ id: String) {
        var h = hiddenTools
        if h.contains(id) { h.remove(id) } else { h.insert(id) }
        hiddenToolsRaw = h.sorted().joined(separator: ",")
    }

    /// §329：把 AI 点修的决策套到对应的人像参数上。
    /// 为什么只能逐个 case：PortraitOptions 是结构体，不能按名字动态赋值 ✗（字段名已核对 ✓）。
    func applyPortraitItem(_ item: String, _ strength: Double) {
        switch item {
        case "eyes":        portrait.eyes = strength
        case "lipColor":    portrait.lipColor = strength
        case "spotBlemish": portrait.spotBlemish = strength
        case "teeth":       portrait.teeth = strength
        default:            break
        }
    }

    var toolItems: [(id: String, icon: String, title: String, action: () -> Void)] {
        [
            ("fit", "arrow.up.left.and.arrow.down.right", "合适", { fitAll() }),
            ("hand", handTool ? "hand.raised.fill" : "hand.raised", handTool ? "抓手·开" : "抓手", {
                setCanvasTool("hand")
            }),
            ("effect", showEffect ? "eye" : "eye.slash", showEffect ? "看效果" : "看原图", {
                showEffect.toggle(); refresh()
            }),
            ("compare", singleView ? "rectangle.split.2x1" : "rectangle", singleView ? "对比" : "单图", {
                singleView.toggle()
                if !singleView { splitCompare = false }   // 回到并排就把滑动对比关掉（两者不能同时生效）
            }),
            ("edge", "rectangle.dashed", autoCropOn ? "祛边·开" : "祛边", {
                autoCropOn.toggle()
                status = autoCropOn ? "祛边已开：自动去掉图中的黑/白边（核心实测：1200×1740 → 1081×1618）" : "祛边已关"
                refresh()
            }),
            ("guides", "ruler", showGuides ? "参考线·开" : "参考线", {
                showGuides.toggle()
                status = showGuides ? "参考线已开（三分线 + 中心线）" : "参考线已关"
            }),
            ("liquify", "waveform.path", liquifyWorkspace ? "液化·工作区" : "液化", {
                // 点它直接进**液化工作区**（整屏，参照 PS）：这是这一轮改的核心——
                // 之前液化是"塞在侧栏里的一个刷子"，工具多、参数散，用起来就是不好用。
                if liquifyWorkspace { confirmLiquify() } else { openLiquifyWorkspace() }
            }),
            ("maskbrush", "paintbrush.pointed", maskBrushMode ? "蒙版·开" : "蒙版画笔", {
                guard selectedRegion != nil || !regions.isEmpty else {
                    status = "先画一个范围（范围选择），再在它的蒙版上涂"
                    return
                }
                if selectedRegion == nil { selectedRegion = regions.last?.id }
                maskBrushMode.toggle(); regionMode = false
                setCanvasToolDirect()
                status = maskBrushMode
                    ? "蒙版画笔已开：在图上涂 —— " + (maskBrushAdd ? "涂白（这块生效）" : "涂黑（这块不生效）") + "，右侧可切换加减"
                    : "已关闭蒙版画笔"
            }),
            ("region", "rectangle.dashed", regionMode ? "范围·开" : "范围选择", {
                regionMode.toggle()
                if regionMode { setCanvasTool("") ; regionMode = true }   // 与笔刷类互斥
                status = regionMode ? "范围选择：在图上拖出一块（矩形/椭圆/圆形），然后在右侧工具属性里调这一块" : "已关闭范围选择（范围内的调整保留着）"
            }),
            ("spot", "bandage", spotActive ? "污点·开" : "污点修复", { setCanvasTool("spot") }),
            ("patch", "arrow.left.and.right.righttriangle.left.righttriangle.right", patchActive ? "修补·开" : "修补", {
                setCanvasTool("patch")
            }),
            ("clone", "square.on.square", cloneActive ? "仿制·开" : "仿制图章", { setCanvasTool("clone") }),
            // ④ 裁剪**只有一处入口**：点它就切到「裁剪旋转」面板，并在画布上进入裁剪框模式。
            // 以前工具条一个入口、右侧面板又一个入口，两边的状态没打通，用起来像"有一半是坏的"。
            ("crop", "crop.rotate", cropMode ? "裁剪·开" : "裁剪", {
                panel = 7
                setCanvasTool("crop")
                status = "裁剪：在图上拖出矩形 → 右侧「工具属性」点「应用裁剪」；比例条在画布左上角"
            }),
            // §298：这两个按钮以前是「未做」占位 ✗，只弹一句「还没做」——而内核其实早就有可用链路。
            // 现在改成**能用的快捷入口**（诚实标注当前能力边界）：
            // · 智能消除 = 污点修复的点笔画通路（落点 → 修复 → 入历史 → 可撤销）✓；
            //   SAM 自动圈选版是第二步（账本 §297），落地前它与「污点修复」走同一条链 ✓。
            // · AI 点修 = 打开人像面板（按部位的面板），把祛斑祛痘/祛痣/祛黑眼圈等拖一下即可局部修 ✓。
            ("heal", "eraser", spotActive ? "智能消除·开" : "智能消除", {
                setCanvasTool("spot")
                status = "智能消除：在图上点/拖要消掉的目标（走已有修复链路，可撤销）；装了 SAM 后会有自动圈选版"
            }),
            ("aifix", "sparkles", aiFixArmed ? "AI点修·待点" : "AI点修", {
                module = "精修"; panel = 3
                aiFixArmed = true
                status = "AI 点修：请在脸上点一下——会按该部位给一个温和的修，点完自动退出"
            }),
            ("reset", "arrow.uturn.backward", "重置", { resetAll() })
        ]
    }

    var leftTools: some View {
        HStack(spacing: 10) {
            Menu {
                Button("适应窗口") { zoom = 0; refresh() }
                Button("50%") { zoom = 50; refresh() }
                Button("100%") { zoom = 100; refresh() }
                Button("200%") { zoom = 200; refresh() }
            } label: {
                Text(zoom == 0 ? "适应" : "\(Int(zoom))%")
                    .font(.system(size: 10)).frame(width: 52)
            }.menuStyle(.borderlessButton)
            Divider().frame(width: 28)
            ForEach(toolItems.filter { !hiddenTools.contains($0.id) }, id: \.id) { t in
                toolBtn(t.icon, t.title, t.action)
            }
            Divider().frame(width: 28)
            toolBtn("sidebar.left", showPresets ? "预设·开" : "预设") {
                showPresets.toggle()
                if showPresets { showHistoryColumn = false }   // 两条列共用同一个位置，互斥
            }
            toolBtn("clock.arrow.circlepath", showHistoryColumn ? "历史·开" : "历史") {
                showHistoryColumn.toggle()
                if showHistoryColumn { showPresets = false }
            }
            // 应用方式（叠加/替换）放在**上方工具条**，不再塞进预设列里：
            // 它是"套预设时怎么合并"的策略，属于全局行为，跟预设列表本身不是一回事。
            Divider().frame(width: 28)
            VStack(spacing: 3) {
                Picker("", selection: $applyMode) {
                    Text("叠加").tag(0); Text("替换").tag(1)
                }.pickerStyle(.segmented).frame(width: 96).labelsHidden()
                Text(applyMode == 1 ? "替换" : "叠加").font(.system(size: 9)).foregroundColor(.secondary)
            }
            Divider().frame(width: 28)
            Button { showToolPicker.toggle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                    Text("自定义").font(.system(size: 9))
                }.frame(width: 48)
            }.buttonStyle(.plain).padding(.vertical, 4)
                .popover(isPresented: $showToolPicker, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("自定义工具栏").font(.headline)
                        Text("勾选要显示的工具（顺序固定照像素蛋糕实机）。").font(.caption2).foregroundColor(.secondary)
                        ForEach(toolItems, id: \.id) { t in
                            Toggle(t.title, isOn: Binding(
                                get: { !hiddenTools.contains(t.id) },
                                set: { _ in toggleTool(t.id) })).font(.system(size: 11))
                        }
                        Divider()
                        HStack {
                            Button("全开") { hiddenToolsRaw = "" }
                            Button("只留常用") { hiddenToolsRaw = "heal,aifix,clone,crop" }
                        }.font(.system(size: 11))
                    }.padding(14).frame(width: 260)
                }
            Text("\(faceCount) 张脸").font(.system(size: 9)).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // 高度必须写死：HStack 里的 Divider 在纵向是「可伸缩」的，于是整行变成贪心高度，
        // 在 VStack 里跟下面的 HSplitView 抢空间 —— 结果工具条压在画布上（自截图一眼看出来的）。
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    func toolBtn(_ icon: String, _ tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                Text(tip).font(.system(size: 9))
            }.frame(width: 52)
        }.buttonStyle(.plain).padding(.vertical, 4)
    }
}
