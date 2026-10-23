// ContentRetouch：四区界面（M3）
// 骨架照像素蛋糕实测的布局：顶栏模块 / 左竖排工具 / 中画布 / 右「窄栏 + 参数面板」/ 底部批量条
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

// 数据目录：优先环境变量 DSH_XIUTU_ROOT（Xcode 里跑时在 Scheme 的 Environment Variables 设它），
// 否则回落到源码树里的固定路径——这样无论从 Xcode、命令行还是 .app 启动都能找到参考库与风格报告。
let projectRoot: String = {
    if let env = ProcessInfo.processInfo.environment["DSH_XIUTU_ROOT"], !env.isEmpty { return env }
    if let cfg = UserDefaults.standard.string(forKey: "DSH_XIUTU_ROOT"), !cfg.isEmpty { return cfg }
    return "/Users/you/Documents/DeepSeek-Harness-Projects/dsh-xiutu"
}()
let stylesPath = projectRoot + "/style_out/style_report.json"
let indexPath = projectRoot + "/style_out/style_index.jsonl"


/// 一条历史（撤销/重做与「历史记录」面板共用）
/// 一个「范围」：图上的一块形状 + 只作用于这一块的参数增量。
///
/// 为什么存**增量**而不是整份参数：用户的心智是"全局调完，再在局部加减一点"，
/// 增量也天然跟随全局变化（全局改了，局部跟着走），不会出现"改了全局、局部还是旧值"。
/// 蒙版上的一笔（归一化坐标 + 占长边的百分比半径），与画笔工具同一套刻度
// 必须显式设成 .regular 并激活，窗口才会出来。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 外观：默认钉死深色（像素蛋糕就是深色界面，也是我们对照的基准）。
    /// 可用 --appearance light 覆盖。
    ///
    /// 为什么必须「提前 + 落到窗口上」：
    /// 在 didFinishLaunching 里只改 NSApp.appearance，**已经建好的窗口背景仍是旧外观**，
    /// 而文字颜色会立刻跟着新外观走 → 白底 + 白字，整个右侧面板看上去像空了。
    /// 实测就在本机复现：暗色外观下截图里右栏全白、只剩一个绿勾能看见。
    static var requestedAppearance: NSAppearance? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--appearance"), i + 1 < args.count {
            return NSAppearance(named: args[i + 1] == "light" ? .aqua : .darkAqua)
        }
        return NSAppearance(named: .darkAqua)
    }()

    /// 窗口出现前就生效（比 didFinishLaunching 更早）
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppDelegate.requestedAppearance
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = AppDelegate.requestedAppearance
        for w in NSApp.windows { w.appearance = AppDelegate.requestedAppearance }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 自截图：ContentRetouch --screenshot <路径>
        // 界面验证一直卡在「终端没有屏幕录制权限，screencapture 拍出来全黑」。
        // 让 App 自己把自己的窗口缓存成位图就不需要任何权限（只读自己的窗口）。
        let args = CommandLine.arguments
        // 外观固定：界面基线截图必须与钟点无关。
        // 踩过：早上 07:40 系统自动切到浅色外观，同一份代码的截图与夜里（深色）的基线差 56%，
        // 看上去像「布局炸了」，其实是系统换肤。基线比对要能钉住外观。
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            let path = args[i + 1]
            let delay = args.contains("--screenshot-late") ? 14.0 : 6.0
            // 截图带重试：窗口不一定在固定延迟内就能截（忙机器上实测出现过
            // 「6 秒时还没有可截的窗口」，而同一时刻 winlist 明明能看到窗口）。
            // 没截到就每 1.5 秒再试一次，三次；这比让人对着「没有可截的窗口」猜原因强。
            func attemptCapture(_ attempt: Int) {
                for w in NSApp.windows { w.appearance = AppDelegate.requestedAppearance }   // 后出现的窗口也要跟上
                var wrote = false
                for w in NSApp.windows where w.isVisible && w.contentView != nil {
                    guard let v = w.contentView, v.bounds.width > 200,
                          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                    // cacheDisplay 不会画窗口底色：暗色外观下白字会糊在白底上（第一次截出来就是一片浅灰）。
                    // 先在这个位图上下文里铺一层窗口底色，再把视图盖上去。
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath.fill(NSRect(origin: .zero, size: v.bounds.size))
                    NSGraphicsContext.restoreGraphicsState()
                    // 先把待画的内容真的画出来再截：cacheDisplay 只画「已标脏且已绘制」的东西，
                    // 画布那张图是异步上屏的，早先 6 秒的固定延迟在忙机器上会截到空白左窗
                    //（基线比对里表现为「左侧 原图 窗整块白」，差异 63%，看着像布局炸了，其实只是没画完）。
                    w.layoutIfNeeded()
                    v.displayIfNeeded()
                    v.cacheDisplay(in: v.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let out = path.hasSuffix(".png") ? path : path + ".png"
                        try? data.write(to: URL(fileURLWithPath: out))
                        FileHandle.standardError.write("已写 \(out) \(rep.pixelsWide)x\(rep.pixelsHigh)\n".data(using: .utf8)!)
                        wrote = true
                    }
                }
                // 重试放宽到 8 次、每次 2 秒：忙机器上「导入 + 首帧渲染 + 人脸/3D 推理」可能要十几秒，
                // 早先 3 次（约 10 秒）不够，于是经常报「没有可截的窗口」——把工具本身的耐心当成了 bug。
                if !wrote && attempt < 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { attemptCapture(attempt + 1) }
                    return
                }
                if !wrote {
                    var info = "没有可截的窗口（已重试 \(attempt) 次）；NSApp.windows=\(NSApp.windows.count)；窗口清单：\n"
                    for w in NSApp.windows {
                        let b = w.contentView?.bounds ?? .zero
                        info += "  visible=\(w.isVisible) size=\(Int(b.width))x\(Int(b.height)) title=\(w.title)\n"
                    }
                    FileHandle.standardError.write(info.data(using: .utf8)!)
                }
                NSApp.terminate(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { attemptCapture(0) }
        }
        // 布局体检：ContentRetouch --layoutcheck <可选:路径>
        // 目的：把「文字被压住」变成**判据**。界面门只比截图相似度，看不出这个（§238/§247 两次都是人眼发现）。
        // 做法：走 AppKit 无障碍树，**只收叶子**文本/按钮（叶子之间不可能互相包含；否则父子关系会让
        // 每个子元素都“与父相交”，全是噪声），两两求交，重合面积占较小者 > 10% 记为相交。
        // 打印一行 UIOCC-SUM overlaps=N texts=M；有相交给退出码 1，便于门直接用。
        // ⚠️ 这是**小样**：SwiftUI 是否稳定暴露这些元素必须先验，验不过就不接门（否则得到假绿）。
        if args.contains("--layoutcheck") {
            let delay = args.contains("--screenshot-late") ? 14.0 : 6.0
            let outPath = args.firstIndex(of: "--layoutcheck").flatMap { i in
                (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? args[i + 1] : nil
            }
            func report(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
            func runLayoutCheck(_ attempt: Int) {
                for w in NSApp.windows { w.appearance = AppDelegate.requestedAppearance }
                guard let win = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                      let cv = win.contentView, cv.bounds.width > 200 else {
                    if attempt < 8 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { runLayoutCheck(attempt + 1) }; return }
                    report("UIOCC-SUM overlaps=0 texts=0 note=no-window")
                    NSApp.terminate(nil); return
                }
                win.layoutIfNeeded(); cv.displayIfNeeded()
                var items: [(String, CGRect)] = []
                func walk(_ el: Any, _ depth: Int) {
                    guard depth < 40, let o = el as? NSAccessibilityProtocol else { return }
                    let kids = (o.accessibilityChildren() ?? [])
                    if kids.isEmpty {
                        let lbl = (o.accessibilityLabel() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let val = ((o.accessibilityValue() as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        let text = lbl.isEmpty ? val : (val.isEmpty ? lbl : lbl + " / " + val)
                        let f = o.accessibilityFrame()
                        if !text.isEmpty, f.width > 1, f.height > 1 { items.append((text, f)) }
                        return
                    }
                    for k in kids { walk(k, depth + 1) }
                }
                walk(cv, 0)
                var hits: [(String, String, CGFloat)] = []
                if items.count > 1 {
                    for i in 0..<items.count {
                        for j in (i + 1)..<items.count {
                            let a = items[i].1, b = items[j].1
                            let it = a.intersection(b)
                            guard !it.isNull, it.width > 1, it.height > 1 else { continue }
                            let smaller = min(a.width * a.height, b.width * b.height)
                            guard smaller > 0 else { continue }
                            let ratio = (it.width * it.height) / smaller
                            if ratio > 0.10 { hits.append((items[i].0, items[j].0, ratio)) }
                        }
                    }
                }
                for (x, y, r) in hits.prefix(25) {
                    report(String(format: "UIOCC %3.0f%% ｜ %@ ⟷ %@", r * 100, x, y))
                }
                for (t, f) in items.prefix(40) {
                    report(String(format: "UIOCC-EL %@ @ %.0f,%.0f %.0fx%.0f", t, f.minX, f.minY, f.width, f.height))
                }
                let sum = "UIOCC-SUM overlaps=\(hits.count) texts=\(items.count)"
                report(sum)
                if let p = outPath { try? sum.data(using: .utf8)?.write(to: URL(fileURLWithPath: p)) }
                if hits.isEmpty { NSApp.terminate(nil) } else { exit(1) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { runLayoutCheck(0) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// 窗口标题里带**版本号 + 二进制构建时间**。
/// 为什么值得加：这一轮"三个问题我自检都过、用户都说没好"耗掉一个回合，
/// 最可能的解释就是两边跑的不是同一个二进制。标题摊开来，这类争论当场结束。
let appTitle: String = {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let d = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
    return "智能修图 " + v + " · 构建 " + (d.map { f.string(from: $0) } ?? "?")
}()

@main
struct ContentRetouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup(appTitle) { MainView() }
            .windowStyle(.titleBar)
    }
}

struct MainView: View {
    // MARK: - 一、预设与风格

    @State var styles: [StylePreset] = []
    // -1 = **没有预设被选中**（开机不默认选中第一条，取消预设后也不保留高亮）
    @State var styleIdx: Int = -1
    // —— 参考追色 ——
    // MARK: - 二、参考追色

    @State var refPaths: [String] = []
    @State var refURLText = ""
    @State var refTargetStats: Stats? = nil
    /// 分区追色勾选的区域（存 rawValue，便于放进 Set）
    @State var refRegionSel: Set<String> = []
    @State var refRegionHint = "未勾选 = 只做全局追色；勾选后每一块单独算一次并贴在该区域里"
    /// 追色之前的状态：供「取消追色」一键还原
    @State var preRefSnapshot: HistoryEntry? = nil
    /// 上一次套用的预设（"index|name"）：再点同一条 = 取消应用
    @State var appliedPresetKey: String? = nil
    // —— ⑩ 按部位调参 ——
    @State var partAdjusts: [PartAdjust] = []
    @State var openPart: String? = "脸"
    /// 部位是否可用的检查结果（按需算、缓存；不要在视图里对每一行现算掩膜——那太贵）
    /// ② 液化保底通路：最近一次在图上点的位置（方向推动/方向键以它为起点）
    @State var liquifyLastPoint: CGPoint? = nil
    @State var lastPushTick = 0
    /// 监视器拖动路径的上一落点（液化推动要用）
    @State var lastStrokePoint: CGPoint? = nil
    /// 画布事件计数（状态栏显示，用来判断事件到没到）
    @State var evDown = 0
    @State var evDrag = 0
    @State var evUp = 0
    /// 按下时的局部坐标（抓手平移算增量用）
    @State var panStartLocal: CGPoint? = nil
    /// ② 当前这一次拖动对应的笔触下标（就地更新用；抬起时清空）
    @State var dragStrokeIndex: Int? = nil
    /// ② 当前这一次拖动的起点（算总位移用）
    @State var dragStartPoint = CGPoint(x: 0.5, y: 0.5)
    /// 各图框在画布坐标里的矩形（由 pane 上报）
    @State var paneFrames: [String: CGRect] = [:]
    @State var partChecked: Set<String> = []
    @State var partAvailable: Set<String> = []
    /// 部位变形的滑杆草稿（松手才提交给 warp 笔触）
    @State var deformDraft: [String: Double] = [:]
    /// 分区追色的结果：区域 → (该区域的局部参数, 蒙版)，渲染时按区域贴回去
    @State var regionMatches: [(region: ColorRegion, params: Params)] = []
    @State var refInfo = ""

    // —— 素材库检索 ——
    @State var searchQuery = ""
    @State var searchHits: [ImageRecord] = []
    @State var simHits: [(String, Double)] = []     // 以图搜图结果（文件名, 距离）
    @State var simInfo = ""
    @State var indexPathHint = ""
    @State var indexProgress = ""
    @State var indexBusy = false

    // MARK: - 三、图片与工作图

    @State var srcURL: URL?
    @State var srcImage: NSImage?
    @State var outImage: NSImage?
    @State var srcStats = Stats()
    // MARK: - 四、调色参数与目标

    @State var params = Params()
    @State var target = Stats()
    @State var faceCount = 0
    @State var status = "点左下「载入示例」或「导入照片」开始（也可以直接把照片拖进窗口）"
    @State var singleView = false          // false = 左右对比；true = 只显示效果
    @State var showEffect = true           // 原图 ↔ 效果
    @State var records: [BatchRow] = []
    @State var busy = false
    @State var progress = 0.0
    // MARK: - 五、界面导航与状态

    @State var panel = 0                   // 右窄栏：0 参考组 1 参数 2 队列 3 人像
    // —— 人像（按脸组织参数）——
    // MARK: - 六、人脸与逐脸参数

    @State var faces: [FaceInfo] = []
    @State var selectedFace = 0
    @State var faceBrightness: [Int: Double] = [:]   // 每张脸的额外提亮（-30~+30）
    @State var faceWarmth: [Int: Double] = [:]       // 每张脸的暖冷偏移（-20~+20）
    @State var attrs: [Int: String] = [:]            // 人物属性：女/男/儿童/长辈女/长辈男
    @State var faceScope = "single"                  // single=只作用选中脸；all=所有人；partial=联动选中的若干张
    @State var selectedFaces: Set<Int> = []          // 「部分人联动」勾选的脸
    // —— 皮肤 ——
    // MARK: - 七、皮肤与质感

    @State var skinGrade = "off"                     // off/light/medium/strong
    @State var skinStrength = 0.0
    /// 祛油光（0~100）：只压皮肤掩膜内的高光顶（对标像素蛋糕「祛除瑕疵·祛油光（脸部）」）—— §188
    /// 祛黑眼圈（0~100）：眼下带提亮 + 略降饱和（对标像素蛋糕「祛除瑕疵 · 祛黑眼圈」）—— §189
    @State var skinTone = false                      // 肤色统一（按测得的暖冷向参考组靠拢）
    @State var texturePreserve = true                // 保毛孔磨皮（频域分离）开关
    @State var liquifyAmount = 0.0                   // 液化（近似：对最大的一张脸做膨胀）
    @State var slimWaist = 0.0                       // 全身美型：收腰 0~100
    // —— 人像全量参数（祛瑕疵全集 / 牙齿眼睛 / 妆容 / 重塑 / 手脚）——
    @State var portrait = PortraitOptions()
    // —— 导出设置 ——
    // MARK: - 八、导出与批量

    @State var export = ExportSettings()
    // 批量导出并行度。默认按性能核数取（8 核机器 → 4），上限 4。
    //
    // 为什么不是 1：实测（2026-09-26，8 张 6MP，同一夹具、同一台机器，各采样两次）
    //   并行 1：导出 1.22 / 1.38 s（6.6 / 5.8 张/秒）
    //   并行 4：导出 0.75 / 0.78 s（10.7 / 10.3 张/秒）  ← 快约 1.7 倍
    //   并行 8：0.78 s，但峰值内存翻到 776 MB（本机 8 核里只有 4 个性能核，多出来的没有收益）
    // ⚠️ 内存**不是**"1 最省"：两组采样里串行 445~645 MB、并行 584~673 MB，属同一量级、不单调 ——
    //    老注释写的"1=最省内存"没有实测支撑，已删掉，别照着它选。
    @State var exportWorkers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
    @State var exportStats = ""                      // 上一次导出的实测
    // —— 历史 / 撤销 ——
    // MARK: - 九、历史与撤销

    @State var history: [HistoryEntry] = []
    /// 当前所处的历史位置（-1 = 还没开始）。**点回前面某一步不删后面的**，只是把它们标灰，
    /// 还能再点回去——这是用户明确要的行为（"变灰即可，不要直接从历史记录中删除"）。
    @State var historyCursor = -1
    /// 拖动开始时的快照：拖动结束再落成一条历史（否则一次拖动会产生几百条）
    @State var dragStartSnapshot: HistoryEntry? = nil
    /// 套预设之前的状态：再点同一个预设 = 取消应用，回到它
    @State var prePresetSnapshot: HistoryEntry? = nil
    /// 裁剪是否**已应用**。没应用时画布显示整图 + 裁剪框（这才是能调整框的前提）；
    /// 应用后画面才真的裁掉。早先是"一拖出框就立刻裁"，于是拖框的时候画面同时在变——
    /// 框跟着自己的结果跑，根本没法调整（用户报的"裁剪完全无法使用"）。
    @State var cropApplied = false
    /// 导出体积预估（按当前设置真的编一遍量出来的）
    // MARK: - 十、弹层与工具属性

    @State var showExportPopover = false
    // ── 范围选择（#6）：在图上圈一块，只对这一块做参数调整；关掉工具后调整**保留** ──
    // MARK: - 十一、范围与蒙版画笔

    @State var regions: [RegionAdjust] = []
    @State var regionMode = false
    @State var selectedRegion: UUID? = nil
    @State var regionShape = 0          // 0 矩形 1 椭圆 2 圆形
    @State var regionFeather = 30.0
    @State private var regionDragging = false
    @State var regionStart: CGPoint? = nil
    /// 蒙版画笔（PS 式的图层蒙版）：涂白=生效、涂黑=不生效
    @State var maskBrushMode = false
    @State var maskBrushRadius = 8.0
    @State var maskBrushAdd = true      // true = 加（白），false = 减（黑）
    @State var exportSizeEstimate = ""
    @State var estimateWork: DispatchWorkItem? = nil
    @State var redoStack: [HistoryEntry] = []
    // —— 搜索（像素蛋糕的「搜索功能」：按名字跳到对应面板）——
    // MARK: - 十二、资料库 / 挑图 / 搜索

    @State var search = ""
    // —— 性能：预览工作图与关键点按 URL 缓存（拖滑杆不再重复跑 Vision）——
    /// 预览长边上限：**随显示倍率自适应**（原来固定 1400）。
    /// 为什么改：预览是按这个上限降采样来的，而用户可以放大到 200%~400% 看细节（修图的基本动作）。
    /// 固定 1400 时，放大后看到的是"被插值放大的低分图" —— 糊；而导出走的是全分辨率，
    /// 于是"放大看是糊的、导出来是清楚的"，又是一种所见非所得。
    /// 现在按倍率放大预览（上限 6000 控内存），代价只是 refresh 变慢
    /// （实测 4× 像素约 34 ms，滑杆仍然跟手）。
    var previewMaxDim: Int {
        let z = zoom > 1 ? zoom / 100.0 : 1.0        // 0 = 适应 → 按 1× 算
        return Int(min(6000, max(1400, 1400 * z)))
    }
    @State var cachedURL: URL? = nil
    @State var cachedImage: CIImage? = nil
    @State var cachedMaxDim = 0
    @State var cachedFaceURL: URL? = nil
    // 直方图异步算的序号：连续拖动时只有最后一次的结果会落到界面上（过程值没人看得见）
    @State var histSeq = 0
    // ⚠️ 只有序号还不够：序号只让"过期的结果"不落到界面，**后台任务照样会一个一个堆起来** ——
    // 拖滑杆时每秒能刷几十次，每次都在 utility 队列上排一个"整条管线的直方图渲染"，
    // 后台越堆越多、和主线程抢同一个 CIContext（发版时撤销门那一步耗了 931 秒，见账本 §173）。
    // 现在改成**单飞 + 待算标记**：任何时刻最多一个后台直方图在跑，期间的请求合并成"再来一次"。
    @State var histBusy = false
    @State var histPending = false
    @State var cachedGeos: [FaceGeo] = []          // 工作图的关键点（一次刷新只算一次）
    @State var wideShoulders = 0.0                   // 全身美型：宽肩 0~100
    // —— 照像素蛋糕布局补的两块 ——
    // MARK: - 十三、模块与缩略图条

    @State var module = "图库"                       // 顶栏模块：图库（主页层）/ 精修 / 创意
    @State var projects: [ProjectRecord] = []        // 项目卡片（持久化到 Application Support）
    @State var showAllProjects = false              // §251：项目列表默认只显示最近 5 个，其余折叠
    @State var newProjectName = ""                  // §251：新建项目的名字输入
    @State var strip: [URL] = []                     // 底部缩略图条
    @State var selectedStrip: Set<URL> = []           // 条上已选
    @State var stripDir: URL? = nil
    @State var zoom = 0.0                            // 0 = 适应；>0 = 固定百分比
    @State var handTool = false                      // 抓手
    @State var panOffset = CGSize.zero               // 抓手平移量
    @State var stars: [URL: Int] = [:]               // 缩略图星级（由挑图分数换算）
    // MARK: - 十四、修复类工具（污点/修补/仿制）

    @State var spotActive = false                    // 污点修复笔刷
// §328：AI 点修的「一次性待点」标志。为什么不做成模式：AI 点修本来就该「点一下就好」✓，
// 所以按钮只负责置位，下一次画布点击消费掉（§320 的路径 B）；点完自动复位 ✓。
@State var aiFixArmed = false
// §351：模型开关（用户需求：可直接选择已装模型、可增可减）。沿用仓库既有先例 @AppStorage(hiddenTools) ✓。
// 默认值与现状严格一致：SAM 开（§315 由正结果翻默认 ✓）、LaMa 关（§289 由负收益撤回 ✓）。
@AppStorage("model_use_sam") var useSAM = true
@AppStorage("model_use_lama") var useLaMa = false
// §395：可下载目录（用户需求：第三方模型自动下载 / 安装 / 评测）。
@State var catalogModels: [CatalogModel] = []
@State var catalogStatus = ""
    @State var spotPoints: [CGPoint] = []
    // 占画面长边百分比（预览/导出一致）。默认给 **0.7%**：在 1050px 的工作图上约 7px 半径、
    // 14px 直径——这才是"一颗痘"的尺度。原来默认 4% 是 47px 半径（直径 94px），
    // 一点下去就是一大片重绘，用户反馈的"程度太严重、缩到最小也太大"就是这个。
    @State var spotRadius = 0.7
    @State var showGuides = false                    // 参考线
    @State var cloneActive = false                    // 仿制图章
    @State var patchActive = false                    // 修补
    @State var cloneSource: CGPoint? = nil            // 取样点
    @State var clonePoints: [CGPoint] = []
    /// 修补与仿制**各存各的落点**：原来共用一个数组、且切工具时清空，
    /// 于是"关掉工具效果就没了"（用户报的正是这个）。两者是两种不同的修复算法，
    /// 混在一个数组里就没法分别重放。
    @State var patchPoints: [CGPoint] = []
    @State var cloneRadius = 0.6        // 仿制/修补：更精修，默认约 6px 半径
    @State var clothesStrength = 0.0                 // 衣物平整 0~100
    @State var bgPurify = 0.0                        // 背景纯化（实例分割版）0~100
    // —— 后调色补充（像素蛋糕「后调色」里的常用几样）——
    @State var sharpenAmount = 0.0                   // 锐化 0~100
    @State var denoiseAmount = 0.0                   // 降噪 0~100
    @State var vignetteAmount = 0.0                  // 暗角 -100~100
    @State var grainAmount = 0.0                     // 颗粒 0~100
    @State var lightAmount = 0.0                     // 补光 0~100
    @State var lightWarm = 0.0                       // 补光暖冷 -30~30
    @State var bgBlur = 0.0                          // 背景虚化 0~100
    @State var edgeRefine = 0.0                      // 边缘优化 0~100
    // —— 镜头校正 + 透视校正 ——
    @State var lensDistortion = 0.0                  // 畸变校正 -100~100
    @State var lensVignette = 0.0                    // 暗角校正 0~100
    @State var lensCA = 0.0                          // 横向色差校正 -100~100
    @State var perspH = 0.0                          // 水平校正 -100~100
    @State var perspV = 0.0                          // 垂直校正 -100~100
    // —— 自动/智能这一层 ——
    // MARK: - 十五、影调补充（白平衡/补光/降噪/锐化…）

    @State var autoWB = 0.0                          // 自动白平衡 0~100
    @State var smartSharpen = 0.0                    // 边缘感知锐化 0~100
    @State var highlightRecover = 0.0                // 高光恢复 0~100
    @State var autoFill = 0.0                        // 自动补光（按光向）0~100
    @State var autoWBInfo = ""
    @State var autoExposeAmount = 0.0                // 自动曝光 0~100
    @State var autoSkinAmount = 0.0                  // 自动肤色 0~100
    @State var autoInfo = ""
    // —— 交付层：虚拟副本 / 回收站 / 选片 ——
    @State var versions: [VersionRecord] = []
    @State var versionName = ""
    @State var trashItems: [TrashItem] = []
    @State var deliverStars = 4
    @State var deliverStats = ""
    @State var burstStats = ""
    @State var burstGroups: [String] = []
    // MARK: - 十六、天空 / 镜头 / 场景智能

    @State var sky = SkyOptions()
    @State var skyInfo = ""
    @State var lensInfo = ""
    @State var lensAutoApplied = false
    @State var samInstalled = SamStore.shared.isInstalled
    /// 可选下载的生成式修复模型（LaMa）
    @State var lamaInstalled = LaMaStore.shared.isInstalled
    @State var lamaBusy = false
    @State var lamaStatus = ""
    @State var samProgress = 0.0
    @State var samStatus = ""
    @State var samBusy = false
    @State var showToolPicker = false
    @State var showShortcuts = false
    // —— 系统 AI 能力面：智能裁剪 / 场景推荐 / 按人物裁剪 ——
    // MARK: - 十七、裁剪与人物实例

    @State var cropAspect = "原图"                    // 原图 | 1:1 | 4:5 | 3:4 | 16:9
    @State var cropPlacement = "thirds"               // thirds | center
    @State var sceneInfo: SceneInfo? = nil
    @State var personRects: [CGRect] = []             // 人物实例框（归一化）
    @State var showPersonCrop = false
    @State var personSkin: [Double] = []              // 每个人的磨皮强度（按实例）
    @State var personCache: [(rect: CGRect, mask: CIImage)] = []
    @State var personCacheURL: URL? = nil
    @State var petStrength = 0.0                     // 宠物美化 0~100（旧字段：预设/项目文件兼容用）
    /// 宠物美化的细化参数（六项）。旧的 petStrength 映射到 soften，读旧文件不会丢。
    // MARK: - 十八、局部调整与宠物

    @State var petOptions = PetOptions()
    @State var localWarm = 0.0                       // 局部 AI 追色：区域色温
    @State var localBright = 0.0                     // 局部 AI 追色：区域亮度
    // —— 编辑（裁剪旋转）——
    @State var autoCropOn = false
    @State var rotateDeg = 0.0
    @State var flipH = false
    @State var quarterTurns = 0      // 90° 整转（裁剪旋转里的「逆时针 90°」）
    // —— 画布液化笔刷（完整工具集：向前变形 / 膨胀 / 收缩 / 旋转 / 冻结）——
    // MARK: - 十九、液化笔触与冻结

    @State var warpStrokes: [WarpStroke] = []
    @State var freezeStrokes: [WarpStroke] = []
    @State var liquifyMode: LiquifyMode = .push
    @State var showFreeze = true
    @State var brushRadius = 1.5        // 液化笔刷：默认约 16px 半径（1050px 图）
    @State private var brushStrength = 0.5
    @State var brushActive = false
    // —— 画布裁剪框 ——
    @State var cropMode = false
    @State var cropRect: CGRect? = nil
    @State var dragStart: CGPoint? = nil
    // —— 挑图 ——
    @State var picks: [ImageScore] = []
    @State var pickBusy = false
    @State var showPresets = true      // 常驻预设列（照像素蛋糕：默认就在，可关掉）
    @State var showHistoryColumn = false   // 历史列（与预设列同一位置，二选一显示）
    @State private var dropTargeted = false    // 拖照片进窗口时高亮
    @State var diagText = ""            // 反馈页的诊断信息
    @State var hoverPoint: CGPoint? = nil   // 画布上的指针位置（笔刷范围提示圈用）
    @State var pendingHistory: DispatchWorkItem?   // 滑杆防抖用的待记录步骤
    /// 应用方式：0 叠加（只覆盖新方案里明确改过的项）、1 替换（整块换掉）
    @State var applyMode = 0
    // —— 参照图库（#1/#2/#3）——
    @State var refLibDir = UserDefaults.standard.string(forKey: "CR_REF_LIB") ?? ""
    @State var refLibIndex = 0            // 图库里已索引张数
    @State var refLibProgress = ""
    @State var refLibBusy = false
    @State var recRefs: [(path: String, distance: Double)] = []   // 推荐参照图
    @State var chosenRef: String? = nil   // 选中的参照图（画布上作第三栏）
    @State var showRefPane = false        // 画布是否显示参照图栏
    @State var cropShape = 0              // 裁剪方式：0 自由 1 1:1 2 4:5 3 3:4 4 16:9 5 原比例
    @State var brushHudDrag = false       // 是否正在拖范围圈改大小
    @State var pickProgress = 0.0       // 挑图进度
    @State var pickCancel = false       // 挑图取消标志
    // —— 预设面板（照像素蛋糕：分类 → 子项，另有「推荐 / 我的」两个页签）——
    @State var presetGroups: [PresetGroup] = []
    @State var myPresets: [StylePreset] = []
    @State var presetTab = 0                  // 0 推荐（内置分类）1 我的（自己存的）
    @State var openPresetGroup: String? = "肤质肤色"  // 展开的分类（同时只展开一个，照参照物）
    // 人像美化的四个页签（照像素蛋糕：祛除瑕疵 / 皮肤调整 / 面部重塑 / 表情管理）
    @State var faceTab = 0
    /// 逐项开关：关掉一项时记住它原来的值，再打开能恢复（像素蛋糕每项都有这样一个开关）
    @State var itemOff: [String: Double] = [:]
    // —— 占位：本机做不了的功能（生成式那一块），列出来但不可用 ——
    /// 本机确实做不了的功能（生成式需要扩散模型、协同类需要服务端）。
    /// 已经做出来的（宠物美化 / 衣物平整 / 背景纯化 / 手部美化 / 面部重塑…）从这里删掉，不留假占位。
    static let placeholders: [(String, String)] = [
        ("创成式填充", "需扩散模型（本机无推理框架、无训练数据）"),
        ("AI 换装 / 证件照换装", "需扩散模型"),
        ("AI 换天空 / 换背景", "需扩散模型 + 全景分割模型"),
        ("AI 拉龄 / 面部重绘", "需扩散模型"),
        ("闭眼修复 / 加腹肌 / 瘦肚子", "需扩散模型"),
        ("表情管理（微笑 / 睁眼）", "关键点驱动的生成式重绘"),
        ("头发调整（发量填充）", "生成式（需模型）；发际线已做（人像面板，几何位移，实测位移 0.03~0.07 脸高）"),
        ("AI 点修（点一下自动修）", "需指令解析 + 局部修复模型；修复那一半可以用可选下载的 LaMa"),
        ("祛路人", "需检测 + 生成式修补（污点修复只能盖小面积）"),
        ("一句话生图 / 像素助手", "需文本到图像生成模型"),
        ("联机拍摄 / 云空间 / 云协同 / ERP", "要服务端；本机只做本地目录与本地选片清单"),
    ]

    // RegionAdjust 定义在文件作用域（HistoryEntry 也要用它）

var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if module == "图库" {
                // 像素蛋糕的「主页」层：导入卡片 + 快捷功能 + 项目卡片
                homeView
            } else if module == "创意" {
                // §246：创意模块页（诚实逐条占位，永远可见）
                creativeView
            } else if liquifyWorkspace {
                // 液化：整屏一个专门界面（参照 PS）。工具条在上一行、笔刷参数在下一行、
                // 中间整块留给画布——PS 的液化就是这么组织的，比塞在侧栏里好用得多。
                ZStack {
                    liquifyWorkspaceView
                    pushTickWatcher          // ② 方向键推一笔的观察点（尺寸 0，不影响布局）
                }
            } else {
                // 像素蛋糕的工具条是**画布上方的横向一条**（不是左竖排）——按实测改过来
                leftTools
                Divider()
                HSplitView {
                    canvas
                    // ⚠️ 这个上限是「右栏只有一条窄栏」时代的遗留。现在右侧是
                // 预设列(215) + 参数面板 + 图标窄栏(54) 三段，仍然卡在 460 的话，
                // 三段会互相挤压：预设列的文字被从左边切掉、最右窄栏的标签也被切
                //（用户报的「预设栏和最右侧功能栏有部分文字被遮挡」就是这个）。
                // 参数面板这一列**自己**限宽：右侧真正的宽度大头是它（预设列 215 + 图标列 54 都是固定的），
                // 用户反馈"点最右侧模块时，右边第二列整列都太宽"——就是它把画面挤没了。
                rightPanels.frame(minWidth: 470, idealWidth: 510, maxWidth: 580)
                }
                if !liquifyWorkspace {
                    Divider()
                    bottomBar
                }
            }
        }
        // 窗口最小尺寸照像素蛋糕的比例放大了一档：右边多了一条常驻预设列，
        // 1120 宽会把画布挤得只剩一条缝（实测：加上预设列后画布几乎不可用）。
        .frame(minWidth: 1440, minHeight: 800)
        .background(shortcutHost)
        // 拖照片 / 文件夹进窗口即可导入；拖着的时候整块高亮，不然用户不知道能不能放
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { handleDrop($0) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            runSelfChecks()
        }
    }




    // MARK: 工具条（像素蛋糕叫「自定义工具栏」：顺序照它实测，可自行增减）
    //
    // 工具是数据驱动的（id / 图标 / 名称 / 动作），「自定义工具栏」只改可见集合，
    // 存 UserDefaults，下次打开还在。
    @AppStorage("hiddenTools") var hiddenToolsRaw = ""










    /// 蒙版上的一个涂点（单独抽出来，避免编译器在 ForEach 里推导超时）
    /// 把某个范围里"蒙版涂过的点"画出来（白=涂上、黑=擦除）。
    /// 单独抽出来是为了让类型推导轻一点（写在 ForEach 里编译器会报 type-check 超时）。

    /// 画落点标记：**拖动中画全部（那是正在做的事），松手后只画最后一个**。
    /// 为什么：原来把历史所有落点都画出来，用户"一按下去就满屏旧圈"（第 103 节）。






    // MARK: 画布



























    /// 画布 → **归一化图像坐标**（0~1，y 向上，与 Core Image 同向）。
    /// 全部落点都按归一化存：预览用 1400px 工作图、导出用全分辨率，两边落点才一致
    /// （早先存的是预览像素，导出时会整体偏掉）。
    @State var handDragging = false   // 抓手正在拖动（光标换成「握住的手」）
    @State var panStart: CGSize? = nil // 抓手按下时的平移基准（见下面那段说明）
    @StateObject var canvasInput = CanvasInput.shared
    // ② 方向键推一笔：观察 tick 变化（液化工作区里用）
    private var pushTickWatcher: some View { Color.clear.frame(width: 0, height: 0)
        .onChange(of: canvasInput.pushTick) { _, _ in consumePushTick() } }
    @State var lastZoomTick: Double = 0
    @State var holdingOriginal = false // 「按住看原图」按住期间为 true
    @State var selfCheckEcho = false   // 自检模式下把批量结果写到 stderr（界面状态命令行看不到）
    @State var dragGestureLogged = false
    /// 液化拖动时「本笔的上一个落点」。必须自己记：原来用的是 warpStrokes.last（**上一条**笔触的末点），
    /// 新起一笔时那个点可能在画面另一头 → 位移向量又大又是错方向。
    @State var lastLiquifyPoint: CGPoint? = nil
    /// 液化工作区（参照 PS：整屏一个专门界面，工具条 + 画布 + 笔刷参数 + 确定/取消）
    @State var liquifyWorkspace = false
    @State var liquifyBackup: (warp: [WarpStroke], freeze: [WarpStroke])? = nil
    @State var liquifyBackupSingleView = false
    /// 落点标记：默认关（挡观察），拖动时临时显示
    @State var showStrokeMarks = false
    @State var strokeMarkLive = false
    // 当前这一笔在各数组里的起点（拖动中只画 [起点...]，不画历史）
    @State var strokeStartSpot = 0
    @State var strokeStartClone = 0
    @State var strokeStartPatch = 0
    /// ⌥ 正在重新取样（这一下不落点）
    @State var optSampling = false
    /// 仿制图章的**取样段**：(段内第一个落点下标, 当时落的取样点)。
    /// 为什么要有它：偏移量（落点 − 取样点）必须在**同一段内恒定**，来源才会跟着笔走；
    /// 而 clonePoints 是全局一个数组，所以得记住"这段从第几个点开始"，才能在渲染时逐点算偏移。
    @State var cloneEpochs: [(at: Int, source: CGPoint)] = []
    @State var strokeStartWarp = 0
    // ── 工具属性（直方图下方的「工具」组）──
    @State var spotFeather = 55.0     // 污点修复：羽化 0~100
    @State var spotStrength = 100.0   // 污点修复：程度 0~100
    @State var cloneFeather = 55.0    // 修补/仿制：羽化
    @State var cloneOpacity = 100.0   // 修补/仿制：不透明度
    @State var brushDensity = 60.0    // 液化：密度（羽化）
    // 液化：压力（程度）。默认从 100 改成 45 —— 100 是满强度，配合"每一小段位移都落一笔"
    // 会推得过猛（用户反馈"拖动程度太严重，几乎无法使用"）。45 起手用户可以自己往上加。
    // ③ 默认压力再降到 30（用户反馈"每次推程度还是变化太厉害"）
    @State var brushPressure = 30.0
    @State var exportCancel = false    // 批量导出：取消标志
    @State var exportProgress = 0.0    // 批量导出进度
    @State var skipExported = true     // 断点续跑：已有的输出直接跳过
    @State var splitCompare = false    // 单图内的「滑动对比」（左原图 / 右修后）
    @State var splitPos = 0.5          // 分割线位置 0~1
    @State var hist: Histogram? = nil  // 当前预览的直方图
    @State var histChannel = 0         // 0 = RGB 叠加，1 = 亮度
    @State var exifRows: [(String, String)] = []
    @State var exifURL: URL? = nil

    /// 每张图各自的编辑状态。
    ///
    /// 为什么需要：参数一直是一份全局的，换张图再换回来，效果就没了（#7 报的就是这个，
    /// 「导出之后再打开效果会消失」）。现在按路径存：切走时存、切回时取，
    /// **没见过的图用干净状态**——这也正好满足 #6「打开图片后不要默认套某种预设」。
    @State var editStates: [String: EditState] = [:]
    /// 当前图的身体朝向（3D 姿态，按图缓存）。全身美型要按它打折，界面也把它显示出来。
    // MARK: - 二十、身体塑形（朝向/折扣）

    @State var bodyYaw: (yaw: Double, ok: Bool) = (0, false)
    @State var bodyYawURL: URL? = nil





    static let cropShapeNames = ["自由", "1:1", "4:5", "3:4", "16:9", "原比例"]
























































    struct DeformSlider: View {
        let label: String
        let value: Double
        let onChange: (Double) -> Void
        let onCommit: (Double) -> Void
        @State private var local: Double = 0
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(label).font(.system(size: 10))
                    Spacer()
                    Text(String(format: "%.0f", local)).font(.system(size: 9)).monospacedDigit()
                }
                Slider(value: Binding(get: { local }, set: { local = $0; onChange($0) }), in: 0...100, step: 5)
                    .controlSize(.mini)
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in onCommit(local) })
            }
            .onAppear { local = value }
        }
    }















































    // MARK: 交付层（虚拟副本 / 回收站 / 选片）












    // MARK: 系统 AI 能力（显著性 / 场景 / 实例）















    /// 修复类操作（污点/修补/仿制）的记忆化。
    ///
    /// 为什么必须缓存：换成基于样例的修补之后，一个 40×40 的洞要 **211 ms**（实测），
    /// 而 renderPipeline 在**每一次滑杆 tick** 都会重跑一遍——不缓存就等于拖一下卡一下。
    /// 修复是对**原片**做的（也在管线最前面），与调色参数无关，所以键里不含参数。
    @State var repairCacheKey = ""
    @State var repairCacheImage: CIImage? = nil
    /// 「已经烤进图里的」污点修复状态，用于**增量**修补。
    ///
    /// 为什么必须增量：修复的算法是「按蒙版把洞整体重算一遍」。落点是只增的，
    /// 所以每点一下，蒙版变大 → 前面几处的补丁**会被重新算成另一个样子**——
    /// 用户看到的就是"点多了之后前面的点也跟着变"。这不对：每一次点击应该是**独立事件**。
    /// 现在只把**新增的点**作用在上一次的结果上，老点已定的像素不再参与重算。
    @State var bakedSpotCount = 0
    @State var bakedSpotRadius = -1.0
    @State var bakedSpotPoints: [CGPoint] = []
    /// 烘焙时用的**工具属性**快照：增量复用时必须要求它没变，
    /// 否则会拿"旧羽化"的结果继续往上叠新落点（第 111 节）。
    @State var bakedParamKey = ""

    /// 整条管线的**值快照**：把 renderPipeline 会用到的界面状态全部收进一个结构。
    ///
    /// 为什么必须这样：上一轮修了「导出只做了一部分」，但只补了手动编辑那几步；
    /// 后调色的降噪/锐化/暗角/颗粒/补光/背景虚化、镜头校正、自动白平衡、逐人磨皮……
    /// 这些**导出同样一步都没做**——同一个东西两份实现，而那份总是跟不全。
    /// 现在导出直接把这份快照喂给**同一个 renderPipeline**，从根上消掉"两份实现"。
    struct PipelineConfig {
        var params = Params()
        var target = Stats()
        var faces: [FaceInfo] = []
        var perFace: [Int: Params] = [:]
        var cachedGeos: [FaceGeo] = []
        var personSkin: [Double] = []
        var portrait = PortraitOptions()
        var skin = SkinOptions()
        var autoSkinAmount = 0.0
        var slimWaist = 0.0
        var wideShoulders = 0.0
        var bodyK = 1.0
        var localWarm = 0.0
        var localBright = 0.0
        var pet = 0.0
        var petOptions = PetOptions()
        var bgPurify = 0.0
        var clothes = 0.0
        var autoWB = 0.0
        var autoExpose = 0.0
        var highlightRecover = 0.0
        var denoise = 0.0
        var sharpen = 0.0
        var smartSharpen = 0.0
        var autoFill = 0.0
        var bgBlur = 0.0
        var edgeRefine = 0.0
        var vignette = 0.0
        var grain = 0.0
        var light = 0.0
        var lightWarm = 0.0
        var lensDistortion = 0.0
        var lensVignette = 0.0
        var lensCA = 0.0
        var perspH = 0.0
        var perspV = 0.0
        var manual = ManualEditSet()
        var regions: [RegionAdjust] = []
        var parts: [PartAdjust] = []
        /// 分区追色结果（区域 + 局部参数）。**必须进快照**：导出在后台线程跑，
        /// 读 @State 既拿不到稳定值也是数据竞争。
        var regionMatches: [(region: ColorRegion, params: Params)] = []
    }


    /// 手动编辑的**值快照**。
    ///
    /// 为什么要有它：批量导出的 outRun 闭包跑在后台线程，不能去读 @State；
    /// 而它原来只做了「调色 + 皮肤 + 人像 + 背景」那几步——**裁剪、祛边、旋转、液化、',
    /// 污点/修补/仿制、换天空全都没做**。用户批量出片会发现「我做的那些编辑呢」。
    /// 现在把这部分统一成两个阶段函数，预览与导出**共用同一份实现**。
    struct ManualEditSet {
        var spotPoints: [CGPoint] = []
        var spotRadius = 0.7
        var spotFeather = 55.0
        var spotStrength = 100.0
        var cloneFeather = 55.0
        var cloneOpacity = 100.0
        var patchActive = false
        var cloneActive = false
        var clonePoints: [CGPoint] = []
        var patchPoints: [CGPoint] = []
        /// 与 clonePoints 一一对应的平移量（预览与导出必须用同一份，否则会"预览对、导出不对"）
        var cloneOffsets: [CGPoint] = []
        var cloneSource: CGPoint? = nil
        var cloneRadius = 0.6
        var warp: [WarpStroke] = []
        var freeze: [WarpStroke] = []
        var sky = SkyOptions()
        var autoCrop = false
        var rotateDeg = 0.0
        var flipH = false
        var quarterTurns = 0
        var cropRect: CGRect? = nil
        var cropApplied = false
        var liquifyAmount = 0.0
        var faceRect: CGRect? = nil      // 最大脸（归一化），整体液化用
    }



























    /// 人像参数同样有叠加/替换两种（逐项：新方案里非 0 的才盖）
    static let portraitKeys: [(String, WritableKeyPath<PortraitOptions, Double>)] = [
        ("faceBlemish", \.faceBlemish), ("spotBlemish", \.spotBlemish), ("mole", \.mole),
        ("shine", \.shine), ("sweat", \.sweat), ("darkCircle", \.darkCircle), ("eyebag", \.eyebag),
        ("nostril", \.nostril), ("lipLine", \.lipLine), ("doubleChin", \.doubleChin), ("jawLine", \.jawLine),
        ("teeth", \.teeth), ("eyes", \.eyes), ("lipColor", \.lipColor), ("blush", \.blush),
        ("hands", \.hands), ("feet", \.feet), ("faceSlim", \.faceSlim), ("eyeBig", \.eyeBig),
        ("noseSlim", \.noseSlim), ("chinShape", \.chinShape), ("forehead", \.forehead),
        // §414：一键上色（第三方模型 DDColor，可选下载）—— 进了这张表就与其它人像参数同构 ✓：
        // 能被预设保存/读取，也能被界面按同一套方式渲染 ✓。
        ("colorize", \.colorize)
    ]










}
