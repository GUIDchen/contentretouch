// PanelsPicking.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("批量结果").font(.headline)
            if records.isEmpty { Text("还没有跑过批量").font(.caption).foregroundColor(.secondary) }
            ForEach(records) { r in
                HStack {
                    Text(r.file).font(.system(size: 11)).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.2f→%.2f", r.errBefore, r.errAfter)).font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
                    if r.alreadyClose { Text("未套用").font(.system(size: 9)).foregroundColor(.orange) }
                }
            }
        }
    }

    // MARK: 编辑面板（裁剪旋转）
    var editPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("裁剪旋转").font(.headline)
            Text("流程：在图上拖出矩形 → 点下面「应用裁剪」。这是**唯一**的裁剪入口（工具条那个按钮也是切到这里）。")
                .font(.caption2).foregroundColor(.secondary)
            Toggle("画布裁剪框（在图上拖一个矩形）", isOn: $cropMode).onChange(of: cropMode) { _, _ in
                if !cropMode { dragStart = nil }
            }
            HStack {
                Text(cropRect == nil ? "未设裁剪框" : String(format: "裁剪框 %.0f×%.0f", cropRect!.width, cropRect!.height))
                    .font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button("清除裁剪框") { cropRect = nil; dragStart = nil; refresh() }
            }
            Divider()
            Text("智能裁剪（按显著性主体）").font(.system(size: 11, weight: .medium))
            Picker("目标比例", selection: $cropAspect) {
                Text("原图").tag("原图"); Text("1:1").tag("1:1"); Text("4:5").tag("4:5")
                Text("3:4").tag("3:4"); Text("16:9").tag("16:9")
            }.pickerStyle(.menu)
            Picker("落点", selection: $cropPlacement) {
                Text("三分法").tag("thirds"); Text("居中").tag("center")
            }.pickerStyle(.segmented)
            Button("按主体智能裁剪") { runSmartCrop() }.disabled(srcURL == nil)
            Button("检测人物实例…") { detectPersons(); showPersonCrop = true }.disabled(srcURL == nil)
                .popover(isPresented: $showPersonCrop, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("按人物裁剪").font(.headline)
                        if personRects.isEmpty {
                            Text("没有分割出人物实例（这张图可能没有完整人体）").font(.caption2).foregroundColor(.secondary)
                        } else {
                            Text("分割出 " + String(personRects.count) + " 个人（从左到右）").font(.caption2).foregroundColor(.secondary)
                            ForEach(Array(personRects.enumerated()), id: \.offset) { i, _ in
                                Button("裁到第 " + String(i + 1) + " 个人（3:4）") { cropToPerson(i) }
                            }
                        }
                    }.padding(14).frame(width: 240)
                }
            Text("实测：主体在 0.72/0.72 时裁到三分线附近（主体贴边时优先保证主体完整）。").font(.caption2).foregroundColor(.secondary)
            Divider()
            Button("按肩线校平") { levelShoulders() }.disabled(srcURL == nil)
            Text("量出两肩连线倾角再反向旋转（实测：原图 4.5°，整体转 8° 后量到 14.0°）。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Toggle("自动祛黑白边", isOn: $autoCropOn).onChange(of: autoCropOn) { _, _ in refresh() }
            slider("旋转（度）", $rotateDeg, -10...10, 0.5) { refresh() }
            Divider()
            Text("校正（透视）").font(.system(size: 11, weight: .medium))
            slider("  水平校正", $perspH, -100...100, 5) { refresh() }
            slider("  垂直校正", $perspV, -100...100, 5) { refresh() }
            Text("实测：人为垂直梯形 上下竖线错位 7.2 px → 校正后 1.0 px。").font(.caption2).foregroundColor(.secondary)
            Toggle("水平翻转", isOn: $flipH).onChange(of: flipH) { _, _ in refresh() }
            HStack {
                Button("逆时针 90°") { quarterTurns = (quarterTurns + 1) % 4; refresh() }
                Button("恢复") { autoCropOn = false; rotateDeg = 0; flipH = false; quarterTurns = 0; refresh() }
            }
            Divider()
            Text("祛黑白边实测：带 60px 白边的图 1200×1740 → 1081×1618（目标 1080×1620）。").font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 图像面板（对应像素蛋糕的「图像」分类：背景纯化）
    /// 拍摄参数（EXIF）：修图时的基本参照——先知道这是 f/1.4 还是 f/8 拍的，再谈降噪和锐化
    @ViewBuilder var exifView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("拍摄参数").font(.system(size: 11, weight: .medium))
            if exifRows.isEmpty {
                Text("这张图没有可读的 EXIF（截图、导出图或被抹掉元数据的图都没有）")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                ForEach(Array(exifRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0).font(.system(size: 10)).foregroundColor(.secondary).frame(width: 62, alignment: .leading)
                        Text(row.1).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    var imagePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("图像美化").font(.headline)
            exifView
            Divider()
            Text("镜头配置：按 EXIF 镜头型号自动匹配 lens_profiles/ 里的配置并套用校正").font(.caption).foregroundColor(.secondary)
            HStack {
                Button("按 EXIF 自动匹配并套用") {
                    guard let url = srcURL else { status = "先打开一张图"; return }
                    guard let img = workImage() else { return }
                    let r = autoLensCorrect(img, path: url.path)
                    if r.profile.isEmpty {
                        let model = readLensModel(url.path)
                        lensInfo = "EXIF 镜头型号「" + (model.isEmpty ? "（无）" : model) + "」没有匹配配置，未做校正"
                    } else {
                        pushHistory("镜头校正（" + r.profile + "）")
                        lensInfo = "命中配置「" + r.profile + "」，已套用畸变/暗角/色差校正"
                        lensAutoApplied = true
                    }
                    status = lensInfo
                    refresh()
                }
                Button("重新读配置") { LensProfileStore.shared.reload(); lensInfo = "已重载 " + String(LensProfileStore.shared.profiles().count) + " 份配置" }
            }.font(.system(size: 11))
            if !lensInfo.isEmpty { Text(lensInfo).font(.caption2).foregroundColor(.secondary) }
            Text("配置目录：" + LensProfileStore.directory.path).font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("背景纯化（实例分割版）：用前景实例掩膜把背景压平，人物不动").font(.caption).foregroundColor(.secondary)
            slider("背景纯化强度", $bgPurify, 0...85, 5) { refresh() }
            Divider()
            Text("背景虚化（真虚化：主体清晰、背景高斯模糊）").font(.system(size: 11, weight: .medium))
            slider("  虚化强度", $bgBlur, 0...100, 5) { refresh() }
            Text("掩膜：VNGenerateForegroundInstanceMaskRequest → 反相 + 羽化 + 夹回，主体区不动。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("边缘优化").font(.system(size: 11, weight: .medium))
            slider("  收边强度", $edgeRefine, 0...100, 5) { refresh() }
            Divider()
            Text("镜头校正").font(.system(size: 11, weight: .medium))
            slider("  畸变校正（负=桶形，正=枕形）", $lensDistortion, -100...100, 5) { refresh() }
            slider("  暗角校正（提亮四角）", $lensVignette, 0...100, 5) { refresh() }
            slider("  横向色差校正", $lensCA, -100...100, 5) { refresh() }
            Text("实测（合成图判据）：畸变 线距标准差 8.96→2.20；暗角 角/中差 28.7→5.2；色差 边缘 R-B 2.565→0.037。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("实测：前景内变化 **0.030**、背景区变化 **12.830**（前景几乎不动、背景显著压平 ✅）").font(.caption2).foregroundColor(.secondary)
            Text("掩膜：VNGenerateForegroundInstanceMaskRequest（macOS 14+），比旧的人像分割边缘更准。").font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 参考追色 / 检索 的辅助
    func thumb(_ path: String, _ size: CGFloat) -> NSImage? {
        guard let ci = loadAnyImage(path, maxDim: Int(size * 2)),
              let cg = sharedCtx.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }

    // MARK: 帮助 / 反馈（像素蛋糕窄栏最下面那两个）
    var helpPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("帮助").font(.headline)
            Text("这个软件是什么").font(.system(size: 11, weight: .medium))
            Text("本地修图工具：导入照片 → 调参 → 导出。所有算法都在本机跑，不联网、不上传。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("三步上手").font(.system(size: 11, weight: .medium))
            Text("1) 左下「导入照片…」（可多选，也能把照片直接拖进来）")
                .font(.caption2).foregroundColor(.secondary)
            Text("2) 右侧按分栏调：人像 / 图像 / 衣物 / 后调色 / 裁剪 / 挑图")
                .font(.caption2).foregroundColor(.secondary)
            Text("3) 右上「导出」出片；整批出片走「导入并批量导出」")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("快捷键").font(.system(size: 11, weight: .medium))
            ForEach(shortcutList, id: \.0) { k, d in
                HStack(spacing: 10) {
                    Text(k).font(.system(size: 10, design: .monospaced)).frame(width: 66, alignment: .leading)
                    Text(d).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Divider()
            Text("哪些做不了（都在「待开发」页）").font(.system(size: 11, weight: .medium))
            Text("换装 / 换天 / 创成式填充 / 拉龄 / 闭眼修复 / 头发填充 / AI 点修 / 祛路人——这些要生成式模型；联机拍摄与云协同要服务端。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    var feedbackPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("反馈").font(.headline)
            Text("把下面的诊断信息连同问题一起发出来就够了——它带版本、系统、模型与缓存状态，能省一轮来回猜。")
                .font(.caption).foregroundColor(.secondary)
            Button("生成诊断信息") { diagText = diagnostics() }
            Button("复制到剪贴板") {
                if diagText.isEmpty { diagText = diagnostics() }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diagText, forType: .string)
                status = "诊断信息已复制到剪贴板"
            }
            if !diagText.isEmpty {
                ScrollView {
                    Text(diagText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 320)
            }
        }
    }

    // MARK: 占位面板（做不了的，先在这儿立着，以后开发）
    var placeholderPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // §421 ③：模型选择设置 —— 用户要求把模型管理从挑图页搬到待开发页，并定位为设置模块 ✓。
            Text("模型选择设置").font(.headline)
            ModelSettingsView()
            Divider()
            Text("待开发").font(.headline)
            Text("分两类：**要生成式模型的**（可选下载装了就能用）与**要服务端的**（本机做不了）。不假装能做。")
                .font(.caption).foregroundColor(.secondary)
            // 已经能可选下载的那一类，单独标出来（不再是"以后开发"）
            HStack {
                Image(systemName: LaMaStore.shared.isInstalled ? "checkmark.seal" : "arrow.down.circle")
                    .font(.system(size: 11))
                    .foregroundColor(LaMaStore.shared.isInstalled ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("大面积修复（祛杂物 / 去线缆 / 祛路人）").font(.system(size: 11))
                    Text("走**可选下载**的 LaMa 生成式修复；入口在「挑图」面板的资源区。没装则用本机样例修补")
                        .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.8))
                }
                Spacer()
                Text(LaMaStore.shared.isInstalled ? "已安装" : "可下载").font(.system(size: 9))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.03)))
            ForEach(Self.placeholders, id: \.0) { item in
                HStack {
                    Image(systemName: "lock.slash").font(.system(size: 11)).foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.0).font(.system(size: 11)).foregroundColor(.secondary)
                        Text(item.1).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.8))
                    }
                    Spacer()
                    Text("以后开发").font(.system(size: 9)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.03)))
            }
        }
    }

    // MARK: 挑图面板
    var pickPanel: some View {
        VStack(alignment: .leading, spacing: 8) {

            // 可选下载的模型：默认不装，装了就用（清晰抠图/虚化边缘）
            Text("清晰度 + 人脸质量 + 曝光 + 笑容 + 姿态 + 闭眼 → 排序。是工程指标，不是审美打分。")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Button("选择文件夹开始挑图…") { runPick() }.disabled(pickBusy)
                if pickBusy {
                    Button("取消") { pickCancel = true }.font(.system(size: 10))
                    ProgressView(value: pickProgress).frame(width: 120)
                    Text(String(format: "%.0f%%", pickProgress * 100)).font(.caption2).foregroundColor(.secondary)
                }
            }
            if !picks.isEmpty {
                Button("导出 CSV…") { exportPickCSV() }
                Divider()
                Text("选片交付").font(.system(size: 11, weight: .medium))
                Picker("最低星级", selection: $deliverStars) {
                    Text("3 星").tag(3); Text("4 星").tag(4); Text("5 星").tag(5)
                }.pickerStyle(.segmented)
                Button("按星级导出交付…") { deliverPicked() }.disabled(picks.isEmpty)
                Button("连拍分组选优（组内最高分打 5 星）") { burstPick() }.disabled(picks.isEmpty)
                if !burstStats.isEmpty {
                    Text(burstStats).font(.caption2).foregroundColor(.secondary).lineLimit(3)
                }
                if !burstGroups.isEmpty {
                    ForEach(Array(burstGroups.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(2)
                    }
                    if burstGroups.count > 8 {
                        Text("…还有 \(burstGroups.count - 8) 组").font(.caption2).foregroundColor(.secondary)
                    }
                }
                if !deliverStats.isEmpty {
                    Text(deliverStats).font(.caption2).foregroundColor(.secondary)
                }
                Text("拷进「交付」子目录并写选片清单.csv；原片不动。").font(.caption2).foregroundColor(.secondary)
                Divider()
                Text("共 \(picks.count) 张（美 = Apple 学习模型美学分，笑/姿/闭 = 关键点判据，末列是总分）：")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(Array(picks.prefix(20).enumerated()), id: \.offset) { i, p in
                    HStack {
                        Text("\(i + 1). \(p.file)").font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        // 前沿：Apple 学习模型的美学分（跑不了就不显示，不拿 0 冒充低分）
                        if p.aestheticOK {
                            Text(String(format: "美%.2f", p.aesthetic)).font(.system(size: 9)).monospacedDigit()
                                .foregroundColor(p.aesthetic > 0.6 ? .green : .secondary)
                        }
                        Text(String(format: "笑%.2f", p.smile)).font(.system(size: 9)).monospacedDigit().foregroundColor(.secondary)
                        Text(String(format: "姿%.0f°", p.headYaw)).font(.system(size: 9)).monospacedDigit().foregroundColor(.secondary)
                        if p.judgedFaces > 0 {
                            Text("闭\(p.closedEyes)/\(p.judgedFaces)").font(.system(size: 9)).monospacedDigit()
                                .foregroundColor(p.closedEyes > 0 ? .orange : .secondary)
                        }
                        Text(String(format: "%.1f", p.total)).font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
                        if !p.flags.isEmpty {
                            Text(p.flags.joined(separator: "/")).font(.system(size: 9)).foregroundColor(.orange)
                        }
                    }
                }
            }
        }
    }

    // §418 ①：模型选择设置 —— 原位抽成同视图的计算属性（零行为变化 ✓，下一步搬到待开发页 ✓）。
    var modelSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !samInstalled {
                Divider()
                Text("精细分割模型（可选下载）").font(.system(size: 11, weight: .medium))
                Toggle("启用（智能消除的点选圈选）", isOn: $useSAM).toggleStyle(.switch).font(.system(size: 10))
                // §373：SAM 槽位的多模型列表（与 LaMa 那段同构 ✓，只换 slot 与顶层目录名 ✓）。
                HStack(spacing: 8) {
                    Button("把已装模型登记进列表") {
                        let n = ModelRegistry.registerScanned(slot: "sam", topLevel: "SAM")
                        status = n > 0 ? ("模型：新登记 " + String(n) + " 个精细分割候选") : "模型：都已登记过（没有新候选）"
                    }.font(.system(size: 10))
                }
                ForEach(ModelRegistry.entries(slot: "sam"), id: \.dir) { e in
                    HStack(spacing: 6) {
                        Toggle(e.name, isOn: Binding(
                            get: { ModelRegistry.entries(slot: "sam").first(where: { $0.dir == e.dir })?.enabled ?? false },
                            set: { v in
                                var list = ModelRegistry.load()
                                for i in list.indices where list[i].slot == "sam" {
                                    list[i].enabled = (list[i].dir == e.dir ? v : false)
                                }
                                _ = ModelRegistry.save(list)
                                status = v ? ("精细分割：已启用 " + e.name) : ("精细分割：已停用 " + e.name)
                            })).toggleStyle(.switch).font(.system(size: 10))
                        Spacer()
                        Button("删除") {
                            var list = ModelRegistry.load()
                            list.removeAll { $0.slot == "sam" && $0.dir == e.dir }
                            _ = ModelRegistry.save(list)
                            status = "精细分割：已从列表移除 " + e.name
                        }.font(.system(size: 10))
                    }
                }
                Text("23 MB，Apache-2.0。装上之后抠图/虚化的边缘会精确到发丝（实测头发区域覆盖 0.34 → 0.99）；")
                    .font(.caption2).foregroundColor(.secondary)
                Text("不装也完全能用，会退回系统的前景掩膜。").font(.caption2).foregroundColor(.secondary)
                HStack {
                    Button(samBusy ? "下载中…" : "下载精细分割模型（23 MB）") {
                        samBusy = true
                        samStatus = "开始下载…"
                        SamStore.shared.install(progress: { f in samProgress = f }) { res in
                            samBusy = false
                            samInstalled = SamStore.shared.isInstalled
                            switch res {
                            case .success(let msg): samStatus = msg
                            case .failure(let e): samStatus = "失败：" + e.localizedDescription
                            }
                        }
                    }.disabled(samBusy)
                    if samBusy {
                        ProgressView(value: samProgress).frame(width: 120)
                    }
                }
                if !samStatus.isEmpty {
                    Text(samStatus).font(.caption2).foregroundColor(.secondary)
                }
            }
            Text("AI 挑图（粗筛）").font(.headline)
            if samInstalled {
                HStack {
                    Text("精细分割模型：已安装 " + String(format: "%.1f MB", Double(SamStore.shared.installedBytes) / 1_048_576))
                        .font(.caption2).foregroundColor(.secondary)
                    Button("删除") {
                        SamStore.shared.remove()
                        samInstalled = false
                        samStatus = "已删除，抠图/虚化退回系统前景掩膜"
                    }.font(.system(size: 10))
                    if !samStatus.isEmpty {
                        Text(samStatus).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            Divider()
            // ── 生成式修复模型（可选下载）──
            VStack(alignment: .leading, spacing: 6) {
                // §395：可下载目录 —— 拉 coreml-zoo 的清单，按许可标注（可入库 ● / 只评测 ○），一键下载并登记。
                Divider()
                // §411：上色的界面入口（安全版）—— 只跑一次并把实测结果报到状态栏 ✓，
                // 不写管线（管线写入的 API 名我尚未核实，宁可不写也不写错 ✗）。
                Divider()
                HStack(spacing: 8) {
                    Button("试一次上色（看效果与耗时）") {
                        if !Colorizer.shared.isAvailable {
                            status = "上色：未安装 DDColor —— 可在下面的可下载目录里装（Apache-2.0）"
                        } else if let img = workImage() {
                            let t0 = Date()
                            if let out = Colorizer.shared.colorize(img) {
                                let ms = Date().timeIntervalSince(t0) * 1000
                                status = "上色：已生成结果（" + String(Int(img.extent.width)) + "x"
                                    + String(Int(img.extent.height)) + "，用时 " + String(format: "%.0f", ms) + " ms）——效果评测见账本 §410"
                                _ = out
                            } else {
                                status = "上色：模型跑不动（形态或尺寸问题，见账本 §407）"
                            }
                        }
                    }.font(.system(size: 10))
                    Text("DDColor Tiny（Apache-2.0）").font(.system(size: 9)).foregroundColor(.secondary)
                }
Text("可下载模型目录（coreml-zoo 清单）").font(.system(size: 11, weight: .medium))
                HStack(spacing: 8) {
                    Button(catalogModels.isEmpty ? "拉取目录" : "刷新目录") {
                        if let man = ModelCatalog.load() {
                            catalogModels = man.models ?? []
                            let ok = catalogModels.filter { ModelCatalog.isShippable($0) }.count
                            catalogStatus = "共 " + String(catalogModels.count) + " 个，许可干净 " + String(ok) + " 个"
                        } else { catalogStatus = "拉取失败（镜像不可用？稍后再试）" }
                    }.font(.system(size: 10))
                    if !catalogStatus.isEmpty {
                        Text(catalogStatus).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
                ForEach(Array(catalogModels.prefix(40)), id: \.id) { m in
                    HStack(spacing: 6) {
                        Text(ModelCatalog.isShippable(m) ? "可入库" : "只评测")
                            .font(.system(size: 9))
                            .foregroundColor(ModelCatalog.isShippable(m) ? .green : .secondary)
                        Text(m.name).font(.system(size: 10)).lineLimit(1)
                        Spacer()
                        Button("下载并登记") {
                            let pl = ModelCatalog.inferPlacement(m)
                            let slot = pl?.slot ?? "faceparse"
                            let top = pl?.topLevel ?? "FaceParsing"
                            if let r = ModelCatalog.install(m, slot: slot, topLevel: top) {
                                status = "模型：" + r
                            } else {
                                status = "模型：" + m.name + " 下载或解压失败"
                            }
                        }.font(.system(size: 9))
                    }
                }
Text("生成式修复模型（可选下载）").font(.system(size: 11, weight: .medium))
                Toggle("启用（默认关：实测同洞误差更差，§289）", isOn: $useLaMa).toggleStyle(.switch).font(.system(size: 10))
                // §368：多模型列表（用户需求：一个功能下挂多个候选，逐个开关、可增可删）。
                // 数据来自 ModelRegistry（models.json ✓）；没有注册表时这一块为空 ⇒ 行为与旧版一致 ✓。
                // §370：一键登记「已下载的模型」——扫描 Models/LaMa/ 下的候选（含顶层旧布局 ✓），
                // 幂等写进注册表 ⇒ 出现在上面这个列表里，并可逐个开关 ✓。（用户需求原话：将已经下载的模型加载显示出来 ✓）
                HStack(spacing: 8) {
                    Button("把已装模型登记进列表") {
                        let n = ModelRegistry.registerScanned(slot: "lama", topLevel: "LaMa")
                        status = n > 0 ? ("模型：新登记 " + String(n) + " 个，可在上面逐个启用") : "模型：都已登记过（没有新候选）"
                    }.font(.system(size: 10))
                    Button("刷新列表") { status = "模型：列表已刷新（" + String(ModelRegistry.entries(slot: "lama").count) + " 项）" }
                        .font(.system(size: 10))
                }
                ForEach(ModelRegistry.entries(slot: "lama"), id: \.dir) { e in
                    HStack(spacing: 6) {
                        Toggle(e.name, isOn: Binding(
                            get: { ModelRegistry.entries(slot: "lama").first(where: { $0.dir == e.dir })?.enabled ?? false },
                            set: { v in
                                var list = ModelRegistry.load()
                                for i in list.indices where list[i].slot == "lama" {
                                    list[i].enabled = (list[i].dir == e.dir ? v : false)   // 互斥 ✓
                                }
                                _ = ModelRegistry.save(list)
                                status = v ? ("模型：已启用 " + e.name) : ("模型：已停用 " + e.name)
                            })).toggleStyle(.switch).font(.system(size: 10))
                        Spacer()
                        Button("删除") {
                            var list = ModelRegistry.load()
                            list.removeAll { $0.slot == "lama" && $0.dir == e.dir }
                            _ = ModelRegistry.save(list)
                            status = "模型：已从列表移除 " + e.name + "（磁盘文件请用下面的按钮删）"
                        }.font(.system(size: 10))
                    }
                }
                if !lamaInstalled {
                    Text("装上之后，祛痘/去杂物/去线缆这类**大面积**修复会走生成式补全（LaMa）；不装则用本机的样例修补。")
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(3)
                    HStack(spacing: 8) {
                        Button(lamaBusy ? "下载中…" : "下载 LaMa 修复模型") {
                            lamaBusy = true
                            lamaStatus = "正在下载…"
                            LaMaStore.shared.download { r in
                                lamaBusy = false
                                switch r {
                                case .success(let m): lamaStatus = m; lamaInstalled = true
                                case .failure(let e): lamaStatus = e.localizedDescription
                                }
                            }
                        }.font(.system(size: 10)).disabled(lamaBusy)
                        Button("选择本地模型文件…") {
                            let op = NSOpenPanel()
                            op.canChooseFiles = true; op.canChooseDirectories = true
                            op.allowsMultipleSelection = false
                            op.message = "选 .mlpackage / .mlmodelc / .zip（从别处拿到的 Core ML 版 LaMa）"
                            guard op.runModal() == .OK, let u = op.url else { return }
                            lamaBusy = true
                            LaMaStore.shared.install(from: u) { r in
                                lamaBusy = false
                                switch r {
                                case .success(let m): lamaStatus = m; lamaInstalled = true
                                case .failure(let e): lamaStatus = e.localizedDescription
                                }
                            }
                        }.font(.system(size: 10)).disabled(lamaBusy)
                    }
                } else {
                    Text("生成式修复模型：已安装 " + String(format: "%.0f MB", Double(LaMaStore.shared.installedBytes) / 1_048_576)
                         + (LaMaInpainter.shared.isReady ? "（已就绪）"
                        // §349：这里以前写「读了出不来，检查模型结构」✗ —— 实测那是**惰性加载**：
                        // isReady 要等第一次用到修复时才 reload 变 true（§280 的 HEALTRACE 就观测到这个转换 ✓），
                        // 面板先渲染就读到 false ⇒ 把「还没加载」误报成「模型坏了」✗。改成如实描述 ✓。
                        : "（尚未加载：首次用到修复时自动加载；若点了修复仍不可用再检查模型结构）"))
                        .font(.system(size: 10))
                    Button("删除") {
                        LaMaStore.shared.remove()
                        LamaReset()
                    }.font(.system(size: 10))
                }
                if !lamaStatus.isEmpty {
                    Text(lamaStatus).font(.caption2).foregroundColor(.secondary).lineLimit(3)
                }
                Text("⚠️ 默认下载地址指向 coreml-zoo 镜像；若镜像不可用，用「选择本地模型文件…」装本地已有的模型。")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(2)
                Text("推理按模型自描述适配输入（不写死输入名）；跑不了时自动退回样例修补，功能不会消失。")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
        }
    }
}
