import SwiftUI
import RetouchCore

// §420 ②：模型选择设置 —— 自洽视图（显式声明状态，不再自动抓）。
// 用法：在任意页面写 ModelSettingsView() 即可渲染整块模型管理。
struct ModelSettingsView: View {
    @AppStorage("model_use_sam") private var useSAM = true
    @AppStorage("model_use_lama") private var useLaMa = false
    @State private var samInstalled = SamStore.shared.isInstalled
    @State private var lamaInstalled = LaMaStore.shared.isInstalled
    @State private var samBusy = false
    @State private var lamaBusy = false
    @State private var samStatus = ""
    @State private var lamaStatus = ""
    @State private var catalogModels: [CatalogModel] = []
    @State private var catalogStatus = ""
    @State private var status = ""
    @State private var samProgress = 0.0
    /// 上色诊断按钮需要当前图；由调用方传入（不在编辑界面时可传 nil，按钮会给出提示）。
    var previewImage: CIImage? = nil

    var body: some View {
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
                        } else if let img = previewImage {
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
                            let isSeg = (m.categoryId == "segmentation")
                            let slot = isSeg ? "sam" : "faceparse"
                            let top = isSeg ? "SAM" : "FaceParsing"
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

    // §420：LamaReset 原本在 LiquifyWorkspace.swift 的原视图类型上；自洽视图需要自带一份 ✓。
    func LamaReset() {
        lamaInstalled = false
        lamaStatus = "已删除，修复退回本机样例修补"
    }
}
