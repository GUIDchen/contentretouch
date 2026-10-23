// LiquifyWorkspace.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 裁剪框要画在**图上**，所以必须按 displayedRect（含缩放与平移）换算，
    /// 不能直接用「归一化 × 视图尺寸」——那是「适应窗口」时的特例，一放大框就飘了。
    var cropOverlay: some View {
        GeometryReader { g in
            if let r = cropRect, let img = srcImage {
                let box = displayedRect(viewSize: g.size, imageSize: img.size)
                let w = max(1, r.width * box.width), h = max(1, r.height * box.height)
                let cx = box.minX + (r.minX + r.width / 2) * box.width
                let cy = box.minY + (1 - (r.minY + r.height / 2)) * box.height
                ZStack {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: w, height: h)
                        .position(x: cx, y: cy)
                    // 三分线，方便按构图摆框
                    Path { p in
                        for f in [1.0 / 3, 2.0 / 3] {
                            p.move(to: CGPoint(x: cx - w / 2 + w * f, y: cy - h / 2))
                            p.addLine(to: CGPoint(x: cx - w / 2 + w * f, y: cy + h / 2))
                            p.move(to: CGPoint(x: cx - w / 2, y: cy - h / 2 + h * f))
                            p.addLine(to: CGPoint(x: cx + w / 2, y: cy - h / 2 + h * f))
                        }
                    }.stroke(Color.white.opacity(0.5), lineWidth: 1)
                }
            }
        }.allowsHitTesting(false)
    }

    // MARK: 右栏（预设列 + 参数面板 + 窄图标列）
    //
    // 顺序照像素蛋糕：画布 | 预设栏 | 参数面板 | 图标窄栏（图标在最右边缘）。
    // 早先我们把图标窄栏放在面板左边，和参照物是反的。
    func openLiquifyWorkspace() {
        liquifyBackup = (warpStrokes, freezeStrokes)   // 取消时回滚用
        liquifyMode = .push
        // 工作区里只留**一张**画布（PS 的液化就是单画布）：对比左右两张反而分散注意力，
        // 退出时恢复原来的显示方式。
        liquifyBackupSingleView = singleView
        singleView = true
        splitCompare = false
        liquifyWorkspace = true
        // ⚠️ 这里**不能**用 setCanvasTool("brush")：它是"再点一次就关掉"的语义，
        // 而用户在第二次打开工作区时 brushActive 往往还是 true（上次退出时没清）——
        // 于是这一次调用把笔刷**关掉**，工作区里怎么拖都没反应。
        // 这就是"向前变形/左推没效果"的真正原因（进工作区 = 应该无条件打开笔刷）。
        handTool = false; spotActive = false; patchActive = false
        cloneActive = false; cropMode = false; brushActive = true
        // ⚠️ 这两个也必须清掉：它们的分支排在笔刷**之前**，而且各自带 guard
        //（蒙版画笔要求先选中一个范围，没有就直接 return）。
        // 用户点过「范围选择」或「蒙版画笔」之后再来开液化，就会被它们挡在半路——
        // 表现完全就是"液化没法用、怎么拖都不动"。这是本轮找到的一个很可能的根因。
        regionMode = false
        maskBrushMode = false
        refresh()
    }

    func confirmLiquify() {
        liquifyWorkspace = false; liquifyBackup = nil
        singleView = liquifyBackupSingleView
        // ⚠️ **必须把"画布工具激活"的状态清掉**：否则退出工作区后，
        // 在大图上拖动仍然会被当成"液化·向前变形"继续刷（用户报的就是这个）。
        // 液化属于"只在工作区里生效"的工具，离开工作区就不该再抢画布拖动。
        brushActive = false
        liquifyLastPoint = nil
        CanvasInput.shared.liquifyArmed = false
        status = "已退出液化工作区（形变已保留，可撤销）"
    }

    /// ② 在"最近落点"上推一笔（方向推动按钮与方向键都走这里）。
    /// 没有落点就推到画面中心——保证**任何情况下都有反应**。
    /// ② 方向键推一笔（由 CanvasInput 观察到 tick 变化后调用）
    func consumePushTick() {
        guard brushActive, CanvasInput.shared.pushTick != lastPushTick else { return }
        lastPushTick = CanvasInput.shared.pushTick
        let d = CanvasInput.shared.pendingPush
        pushAtLastPoint(dx: d.0, dy: d.1)
    }

    /// ③ 在"最近落点"旋转一笔。左旋 = 逆时针（正角度），右旋 = 顺时针（负角度）。
    func twirlAtLastPoint(ccw: Bool) {
        guard brushActive else { status = "液化没在激活状态，请重新进一次工作区"; return }
        let c = liquifyLastPoint ?? CGPoint(x: 0.5, y: 0.5)
        let a = (brushPressure / 100) * (ccw ? 0.9 : -0.9)
        warpStrokes.append(WarpStroke(mode: .twirl, center: c, radius: brushRadius,
                                      delta: CGPoint(x: a, y: 0),
                                      strength: brushPressure / 100, density: brushDensity / 100))
        status = String(format: "已%@一笔 @(%.2f, %.2f)", ccw ? "左旋（逆时针）" : "右旋（顺时针）", c.x, c.y)
        refresh()
        pushHistory(ccw ? "液化·左旋" : "液化·右旋")   // 记"改动后"
    }

    func pushAtLastPoint(dx: Double, dy: Double) {
        guard brushActive else { status = "液化没在激活状态，请重新进一次工作区"; return }
        let c = liquifyLastPoint ?? CGPoint(x: 0.5, y: 0.5)
        // 位移量：方向单位向量 × 强度（0.02~0.06 是实测"明显但不撕裂"的区间）
        // 位移量：0.03~0.075 是实测"明显但不撕裂"的区间（1 笔就看得出来，连点也不会崩）
        let k = 0.015 + brushPressure / 100 * 0.03
        pushHistory("液化·方向推动")
        warpStrokes.append(WarpStroke(mode: liquifyMode == .push || liquifyMode == .pushLeft ? .push : liquifyMode,
                                      center: c, radius: brushRadius,
                                      delta: CGPoint(x: dx * k, y: dy * k),
                                      strength: brushPressure / 100, density: brushDensity / 100))
        status = String(format: "已推一笔（%+.2f, %+.2f）@(%.2f, %.2f)；方向键同样可以推", dx * k, dy * k, c.x, c.y)
        refresh()
    }

    func cancelLiquify() {
        if let b = liquifyBackup { warpStrokes = b.warp; freezeStrokes = b.freeze }
        liquifyWorkspace = false; liquifyBackup = nil
        singleView = liquifyBackupSingleView
        // ③ 取消这条路也要清掉画布工具状态（否则退出后大图拖动仍然在做液化）
        brushActive = false
        liquifyLastPoint = nil
        dragStrokeIndex = nil
        CanvasInput.shared.liquifyArmed = false
        status = "已取消液化，回到进入前的样子"
        refresh()
    }

    /// 液化工作区：整屏一个界面（照 PS 的组织方式）
    @ViewBuilder var liquifyWorkspaceView: some View {
        VStack(spacing: 0) {
            // 顶栏只放「标题 + 确认/取消」（照 PS：工具在左、属性在右、中间是画布）
            HStack(spacing: 8) {
                Text("液化").font(.headline)
                Text("（工具在左侧，笔刷参数在右侧；拖动不好使时用下面的「方向推动」或方向键）")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                // 当前画布工具：如果这里不是「液化」，就说明被别的工具挡住了（一眼能看出来）
                Text(brushActive ? "画布工具：液化 ✅" : "⚠️ 画布工具：被 " + activeCanvasTool + " 挡住，点左侧工具没用的话请退出重进")
                    .font(.system(size: 10))
                    .foregroundColor(brushActive ? .green : .orange)
                if liquifyMode == .push || liquifyMode == .pushLeft {
                    Text("这一模式可以不用拖动：先在图上点一下定位，再用上面的「方向推动」或直接按方向键")
                        .font(.system(size: 10)).foregroundColor(.orange)
                }
                Spacer()
                Button("恢复全部") {
                    warpStrokes = []; freezeStrokes = []
                    status = "已恢复全部形变"
                    refresh()
                }.font(.system(size: 11))
                Button("取消") { cancelLiquify() }.font(.system(size: 11))
                Button("确定") { confirmLiquify() }.font(.system(size: 11)).keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                // 左：竖向工具列（PS 的液化就是左侧一列）
                VStack(alignment: .leading, spacing: 4) {
                    Text("工具").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                    ForEach(LiquifyMode.allCases.filter { $0 != .twirl }, id: \.self) { m in
                        Button {
                            liquifyMode = m
                            status = "液化方式：" + m.rawValue
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: liquifyIcon(m)).font(.system(size: 12)).frame(width: 16)
                                Text(m.rawValue).font(.system(size: 11))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(liquifyMode == m ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.06)))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(10).frame(width: 118, alignment: .top)
                // ② 进工作区就武装方向键；离开自动解除（onDisappear）
                .onAppear { CanvasInput.shared.liquifyArmed = true }
                .onDisappear { CanvasInput.shared.liquifyArmed = false }
                Divider()
                VStack(spacing: 0) {
                    // ② **保底通路**：拖动这条路依赖连续鼠标事件（触控板设置、手势竞争、
                    // 外接鼠标都可能让它失效），所以再给一条"点一下就推"的路——
                    // 先在图上点一下定位（落点会显示），再用这 8 个方向键推。
                    // 这样即使拖动在你的环境里真的不工作，液化也不是不可用。
                    HStack(spacing: 4) {
                        Text("方向推动").font(.system(size: 10)).foregroundColor(.secondary)
                        ForEach([("↑", 0.0, 1.0), ("↓", 0.0, -1.0), ("←", -1.0, 0.0), ("→", 1.0, 0.0),
                                 ("↖", -0.7, 0.7), ("↗", 0.7, 0.7), ("↙", -0.7, -0.7), ("↘", 0.7, -0.7)],
                                id: \.0) { item in
                            Button(item.0) { pushAtLastPoint(dx: item.1, dy: item.2) }
                                .font(.system(size: 11)).frame(width: 24)
                        }
                        // ③ 旋转要能分左右（原来只有"逆时针"一个方向）
                        Text("旋转").font(.system(size: 10)).foregroundColor(.secondary)
                        Button("↺ 左旋") { twirlAtLastPoint(ccw: true) }.font(.system(size: 10))
                        Button("↻ 右旋") { twirlAtLastPoint(ccw: false) }.font(.system(size: 10))
                        Text(liquifyLastPoint == nil
                             ? "先在图上点一下确定位置（或直接用方向键/按钮，默认作用在画面中心）"
                             : String(format: "落点 (%.2f, %.2f)", liquifyLastPoint!.x, liquifyLastPoint!.y))
                            .font(.system(size: 9)).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                // 右：当前工具的详细属性（照 PS 的右侧参数区）+ ④ 本工作区的液化步骤
                VStack(alignment: .leading, spacing: 6) {
                    Text("液化步骤").font(.system(size: 11, weight: .medium))
                    Text("点任意一步 = 回到那一步（后面的会被丢掉，可用撤销恢复）")
                        .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                    if warpStrokes.isEmpty {
                        Text("还没有笔触").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(warpStrokes.enumerated()), id: \.offset) { i, w in
                                Button {
                                    warpStrokes = Array(warpStrokes.prefix(i + 1))
                                    status = String(format: "回到第 %d 步（共 %d 笔）", i + 1, warpStrokes.count)
                                    refresh()
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(String(i + 1)).font(.system(size: 9)).foregroundColor(.secondary)
                                        Text(w.mode.rawValue).font(.system(size: 10))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4)
                                        .fill(i == warpStrokes.count - 1 ? Color.accentColor.opacity(0.25) : Color.clear))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    Divider()
                    Text("当前工具的详细属性").font(.system(size: 10, weight: .medium)).foregroundColor(.secondary)
                }
                .padding(10).frame(width: 150, alignment: .top)
                VStack(alignment: .leading, spacing: 10) {
                    Text("笔刷参数").font(.system(size: 11, weight: .medium))
                    WSRow(label: "画笔大小", value: String(format: "%.1f%%", brushRadius)) {
                        Slider(value: $brushRadius, in: 0.2...12, step: 0.1)
                    }
                    WSRow(label: "画笔密度", value: String(format: "%.0f", brushDensity)) {
                        Slider(value: $brushDensity, in: 0...100, step: 5)
                    }
                    WSRow(label: "画笔压力", value: String(format: "%.0f", brushPressure)) {
                        Slider(value: $brushPressure, in: 1...100, step: 1)
                    }
                    Divider()
                    Text("当前工具").font(.system(size: 11, weight: .medium))
                    Text(liquifyMode.rawValue).font(.system(size: 12))
                    Text(hintForLiquify).font(.system(size: 10)).foregroundColor(.secondary)
                    Text("笔触 \(warpStrokes.count)｜冻结 \(freezeStrokes.count)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(12).frame(width: 190, alignment: .topLeading)
            }
            // 笔刷参数已经搬到右侧属性栏，这里不再重复一条底栏
        }
    }

    /// 量一次"按当前设置导出这张图会有多大"。
    /// 防抖 0.5 秒：拖质量滑杆时不要每一帧都编码一遍（一次编码在预览分辨率下几十毫秒，
    /// 全分辨率上百毫秒）。
    /// 删掉模型后刷新界面状态
    func LamaReset() {
        lamaInstalled = false
        lamaStatus = "已删除，修复退回本机样例修补"
    }
}
