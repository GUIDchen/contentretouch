// Canvas.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    var canvas: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            // 液化工作区：**整屏一张大图**（修后）。
            // 用户两次报"液化在大图上没用"，除了坐标映射那个真 bug 之外，
            // 还有一层体验问题：工作区里本来是"原图 / 修后"并排两栏，每栏都不够大，
            // 笔刷落点又靠猜。PS 的液化是整屏一张，这里照它。
            if liquifyWorkspace {
                pane(brushActive ? "液化画布（整屏，工具在左侧）" : "修后", outImage ?? srcImage, key: "out")
            } else if singleView {
                if splitCompare, srcImage != nil, outImage != nil {
                    splitPane()
                } else {
                    // 按住看原图时：**只把"修后"那一栏临时换成无效果的版本**，
                    // 不再跳到单张原图（用户要求：并排时按住 = 右栏临时取消效果，松手恢复）。
                    pane(showingEffect ? "修后" : "修后（按住看原图·已取消效果）",
                         showingEffect ? outImage : srcImage)
                }
            } else {
                HStack(spacing: 10) {
                    // 参照图栏：选了推荐参照图就并排显示（#7：参照 / 原图 / 修后 三栏）
                    if showRefPane, let rp = chosenRef, let ri = ThumbCache.shared.image(URL(fileURLWithPath: rp), maxPixel: 1400) {
                        pane("参照：" + (rp as NSString).lastPathComponent, ri)
                    }
                    pane("原图", srcImage, key: "src")
                    // 并排模式下「按住看原图」：右栏临时显示**无效果**的同一张图（左边仍留着原图对照）
                    pane(showingEffect ? "修后（\(currentStyle.name)）" : "修后（按住看原图·已取消效果）",
                         showingEffect ? outImage : srcImage, key: "out")
                }
            }
            if busy {
                VStack {
                    ProgressView(value: progress).frame(width: 220)
                    Text(status).font(.caption)
                }.padding().background(.thinMaterial).cornerRadius(8)
            }
        }
        // 液化工作区里不显示画布底栏（星级/对比开关在那边用不上，只占地方）
        .overlay(alignment: .bottom) { if !liquifyWorkspace { canvasFooter } }
        // 画布坐标空间：pane 上报与拖动事件**必须在同一个空间**里比较，
        // 否则"指针落在哪一栏"就无从判断（并排模式下的坐标 bug，见 paneFrames 的说明）
        .coordinateSpace(name: "canvasSpace")
        // 画布在窗口坐标里的矩形：鼠标监视器收到的是窗口坐标，要据此判断按下点是否落在画布内
        // ⚠️ 这里用 onAppear + onChange(size) **主动写入**，而不是靠 onPreferenceChange：
        // 实测（合成鼠标事件 + DIAG 打印）读到的是 0,0,0,0 —— 偏好值那一路没把非零矩形送进来，
        // 于是监视器里的"按下点是否在画布内"永远为假，表现就是"怎么拖都不动"。
        .background(GeometryReader { gg in
            Color.clear
                .onAppear {
                    canvasInput.canvasFrameGlobal = gg.frame(in: .global)
                    canvasInput.installMouse()
                }
                .onChange(of: gg.size) { _, _ in canvasInput.canvasFrameGlobal = gg.frame(in: .global) }
        })
        // 拖动类工具激活时，挂一层 AppKit 事件捕获视图：**绕过 SwiftUI 手势识别**直接收鼠标事件。
        // 这是拖动问题的正面修法——不再依赖 DragGesture 能否被识别。
        // 拖动类工具激活时挂一层 AppKit 事件捕获视图（绕开 SwiftUI 手势识别），
        // 并**由它定义光标**——它在画布最上面，AppKit 只看最上层视图的光标定义。
        .overlay {
            if handTool || cropMode || realBrushActive || regionMode || maskBrushMode {
                GeometryReader { gg in
                    CanvasEventCatcher(onEvent: { phase, pt, mods in
                        handleCanvasDrag(phase: phase, local: pt, viewSize: gg.size, modifiers: mods)
                    },
                    cursor: canvasCursor(viewSize: gg.size))
                }
            }
        }
        .onChange(of: canvasInput.dragTick) { _, _ in handleMonitorDrag() }
        .onPreferenceChange(PaneFramesKey.self) { paneFrames = $0 }
        .padding(10)
    }

    /// 画布底部信息条（照像素蛋糕：‹ 1/1 › + 星级 + 文件名）
    /// 星级同时是「挑图」的输入：点一下就能打星，不用切面板。
    @ViewBuilder var canvasFooter: some View {
        if let u = srcURL {
            HStack(spacing: 8) {
                Button { stepImage(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Text(strip.isEmpty ? "1/1" : "\(currentIndex + 1)/\(strip.count)")
                    .font(.system(size: 10)).monospacedDigit()
                Button { stepImage(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                // 画布事件计数：拖动时这几个数会跳。哪一层收不到事件，一眼可见
                // （用户报"拖不动"时，这行数字就是最直接的证据）。
                Text(String(format: "事件 按%d 拖%d 抬%d", evDown, evDrag, evUp))
                    .font(.system(size: 9)).monospacedDigit().foregroundColor(.secondary)
                Divider().frame(height: 12)
                ForEach(1...5, id: \.self) { s in
                    Button { setStar(s) } label: {
                        Image(systemName: (stars[u] ?? 0) >= s ? "star.fill" : "star")
                            .font(.system(size: 10))
                            .foregroundColor((stars[u] ?? 0) >= s ? .orange : .secondary)
                    }.buttonStyle(.plain)
                }
                Text(u.lastPathComponent).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Divider().frame(height: 12)
                // —— 前后对比（#1）——
                // 1) 按住看原图：松手就回到修后，是修图软件里最常用的对比方式
                Text(holdingOriginal ? "原图" : "按住看原图")
                    .font(.system(size: 10))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(holdingOriginal ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12)))
                    .foregroundColor(.white)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !holdingOriginal { holdingOriginal = true } }
                            .onEnded { _ in holdingOriginal = false }
                    )
                // 2) 并排对比开关：原图 | 修后
                Toggle("并排", isOn: Binding(get: { !singleView }, set: { singleView = !$0 }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    .help("打开：左右并排显示原图与修后；关闭：只显示一张")
                // 3) 滑动对比：单图内左原图/右修后，中间一条可拖的分割线
                // 笔刷半径就在画布上改：用户反馈"缩到最小也太大"，说明它藏在面板里不好找也不好调。
                // 只在使用笔刷类工具时出现（否则白占地方）。
                if realBrushActive {
                    Divider().frame(height: 12)
                    Image(systemName: "circle.dashed").font(.system(size: 10)).foregroundColor(.secondary)
                    Slider(value: activeRadius, in: 0.2...8)
                        .frame(width: 96)
                        .onChange(of: activeRadiusPercent) { _, v in
                            status = String(format: "%@半径 %.1f%%（画面长边的百分比，1.0%% 在 1000px 图上约 10px 半径）",
                                            spotActive ? "污点修复" : (cloneActive ? "仿制图章" : (patchActive ? "修补" : "液化")), v)
                        }
                    Text(String(format: "%.1f%%", activeRadiusPercent))
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
                Toggle("滑动", isOn: $splitCompare)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10))
                    .onChange(of: splitCompare) { _, on in
                        if on { singleView = true }   // 滑动对比只在单图模式下有意义
                    }
                    .help("单图内左右对比：拖中间的分割线")
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
            .padding(.bottom, 4)
        }
    }


    /// 缩略图导航：小图里画出当前视野框，点击/拖动就能把视野挪过去。
    /// 为什么需要：抓手把画面拖出去之后，画布上什么都没有，用户只能一路瞎拖回来
    ///（#8 报的就是这个）。有了它随时能看到「图在哪、我在看哪一块」。
    @ViewBuilder func minimap(img: NSImage, viewSize: CGSize) -> some View {
        let box = displayedRect(viewSize: viewSize, imageSize: img.size)
        let scale = min(160 / max(1, img.size.width), 160 / max(1, img.size.height))
        let mw = max(24, img.size.width * scale), mh = max(24, img.size.height * scale)
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.5))
                Image(nsImage: img).resizable().frame(width: mw, height: mh).opacity(0.85)
                // 视野框：把画布上那个矩形换算到小图坐标
                let vx = max(0, -box.minX / max(1, box.width)) * mw
                let vy = max(0, -box.minY / max(1, box.height)) * mh
                let vw = min(mw, mw * viewSize.width / max(1, box.width))
                let vh = min(mh, mh * viewSize.height / max(1, box.height))
                Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: vw, height: vh)
                    .position(x: min(mw - vw / 2, max(vw / 2, vx + vw / 2)),
                              y: min(mh - vh / 2, max(vh / 2, vy + vh / 2)))
                if vw < 2 || vh < 2 {   // 图完全在视野外：整框描红，明确告诉用户「跑了」
                    Rectangle().stroke(Color.red, lineWidth: 2).frame(width: mw, height: mh)
                }
            }
            .frame(width: mw, height: mh)
            Text(String(format: "%.0f%%", zoom == 0 ? 100 : zoom))
                .font(.system(size: 8)).foregroundColor(.white)
                .padding(.horizontal, 4).background(Capsule().fill(Color.black.opacity(0.5)))
        }
        .padding(8)
        .onTapGesture { p in
            // 点小图 = 把那一点挪到画布中心
            let nx = (p.x - 8) / mw, ny = (p.y - 8) / mh
            panOffset = CGSize(width: (0.5 - nx) * box.width, height: (0.5 - ny) * box.height)
        }
        .help("缩略图导航：点一下就把那里移到画面中央")
    }



    /// 画布上这张图**实际占的矩形**（含缩放与平移）。
    /// 显示和输入映射都必须走它：早先显示用了 zoom/panOffset，而 imagePoint 只按「适应窗口」算，
    /// 结果放大后落点是错的（看着点在脸上，笔刷落到别处）。
    func displayedRect(viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 1, viewSize.height > 1,
              imageSize.width > 1, imageSize.height > 1 else { return .zero }
        let fit = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let s = fit * (zoom == 0 ? 1 : CGFloat(zoom) / 100)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (viewSize.width - w) / 2 + panOffset.width,
                      y: (viewSize.height - h) / 2 + panOffset.height,
                      width: w, height: h)
    }

    /// 光标那圈的直径 = 画布上范围圈的直径（含 4px 下限，与屏幕上的提示圈同一套算法，
    /// 保证"光标圈"和"提示圈"永远一样大）。
    /// 画布光标：**全仓唯一的判据**。
    /// 之前有两处各自算一份（捕获层 + 旧的 CursorArea），AppKit 那边谁最后 set 谁赢 ——
    /// 实测旧那份（十字）赢了新的（圈），于是"改成圆圈"变成了"还是十字"。两边都调这个函数，
    /// 谁赢都对，就不用去赌 AppKit 的 z 序了。
    func canvasCursor(viewSize: CGSize) -> NSCursor {
        if handTool { return handDragging ? .closedHand : .openHand }
        if realBrushActive { return BrushCursor.circle(brushCursorDiameter(viewSize: viewSize)) }
        if brushToolActive { return .crosshair }
        return .arrow
    }

    /// 当前工具在画布上的笔刷**半径**（点）。**光标圈与屏幕提示圈共用它** ——
    /// 否则会出现"提示圈画的是一套、实际作用的是另一套"（污点修复的圈曾经用的是液化的半径）。
    func currentBrushRadius(viewSize: CGSize) -> CGFloat {
        guard let img = srcImage else { return 12 }
        let rect = displayedRect(viewSize: viewSize, imageSize: img.size)
        return max(4, max(rect.width, rect.height) * CGFloat(activeRadiusPercent) / 100)
    }

    func brushCursorDiameter(viewSize: CGSize) -> CGFloat {
        currentBrushRadius(viewSize: viewSize) * 2
    }

    /// 笔刷半径（占长边百分比）→ 画布上的像素半径
    func brushRadiusPx(viewSize: CGSize, imageSize: CGSize) -> CGFloat {
        let r = displayedRect(viewSize: viewSize, imageSize: imageSize)
        return max(r.width, r.height) * CGFloat(brushRadius) / 100
    }

    func imagePoint(_ p: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint? {
        guard viewSize.width > 1, viewSize.height > 1,
              imageSize.width > 1, imageSize.height > 1 else { return nil }
        // **按指针所在的那一栏**换算（并排模式下画布上有 2~3 栏，见 paneFrames 的说明）。
        // 找不到所属栏时退回"整块画布当一张图"的老口径，保证单图模式行为不变。
        if let hit = paneFrames.first(where: { $0.value.contains(p) }) {
            let r = hit.value
            // 栏内顶部有标题行（Text + 4pt spacing），图片实际占标题以下的部分
            let headerH: CGFloat = 16
            let inner = CGRect(x: r.minX, y: r.minY + headerH, width: r.width, height: max(1, r.height - headerH))
            let box = displayedRect(viewSize: inner.size, imageSize: imageSize)
                .offsetBy(dx: inner.minX, dy: inner.minY)
            guard box.width > 1, box.height > 1 else { return nil }
            let nx = (p.x - box.minX) / box.width, ny = (p.y - box.minY) / box.height
            guard nx >= -0.02, nx <= 1.02, ny >= -0.02, ny <= 1.02 else { return nil }
            return CGPoint(x: min(1, max(0, nx)), y: min(1, max(0, 1 - ny)))
        }
        let box = displayedRect(viewSize: viewSize, imageSize: imageSize)
        guard box.width > 1, box.height > 1 else { return nil }
        let nx = (p.x - box.minX) / box.width, ny = (p.y - box.minY) / box.height
        guard nx >= -0.02, nx <= 1.02, ny >= -0.02, ny <= 1.02 else { return nil }
        return CGPoint(x: min(1, max(0, nx)), y: min(1, max(0, 1 - ny)))
    }




    /// 裁剪框叠加（状态里存的是归一化坐标，这里换算到视图坐标）
    /// 单图内的滑动对比：左边原图、右边修后，中间一条可拖的分割线。
    /// 比「并排两张」更适合看**同一个位置**的差别（并排时眼睛要在两张图之间来回找同一点）。
    func splitPane() -> some View {
        VStack(spacing: 4) {
            Text("滑动对比：左原图 / 右修后").font(.caption).foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06))
                    if let after = outImage, let before = srcImage {
                        let box = displayedRect(viewSize: geo.size, imageSize: after.size)
                        Image(nsImage: after)
                            .resizable().interpolation(.high)
                            .frame(width: max(1, box.width), height: max(1, box.height))
                            .position(x: box.midX, y: box.midY)
                        Image(nsImage: before)
                            .resizable().interpolation(.high)
                            .frame(width: max(1, box.width), height: max(1, box.height))
                            // ⚠️ mask 必须在 position **之前**：position 会让视图占满整个面板，
                            // 之后再挂 mask，遮罩的坐标系就是面板而不是图——遮罩会被整体左移 box.minX，
                            // 于是「划到最右」时右边仍然露出一条修后的图（用户报的正是这个）。
                            // 先按图的尺寸挂遮罩、再摆位置，坐标系才对得上。
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: max(0.01, box.width * splitPos))
                            }
                            .position(x: box.midX, y: box.midY)
                        // 分割线 + 手柄
                        Rectangle().fill(Color.white.opacity(0.9))
                            .frame(width: 1.5, height: max(1, box.height))
                            .position(x: box.minX + box.width * splitPos, y: box.midY)
                        Circle().fill(Color.white)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                            .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10)).foregroundColor(.black.opacity(0.7)))
                            .position(x: box.minX + box.width * splitPos, y: box.midY)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { g in
                                        splitPos = min(1, max(0, Double((g.location.x - box.minX) / max(1, box.width))))
                                    }
                            )
                    }
                }
                .clipped()
            }
        }
    }

    func pane(_ title: String, _ img: NSImage?, key: String = "") -> some View {
        let paneKey = key.isEmpty ? title : key
        return VStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06))
                    if let img {
                        let box = displayedRect(viewSize: geo.size, imageSize: img.size)
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: max(1, box.width), height: max(1, box.height))
                            .position(x: box.midX, y: box.midY)
                            .clipped()
                    }
                    else { Text("点左下「导入照片…」开始（也可以把照片拖进来）").font(.caption).foregroundColor(.secondary) }
                    // 笔刷范围提示圈：跟着指针走，圈的大小就是真实生效的范围
                    if let hp = hoverPoint, realBrushActive, img != nil {
                        // 显示用的半径有下限 4px：缩到 3px 时圆圈会小到看不见（但真实作用半径仍是设定值）
                        let r = currentBrushRadius(viewSize: geo.size)
                        Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.2)
                            .background(Circle().stroke(Color.black.opacity(0.5), lineWidth: 2.4))
                            .frame(width: r * 2, height: r * 2)
                            .position(hp)
                            .allowsHitTesting(false)
                        Text(String(format: "半径 %.0f%% （%.0f px）", brushRadius, r))
                            .font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                            .foregroundColor(.white)
                            .position(x: hp.x, y: max(12, hp.y - r - 12))
                            .allowsHitTesting(false)
                    }
                }
                // 光标随工具变：笔刷类=十字、抓手=张开的手（拖动时是握住的手）、其它=箭头
                .overlay(CursorArea(cursor: canvasCursor(viewSize: geo.size)))
                // ⚠️ 这里原来有一段「在范围圈上按住拖动改笔刷大小」。**已删除**，因为它的判据
                // 从原理上就不成立：范围圈是**跟着指针画**的（圈心 = 指针位置），所以按下时
                // 「按下点到圈心」的距离恒为 0，`abs(d - r) < 10` 只在半径小于 10px 时成立。
                // 后果很具体：把笔刷半径调小（0.2%~1%）之后，每一个拖动手势都会被这段抢走——
                // 圈没变大，形变也不发生。用户反馈的「液化按住鼠标拖不动」就是它。
                // 改大小的正确入口有三个，都还在：画布底栏的半径滑杆、右上工具属性滑杆、[ / ] 键。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            // 保留一个**按住 ⌥ 拖动 = 改笔刷大小**（很多修图软件的通用做法），
                            // 给需要"边看边调"的人一条路；不按 ⌥ 就完全不拦，交给工具本身。
                            // ⚠️ 仿制图章的 ⌥ 已改为"重新取样"（用户的习惯操作），所以这里排除它
                            guard realBrushActive, !cloneActive, NSEvent.modifierFlags.contains(.option) else { return }
                            let d = hypot(g.translation.width, g.translation.height)
                            brushRadius = min(20, max(0.2, brushRadius + Double(d) * 0.02))
                            status = String(format: "笔刷半径 %.1f%%（按住 ⌥ 拖动即可改）", brushRadius)
                        }
                        .onEnded { _ in brushHudDrag = false }
                )
                // 缩略图导航（#8）：抓手把图拖出画面后，至少知道自己在哪、也能一眼拖回来
                .overlay(alignment: .bottomTrailing) {
                    if handTool || zoom != 0, let img {
                        minimap(img: img, viewSize: geo.size)
                    }
                }
                // 裁剪比例条（#4）：鼠标形状与「拖出什么形状」都由这里决定
                .overlay(alignment: .topLeading) {
                    if cropMode {
                        HStack(spacing: 4) {
                            ForEach(Array(Self.cropShapeNames.enumerated()), id: \.offset) { i, n in
                                Button {
                                    cropShape = i
                                    cropRect = nil; dragStart = nil
                                    status = "裁剪方式：\(n)（在图上拖出裁剪框）"
                                    refresh()
                                } label: {
                                    Text(n).font(.system(size: 10))
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 5)
                                            .fill(cropShape == i ? Color.accentColor.opacity(0.85) : Color.black.opacity(0.45)))
                                        .foregroundColor(.white)
                                }.buttonStyle(.plain)
                            }
                        }.padding(8)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverPoint = p
                        canvasInput.pointerInCanvas = true
                    case .ended:
                        hoverPoint = nil
                        canvasInput.pointerInCanvas = false
                    }
                }
                // 滚轮 / 触控板双指滑动 = 以指针为中心缩放（按住左键拖动的同时滚也行，#3）
                .onChange(of: canvasInput.zoomTick) { _, t in
                    let d = t - lastZoomTick
                    lastZoomTick = t
                    guard abs(d) > 0.01 else { return }
                    let base = zoom == 0 ? 100.0 : zoom
                    zoom = min(400, max(10, base * exp(d * 0.004)))
                    status = String(format: "缩放 %.0f%%（滚轮）", zoom)
                }
                .onAppear { canvasInput.install(); canvasInput.installKeys() }
                .onChange(of: canvasInput.undoTick) { _, _ in undo() }
                .onChange(of: canvasInput.redoTick) { _, _ in redo() }
                // 触控板捏合缩放（像素蛋糕也是这样缩放的）
                // ⚠️ 必须用 simultaneousGesture：早先写成 .gesture(MagnificationGesture(), including: .gesture)，
                // 那会把**同一个视图上的拖动手势**顶掉 —— 结果裁剪拖不出框、仿制图章点不动
                //（#2 #3 报的就是这个）。捏合与拖动可以共存，本来也不需要二选一。
                // 触控板捏合缩放已停用（原来的实现见下）。原因：
                // MagnificationGesture 是**连续手势**，与同视图上的 DragGesture 竞争识别时会把拖动顶掉；
                // 本文件下面 2214 行那处注释就记过一次同类问题（"拖动手势被顶掉，裁剪拖不出框、仿制图章点不动"）。
                // 用户报的"抓手/液化拖不动、但点按类工具正常"完全符合这个症状。
                // 缩放仍有三条路：滚轮与触控板双指滑动（监视器）、⌥+拖动、左上角缩放菜单。
                // .simultaneousGesture(MagnificationGesture().onChanged { v in
                //     zoom = min(400, max(10, (zoom == 0 ? 100.0 : zoom) * Double(v)))
                // }.onEnded { _ in panOffset = .zero; refresh() })
                .overlay(showGuides ? AnyView(guidesOverlay) : AnyView(EmptyView()))
                .overlay(strokesOverlay)
                .overlay(cropRect == nil ? AnyView(EmptyView()) : AnyView(cropOverlay))
                .overlay((showFreeze && !freezeStrokes.isEmpty) ? AnyView(freezeOverlay) : AnyView(EmptyView()))
                .contentShape(Rectangle())
                // **单击也能用**：很多工具"点哪修哪"比拖着涂更顺手（像素蛋糕的污点修复就是点一下修一下）。
                // 另一层考虑：拖动这条路依赖连续事件，触控板设置、手势竞争、外接鼠标都可能让它失效；
                // 点击是一条独立的路，两条路都通，工具才真的"能用"。
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .named("canvasSpace"))
                        .onEnded { v in
                            guard let img = img,
                                  let pt = imagePoint(v.location, viewSize: geo.size, imageSize: img.size) else { return }
                            // ⚠️ 这三条都是"单击落点"的路（拖动那条走 beginStrokeHistory/endStrokeHistory）。
                            // pushHistory 必须写在**落点之后**：它记的是 snapshot(label) 当时的状态，
                            // 写在前面就记成了"改之前"，于是撤销这一步会原地不动（第 144 节）。
                            if spotActive {
                                spotPoints.append(pt)
                                status = String(format: "污点修复：已点第 %d 处（拖动能连续涂，[ ] 调大小）", spotPoints.count)
                                refresh()
                                pushHistory("污点修复")
                            } else if patchActive {
                                patchPoints.append(pt)
                                status = "修补：已涂 \(patchPoints.count) 处（点一下补一块）"
                                refresh()
                                pushHistory("修补")
                            } else if cloneActive {
                                // ⌥ = 重新取样（与捕获层同一条规则）
                                if NSEvent.modifierFlags.contains(.option) {
                                    cloneSource = pt
                                    cloneEpochs.append((at: clonePoints.count, source: pt))
                                    status = String(format: "仿制图章：已重新取样 (%.2f, %.2f)", pt.x, pt.y)
                                    refresh(); return
                                }
                                if cloneSource == nil {
                                    cloneSource = pt
                                    cloneEpochs.append((at: clonePoints.count, source: pt))
                                    status = String(format: "仿制图章：取样点 (%.2f, %.2f)，再点别处就复制过去（⌥+点击 换取样点）", pt.x, pt.y)
                                } else {
                                    clonePoints.append(pt)
                                    status = "仿制图章：已落 \(clonePoints.count) 个点"
                                }
                                refresh()
                                pushHistory("仿制图章")   // 同前：记"改动后"
                            } else if brushActive {
                                strokeMarkLive = true
                                liquifyLastPoint = pt          // ② 记下落点，方向推动/方向键要用
                                if liquifyMode == .push || liquifyMode == .pushLeft {
                                    // 向前变形/左推靠"拖动方向"，单击没有方向可言——如实提示，不记空笔触
                                    status = "向前变形要按住拖动（跟着鼠标方向推）；点一下没有方向，不生效"
                                } else {
                                    pushHistory("液化·" + liquifyMode.rawValue)
                                    warpStrokes.append(WarpStroke(mode: liquifyMode, center: pt,
                                                                  radius: brushRadius,
                                                                  strength: brushPressure / 100,
                                                                  density: brushDensity / 100))
                                    status = "液化：" + liquifyMode.rawValue + " 已点第 \(warpStrokes.count) 笔"
                                    refresh()
                                }
                            }
                        }
                )
                .gesture(
                    // 坐标空间必须和 pane 上报的一致（canvasSpace），否则"指针在哪一栏"判不出来
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            if diagLog, dragGestureLogged == false {
                                dragGestureLogged = true
                                let hit = imagePoint(g.location, viewSize: geo.size, imageSize: img?.size ?? .zero) != nil
                                FileHandle.standardError.write(
                                    "DIAG 画布拖动 工具=\(activeCanvasTool) 落在图内=\(hit)\n".data(using: .utf8)!)
                            }
                            guard let img = img else { return }
                            // 修补 / 仿制图章：把经过的点收进来（仿制需要先落一个取样点）
                            // ⚠️ ⌥ = 重新取样，**这一下不落点**（与捕获层同一条规则；
                            // 上一版只有捕获层认 ⌥，这条手势路照样落点，于是"取样"会顺手盖一下）
                            if cloneActive, NSEvent.modifierFlags.contains(.option) { return }
                            if patchActive || cloneActive {
                                guard let pt = imagePoint(g.location, viewSize: geo.size, imageSize: img.size) else { return }
                                if cloneActive && cloneSource == nil {
                                    cloneSource = pt
                                    status = String(format: "取样点已设 (%.2f, %.2f) —— 现在在别处涂就会把那块复制过去", pt.x, pt.y)
                                    return
                                }
                                let sp = spacing(cloneRadius)
                                let arr = cloneActive ? clonePoints : patchPoints
                                if let last = arr.last, abs(last.x - pt.x) < sp, abs(last.y - pt.y) < sp { return }
                                beginStrokeHistory(cloneActive ? "仿制图章" : "修补")
                                if cloneActive { clonePoints.append(pt) } else { patchPoints.append(pt) }
                                refresh()
                                return
                            }
                            // 污点修复笔刷：把经过的点收进来
                            if spotActive {
                                if let pt = imagePoint(g.location, viewSize: geo.size, imageSize: img.size) {
                                    let sp = spacing(spotRadius)
                                    if let last = spotPoints.last, abs(last.x - pt.x) < sp, abs(last.y - pt.y) < sp { return }
                                    beginStrokeHistory("污点修复")
                                    spotPoints.append(pt)
                                    refresh()
                                }
                                return
                            }
                            // 蒙版画笔：把经过的点涂进选中区域的蒙版
                            if maskBrushMode {
                                guard let pt = imagePoint(g.location, viewSize: geo.size, imageSize: img.size),
                                      let sid = selectedRegion ?? regions.last?.id,
                                      let idx = regions.firstIndex(where: { $0.id == sid }) else { return }
                                let sp = spacing(maskBrushRadius)
                                let stroke = MaskStroke(x: Double(pt.x), y: Double(pt.y), r: maskBrushRadius)
                                if maskBrushAdd {
                                    if let l = regions[idx].paintAdd.last,
                                       abs(l.x - stroke.x) < sp, abs(l.y - stroke.y) < sp { return }
                                    beginStrokeHistory("蒙版·涂白")
                                    regions[idx].paintAdd.append(stroke)
                                } else {
                                    if let l = regions[idx].paintSub.last,
                                       abs(l.x - stroke.x) < sp, abs(l.y - stroke.y) < sp { return }
                                    beginStrokeHistory("蒙版·涂黑")
                                    regions[idx].paintSub.append(stroke)
                                }
                                refresh()
                                return
                            }
                            // 范围选择：按下拖出一块（第一下记录起点，之后实时更新）
                            if regionMode {
                                guard let pt = imagePoint(g.location, viewSize: geo.size, imageSize: img.size) else { return }
                                if regionStart == nil {
                                    regionStart = pt
                                    regions.append(RegionAdjust(shape: regionShape, rect: CGRect(x: pt.x, y: pt.y, width: 0.02, height: 0.02),
                                                                feather: regionFeather))
                                    selectedRegion = regions.last?.id
                                }
                                if let s = regionStart, let idx = regions.indices.last {
                                    regions[idx].rect = CGRect(x: min(s.x, pt.x), y: min(s.y, pt.y),
                                                               width: abs(pt.x - s.x), height: abs(pt.y - s.y))
                                    // 形状实时跟随（圆形 = 取短边）
                                    regions[idx].shape = regionShape
                                    selectedRegion = regions[idx].id
                                    status = "范围已画好：去右侧「工具属性 → 该范围内调整（增量）」拖亮度/对比/饱和/暖冷即可看到效果"
                                    refresh()
                                }
                                return
                            }
                            // 抓手优先：拖动平移画布
                            if handTool {
                                handDragging = true
                                // ① 按住 ⌥ 拖动 = 缩放：**向左放大、向右缩小**（用户指定）。
                                // 左拖 dx 为负 → zoom 变大；右拖为正 → 变小。用指数保证手感线性。
                                if NSEvent.modifierFlags.contains(.option) {
                                    let z0 = zoom == 0 ? 100.0 : zoom
                                    // 150pt 的横拖约等于一档（×e）
                                    zoom = min(400, max(10, z0 * exp(-Double(g.translation.width) / 150.0)))
                                    status = String(format: "缩放 %.0f%%（按住 ⌥ 左右拖动：左放大 / 右缩小）", zoom)
                                    return
                                }
                                // ⚠️ 这里原来是「每次都把 g.translation 加到当前 panOffset 上」——
                                // 而 translation 是**相对按下那一刻**的累计量，于是每来一个事件又加一遍总量，
                                // 手感就是「越拖越快、图从光标下逃走」（#3 报的「不够丝滑」正是这个）。
                                // 正确做法：按下时记基准，之后用 基准 + 累计位移。
                                let base = panStart ?? panOffset
                                if panStart == nil { panStart = base }
                                let box0 = displayedRect(viewSize: geo.size, imageSize: img.size)
                                // 限位按**图的尺寸**算（与当前平移无关），图至少留 15% 在画面里
                                let maxX = max(0, box0.width * 0.85)
                                let maxY = max(0, box0.height * 0.85)
                                panOffset = CGSize(
                                    width: min(maxX, max(-maxX, base.width + g.translation.width)),
                                    height: min(maxY, max(-maxY, base.height + g.translation.height)))
                                return
                            }
                            // 裁剪模式：按下拖出一个矩形（第一下记录起点，之后实时更新）
                            if cropMode {
                                guard let pt = imagePoint(g.location, viewSize: geo.size, imageSize: img.size) else { return }
                                beginStrokeHistory("裁剪框")
                                if dragStart == nil { dragStart = pt }
                                if let s = dragStart {
                                    // ⚠️ 比例必须在**像素**里约束：归一化坐标下 w 与 h 的单位不同
                                    //（宽高各除了不同的数），拿归一化的 w/h 当比例算出来是错的
                                    //（这个坑本项目在智能裁剪里踩过一次，文档里记着）。
                                    let e = img.size
                                    let dxPx = (pt.x - s.x) * e.width
                                    let dyPx = (pt.y - s.y) * e.height
                                    var wPx = abs(dxPx), hPx = abs(dyPx)
                                    if let ar = cropRatio(for: e), ar > 0.01 {
                                        if wPx / max(1, hPx) > ar { hPx = wPx / ar } else { wPx = hPx * ar }
                                    }
                                    let ex = s.x + (dxPx >= 0 ? 1 : -1) * wPx / max(1, e.width)
                                    let ey = s.y + (dyPx >= 0 ? 1 : -1) * hPx / max(1, e.height)
                                    cropRect = CGRect(x: min(s.x, ex), y: min(s.y, ey),
                                                      width: abs(ex - s.x), height: abs(ey - s.y))
                                    refresh()
                                }
                                return
                            }
                            guard brushActive else { return }
                            guard let pt = imagePoint(g.location, viewSize: geo.size, imageSize: img.size) else { return }
                            beginStrokeHistory("液化")
                            let sp = spacing(brushRadius)
                            if let l = warpStrokes.last, abs(l.center.x - pt.x) < sp, abs(l.center.y - pt.y) < sp { return }
                            if let l = freezeStrokes.last, liquifyMode == .freeze,
                               abs(l.center.x - pt.x) < sp, abs(l.center.y - pt.y) < sp { return }
                            switch liquifyMode {
                            case .push, .pushLeft:
                                // 位移 = **本笔**上一落点 → 本落点：这才叫「跟着鼠标拖动的方向变形」
                                let prev = lastLiquifyPoint ?? pt
                                lastLiquifyPoint = pt
                                let d = CGPoint(x: pt.x - prev.x, y: pt.y - prev.y)
                                // 一笔的第一个点没有方向（prev 就是它自己），不记——记了也是一个空位移
                                guard abs(d.x) > 1e-5 || abs(d.y) > 1e-5 else { return }
                                warpStrokes.append(WarpStroke(mode: liquifyMode, center: pt, radius: brushRadius,
                                                              delta: CGPoint(x: d.x * brushPressure / 100,
                                                                             y: d.y * brushPressure / 100),
                                                              density: brushDensity / 100))
                            case .freeze:
                                beginStrokeHistory("液化·冻结")
                                freezeStrokes.append(WarpStroke(mode: .freeze, center: pt, radius: brushRadius,
                                                                density: brushDensity / 100))
                            case .thaw:
                                let r = brushRadius / 100.0
                                freezeStrokes.removeAll { hypot($0.center.x - pt.x, $0.center.y - pt.y) < r * 3 }
                            case .reconstruct:
                                // 重建 = 把笔刷范围内的形变退掉（PS 的复原画笔）
                                let r = brushRadius / 100.0
                                warpStrokes.removeAll { hypot($0.center.x - pt.x, $0.center.y - pt.y) < r * 3 }
                                freezeStrokes.removeAll { hypot($0.center.x - pt.x, $0.center.y - pt.y) < r * 3 }
                            default:
                                warpStrokes.append(WarpStroke(mode: liquifyMode, center: pt, radius: brushRadius,
                                                              strength: brushPressure / 100,
                                                              density: brushDensity / 100))
                            }
                            refresh()
                        }
        .onEnded { g in
                            endStrokeHistory()
                            dragGestureLogged = false
                            strokeMarkLive = false
                            dragStart = nil
                            if regionMode, let idx = regions.indices.last, regions[idx].rect.width < 0.01 {
                                regions.remove(at: idx)      // 只是点了一下、没拖出东西 → 不留空范围
                            }
                            regionStart = nil
                            lastLiquifyPoint = nil      // 一笔结束：下一笔的方向重新开始算
                            panStart = nil
                            if handTool {   // 松手时把平移量定下来（不再累加）
                                panOffset = CGSize(width: panOffset.width, height: panOffset.height)
                            }
                            _ = g
                        }
                )
            }
        }
        // 上报这一栏在**画布坐标**里的位置（imagePoint 用它判断"指针落在哪一栏"）
        .background(GeometryReader { gg in
            Color.clear.preference(key: PaneFramesKey.self,
                                   value: [paneKey: gg.frame(in: .named("canvasSpace"))])
        })
    }
}
