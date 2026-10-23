// Home.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    // MARK: 主页层（照像素蛋糕：导入大卡片 + 快捷功能行 + 项目列表）
    var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("主页").font(.system(size: 20, weight: .semibold))
                // 导入大卡片
                Button {
                    pickFolderAndBatch()
                    module = "精修"
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 26))
                            .frame(width: 54, height: 54)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.15)))
                        Text("导入照片").font(.system(size: 15, weight: .medium))
                        Text("点击选择文件夹（像素蛋糕这里是拖入或点击导入）").font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 34)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.04)))
                }.buttonStyle(.plain)

                // 快捷功能行（只列我们真有的）
                Text("快捷功能").font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    quickCard("参考组追色", "wand.and.stars") { module = "精修"; panel = 0 }
                    quickCard("AI 挑图", "chart.bar.doc.horizontal") { module = "精修"; panel = 5; runPick() }
                    quickCard("去瑕疵/磨皮", "bandage") { module = "精修"; panel = 4 }
                    quickCard("裁剪旋转", "crop.rotate") { module = "精修"; panel = 7 }
                    quickCard("历史与回滚", "clock.arrow.circlepath") { module = "精修"; panel = 2 }
                }

                // 项目卡片（像素蛋糕显示「已修 N 张 / 共 M 张」）
                // §251：默认只显示**最近 5 个**，其余折叠（用户要求）；旁边加「新建项目」。
                HStack(spacing: 8) {
                    Text(projects.count > 5 ? "项目（最近 5 个 / 共 \(projects.count) 个）" : "项目（共 \(projects.count) 个）")
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    if projects.count > 5 {
                        Button(showAllProjects ? "收起" : "展开全部（\(projects.count) 个）") { showAllProjects.toggle() }
                            .font(.system(size: 11)).fixedSize()
                    }
                }
                // 新建项目：可设项目名 + 选目录；导入照片仍走批量入口（两边共用同一份 ProjectStore）
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 13)).foregroundColor(.secondary)
                    TextField("新项目名称（留空则用目录名）", text: $newProjectName)
                        .textFieldStyle(.roundedBorder).frame(width: 220).font(.system(size: 11))
                    Button("选择目录并新建") { createProject() }.font(.system(size: 11)).fixedSize()
                    Button("导入照片（批量）") { pickFolderAndBatch() }.font(.system(size: 11)).fixedSize()
                    Spacer(minLength: 0)
                }
                if projects.isEmpty {
                    Text("还没有项目。上面「选择目录并新建」建一个，或直接「导入照片（批量）」——跑完会自动登记一条。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // §247：原来是横向 HStack + 固定宽 190 的卡片 ⇒ 项目一多就**冲出窗口右边缘**
                    //（用户截图里第 7 张被切，就是这里）。改成自适应网格：放不下自动换行，
                    // 每行张数随窗口宽度变，永远不会被切。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        ForEach(Array((showAllProjects ? projects : Array(projects.prefix(5))).enumerated()), id: \.offset) { _, p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name ?? URL(fileURLWithPath: p.path).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("已修 \(p.done) 张 / 共 \(p.total) 张").font(.system(size: 11)).foregroundColor(.secondary)
                                Text(p.updated.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 9)).foregroundColor(.secondary)
                                Text(p.path).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.04)))
                        }
                    }
                }
                // 回收站（本地实现：移进去能恢复，清空才是真删）
                HStack {
                    Text("回收站（本地）").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(trashItems.count) 项 · " + String(format: "%.1f MB", Double(LocalTrash.sizeBytes()) / 1_048_576))
                        .font(.caption).foregroundColor(.secondary)
                    Button("打开目录") { NSWorkspace.shared.open(LocalTrash.dir) }.font(.system(size: 11))
                    Button("清空") { emptyTrash() }.font(.system(size: 11)).disabled(trashItems.isEmpty)
                }
                if trashItems.isEmpty {
                    Text("空的。底部缩略图条上选几张点「移入回收站」，原片不会真删。")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ForEach(trashItems.prefix(6)) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 11)).lineLimit(1)
                                Text(item.originalPath).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                                Button("恢复") { restoreFromTrash(item) }.font(.system(size: 10))
                            }
                            .frame(width: 200, alignment: .leading).padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
                        }
                    }
                }
                Spacer(minLength: 20)
                // §247：创意原来在图库页只有一行小字 ⇒ 用户找不到「功能在哪」。改成可点入口，
                // 点进去是诚实的逐条占位页（说明每条需要什么），不是坏按钮。
                Text("创意（生成式）").font(.system(size: 13, weight: .medium))
                Button { module = "创意" } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 14)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("创成式填充 / 换装 / 换天 / 拉龄 / 祛路人 / AI 点修")
                                .font(.system(size: 12, weight: .medium))
                            Text("本机没有生成式模型 ⇒ 进去逐条看需要什么（诚实占位）")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text("进入").font(.system(size: 10)).fixedSize()
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
                }.buttonStyle(.plain)
            }
            .padding(24)
        }
    }

    /// 创意模块页（§246）：生成式功能本机做不了，但入口必须稳定可见、逐条说明需要什么。
    /// 原状是「点创意只出一句状态、module 都不切」⇒ 用户看到的就是时隐时现 / 没有这个功能。
    var creativeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("创意（生成式）").font(.system(size: 20, weight: .semibold))
                Text("这些功能需要生成式模型（扩散 / 大模型），本机没有、也没有云端接口。逐条列出需要的条件，避免「看起来有、点不动」。")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                creativeRow("创成式填充", "wand.and.rectangle", "需要扩散模型 + 区域掩膜；本机没有模型也没有云端接口")
                creativeRow("更换服装", "tshirt", "需要服装分割 + 生成模型；服装分割可做，生成部分做不了")
                creativeRow("一键换天", "cloud.sun", "天空/背景分割已有（解析类里有背景），生成新天空需要生成模型")
                creativeRow("拉龄 / 变老", "face.smiling", "需要年龄编辑生成模型（本机没有）")
                creativeRow("祛除路人", "person.crop.circle.badge.xmark", "需要实例分割 + 修复生成；修复本身已有（污点/仿制），生成部分没有")
                creativeRow("AI 点修", "sparkles", "需要点选交互 + 图像修复生成模型")
                Spacer(minLength: 10)
                Text("这些条目在精修页的「待开发」面板里也逐条列着（同一份口径）。")
                    .font(.caption2).foregroundColor(.secondary)
            }.padding(24)
        }
    }

    /// 创意条目行（不用元组 + ForEach：Swift 的元组键路径不可用，用小函数更稳）
    func creativeRow(_ name: String, _ icon: String, _ needs: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12, weight: .medium))
                Text(needs).font(.system(size: 10)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text("未实现").font(.system(size: 9)).foregroundColor(.secondary).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
    }

    /// 回收站面板（§246）：原来回收站只挂在首页（一导入就 module=精修 走了）⇒ 看起来时隐时现。
    /// 现在窄栏有常驻入口（面板 18），进面板时重新读一次本地回收站，状态不会旧。
    var trashPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("回收站（本地，可恢复）").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(trashItems.count) 项").font(.caption).foregroundColor(.secondary).fixedSize()
                    Button("打开目录") { NSWorkspace.shared.open(LocalTrash.dir) }.font(.system(size: 11)).fixedSize()
                    Button("清空") { emptyTrash() }.font(.system(size: 11)).disabled(trashItems.isEmpty).fixedSize()
                }
                if trashItems.isEmpty {
                    Text("空的。底部缩略图条上选几张点「移入回收站」，原片不会真删。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(trashItems) { item in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.system(size: 11)).lineLimit(1)
                                Text(item.originalPath).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("恢复") { restoreFromTrash(item) }.font(.system(size: 10)).fixedSize()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.04)))
                    }
                }
            }.padding(12)
        }
        .onAppear { reloadTrash() }
    }

    /// §251：新建项目 —— 只登记「名字 + 目录」，张数等这个目录跑过批量再更新。
    /// 不新建别的数据模型：项目就是 ProjectStore 里的一条（持久化到 Application Support）。
    func createProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "选择这个项目的照片目录（项目会记住它）"
        panel.prompt = "作为项目目录"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        let typed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = typed.isEmpty ? u.lastPathComponent : typed
        projects = ProjectStore.create(path: u.path, name: finalName)
        newProjectName = ""
        status = "已新建项目「\(finalName)」（目录 \(u.path)）；点「导入照片（批量）」跑完会更新已修张数"
    }

    func quickCard(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 18))
                Text(title).font(.system(size: 11))
            }
            .frame(width: 110, height: 78)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
        }.buttonStyle(.plain)
    }

    // MARK: 顶栏
    var topBar: some View {
        HStack(spacing: 12) {
            Text("智能修图").font(.headline)
            Divider().frame(height: 16)
            // 像素蛋糕的顶栏是三个模块标签，当前只有「精修」有内容，其余标灰占位
            ForEach(["图库", "精修", "创意"], id: \.self) { m in
                Button {
                    // #1：以前只有「精修」能点，图库/创意一律弹一句"还没做"——连首页都回不去。
                    // 现在「图库」真的切过去（首页层已经做好了），只有创意是生成式模块，如实占位。
                    switch m {
                    // §246：创意原来点了只出一句提示、连 module 都不切 ⇒ 看起来像功能缺失。现在它有真页面。
                    case "图库", "精修", "创意": module = m
                    default: status = "「创意」是生成式模块（换装/换天/创成式填充/拉龄…），本机做不了，见「待开发」页"
                    }
                } label: {
                    Text(m).font(.system(size: 12, weight: module == m ? .semibold : .regular))
                        .foregroundColor(module == m ? .accentColor : .secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(module == m ? Color.accentColor.opacity(0.12) : Color.clear))
                }.buttonStyle(.plain)
            }
            Spacer()
            // 搜索（像素蛋糕的「搜索功能」）：输入面板/功能名，回车跳过去
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
                TextField("搜索功能…", text: $search)
                    .textFieldStyle(.plain).frame(width: 120).font(.system(size: 11))
                    .onSubmit { jumpToSearch() }
                    .help("按 ⌘F 或点这里才能输入；打开 App 时不会自动聚焦")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
            if !styles.isEmpty {
                Text("参考组：\(currentStyle.name)").font(.caption).foregroundColor(.secondary)
            }
            Button { showShortcuts.toggle() } label: { Image(systemName: "keyboard") }
                .popover(isPresented: $showShortcuts, arrowEdge: .bottom) { shortcutHelp }
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command).disabled(history.isEmpty)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redoStack.isEmpty)
            Button { pickFolderAndBatch() } label: { Label("导入并批量导出", systemImage: "square.and.arrow.down") }
                .disabled(busy)
            // 导出设置搬到**右上角这个按钮的弹窗**里（用户要求）：点它弹出原来右侧那个导出面板，
            // 面板底部直接有「导出当前图 / 批量导出目录」两个按钮，设置完就能出片。
            Button { showExportPopover.toggle() } label: { Label("导出", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(busy)
                .popover(isPresented: $showExportPopover, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        exportPanel.frame(width: 330, alignment: .leading)
                        Divider()
                        HStack(spacing: 8) {
                            Button {
                                showExportPopover = false
                                exportSingle()
                            } label: { Label("导出当前图", systemImage: "photo") }
                                .disabled(srcURL == nil || busy)
                            Button {
                                showExportPopover = false
                                exportFolder()
                            } label: { Label("批量导出目录…", systemImage: "folder") }
                                .disabled(busy)
                            Spacer()
                        }
                    }
                    .padding(12)
                }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// 画布上那个半径滑杆要控制**当前工具自己的半径**：污点/修补·仿制/液化各有一套
    ///（原来只绑到液化那一个，改污点半径时滑杆动的是别的值，等于没接对）
    var activeRadius: Binding<Double> {
        if spotActive { return $spotRadius }
        if patchActive || cloneActive { return $cloneRadius }
        return $brushRadius
    }

    var activeRadiusPercent: Double {
        if spotActive { return spotRadius }
        if patchActive || cloneActive { return cloneRadius }
        return brushRadius
    }

    /// 交互诊断：CR_DIAG=1 时把「工具切换 / 画布拖动」写到 stderr。
    /// 用来判断"点了没反应"到底是**按钮没触发**还是**拖动没到画布**（命令行里看不见界面，只能靠日志）。
    var diagLog: Bool { ProcessInfo.processInfo.environment["CR_DIAG"] == "1" }

    /// 当前是否显示修后效果（按住看原图时会临时变成 false）
    var showingEffect: Bool { showEffect && !holdingOriginal }

    /// 侧身折扣：0° → 1.0（照做），90° → 0.25（几乎不做）。
    /// 为什么需要：收腰/宽肩都是**横向位移**，身体转到侧面时左右肩在画面里几乎重合，
    /// 硬推就会把身体推歪。这是有物理依据的取舍，不是拍脑袋的保险。
    var bodyDeformFactor: Double {
        guard bodyYaw.ok else { return 1 }
        return max(0.25, abs(cos(bodyYaw.yaw * .pi / 180)))
    }

    /// 朝向的文字说明（界面直接显示，让用户知道为什么效果变弱了）
    var bodyYawText: String {
        guard bodyYaw.ok else { return "未检出人体（全身美型不额外折算）" }
        let a = abs(bodyYaw.yaw)
        let side = a < 25 ? "正面" : (a < 55 ? "略侧身" : "大侧身")
        return String(format: "%@ %.0f°｜收腰/宽肩按 %.2f 折算", side, bodyYaw.yaw, bodyDeformFactor)
    }

    /// 裁剪比例（nil = 自由拖）。"原比例" 用图片自身的宽高比。
    func cropRatio(for imageSize: CGSize) -> Double? {
        switch cropShape {
        case 1: return 1.0
        case 2: return 4.0 / 5.0
        case 3: return 3.0 / 4.0
        case 4: return 16.0 / 9.0
        case 5: return imageSize.height > 1 ? Double(imageSize.width / imageSize.height) : nil
        default: return nil
        }
    }

    /// 归一化半径的「最小间距」（防止一笔下去生成几十个落点）
    func spacing(_ percentRadius: Double) -> Double { max(0.004, percentRadius / 100.0 * 0.4) }

    var cropAspectValue: Double {
        switch cropAspect {
        case "1:1": return 1.0
        case "4:5": return 0.8
        case "3:4": return 0.75
        case "16:9": return 16.0 / 9.0
        default: return 0
        }
    }

    /// 智能裁剪：按显著性主体 + 目标比例算裁剪框（三分法落点，主体优先保证完整）
    func runSmartCrop() {
        guard let u = srcURL, let img = loadAnyImage(u.path, maxDim: 0),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { return }
        let e = img.extent
        let sal = detectSaliency(cg)
        let subject = sal?.subject ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        var aspect = cropAspectValue
        if aspect < 0.01 { aspect = Double(e.width / e.height) }
        let rect = smartCropRect(imageSize: e.size, aspect: aspect, subject: subject, placement: cropPlacement)
        cropRect = CGRect(x: rect.minX / e.width, y: rect.minY / e.height,
                          width: rect.width / e.width, height: rect.height / e.height)
        pushHistory("智能裁剪 " + cropAspect)
        refresh()
        let conf = sal.map { String(format: "%.2f", $0.confidence) } ?? "—"
        // 主体比裁剪框还大时不可能两全：如实说出来，别让用户以为裁歪了
        let subjectPx = CGRect(x: subject.minX * e.width, y: subject.minY * e.height,
                               width: subject.width * e.width, height: subject.height * e.height)
        let fits = rect.contains(subjectPx)
        status = String(format: "智能裁剪：主体 x%.2f y%.2f w%.2f h%.2f（置信度 %@）→ %dx%d %@",
                        subject.minX, subject.minY, subject.width, subject.height, conf,
                        Int(rect.width), Int(rect.height), cropPlacement == "thirds" ? "三分法落点" : "居中落点")
            + (fits ? "，主体完整" : "；⚠️ 这个比例装不下整个主体，已按主体中心对齐（换更接近原图的比例可完整）")
    }

    /// 场景识别 → 推荐一套起点参数（依据会被打印出来，不假装是官方预设映射）
    func runSceneSuggest() {
        guard let u = srcURL, let img = loadAnyImage(u.path, maxDim: 900),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { return }
        let info = classifyScene(cg)
        sceneInfo = info
        let sug = suggestParams(for: info)
        portrait = mergePortrait(sug.portrait)
        skinGrade = sug.skinGrade
        skinTone = sug.skinTone
        texturePreserve = sug.texturePreserve
        sharpenAmount = sug.extras["sharpen"] ?? 0
        denoiseAmount = sug.extras["denoise"] ?? 0
        vignetteAmount = sug.extras["vignette"] ?? 0
        bgPurify = sug.extras["bgPurify"] ?? 0
        bgBlur = sug.extras["bgBlur"] ?? 0
        lensVignette = sug.extras["lensVignette"] ?? 0
        lensDistortion = sug.extras["lensDistortion"] ?? 0
        refresh()
        pushHistory("场景推荐：" + info.category)   // 记"改动后"
        status = "识别为「\(info.category)」→ 已套用推荐参数（" + sug.reasons.joined(separator: "；") + "）"
    }

    /// 懒加载人物实例：只在「按人处理」真正用到时才跑分割（分割本身约 0.1~0.2 s）
    @discardableResult
    func ensurePersons() -> [(rect: CGRect, mask: CIImage)] {
        guard let u = srcURL, let img = workImage() else { return [] }
        if personCacheURL == u, !personCache.isEmpty { return personCache }
        let list = personInstanceMasks(img)
        personCache = list
        personCacheURL = u
        personRects = list.map { p in
            let e = img.extent
            return CGRect(x: p.rect.minX / e.width, y: p.rect.minY / e.height,
                          width: p.rect.width / e.width, height: p.rect.height / e.height)
        }
        if personSkin.count != list.count {
            personSkin = Array(repeating: 0.0, count: list.count)
        }
        return list
    }

    /// 肩线校平：量出肩线倾角，把旋转角设成它的负值
    func levelShoulders() {
        guard let img = workImage(), let cg = sharedCtx.createCGImage(img, from: img.extent) else { return }
        guard let tilt = shoulderTilt(cg, extent: img.extent) else {
            status = "这张图没检出双肩，肩线校平不可用"
            return
        }
        rotateDeg = max(-10, min(10, -tilt))
        refresh()
        pushHistory("肩线校平")     // 记"改动后"（写在前面就记成改之前 → 撤销原地不动）
        status = String(format: "肩线倾角 %.1f° → 反向旋转 %.1f° 校平", tilt, rotateDeg)
    }

    /// 按人物实例裁剪（合影里抠出某一个人的半身像）
    func detectPersons() {
        personCacheURL = nil              // 强制重算
        let persons = ensurePersons()
        status = persons.isEmpty ? "没有分割出人物实例" : "分割出 \(persons.count) 个人物实例（可分别给强度）"
    }

    func cropToPerson(_ i: Int) {
        guard i < personRects.count, let img = workImage() else { return }
        let e = img.extent
        let r = smartCropRect(imageSize: e.size, aspect: 3.0 / 4.0, subject: personRects[i], placement: "center")
        cropRect = CGRect(x: r.minX / e.width, y: r.minY / e.height,
                          width: r.width / e.width, height: r.height / e.height)
        pushHistory("按人物裁剪 \(i + 1)")
        refresh()
        status = "已裁到第 \(i + 1) 个人（3:4 半身）"
    }

    /// 快捷键指南（像素蛋糕手册里单列了一节「快捷键指南」）
    var shortcutHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("快捷键").font(.headline)
            ForEach(shortcutList, id: \.0) { k, d in
                HStack(spacing: 10) {
                    Text(k).font(.system(size: 11, design: .monospaced))
                        .frame(width: 62, alignment: .leading)
                    Text(d).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Divider()
            Text("画布上：滚轮/抓手平移，拖动画笔时按当前工具模式（向前变形/左推/膨胀/收缩/褶皱/旋转/平滑/冻结）生效。")
                .font(.caption2).foregroundColor(.secondary).frame(width: 250)
        }.padding(14)
    }

    var shortcutList: [(String, String)] {
        [("H", "抓手"), ("[ ]", "笔刷调小 / 调大"), ("⌘Z", "撤销"), ("⇧⌘Z", "重做"), ("⌘E", "导出当前图"), ("⇧⌘E", "批量导出目录"),
         ("⌘O", "导入照片（可多选，也可选文件夹）"), ("⌘D", "同上"), ("← →", "上一张 / 下一张"), ("⌘S", "存为虚拟副本"),
         ("⌘F", "跳到搜索框"), ("⌘0", "适应窗口"), ("⌘+", "放大"), ("⌘-", "缩小"),
         ("⌘1", "人像面板"), ("⌘2", "导出面板"), ("⌘3", "历史面板")]
    }

    /// 隐藏的快捷键承载按钮（SwiftUI 里 keyboardShortcut 必须有控件挂着）
    var shortcutHost: some View {
        Group {
            Button("") { importItems() }.keyboardShortcut("o", modifiers: .command).hidden()
            Button("") { importItems() }.keyboardShortcut("d", modifiers: .command).hidden()
            Button("") { exportFolder() }.keyboardShortcut("e", modifiers: [.command, .shift]).hidden()
            Button("") { saveVersion() }.keyboardShortcut("s", modifiers: .command).hidden()
            Button("") { zoom = 0; refresh() }.keyboardShortcut("0", modifiers: .command).hidden()
            // [ / ] 调笔刷半径（修图软件的通用习惯；#2 要的「自由调整大小」）
            Button("") { brushRadius = min(20, brushRadius + 0.5)
                status = String(format: "笔刷半径 %.1f%%", brushRadius) }
                .keyboardShortcut("[", modifiers: []).hidden()
            Button("") { brushRadius = max(0.2, brushRadius - 0.5)
                status = String(format: "笔刷半径 %.1f%%", brushRadius) }
                .keyboardShortcut("]", modifiers: []).hidden()
            Button("") { zoom = min(400, max(10, (zoom == 0 ? 100 : zoom) + 25)); refresh() }
                .keyboardShortcut("+", modifiers: .command).hidden()
            Button("") { zoom = max(10, (zoom == 0 ? 100 : zoom) - 25); refresh() }
                .keyboardShortcut("-", modifiers: .command).hidden()
            // H = 抓手（修图软件的通用习惯）
            Button("") { setCanvasTool("hand") }.keyboardShortcut("h", modifiers: []).hidden()
            Button("") { module = "精修"; panel = 3 }.keyboardShortcut("1", modifiers: .command).hidden()
            Button("") { module = "精修"; panel = 11 }.keyboardShortcut("2", modifiers: .command).hidden()
            Button("") { module = "精修"; panel = 2 }.keyboardShortcut("3", modifiers: .command).hidden()
        }
    }

    /// 搜索：按名字跳到对应面板（像素蛋糕的搜索功能）
    func jumpToSearch() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let table: [(String, [String], Int)] = [
            ("预设/参考组", ["预设", "风格", "参考组", "追色", "preset", "style"], 0),
            ("后调色", ["调色", "曲线", "色阶", "饱和", "色彩平衡", "局部追色", "color"], 1),
            ("历史/撤销", ["历史", "撤销", "重做", "回滚", "history", "undo"], 2),
            ("人像", ["人像", "磨皮", "祛斑", "祛痘", "祛痣", "油光", "汗孔", "黑眼圈", "眼袋",
                     "唇纹", "双下巴", "下颌", "牙齿", "眼睛", "妆容", "唇色", "腮红", "瘦脸",
                     "大眼", "鼻翼", "下巴", "额头", "手部", "脚部", "液化", "重塑", "portrait"], 3),
            ("挑图", ["挑图", "选片", "评分", "星级", "pick"], 5),
            ("待开发", ["待开发", "占位", "做不了", "生成式", "换装", "换天", "拉龄"], 6),
            ("裁剪旋转", ["裁剪", "旋转", "翻转", "祛边", "参考线", "crop"], 7),
            ("衣物", ["衣物", "平整", "褶皱", "clothes"], 8),
            ("图像", ["图像", "背景", "纯化", "分割", "bg"], 9),
            ("宠物", ["宠物", "动物", "pet", "animal"], 10),
            ("导出", ["导出", "格式", "质量", "水印", "位深", "色彩空间", "重命名", "export"], 11),
            ("自动/智能", ["自动白平衡", "白平衡", "智能锐化", "高光", "补光", "光向", "自动曝光", "自动摆正", "摆正", "水平", "自动肤色", "肤色", "auto"], 1)
        ]
        for (name, keys, idx) in table {
            if keys.contains(where: { $0.localizedCaseInsensitiveContains(q) || q.localizedCaseInsensitiveContains($0) }) {
                module = "精修"; panel = idx
                status = "搜索「\(q)」→ \(name)"
                return
            }
        }
        status = "没找到「\(q)」：可以试 磨皮 / 祛斑 / 裁剪 / 导出 / 挑图"
    }

    func fitAll() { refresh() }
}
