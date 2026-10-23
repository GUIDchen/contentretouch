// PanelsParam.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 液化工具的图标（照 PS 的语义挑 SF Symbol）
    func liquifyIcon(_ m: LiquifyMode) -> String {
        switch m {
        case .push: return "hand.point.up.left"
        case .pushLeft: return "arrow.left"
        case .expand: return "arrow.up.left.and.arrow.down.right"
        case .pinch: return "arrow.down.right.and.arrow.up.left"
        case .pucker: return "arrow.down.forward.and.arrow.up.backward"
        case .twirl: return "arrow.triangle.2.circlepath"
        case .smooth: return "drop"
        case .freeze: return "snowflake"
        case .thaw: return "sun.max"
        case .reconstruct: return "arrow.uturn.backward"
        }
    }

    /// 液化工作区右侧的属性行（标签 + 值 + 滑杆）
    func WSRow<Content: View>(label: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Text(value).font(.system(size: 10, design: .monospaced))
            }
            content()
        }
    }

    var hintForLiquify: String {
        switch liquifyMode {
        case .push, .pushLeft: return "按住拖动：内容跟着鼠标方向推"
        case .expand, .pinch, .pucker, .twirl, .smooth: return "点一下或拖动都可以"
        case .freeze: return "涂过的地方被冻结（后续形变不动它）"
        case .thaw: return "涂过的地方解冻"
        case .reconstruct: return "涂过的地方把之前的形变退掉"
        }
    }

    /// 当前画布工具的属性（半径 / 羽化 / 程度 …）。放在直方图正下方，切工具就换内容。
    @ViewBuilder var toolPropertiesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(toolTitle).font(.system(size: 11, weight: .medium))
                Spacer()
                Toggle("显示全部落点", isOn: $showStrokeMarks).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 9))
            }
            if spotActive || patchActive || cloneActive {
                miniSlider("范围（占长边 %）", $spotRadius, 0.2...8, 0.1)
                miniSlider("羽化", spotActive ? $spotFeather : $cloneFeather, 0...100, 5)
                miniSlider(spotActive ? "程度" : "不透明度",
                           spotActive ? $spotStrength : $cloneOpacity, 0...100, 5)
                Text(spotActive
                     ? "点一下修一处；拖动能连续修。范围与羽化越小越精修。"
                     : "仿制先点一下设取样点，之后每点一下落一个落点（绿色圈是取样点）。")
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            } else if brushActive {
                miniSlider("画笔大小", $brushRadius, 0.2...12, 0.1)
                miniSlider("画笔密度（羽化）", $brushDensity, 0...100, 5)
                miniSlider("画笔压力（程度）", $brushPressure, 1...100, 1)
                Picker("方式", selection: $liquifyMode) {
                    ForEach(LiquifyMode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) }
                }.pickerStyle(.menu).font(.system(size: 10))
                Text(liquifyMode == .push || liquifyMode == .pushLeft
                     ? "向前变形/左推：按住**拖动**，跟着鼠标方向推。"
                     : "点一下或拖动都能用。")
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                Button("打开液化工作区（整屏，参照 PS）") { openLiquifyWorkspace() }
                    .font(.system(size: 10))
            } else if regionMode || !regions.isEmpty {
                Picker("形状", selection: $regionShape) {
                    Text("矩形").tag(0); Text("椭圆").tag(1); Text("圆形").tag(2)
                }.pickerStyle(.segmented).font(.system(size: 10))
                // 羽化改成作用在**当前选中的那个范围**上：原来它只在新建范围时读一次，
                // 之后再拖这个滑杆对已有的范围没有任何影响（"拖了没用"）。
                miniSlider("边缘羽化", Binding(
                    get: { regionFeather },
                    set: { v in
                        regionFeather = v
                        if let sid = selectedRegion, let i = regions.firstIndex(where: { $0.id == sid }) {
                            regions[i].feather = v
                            refresh()
                        }
                    }), 0...100, 5)
                ForEach(regions) { r in
                    HStack(spacing: 6) {
                        Button {
                            selectedRegion = r.id
                            regionMode = true
                        } label: {
                            Image(systemName: selectedRegion == r.id ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 10))
                        }.buttonStyle(.plain)
                        Text(String(format: "范围 %d %@", (regions.firstIndex(where: { $0.id == r.id }) ?? 0) + 1,
                                    r.isEmpty ? "（未调）" : "（已调）"))
                            .font(.system(size: 10))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { r.enabled },
                            set: { v in
                                if let i = regions.firstIndex(where: { $0.id == r.id }) { regions[i].enabled = v }
                                refresh()
                            })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        Button {
                            regions.removeAll { $0.id == r.id }
                            refresh()
                        } label: { Image(systemName: "trash").font(.system(size: 9)) }.buttonStyle(.plain)
                    }
                }
                if let sid = selectedRegion, let i = regions.firstIndex(where: { $0.id == sid }) {
                    Divider()
                    Text("该范围内调整（增量，跟随全局）").font(.system(size: 9)).foregroundColor(.secondary)
                    miniSlider("亮度 +", Binding(get: { regions[i].dBrightness },
                                                set: { regions[i].dBrightness = $0; refresh() }), -50...50, 1)
                    miniSlider("对比 +", Binding(get: { regions[i].dContrast },
                                                set: { regions[i].dContrast = $0; refresh() }), -50...50, 1)
                    miniSlider("饱和 +", Binding(get: { regions[i].dSat },
                                                set: { regions[i].dSat = $0; refresh() }), -50...50, 1)
                    miniSlider("暖冷 +", Binding(get: { regions[i].dWarm },
                                                set: { regions[i].dWarm = $0; refresh() }), -30...30, 1)
                    miniSlider("gamma +", Binding(get: { regions[i].dGamma },
                                                 set: { regions[i].dGamma = $0; refresh() }), -0.5...0.5, 0.05)
                    Divider()
                    // ── 蒙版（照 PS 的图层蒙版：白=生效、黑=不生效）──
                    HStack(spacing: 6) {
                        Text("蒙版").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $maskBrushAdd) {
                            Text("涂白").tag(true); Text("涂黑").tag(false)
                        }.pickerStyle(.segmented).frame(width: 96).font(.system(size: 9)).labelsHidden()
                        Toggle("画笔", isOn: $maskBrushMode).toggleStyle(.switch).controlSize(.mini).font(.system(size: 9))
                    }
                    miniSlider("蒙版笔刷", $maskBrushRadius, 1...25, 0.5)
                    // ③ "填充颜色"：不用一笔笔涂，直接把整块范围填满 / 反相（PS 图层蒙版的填充）
                    HStack(spacing: 6) {
                        Button("填满整块") {
                            pushHistory("蒙版·填满")
                            let side = Double(min(regions[i].rect.width, regions[i].rect.height))
                            let r = max(2.0, side * 100)
                            var dots: [MaskStroke] = []
                            let step = max(0.01, side / 8)
                            var y = regions[i].rect.minY
                            while y <= regions[i].rect.maxY {
                                var x = regions[i].rect.minX
                                while x <= regions[i].rect.maxX {
                                    dots.append(MaskStroke(x: x, y: y, r: r))
                                    x += step
                                }
                                y += step
                            }
                            regions[i].paintAdd = dots
                            regions[i].paintSub = []
                            status = "已把整块范围填成「生效」（也可再用涂黑笔刷挖掉局部）"
                            refresh()
                        }.font(.system(size: 9))
                        Button("反相") {
                            pushHistory("蒙版·反相")
                            regions[i].inverted.toggle()
                            refresh()
                        }.font(.system(size: 9))
                        Spacer()
                        Button("清空") {
                            pushHistory("清空蒙版")
                            regions[i].paintAdd = []; regions[i].paintSub = []
                            refresh()
                        }.font(.system(size: 9))
                    }
                    Picker("", selection: Binding(get: { regions[i].shape }, set: {
                        regions[i].shape = $0; refresh()
                    })) {
                        Text("矩形").tag(0); Text("椭圆").tag(1); Text("圆形").tag(2); Text("纯画笔").tag(3)
                    }.pickerStyle(.segmented).font(.system(size: 9)).labelsHidden()
                }
                Text("关掉「范围选择」后这一块的调整**保留**；开关是每条范围右边那个小开关。")
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            } else if cropMode {
                Text("在图上拖出裁剪框；比例条在画布左上角。").font(.system(size: 9)).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Button(cropApplied ? "已应用裁剪" : "应用裁剪") {
                        guard cropRect != nil else { status = "先在图上拖出裁剪框"; return }
                        pushHistory("应用裁剪")
                        cropApplied = true
                        cropMode = false
                        setCanvasTool("")     // 应用后退出裁剪模式，避免误拖
                        status = "裁剪已应用（想改回来：撤销 ⌘Z，或再点一次裁剪框工具）"
                        refresh()
                    }.font(.system(size: 10)).disabled(cropRect == nil)
                    Button("取消裁剪") {
                        pushHistory("取消裁剪")
                        cropApplied = false; cropRect = nil
                        status = "已取消裁剪"
                        refresh()
                    }.font(.system(size: 10))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    var toolTitle: String {
        switch activeCanvasTool {
        case "spot": return "工具：污点修复"
        case "patch": return "工具：修补"
        case "clone": return "工具：仿制图章"
        case "brush": return "工具：液化"
        case "crop": return "工具：裁剪框"
        case "hand": return "工具：抓手"
        default: return "工具"
        }
    }

    /// 滑杆的「复位值」——**全仓只此一份**。
    /// 为什么不是一律下界：逐脸提亮/暖冷这类区间是 -30...30，下界是 -30，
    /// 双击复位跳去 -30 完全不是用户说的“复位”（用户看到的正是“双击没反应/没复位”）。
    /// 规则：区间含 0 就回 0，否则回下界（如 0.2...8 的笔刷范围回 0.2）。
    func resetValue(_ r: ClosedRange<Double>) -> Double { r.contains(0) ? 0 : r.lowerBound }

    /// 窄行滑杆（工具属性里用，比面板里的紧凑）
    func miniSlider(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ step: Double) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary).frame(width: 78, alignment: .leading)
                // 双击标签复位（原生 Slider 会吃掉双击，标签行才收得到）
                .onTapGesture(count: 2) { v.wrappedValue = resetValue(r); refresh() }
                .help("双击还原为初始值")
            Slider(value: v, in: r, step: step).onChange(of: v.wrappedValue) { _, _ in refresh() }
                .sliderDblClickReset { v.wrappedValue = resetValue(r); refresh() }
            Text(String(format: step < 1 ? "%.1f" : "%.0f", v.wrappedValue))
                .font(.system(size: 9, design: .monospaced)).frame(width: 30, alignment: .trailing)
        }
    }

    /// 直方图：RGB 三通道叠加 / 亮度二选一，附死黑死白比例。
    /// 峰值取分位而不是最大值：背景一片白会让某个 bin 高得离谱，线性按最大值归一化会把曲线压成一条线。
    @ViewBuilder var histogramView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("直方图").font(.system(size: 11, weight: .medium))
                Spacer()
                Picker("", selection: $histChannel) {
                    Text("RGB").tag(0); Text("亮度").tag(1)
                }.pickerStyle(.segmented).frame(width: 116).font(.system(size: 10))
            }
            if let h = hist {
                let bins = histChannel == 1 ? h.lum : (h.r + h.g + h.b)
                let peak = histPeak(bins)
                // ⚠️ 曲线必须按**视图尺寸**画：Path 用的是绝对点坐标，
                // 我第一版把小图坐标（0~1）直接丢进去，结果三条曲线全挤在左上角一个点里，
                // 界面上看着就是一块空黑（这个只有真截图看才发现）。
                GeometryReader { g in
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35))
                        if histChannel == 1 {
                            histPath(h.lum, peak: peak, size: g.size).stroke(Color.white.opacity(0.9), lineWidth: 1)
                        } else {
                            histPath(h.r, peak: peak, size: g.size).stroke(Color.red.opacity(0.75), lineWidth: 1)
                            histPath(h.g, peak: peak, size: g.size).stroke(Color.green.opacity(0.75), lineWidth: 1)
                            histPath(h.b, peak: peak, size: g.size).stroke(Color.blue.opacity(0.75), lineWidth: 1)
                        }
                    }
                }
                // 收窄 + 压扁：原来它铺满整个参数区宽度（用户反馈"一竖列都太宽"），
                // 直方图看的是形状与死黑死白，不需要那么宽
                .frame(width: 190, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12)))
                .overlay(alignment: .leading) {
                    // 左侧纵标尺（峰值线，3 档）
                    VStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { i in
                            Rectangle().fill(Color.white.opacity(i == 3 ? 0 : 0.18)).frame(width: i == 3 ? 6 : 4, height: 0.5)
                            if i < 3 { Spacer() }
                        }
                    }.frame(width: 6, height: 64, alignment: .leading).offset(x: -7)
                }
                // 下方横标尺 + 三部分分区（阴影 / 中间调 / 高光）
                HStack(spacing: 0) {
                    ForEach([("阴影", 0, 64), ("中间调", 64, 192), ("高光", 192, 256)], id: \.0) { seg in
                        let n = histSegmentShare(h, from: seg.1, to: seg.2)
                        VStack(alignment: .leading, spacing: 1) {
                            Rectangle()
                                .fill(Color.white.opacity(0.25))
                                .frame(height: 0.5)
                            HStack(spacing: 2) {
                                Text(seg.0).font(.system(size: 8)).foregroundColor(.secondary)
                                Text(String(format: "%.0f%%", n * 100))
                                    .font(.system(size: 8, design: .monospaced)).foregroundColor(.secondary)
                            }
                        }
                        .frame(width: 63, alignment: .leading)
                    }
                }
                .frame(width: 190, alignment: .leading)
                Text(String(format: "死黑 %.2f%%　死白 %.2f%%", h.clippedLow * 100, h.clippedHigh * 100))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                Text("打开一张照片后显示").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    /// 某一段亮度区间（bin 下标）占多少：用于直方图下方的「阴影/中间调/高光」分区
    func histSegmentShare(_ h: Histogram, from: Int, to: Int) -> Double {
        guard h.samples > 0 else { return 0 }
        var s = 0
        for i in max(0, from)..<min(256, to) { s += h.lum[i] }
        return Double(s) / Double(h.samples)
    }

    /// 直方图峰值：取第 97 百分位的 bin 计数（抗单个尖峰）
    func histPeak(_ bins: [Int]) -> Double {
        let sorted = bins.sorted()
        let idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.97))
        return max(1, Double(sorted[idx]))
    }

    /// 把 256 个 bin 画成一条曲线（按视图尺寸铺满）
    func histPath(_ bins: [Int], peak: Double, size: CGSize) -> Path {
        Path { p in
            let n = bins.count
            for i in 0..<n {
                let x = CGFloat(i) / CGFloat(max(1, n - 1)) * size.width
                let y = (1 - CGFloat(min(1.0, Double(bins[i]) / peak))) * size.height
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    var paramPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 命名照像素蛋糕的调色词汇（色阶 / 曲线 / 色彩平衡 / 饱和度）
            Text("后调色").font(.headline)
            Text("影调与色彩（风格项来自参考组，安全项来自本图）").font(.caption).foregroundColor(.secondary)
            Text("曲线 · 中调").font(.system(size: 11, weight: .medium))
            slider("  曲线 gamma", $params.gamma, 0.8...1.35, 0.005) { refresh() }
            Text("色阶 · 输出黑场").font(.system(size: 11, weight: .medium))
            slider("  抬黑（输出黑场）", Binding(get: { params.levelsOut[0] }, set: { params.levelsOut[0] = $0 }), 0...60, 1) { refresh() }
            Text("饱和度").font(.system(size: 11, weight: .medium))
            slider("  降饱和", $params.desat, 0...80, 1) { refresh() }
            slider("  对比度", $params.contrast, -20...30, 1) { refresh() }
            Text("色彩平衡").font(.system(size: 11, weight: .medium))
            slider("  高光（R-B）", Binding(get: { params.cbHi[0] }, set: { params.cbHi[0] = $0; params.cbHi[2] = -$0 }), 0...20, 0.5) { refresh() }
            slider("  阴影（R-B）", Binding(get: { params.cbSh[0] }, set: { params.cbSh[0] = $0; params.cbSh[2] = -$0 }), -20...20, 0.5) { refresh() }
            // 中间调：以前既没有入口、渲染里也没被应用（coretest 第 27 段量出 0.00）。两边都补上。
            slider("  中间调（R-B）", Binding(get: { params.cbMid[0] }, set: { params.cbMid[0] = $0; params.cbMid[2] = -$0 }), -20...20, 0.5) { refresh() }
            Divider()
            // 对应像素蛋糕的「局部AI追色」：只把区域内的色温/亮度朝参考组推
            Text("局部 AI 追色（近似）").font(.system(size: 11, weight: .medium))
            Text(cropRect == nil ? "先在「裁剪」面板拖一个区域，这两个滑杆才生效" : "作用区域 = 裁剪面板里拖出的那个框")
                .font(.caption2).foregroundColor(.secondary)
            slider("  区域色温", $localWarm, -30...30, 1) { refresh() }
            slider("  区域亮度", $localBright, -40...40, 1) { refresh() }
            Divider()
            Divider()
            Text("自动 / 智能").font(.system(size: 11, weight: .medium))
            HStack {
                Button("自动白平衡") {
                    guard let img = workImage() else { return }
                    let wb = estimateWhiteBalance(img)
                    pushHistory("自动白平衡")
                    autoWB = 100
                    autoWBInfo = String(format: "R-B 偏差 %.1f → 增益 R%.3f G%.3f B%.3f（%@）",
                                        wb.castR > 0 ? wb.castR : -wb.castR, wb.rGain, wb.gGain, wb.bGain, wb.source)
                    refresh()
                }
                Button("自动曝光/分级") {
                    guard let img = workImage() else { return }
                    let plan = planAutoExposure(img)
                    pushHistory("自动曝光")
                    autoExposeAmount = plan.changed ? 100 : 0
                    autoInfo = plan.changed
                        ? String(format: "p5/p50/p95 %.0f/%.0f/%.0f → 黑场 %.0f 白场 %.0f gamma %.2f",
                                 plan.beforeP5, plan.beforeP50, plan.beforeP95, plan.blackIn, plan.whiteIn, plan.gamma)
                        : String(format: "中调 %.0f 已经到位、跨度 %.0f 够用，不动", plan.beforeP50, plan.beforeP95 - plan.beforeP5)
                    refresh()
                    status = autoInfo
                }
                Button("自动摆正（量倾角）") {
                    guard let img = workImage() else { return }
                    guard let tilt = estimateTiltAngle(img) else {
                        status = "这张图没有明显的主轴（没有地平线/建筑边），不报倾角"
                        return
                    }
                    pushHistory("自动摆正")
                    rotateDeg = max(-10, min(10, -tilt))
                    refresh()
                    status = String(format: "量到倾角 %+.2f° → 已把旋转设为 %+.2f°（可在裁剪面板继续微调）", tilt, rotateDeg)
                }
                Button("自动肤色") {
                    guard let img = workImage() else { return }
                    var faces: [FaceGeo] = cachedGeos
                    if faces.isEmpty, let cg = sharedCtx.createCGImage(img, from: img.extent) {
                        faces = detectFaceGeos(cg, size: img.extent.size)
                    }
                    guard !faces.isEmpty else { status = "没有检出人脸，自动肤色跳过"; return }
                    let mask = faces.count == 1 ? skinMaskForFace(img, face: faces[0])
                                                : skinMaskForFaces(img, geos: faces)
                    guard let tone = measureSkinTone(img, mask: mask) else { status = "皮肤区太小，量不到肤色"; return }
                    pushHistory("自动肤色")
                    autoSkinAmount = 100
                    autoInfo = String(format: "肤色色相 %.1f° 饱和 %.2f（目标带 26°）", tone.hue, tone.saturation)
                    refresh()
                    status = autoInfo
                }
                Button("按场景自适应") {
                    guard let img = workImage() else { return }
                    var scene: SceneInfo? = nil
                    if let cg = sharedCtx.createCGImage(img, from: img.extent) { scene = classifyScene(cg) }
                    var face: CGRect? = nil
                    if let cg = sharedCtx.createCGImage(img, from: img.extent) {
                        face = detectFaceGeos(cg, size: img.extent.size).max(by: { $0.box.width < $1.box.width })?.box
                    }
                    let p = planSceneAdaptive(img, scene: scene, faceBox: face)
                    pushHistory("按场景自适应")
                    if p.fillLight > 0 { autoFill = p.fillLight }
                    if p.exposure > 0 { autoExposeAmount = p.exposure }
                    if p.denoise > 0 { denoiseAmount = p.denoise }
                    if p.wb > 0 { autoWB = p.wb }
                    status = "场景 " + p.category + "：" + (p.reasons.isEmpty ? "这张图不需要额外处理" : p.reasons.joined(separator: "；"))
                    autoInfo = status
                    refresh()
                }
                Button("自动暗角") {
                    guard let img = workImage() else { return }
                    let p = planAutoVignette(img)
                    autoInfo = p.detail + " → 建议校正 " + String(format: "%.0f", p.amount)
                    pushHistory("自动暗角")
                    if p.needed {
                        lensVignette = p.amount
                        status = "已按测量值设暗角校正 " + String(format: "%.0f", p.amount)
                    } else {
                        status = "四角/中心 " + String(format: "%.3f", p.cornerToCenter) + "，不需要校正"
                    }
                    refresh()
                }
                Button("自动降噪") {
                    guard let img = workImage() else { return }
                    let p = planAutoDenoise(img)
                    autoInfo = p.detail + " → 建议降噪 " + String(format: "%.0f", p.amount)
                    pushHistory("自动降噪")
                    if p.needed {
                        denoiseAmount = p.amount
                        status = "已按测量值设降噪 " + String(format: "%.0f", p.amount)
                    } else {
                        status = "噪声 σ ≈ " + String(format: "%.2f", p.noiseSigma) + "，不需要降噪"
                    }
                    refresh()
                }
                Button("自动补光（按光向）") {
                    guard let img = workImage(), sharedCtx.createCGImage(img, from: img.extent) != nil else { return }
                    let face = cachedGeos.max(by: { $0.box.width < $1.box.width })?.box
                    let dir = estimateLightDirection(img, face: face)
                    pushHistory("自动补光")
                    autoFill = 60
                    status = String(format: "估计光向 dx %.2f dy %.2f 强度 %.2f → 往暗侧补光", dir.dx, dir.dy, dir.strength)
                    refresh()
                }
            }.font(.system(size: 11))
            if !autoWBInfo.isEmpty {
                Text(autoWBInfo).font(.caption2).foregroundColor(.secondary)
            }
            if !autoInfo.isEmpty {
                Text(autoInfo).font(.caption2).foregroundColor(.secondary)
            }
            slider("  自动曝光/分级强度", $autoExposeAmount, 0...100, 5) { refresh() }
            slider("  自动肤色强度", $autoSkinAmount, 0...100, 5) { refresh() }
            slider("  自动白平衡强度", $autoWB, 0...100, 5) { refresh() }
            slider("  智能锐化（只锐边缘）", $smartSharpen, 0...100, 5) { refresh() }
            slider("  高光恢复", $highlightRecover, 0...100, 5) { refresh() }
            slider("  自动补光", $autoFill, 0...100, 5) { refresh() }
            Text("实测：白平衡把 R-B 偏差 32 → 0.2；智能锐化平坦皮肤只提 40%（普通锐化 100%）而纹理仍提 113%；")
                .font(.caption2).foregroundColor(.secondary)
            Text("高光恢复把溢出区 255 拉到 224、相邻暗区不变；补光按光向落在暗侧（左 +50 vs 右 +18）。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("影调补充").font(.system(size: 11, weight: .medium))
            slider("  降噪", $denoiseAmount, 0...100, 5) { refresh() }
            slider("  锐化", $sharpenAmount, 0...100, 5) { refresh() }
            slider("  暗角", $vignetteAmount, -100...100, 5) { refresh() }
            slider("  颗粒（胶片感）", $grainAmount, 0...100, 5) { refresh() }
            slider("  补光", $lightAmount, 0...100, 5) { refresh() }
            slider("  补光暖冷", $lightWarm, -30...30, 1) { refresh() }
            Text("补光位置固定在画面上部中央；颗粒用 CIRandomGenerator 叠单色噪声。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("本图度量").font(.subheadline)
            Text(String(format: "p50 %.0f · 饱和度 %.0f%% · 阴影 %+.1f / 高光 %+.1f",
                        srcStats.p50, srcStats.sat, srcStats.warmSh, srcStats.warmHi))
                .font(.system(size: 11)).foregroundColor(.secondary)
            Text(String(format: "与参考组误差 %.3f", srcStats.distance(to: target)))
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    func slider(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>, _ step: Double,
                _ onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.system(size: 11))
                // 双击标签复位（原生 Slider 会吃掉双击）
                .onTapGesture(count: 2) { v.wrappedValue = resetValue(r); onChange() }
                .help("双击还原为初始值")
                Spacer()
                Text(String(format: "%.2f", v.wrappedValue)).font(.system(size: 11)).monospacedDigit()
                Button { v.wrappedValue = 0 } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 9)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            Slider(value: v, in: r, step: step).onChange(of: v.wrappedValue) { _, _ in
                onChange()
                sliderHistory("调整 " + label.trimmingCharacters(in: .whitespaces))
            }
            // ② 双击滑杆 = 还原初始值。"初始值"取该滑杆的**下界**（本项目所有滑杆都以 0/正下界为"没调过"）。
            // ⚠️ 手势那套已经证明收不到（Slider 是原生控件、会吃掉双击；挂标签行也只在点到字上才有效），
            // 所以改走**应用级双击监视器**（SliderResetStore）：滑杆把自己的屏幕矩形登记上去，
            // 双击落在矩形内就复位——点滑杆任意位置都生效。
            .sliderDblClickReset {
                v.wrappedValue = resetValue(r)
                onChange()
                sliderHistory("双击复位 " + label.trimmingCharacters(in: .whitespaces))
            }
            .help("双击滑杆任意位置 = 还原为初始值（" + String(format: "%.2f", resetValue(r)) + "）")
        }
    }
}
