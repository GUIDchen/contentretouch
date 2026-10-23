// Export.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    // MARK: 底栏
    var bottomBar: some View {
        VStack(spacing: 4) {
            // 缩略图条（像素蛋糕底部就是这条：缩略图 + 星级 + 已选张数）
            if !strip.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    // LazyHStack 是关键：普通 HStack 会把 13485 个子视图全部建出来，
                    // 每个子视图里还各自解一次图 → 内存直接失控（实测 3.17 GB 且持续上涨）。
                    LazyHStack(spacing: 6) {
                        ForEach(strip, id: \.self) { u in
                            let on = selectedStrip.contains(u)
                            VStack(spacing: 2) {
                                if let t = ThumbCache.shared.image(u) {
                                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 54, height: 54).clipped()
                                        .cornerRadius(4)
                                        .overlay(RoundedRectangle(cornerRadius: 4)
                                            .stroke(on ? Color.accentColor : Color.black.opacity(0.15), lineWidth: on ? 2 : 1))
                                }
                                if let s = stars[u] {
                                    Text(String(repeating: "★", count: s) + String(repeating: "☆", count: max(0, 5 - s)))
                                        .font(.system(size: 7)).foregroundColor(.orange).lineLimit(1)
                                } else {
                                    Text(u.lastPathComponent.prefix(6))
                                        .font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                                }
                            }
                            .onTapGesture {
                                if on { selectedStrip.remove(u) } else { selectedStrip.insert(u) }
                                switchToImage(u)
                                // 星级 = 挑图总分映射到 1~5 星（首次点击时算一次，结果缓存）
                                if stars[u] == nil, let sc = scoreImage(u.path) {
                                    stars[u] = max(1, min(5, Int((sc.total / 60.0 * 5).rounded())))
                                }
                            }
                        }
                    }.padding(.horizontal, 10).padding(.top, 6)
                }.frame(height: 76)
            }
            HStack(spacing: 12) {
                Button("载入示例") { loadSample() }
                Button("导入照片…（可多选）") { importItems() }
                Button("导入并批量导出…") { importItems(); status += "；导完点右上「导出」开始批量" }.disabled(busy)
                Button("只看选中") { if let u = selectedStrip.first { switchToImage(u) } }.disabled(selectedStrip.isEmpty)
                Button("同步到选中图片") { applyToSelected() }.disabled(strip.isEmpty || busy)
                Button("移入回收站") { moveSelectedToTrash() }.disabled(selectedStrip.isEmpty)
                Spacer()
                Text(strip.isEmpty ? "已选 0 张" : "已选 \(selectedStrip.count) 张（共 \(strip.count) 张）")
                    .font(.caption).foregroundColor(.secondary).fixedSize()
                // 看效果开关：去掉文字标签（"看效果" 三个字会跟右边的状态文字压在一起——
                // #3 报的遮挡就是这个），只留开关 + 一个小眼睛图标
                HStack(spacing: 4) {
                    Image(systemName: showEffect ? "eye" : "eye.slash").font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Toggle("", isOn: $showEffect).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        .onChange(of: showEffect) { _, _ in refresh() }
                }.fixedSize()
                // 状态文字：给一个明确的上限并允许省略，绝不与左边抢位置
                Text(status).font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 420, alignment: .trailing)
                    .layoutPriority(-1)
            }.padding(.horizontal, 14).padding(.vertical, 6)
        }
    }

    /// 原来的「选文件夹并批量导出」：改成同一个导入入口，再按用户选择决定要不要立刻批量
    func pickFolderAndBatch() {
        importItems()
    }

    /// 指定目录直接批量导出（不弹选择框）
    func exportFolderAt(_ dir: URL) {
        guard !busy else { return }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
        // ⚠️ 空目录必须**同时写 stderr**：批量的两个入口都从这里走，而无头自检（--run=export:<dir>）
        // 只能看日志。只写状态栏的话，"指错了目录"在自动化里会表现成"静默成功"——
        // 这一轮就是这么被骗了二十分钟（把"目录里没有图"当成了"导出卡死"）。
        guard !files.isEmpty else {
            status = "这个目录里没有可导出的图"
            FileHandle.standardError.write("没有可导出的图：这个目录里没有图片文件（未导出任何东西）\n".data(using: .utf8)!)
            return
        }
        runExport(files: files, dir: dir)
    }

    // MARK: 导出
    func exportSingle() {
        guard let u = srcURL, let full = loadAnyImage(u.path, maxDim: 0) else {
            status = "没有可导出的原片"
            return
        }
        let panel0 = NSSavePanel()
        panel0.nameFieldStringValue = exportName(export.nameTemplate, source: u.path, index: export.startIndex) + "." + export.fileExtension
        guard panel0.runModal() == .OK, let dst = panel0.url else { return }
        let t0 = Date()
        // 水印"配了但用不了"要**当场说出来**：LOGO 路径写错/文件被移走时，
        // 原来会静默地不打水印并报成功（§177）—— 交付场景下这是最坏的一种失败。
        let wmTrouble = watermarkTrouble(export)
        if let t = wmTrouble {
            status = "⚠️ " + t
            // 同时写一行到 stderr：界面状态栏人看得见，但自检与门**只能看日志** ——
            // 只写状态栏的话，这条"静默失败"在自动化里仍然不可见（这正是它当初能藏住的原因）。
            FileHandle.standardError.write(("⚠️ " + t + "\n").data(using: .utf8)!)
        }
        var out = renderPipeline(full)
        if !export.watermarkText.isEmpty || !export.watermarkImagePath.isEmpty {
            out = applyWatermark(out, export, sourceName: u.path)
        }
        let ok = exportImage(out, to: dst, export, sourceURL: u)
        let dt = Date().timeIntervalSince(t0)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        exportStats = String(format: "单张 %.2f s，%.1f MB，%d×%d %@", dt, Double(bytes) / 1_048_576,
                             Int(out.extent.width), Int(out.extent.height), export.colorSpace)
            + (wmTrouble.map { " ｜ ⚠️ " + $0 } ?? "")
        status = ok ? "已导出：\(dst.path)" : "导出失败"
    }

    /// 批量导出：选目录
    func exportFolder() {
        let panel0 = NSOpenPanel()
        panel0.canChooseDirectories = true
        panel0.canChooseFiles = false
        guard panel0.runModal() == .OK, let dir = panel0.url else { return }
        exportFolderAt(dir)
    }

    /// 批量导出主体：每张走「调色闭环 + 人像 + 皮肤 + 水印 + 导出设置」
    func runExport(files fileURLs: [URL], dir: URL) {
        guard !busy else { return }
        let files = fileURLs
        let outDir = dir.appendingPathComponent("retouched")
        // 水印"配了但用不了"要**在开跑前就说出来**（LOGO 路径写错/文件被移走时，
        // 原来会静默不打水印、报"导出完成"，产物与"没设水印"一模一样 —— §177）。
        // 放在这里是因为**两条批量入口都经过它**（导出目录… / 指定目录直接导出），一处覆盖全部。
        let wmTrouble = watermarkTrouble(export)
        if let t = wmTrouble {
            status = "⚠️ " + t
            // 同时写一行到 stderr：界面状态栏人看得见，但自检与门**只能看日志** ——
            // 只写状态栏的话，这条"静默失败"在自动化里仍然不可见（这正是它当初能藏住的原因）。
            FileHandle.standardError.write(("⚠️ " + t + "\n").data(using: .utf8)!)
        }
        busy = true; progress = 0; exportProgress = 0; exportCancel = false; records = []
        let style = currentStyle
        let settings = export
        let workers = exportWorkers
        _ = settings.self     // 说明：上面那句 wmTrouble 用的是同一份 export（此时还没被 settings 遮蔽）
        // **必须在主线程取的整条管线快照**：导出闭包跑在后台线程，不能读 @State。
        // 它涵盖调色、皮肤、人像、影调补充、镜头校正、手动编辑——
        // 也就是 renderPipeline 用到的**全部**输入（见 PipelineConfig 的说明）。
        var exportCfg = pipelineConfigNow()
        exportCfg.faces = []            // 导出走全分辨率：关键点由管线内部重新检测
        exportCfg.cachedGeos = []
        exportCfg.perFace = [:]         // 逐脸参数按整图重新走「全局 + 逐脸」（预览里的脸索引与全分辨率不同）
        exportCfg.personSkin = []       // 逐人磨皮需要按全分辨率重新分割，这里不参与（如实标注）
        let cfg = exportCfg
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let res = exportBatch(files: files.map { $0.path }, outDir: outDir.path, settings, makeImage: { path in
                guard let ci0 = loadAnyImage(path, maxDim: 0) else { return nil }
                // **整条管线走同一份实现**：以前这里是一份"私有链"，只跟了一部分步骤，
                // 结果是裁剪/液化/祛痘/换天空/降噪/锐化/暗角/颗粒/镜头校正……全都没做。
                // 现在把主线程取好的快照喂进去，预览做什么、导出就做什么。
                let s0 = measure(ci0)
                var c = cfg
                // ⚠️ 本图自适应曝光**只在真的有调色目标时才做**（§207）：
                // 它存在的理由是服务下面的 closedLoop，而闭环在没有目标时本来就会被跳过（§194）。
                // 两者不同进同出会留下一个说不通的后果：用户什么都没改、导出却比源**亮 8%~12%**
                //（§206 三个夹具实测：+8.3% / +10.1% / +12.1%），这直接顶在"原图无损"的字面承诺上。
                let hasTarget = style.target.p50 > 1 || style.target.p95 > 1
                if hasTarget {
                    let over = max(0, s0.p50 - 120)
                    c.params.gamma = max(1.0, c.params.gamma - over * 0.001)
                    c.params.brightness = max(0, 5 - over * 0.10)
                }
                // 调色闭环：按这张图自己的分布朝目标收敛（预览在 refresh 里用的是同一套参数与目标）
                let (bp, _, _, _) = closedLoop(ci0, base: c.params, target: style.target, iterations: 3)
                c.params = bp
                // 全分辨率上自己检一次脸：这样「逐脸提亮/暖冷」在导出时也能按同一套脸序对上
                // （预览的脸序来自降采样图，Vision 对同一张图的排序是一致的，所以下标能对上）
                if let cgTmp = sharedCtx.createCGImage(ci0, from: ci0.extent) {
                    let geos = detectFaceGeos(cgTmp, size: ci0.extent.size)
                    let e = ci0.extent
                    c.cachedGeos = geos
                    c.faces = geos.map { g in
                        FaceInfo(index: g.index,
                                 rect: CGRect(x: g.box.minX / e.width, y: g.box.minY / e.height,
                                              width: g.box.width / e.width, height: g.box.height / e.height),
                                 quality: g.quality, geo: g)
                    }
                    return renderPipeline(ci0, geos: geos, cfg: c)
                }
                return renderPipeline(ci0, geos: nil, cfg: c)
            }, workers: workers, skipExisting: skipExported,
               shouldCancel: { exportCancel },
               progress: { done, total in
                DispatchQueue.main.async {
                    progress = Double(done) / Double(max(1, total))
                    exportProgress = Double(done) / Double(max(1, total))
                    status = "导出中 \(done)/\(total)（点「取消」随时停在已完成的那里）"
                }
            })
            let dt = Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                busy = false; exportCancel = false
                let done = (try? FileManager.default.contentsOfDirectory(atPath: outDir.path))?.count ?? res.written
                projects = ProjectStore.upsert(ProjectRecord(path: outDir.path, done: done, total: files.count))
                exportStats = String(format: "%d 张 %.2f s（%.2f 张/秒，%@，并行 %d，共 %.1f MB）%@",
                                     res.written, dt, Double(res.written) / max(0.001, dt),
                                     settings.format, workers, Double(res.bytes) / 1_048_576,
                                     res.skippedExisting > 0 ? "，跳过已有 \(res.skippedExisting) 张" : "")
                status = res.cancelled
                    ? "已取消：这次出了 \(res.written) 张（已出的都在），再点一次「导出」会从没出的继续"
                    : "导出完成：\(res.written) 张 → \(outDir.path)"
                if selfCheckEcho {
                    FileHandle.standardError.write((status + "｜" + exportStats + "\n").data(using: .utf8)!)
                }
                pushHistory("导出 \(res.written) 张")
            }
        }
    }

    var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("导出图片设置").font(.headline)
            // 断点续跑：一万张的批量跑到一半退出，再点一次只补没出的（不重做已经出好的）
            Toggle("跳过已导出（断点续跑：再点一次只补没出的）", isOn: $skipExported)
                .font(.system(size: 11))
            // 导出体积：按当前设置**真的编一遍**量出来的（不是估算公式）
            HStack(spacing: 6) {
                Text(exportSizeEstimate.isEmpty ? "体积：计算中…" : exportSizeEstimate)
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Button("重新测") { measureExportSize() }.font(.system(size: 9))
            }
            .onAppear { measureExportSize() }
            .onChange(of: export.format) { _, _ in measureExportSize() }
            .onChange(of: export.quality) { _, _ in measureExportSize() }
            .onChange(of: export.maxLongEdge) { _, _ in measureExportSize() }
            .onChange(of: export.bitDepth) { _, _ in measureExportSize() }
            if busy {
                HStack(spacing: 8) {
                    ProgressView(value: exportProgress).frame(width: 140)
                    Text(String(format: "%.0f%%", exportProgress * 100)).font(.caption2).foregroundColor(.secondary)
                    Button("取消") { exportCancel = true }.font(.system(size: 10))
                }
            }
            Text("对应像素蛋糕的「导出」（右上角常驻主操作）").font(.caption).foregroundColor(.secondary)
            Picker("格式", selection: $export.format) {
                Text("JPEG").tag("jpeg"); Text("TIFF").tag("tiff"); Text("PNG").tag("png")
            }.pickerStyle(.segmented)
            if export.format == "jpeg" {
                slider("质量", $export.quality, 60...100, 1) { }
            } else {
                Picker("位深", selection: $export.bitDepth) {
                    Text("8 位").tag(8); Text("16 位").tag(16)
                }.pickerStyle(.segmented)
            }
            Picker("色彩空间", selection: $export.colorSpace) {
                Text("sRGB").tag("sRGB"); Text("Display P3").tag("DisplayP3")
            }.pickerStyle(.segmented)
            Picker("长边", selection: $export.maxLongEdge) {
                Text("原尺寸").tag(0); Text("4096").tag(4096)
                Text("2048").tag(2048); Text("1600").tag(1600); Text("1080").tag(1080)
            }
            TextField("命名模板（{name} {index} {seq} {date}）", text: $export.nameTemplate)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            Divider()
            Text("水印").font(.system(size: 11, weight: .medium))
            TextField("水印文字（空 = 不加，支持 {name}）", text: $export.watermarkText)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            HStack {
                TextField("LOGO 图片路径（PNG 带透明通道最好）", text: $export.watermarkImagePath)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("选…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.png, .jpeg, .image]
                    if p.runModal() == .OK, let u = p.url { export.watermarkImagePath = u.path }
                }.font(.system(size: 11))
                if !export.watermarkImagePath.isEmpty {
                    Button("清除") { export.watermarkImagePath = "" }.font(.system(size: 11))
                }
            }
            if !export.watermarkImagePath.isEmpty {
                slider("LOGO 宽度（占长边比例）", $export.watermarkImageScale, 0.03...0.5, 0.01) { }
            }
            slider("不透明度", $export.watermarkOpacity, 0.05...1, 0.05) { }
            slider("字号（占长边比例）", $export.watermarkScale, 0.01...0.12, 0.005) { }
            Picker("位置", selection: $export.watermarkPosition) {
                Text("右下").tag("bottom-right"); Text("左下").tag("bottom-left")
                Text("右上").tag("top-right"); Text("左上").tag("top-left"); Text("居中").tag("center")
            }.pickerStyle(.menu)
            Divider()
            Text("批量").font(.system(size: 11, weight: .medium))
            Picker("并行度", selection: $exportWorkers) {
                // ⚠️ 别在这里写"1=最省内存 / 8=最快"这类没量过的形容词：实测吞吐只到 4 为止，
                //    8 在 8 核机器上不再变快，内存也不随并行度单调变化。
                Text("1").tag(1); Text("2").tag(2); Text("4").tag(4); Text("8").tag(8)
            }.pickerStyle(.segmented)
            HStack {
                Button("导出当前图…") { exportSingle() }.disabled(srcURL == nil || busy)
                Button("批量导出目录…") { exportFolder() }.disabled(busy)
            }
            if !exportStats.isEmpty {
                Text("上次：\(exportStats)").font(.caption2).foregroundColor(.secondary)
            }
            Divider()
            Text("文字与 LOGO 水印可同时用；位置/透明度共用上面这几个滑杆。").font(.caption2).foregroundColor(.secondary)
            Text("色彩管理：全部读图统一转 sRGB 工作空间再渲染，导出按所选色彩空间打标；RAW 走 CIRAWFilter（非草稿模式）。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }
}
