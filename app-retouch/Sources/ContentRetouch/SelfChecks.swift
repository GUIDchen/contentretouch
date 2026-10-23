// SelfChecks.swift：自检与诊断（从 ContentRetouchApp.swift 的 body.onAppear 整段搬出）。
// 为什么单独成文件：这段 600 多行全是命令行自检（CR_*）与诊断打印，
// 挂在视图构建链上既难读也难改；搬家后行为完全不变（同一个 self，@State 语义一致）。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 自检入口。原来直接写在 .onAppear 里，现在只留一行调用。
    func runSelfChecks() {
            // 重活挪到下一轮 runloop：onAppear 里同步做的每一毫秒，都会推迟窗口第一次上屏。
            // 实测踩到：带 --preview（内部要跑人物实例分割）时，6 秒后窗口**根本还没建出来**，
            // 自截图直接报「没有可截的窗口」。用户侧的表现就是「点开 App 半天不出画面」。
            // ⑤ 打开 App 时**不要把键盘焦点落在搜索框上**：SwiftUI 会把工具栏里的第一个
            // 可聚焦控件当初始第一响应者，于是"一进来打字就进了搜索框"。
            // 做法是在窗口起来之后主动清掉第一响应者（用户点搜索框仍然能输入）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            DispatchQueue.main.async {
            projects = ProjectStore.load()          // 启动时读回项目列表
            reloadTrash()
            // 启动**不再自动载入示例图**：之前一进 App 画布上就并排摆着「原图 / 效果」两张示例，
            // 用户看着像「我不知道什么时候导入了照片」。现在默认是空画布 + 一行提示，示例图改成按钮。
            // 但参数与目标仍要按第一条风格初始化——target 留空会让闭环追一个全黑目标。
            if srcURL == nil {
                styleIdx = min(styleIdx, max(-1, styles.count - 1))   // -1 = 未选中任何预设
                if !styles.isEmpty {
                    params = currentStyle.params
                    target = currentStyle.target
                }
            }
            }
            // 预设/风格先装好再处理命令行参数：--preset 要按名字找预设，
            // 而 reloadStyles 早先只在异步的 loadSample 里跑，导致命令行永远找不到（实测踩到）
            reloadStyles()
            // #5：启动时别把焦点落在顶栏的搜索框上——一进来就一圈蓝色焦点环、
            // 打字全进了搜索框，很不礼貌。把第一响应者交还给窗口。
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            // 验证用：--module 精修 --panel 3 直接进到指定视图（截图核对界面时省得手点）
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--module"), i + 1 < args.count { module = args[i + 1] }
            if let i = args.firstIndex(of: "--panel"), i + 1 < args.count, let p = Int(args[i + 1]) {
                panel = p
                module = "精修"
            }
            // 自检用：--import "a.jpg,b.jpg,某个目录" → 走的就是用户点「导入照片…」那条路
            if diagLog {   // 打印窗口几何，供外部用合成事件点在正确坐标上
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if let w = NSApp.windows.first {
                        FileHandle.standardError.write(String(format: "DIAG 窗口 frame=%@ 屏幕高=%.0f\n",
                            NSStringFromRect(w.frame), NSScreen.main?.frame.height ?? 0).data(using: .utf8)!)
                    }
                }
            }
            if let v = selfCheckValue("--import") {
                // 导入要跑一遍完整预览（人脸检测 + 3D 姿态 + 渲染 + 直方图），是**秒级**的同步活。
                // 放在 onAppear 里同步做，会把窗口第一次上屏推到 10 秒之后——自截图于是经常报
                // 「没有可截的窗口」。挪到下一轮 runloop：窗口先出来，重活随后。
                let urls = v.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
                // 延迟到窗口确实建好之后再导：实测「onAppear 里同步导」和「紧接着 async 导」
                // 都会让 **NSApp.windows 一直是 0**（窗口根本没被创建，自截图刷屏「没有可截的窗口」）；
                // 等 1.5 秒、窗口先落地再导，就稳定了。
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { importURLs(urls) }
            }
            // 自检用：--preset "通透" → 走的就是点预设那条路（参数 + 目标一起换）
            if let want = selfCheckValue("--preset") {
                if let s = styles.first(where: { $0.name == want }),
                   let idx = styles.firstIndex(where: { $0.name == want }) {
                    styleIdx = idx; params = s.params; target = s.target
                    FileHandle.standardError.write("已套用预设 \(want)：q50 目标 \(s.target.q50)\n".data(using: .utf8)!)
                    refresh()
                } else {
                    FileHandle.standardError.write("找不到预设 \(want)；可用：\(styles.prefix(8).map { $0.name }.joined(separator: " / "))\n".data(using: .utf8)!)
                }
            }
            // ⚠️ 自检参数一律用 --flag=value 的**单 token** 形式，不要用「--flag 值」的空格形式。
            // 实测踩到：给 app 传一个额外的裸参数（比如 "/tmp/emptydir" 或 "xyz"），窗口就**根本不会出现**
            //（NSApp.windows = 0，截图报「没有可截的窗口」）——那是 AppKit/SwiftUI 在启动时把裸参数当成
            // 「要打开的文件」处理了，跟我们的代码无关。写成 --flag=value 就绕开了。
            // 自检用：--run=pick:/tmp/目录 （export|pick|index|sim，目录可选）
            // 用来量内存与耗时（界面上点一次要人守着，命令行能自动量）
            if let spec = selfCheckValue("--run") {
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                let what = parts[0]
                let dirArg = parts.count > 1 ? parts[1] : ""
                // 组合使用时的时序：--import 在 1.5s 才把图装上，所以模拟与导出都必须排在它之后，
                // 否则 simulateTool 会因为「还没有图」直接返回（实测：裁剪没进导出）。
                if let sim = selfCheckValue("--simulate") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { simulateTool(sim) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                    let d = dirArg.isEmpty ? projectRoot + "/2604_wedding/00_RAW_readonly" : dirArg
                    FileHandle.standardError.write("自检 --run \(what) 目录 \(d)\n".data(using: .utf8)!)
                    switch what {
                    case "export":
                        selfCheckEcho = true
                        exportFolderAt(URL(fileURLWithPath: d))
                    case "pick": runPick(dir: URL(fileURLWithPath: d))
                    case "index": runIndex(dir: URL(fileURLWithPath: d))
                    case "sim": runSimilar()
                    default: break
                    }
                }
            }
            // 自检用：--watermark-image=/path/logo.png ｜ --watermark-text="…"
            // 水印只有在"导出"这条路上才看得见，所以体检必须能把它设起来（导出体检用）
            if let v = selfCheckValue("--reference") { refPaths = v.split(separator: ",").map(String.init) }
            // 自检用：导出设置矩阵（每项都有可算真值，见 tools/dist/audit_export.sh）
            if let v = selfCheckValue("--export-long-edge"), let n = Int(v) { export.maxLongEdge = n }
            if let v = selfCheckValue("--export-format") { export.format = v }
            if let v = selfCheckValue("--export-bit-depth"), let n = Int(v) { export.bitDepth = n }
            if let v = selfCheckValue("--export-color-space") { export.colorSpace = v }
            if let v = selfCheckValue("--export-name-template") { export.nameTemplate = v }
            if let v = selfCheckValue("--export-quality"), let n = Double(v) { export.quality = n }
            // 批量并行度也能从命令行设：界面里是 1/2/4/8 的手选，但"选几"一直只有注释里的
            // 一句「1=最省内存」，没有量过吞吐/内存的取舍。有了这个开关，体检才能把四个档位都跑一遍。
            if let v = selfCheckValue("--export-workers"), let n = Int(v), n >= 1 { exportWorkers = n }
            if let v = selfCheckValue("--watermark-image") { export.watermarkImagePath = v }
            if let v = selfCheckValue("--watermark-text") { export.watermarkText = v }
            // 重参数档（CR_BENCH_HEAVY=1 或 --bench-heavy）：空参数下管线常常退化成"原图直出"，
            // 量出来的 8 ms 不代表真实修图（§167.9 记的就是这个缺口）。这里把"真会干活"的那几个打开：
            // 磨皮/自动肤色走皮肤与肤色掩膜，补光/暗角/颗粒走像素运算，收腰走身体变形。
            //
            // ⚠️ 放在**顶层**而不是基准块里面：这样 --run=export 之类的自检也吃得到这组参数，
            // 于是"导出通路里掩膜要花多少"才量得出来（第 169 节之后的 B10 就是这个问题）。
            let benchHeavy = ProcessInfo.processInfo.environment["CR_BENCH_HEAVY"] != nil
                || selfCheckValue("--bench-heavy") != nil
            if benchHeavy {
                skinStrength = 80; autoSkinAmount = 80; lightAmount = 80
                vignetteAmount = 60; grainAmount = 80; slimWaist = 80
            }
            // 只开一个参数（CR_BENCH_ONLY=skin/autoskin/light/vignette/grain/slim/blemish/nostril）：
            // 用来**二分定位"图构建"的耗时花在谁身上**，比在 880 行管线里到处插计时器干净。
            if let only = ProcessInfo.processInfo.environment["CR_BENCH_ONLY"] {
                skinStrength = 0; autoSkinAmount = 0; lightAmount = 0
                vignetteAmount = 0; grainAmount = 0; slimWaist = 0
                switch only {
                case "skin": skinStrength = 80
                case "autoskin": autoSkinAmount = 80
                case "light": lightAmount = 80
                case "vignette": vignetteAmount = 60
                case "grain": grainAmount = 80
                case "slim": slimWaist = 80
                // 祛瑕类：§191 把斑点掩膜加强了 5~33 倍（threshold 终于生效），
                // 掩膜一变强，`bboxOfBright` 的包围盒就可能越过 18/40px 门槛 ⇒ 换成样例修补甚至 LaMa。
                // 所以必须单列这两档，量"加强"有没有把预览拖慢。
                case "blemish": portrait.faceBlemish = 100; portrait.spotBlemish = 100; portrait.mole = 100
                case "nostril": portrait.nostril = 100
                default: break
                }
            }
            // 性能自检：--bench-preview=30 → 跑 30 次预览并按阶段报中位/p95（滑杆手感就是它决定的）
            if let v = selfCheckValue("--bench-preview"), let n = Int(v), n > 0 {
                // 必须排在 --import（1.5s 装图）之后，否则 workImage() 还是 nil，跑出「0 次」。
                // ⚠️ 2026-09-26：还要**等图真的装成预览尺寸**再跑 —— 固定 3.5 秒在负载高时只等到占位图，
                // 于是量出 0.67 ms 这种"快得不可能"的数字（同一张图门里量的是 7.31 ms）。
                // 所以改成轮询 + 把"工作图尺寸"打在输出里：小图一眼就能看出来，不会再被误读成"变快了"。
                func benchReady() -> Bool {
                    guard let w = workImage() else { return false }
                    return Int(max(w.extent.width, w.extent.height)) >= 700
                }
                // 排在 --import 之后起跑，然后**轮询等图装好**（最多 15 秒），再做测量
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { benchRun(60) }
                func benchRun(_ tries: Int) {
                    if !benchReady() && tries > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { benchRun(tries - 1) }
                        return
                    }
                    var total: [Double] = [], pipe: [Double] = [], render: [Double] = [], hg: [Double] = []
                    var nilRender = 0
                    var outWH = "—"
                    for _ in 0..<n {
                        guard let ci = workImage() else { break }
                        let t0 = Date()
                        let out = renderPipeline(ci, geos: cachedGeos)
                        let t1 = Date()
                        outWH = String(Int(out.extent.width)) + "x" + String(Int(out.extent.height))
                        // ⚠️ createCGImage 返回 nil 时，旧写法是**静默跳过** —— 于是"出图"那一格量出 0.02 ms，
                        // 看着像"快到不可思议"，其实是这一步根本没做（2026-09-26 实测踩到）。
                        // 现在把它记数并打进输出，让"没做成"和"做得快"在小数点后面就能分开。
                        if let cg = sharedCtx.createCGImage(out, from: out.extent.integral) {
                            _ = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        } else {
                            nilRender += 1
                        }
                        let t2 = Date()
                        // 直方图这一段在 App 里是**异步**的（不在关键路径上），这里仍单独量出来，
                        // 好让"关键路径"与"总开销"两个数都看得见。
                        _ = histogram(out)
                        let t3 = Date()
                        pipe.append(t1.timeIntervalSince(t0) * 1000)
                        render.append(t2.timeIntervalSince(t1) * 1000)   // 出图：真正把 CI 图求值成位图
                        hg.append(t3.timeIntervalSince(t2) * 1000)
                        total.append(t3.timeIntervalSince(t0) * 1000)
                    }
                    func stat(_ a: [Double]) -> String {
                        let s = a.sorted()
                        guard !s.isEmpty else { return "—" }
                        // 用两位小数：分阶段耗时常常不到 1 ms，用 %.0f 会全印成 0，
                        // 看着像"没跑"，实际是精度不够（这一版就是被这个坑过一次）
                        // 多印一个"最小"：同一组参数连跑时，第 2 次起可能命中 CoreImage 的缓存，
                        // 于是中位数看着很快、其实第一次才是真耗时（2026-09-26：6MP 的图量出 0.07 ms
                        // 就是这么来的）。最小值和最大值一起印出来，这种假象就藏不住了。
                        return String(format: "中位 %.2f ms（最小 %.2f / 最大 %.2f / p95 %.2f）",
                                      s[s.count / 2], s[0], s[s.count - 1], s[min(s.count - 1, Int(Double(s.count) * 0.95))])
                    }
                    let ws = workImage().map { Int($0.extent.width) } ?? 0
                    let hs = workImage().map { Int($0.extent.height) } ?? 0
                    // ASCII 汇总行：跨进程取数一律走这种行（中文行只给人看，别拿去抠数字）
                    func quad(_ a: [Double]) -> (Double, Double, Double, Double) {
                        let s = a.sorted()
                        if s.isEmpty { return (0, 0, 0, 0) }
                        return (s[s.count / 2], s[0], s[s.count - 1], s[min(s.count - 1, Int(Double(s.count) * 0.95))])
                    }
                    let qt = quad(total), qr = quad(render), qh = quad(hg)
                    // only= 由应用自报：门里靠它确认"这一档真的开了那个参数"，
                    // 否则参数名写错时会拿空参数的成绩冒充（这类"等于没测"的绿是本项目的老坑）
                    let onlyTag = ProcessInfo.processInfo.environment["CR_BENCH_ONLY"] ?? "-"
                    let sumLine = "BENCH-SUM n=" + String(total.count) + " heavy=" + (benchHeavy ? "1" : "0")
                        + " only=" + onlyTag
                        + " zoom=" + String(Int(zoom)) + " work=" + String(ws) + "x" + String(hs)
                        + " median=" + String(format: "%.2f", qt.0) + " min=" + String(format: "%.2f", qt.1)
                        + " max=" + String(format: "%.2f", qt.2) + " p95=" + String(format: "%.2f", qt.3)
                        + " render_median=" + String(format: "%.2f", qr.0)
                        + " crit_median=" + String(format: "%.2f", qt.0 - qh.0) +
                          " hist_median=" + String(format: "%.2f", qh.0)
                        + " nil_render=" + String(nilRender) + "\n"
                    FileHandle.standardError.write(sumLine.data(using: .utf8)!)
                    let msg = "预览性能（" + String(total.count) + " 次，" + (benchHeavy ? "重参数" : "空参数") + "）：工作图 " + String(ws) + "x" + String(hs)
                        + "｜管线输出 " + outWH
                        + "｜总计 " + stat(total) + "｜图构建 " + stat(pipe) + "｜出图(求值成位图) " + stat(render)
                        + "｜直方图 " + stat(hg) + "｜出图失败 " + String(nilRender) + " 次"
                        + (ws < 700 ? "  ⚠️ 工作图没装成预览尺寸，这组数字不能用" : "")
                        + (nilRender > 0 ? "  ⚠️ 有出图失败，出图耗时不可信" : "")
                    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
                }
            }
            // 截图核对用：--tool=hand|crop|spot|patch|clone|brush 直接选中画布工具；--zoom=200；--cropshape=1
            if let v = selfCheckValue("--tool") {
                DispatchQueue.main.async { setCanvasTool(v) }
            }
            if let v = selfCheckValue("--zoom"), let z = Double(v) { zoom = z }
            if selfCheckValue("--split") != nil { splitCompare = true; singleView = true }
            // 自检：并排模式下"指针落在哪一栏"的坐标映射（本轮修的核心 bug）
            if ProcessInfo.processInfo.environment["CR_CANVASPT"] != nil {
                // ⚠️ 定时器要**早于**自截图流程退出进程（4.5s 试过，没输出；1.2s 能出来）。
                // 这类"自检没打印"很容易被误读成"代码没跑"，其实是进程先退了。
                // 图框要在图片加载并布局之后才上报，所以**轮询几次**而不是只等一次
                // ⚠️ 等待预算要够宽：paneFrames 要等 SwiftUI 布局出来，机器负载高时 4.8 秒根本不够
                //（实测：负载高时 12×0.4s 全部落空，探针报"没等到 paneFrames"，看起来像功能坏了）。
                func canvasProbe(_ tryIndex: Int) {
                    guard tryIndex < 60 else {
                        // 给门一个 ASCII 失败标记：没测到 ≠ 通过
                        FileHandle.standardError.write("CANVASPT-FAIL 30 秒内没等到 paneFrames\n".data(using: .utf8)!)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if paneFrames.isEmpty || srcImage == nil { canvasProbe(tryIndex + 1); return }
                        canvasProbe2()
                    }
                }
                func canvasProbe2() {
                    guard let img = srcImage, paneFrames.count > 0 else {
                        FileHandle.standardError.write("CANVASPT 没有 paneFrames\n".data(using: .utf8)!)
                        return
                    }
                    // 判据是**不变量**，与实现无关（这才是坐标映射该被卡住的方式）：
                    //   ① 每栏的中心点必须映射到图像中心 (0.500, 0.500) —— 任何缩放/并排位置下都成立
                    //   ② 栏内"3/4 宽、1/2 高"处必须映射到 (0.750, 0.500)
                    //   ③ 栏外一点必须映射为 nil（否则工具会对画面外的位置动手）
                    var out = "CANVASPT 图框数 \(paneFrames.count)\n"
                    // z 一起报出来：3/4 点的期望值依赖缩放（画面只露出一部分时 3/4 横跨栏 ≠ 图像 3/4）
                    // 预览尺寸也报出来：它随倍率自适应（放大看细节时不该是"被插值放大的低分图"）
                    let wi = workImage()
                    out += "  ｜ 预览 \(Int(wi?.extent.width ?? 0))x\(Int(wi?.extent.height ?? 0))（上限 \(previewMaxDim)）\n"
                    var sum = String(format: "CANVASPT-SUM panes=%d z=%.1f preview=%dx%d cap=%d",
                                     paneFrames.count, zoom,
                                     Int(wi?.extent.width ?? 0), Int(wi?.extent.height ?? 0), previewMaxDim)
                    var idx = 0
                    for (k, r) in paneFrames.sorted(by: { $0.value.minX < $1.value.minX }) {
                        let p = CGPoint(x: r.midX, y: r.midY)
                        let got = imagePoint(p, viewSize: r.size, imageSize: img.size)
                        let q = CGPoint(x: r.minX + r.width * 0.75, y: r.minY + r.height * 0.5)
                        let gotQ = imagePoint(q, viewSize: r.size, imageSize: img.size)
                        let outside = imagePoint(CGPoint(x: r.minX - 30, y: r.minY - 30), viewSize: r.size, imageSize: img.size)
                        sum += String(format: " c%d%@ q%d%@ out%d%d", idx,
                                      got.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "nil", idx,
                                      gotQ.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "nil", idx,
                                      outside == nil ? 1 : 0, idx)
                        // 同一点用**老口径**（把整块画布当一张图）算一遍，用来对照修好之前的行为
                        let old = displayedRect(viewSize: CGSize(width: paneFrames.values.map { $0.maxX }.max() ?? 1,
                                                                 height: r.height), imageSize: img.size)
                        let onx = (p.x - old.minX) / max(1, old.width)
                        let oldResult = (onx >= -0.02 && onx <= 1.02) ? String(format: "(%.2f, …)", onx) : "nil（工具无反应）"
                        out += String(format: "CANVASPT 栏 %@ x %.0f~%.0f → %@｜老口径 %@\n", k, r.minX, r.maxX,
                                      got.map { String(format: "(%.2f, %.2f)", $0.x, $0.y) } ?? "nil（会被当成不在图上 → 工具无反应）",
                                      oldResult)
                        idx += 1
                    }
                    out += sum + "\n"
                    FileHandle.standardError.write(out.data(using: .utf8)!)
                }
                canvasProbe(0)
            }
            // 自检：预设"再点一次 = 取消"（用户两次报"仍未实现"，所以必须有可复现的验证）
            if ProcessInfo.processInfo.environment["CR_PRESETTOGGLE"] != nil {
                func presetProbe(_ tryIndex: Int) {
                    guard tryIndex < 12 else {
                        FileHandle.standardError.write("PRESET 12 次都没等到预设加载\n".data(using: .utf8)!)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard styles.count > 1 else { presetProbe(tryIndex + 1); return }
                        // 挑一条"参数确实和当前不同"的预设，否则亮度都是 0，测了等于没测
                        func fp(_ q: Params) -> String {
                            String(format: "%.2f|%.2f|%.2f|%.2f|%.2f", q.brightness, q.contrast, q.desat,
                                   q.cbSh[0], q.levelsOut[1])
                        }
                        guard let s = styles.dropFirst().first(where: { fp($0.params) != fp(params) }) else {
                            FileHandle.standardError.write("PRESET 找不到参数不同的预设\n".data(using: .utf8)!); return
                        }
                        let before = params
                        applyPreset(s)                       // 第一次：套用
                        let applied = params
                        let matched = fp(applied) == fp(s.params)
                        applyPreset(s)                       // 第二次：应当 = 取消
                        let back = params
                        let restored = fp(back) == fp(before)
                        FileHandle.standardError.write(String(format:
                            "PRESET[%@] 第一次套用生效=%@（%@ → %@，期望 %@）；第二次退回原值=%@（%@，原 %@）\n",
                            s.name, matched ? "是" : "否", fp(before), fp(applied), fp(s.params),
                            restored ? "是" : "否", fp(back), fp(before)).data(using: .utf8)!)
                    }
                }
                presetProbe(0)
            }
            // 部位变形自检（CR_DEFORM）暂时撤掉：它一直编译不过（DispatchWorkItem 那个报错），
            // 而这一轮已经把该问的问清了（引擎 OK、App 侧峰值只有 1）。下轮用更小的探针重做。
            // 自检：部位变形端到端（⑧⑨）。小探针，别再加长——上一轮诊断代码写太长导致编译挂掉一整轮。
            if ProcessInfo.processInfo.environment["CR_PARTDEFORM"] != nil {
                func pdProbe(_ t: Int) {
                    guard t < 12 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard workImage() != nil else { pdProbe(t + 1); return }
                        let before = outImage
                        applyPartDeform(.eyes, kind: "大眼", amount: 80)
                        let n = warpStrokes.count
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            var peak = -1.0
                            if let b0 = before, let a0 = outImage,
                               let cgB = b0.cgImage(forProposedRect: nil, context: nil, hints: nil),
                               let cgA = a0.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                let W = 128, H = max(1, cgB.height * W / max(1, cgB.width))
                                var bb = [UInt8](repeating: 0, count: W * H * 4)
                                var aa = [UInt8](repeating: 0, count: W * H * 4)
                                sharedCtx.render(CIImage(cgImage: cgB), toBitmap: &bb, rowBytes: W * 4,
                                                 bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                                sharedCtx.render(CIImage(cgImage: cgA), toBitmap: &aa, rowBytes: W * 4,
                                                 bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                                for i in 0..<(W * H) {
                                    let d = (abs(Double(bb[i * 4]) - Double(aa[i * 4]))
                                             + abs(Double(bb[i * 4 + 1]) - Double(aa[i * 4 + 1]))
                                             + abs(Double(bb[i * 4 + 2]) - Double(aa[i * 4 + 2]))) / 3
                                    peak = max(peak, d)
                                }
                            }
                            FileHandle.standardError.write(String(format: "PARTDEFORM 大眼：笔触 %d 笔，画面峰值改动 %.0f\n", n, peak).data(using: .utf8)!)
                        }
                    }
                }
                pdProbe(0)
            }
            // 自检：**合成鼠标拖动**（这是我一直缺的手段——本机点不了鼠标，只能靠它验证拖动类功能）
            // 用法：CR_SYNTHDRAG=hand 或 =brush，会往窗口里投一串 mouseDown/Dragged/Up 事件，
            // 然后打印拖动前后的状态（平移量 / 笔触数），据此判断事件有没有走到处理函数里。
            if let mode = ProcessInfo.processInfo.environment["CR_SYNTHDRAG"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    guard let win = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 400 }) else {
                        FileHandle.standardError.write("SYNTHDRAG 没有可用窗口\n".data(using: .utf8)!); return
                    }
                    // 在"修后"那一栏的中心附近拖：有 paneFrames 就用它，没有就退回窗口中心
                    let target: CGRect = paneFrames.sorted(by: { $0.value.minX < $1.value.minX }).last?.value
                        ?? CGRect(x: 0, y: 0, width: win.frame.width, height: win.frame.height)
                    // ⚠️ paneFrames 是"画布局部坐标"，而鼠标事件是"窗口坐标"，必须换算过去
                    //（上一版直接拿局部坐标当窗口坐标用，按下点落到了右侧面板里，被监视器正确拒绝了）
                    let cf = canvasInput.canvasFrame
                    let winPt = NSPoint(x: cf.minX + target.midX,
                                        y: cf.minY + (cf.height - target.midY))   // 局部 y 自上而下 → 窗口 y 自下而上
                    let start = winPt
                    func post(_ t: NSEvent.EventType, _ p: NSPoint, _ n: Int) {
                        if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: win.windowNumber, context: nil,
                                                      eventNumber: n, clickCount: 1, pressure: 1) {
                            win.postEvent(e, atStart: false)
                        }
                    }
                    // 两种注入方式：window.postEvent（队列，**不会派发 dragged**）与 CGEvent（真实 HID，会派发）
                    let useCG = ProcessInfo.processInfo.environment["CR_CGDRAG"] != nil
                    FileHandle.standardError.write(("SYNTHDRAG 方式=" + (useCG ? "CGEvent(HID)" : "postEvent(队列)") + " 辅助功能授权=" + (AXIsProcessTrusted() ? "是" : "否") + "\n").data(using: .utf8)!)
                    func cg(_ type: CGEventType, _ p: NSPoint) {
                        // CGEvent 用**屏幕坐标、原点左上**
                        let scr = NSScreen.main?.frame.height ?? 0
                        let gp = CGPoint(x: p.x + (win.frame.minX), y: scr - (p.y + win.frame.minY))
                        if let ev = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                            mouseType: type, mouseCursorPosition: gp, mouseButton: .left) {
                            ev.post(tap: .cghidEventTap)
                        }
                    }
                    let pan0 = panOffset, strokes0 = warpStrokes.count
                    if useCG { cg(.leftMouseDown, start) } else { post(.leftMouseDown, start, 1) }
                    for i in 1...8 {
                        let p = NSPoint(x: start.x + CGFloat(i) * 12, y: start.y + CGFloat(i) * 4)
                        if useCG { cg(.leftMouseDragged, p) } else { post(.leftMouseDragged, p, i + 1) }
                    }
                    if useCG { cg(.leftMouseUp, NSPoint(x: start.x + 96, y: start.y + 32)) }
                    else { post(.leftMouseUp, NSPoint(x: start.x + 96, y: start.y + 32), 10) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        FileHandle.standardError.write(String(format:
                            "SYNTHDRAG mode=%@ 工具 hand=%@ brush=%@｜平移 (%.0f,%.0f)→(%.0f,%.0f)｜笔触 %d→%d\n",
                            mode, handTool ? "是" : "否", brushActive ? "是" : "否",
                            pan0.width, pan0.height, panOffset.width, panOffset.height,
                            strokes0, warpStrokes.count).data(using: .utf8)!)
                    }
                }
            }
            // 自检：给"滑杆双击复位"发一次**合成双击**，确认监视器那条路真的通。
            // （合成的 down/up 事件是能送达的，drag 不能——见第 78 节。）
            if ProcessInfo.processInfo.environment["CR_SLIDERCLICK"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let items = SliderResetStore.shared.debugItems()
                    guard let first = items.first, let win = NSApp.windows.first(where: { $0.isVisible }) else {
                        FileHandle.standardError.write("SLIDERCLICK 没有登记任何滑杆\n".data(using: .utf8)!); return
                    }
                    // 实测（第 104 节）：SwiftUI 的 .global 这里是**窗口内容坐标、原点左上**，
                    // 所以换成"窗口坐标、原点左下"只需按内容高翻一次 y，不要减窗口原点、不要碰屏幕。
                    let contentTop = win.contentView?.frame.maxY ?? win.frame.height
                    let target = items.min(by: { $0.rect.minY < $1.rect.minY }) ?? first
                    let winPt = NSPoint(x: target.rect.midX, y: contentTop - target.rect.midY)
                    func post(_ t: NSEvent.EventType, _ n: Int) {
                        if let e = NSEvent.mouseEvent(with: t, location: winPt, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: win.windowNumber, context: nil,
                                                      eventNumber: n, clickCount: n >= 3 ? 2 : 1, pressure: 1) {
                            win.postEvent(e, atStart: false)
                        }
                    }
                    FileHandle.standardError.write(String(format: "SLIDERCLICK 已登记 %d 个滑杆，取最上面的 目标矩形=%.0fx%.0f@%.0f,%.0f 投点(%.0f,%.0f)\n",
                        items.count, target.rect.width, target.rect.height, target.rect.minX, target.rect.minY,
                        winPt.x, winPt.y).data(using: .utf8)!)
                    for (i, w) in NSApp.windows.enumerated() {
                        let scrH = (w.screen ?? NSScreen.main)?.frame.maxY ?? 0
                        FileHandle.standardError.write(String(format:
                            "SLIDERWIN #%d num=%d 可见=%@ key=%@ 帧=%.0f,%.0f %.0fx%.0f 屏maxY=%.0f 内容=%@ 内容帧=%.0f,%.0f %.0fx%.0f\n",
                            i, w.windowNumber, w.isVisible ? "是" : "否", w.isKeyWindow ? "是" : "否",
                            w.frame.minX, w.frame.minY, w.frame.width, w.frame.height, scrH,
                            String(describing: type(of: w.contentView ?? NSView())),
                            w.contentView?.frame.minX ?? -1, w.contentView?.frame.minY ?? -1,
                            w.contentView?.frame.width ?? -1, w.contentView?.frame.height ?? -1).data(using: .utf8)!)
                    }
                    post(.leftMouseDown, 1); post(.leftMouseUp, 2)
                    post(.leftMouseDown, 3); post(.leftMouseUp, 4)   // 第二次 clickCount=2 → 这是双击
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        FileHandle.standardError.write(("SLIDERCLICK 结束：双击命中次数 = " + String(SliderResetStore.shared.hitCount) + "\n").data(using: .utf8)!)
                    }
                }
            }
            // ① ② ③ **真·输入**自检：用 CGEvent（真实 HID 事件）走一遍，不再用合成事件自欺。
            // 为什么必须换掉合成事件：第 103 节那次“命中 2 次”是假阳性 —— 合成事件和监视器
            // 用了同一个错误坐标假设，于是两边自洽地“通过”，而用户手上还是坏的。
            // CGEvent 走的是真实输入通道（抓手/液化的真拖动就是靠它验过的）。
            if let tr = ProcessInfo.processInfo.environment["CR_UITRACE"] {
                func runTrace(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 25 ? 4.5 : 0.5)) {
                    guard let win = NSApp.windows.first(where: { $0.isVisible }) else {
                        if tries > 0 { runTrace(tries - 1) }      // 窗口还没建好也要重试（原来直接 return = 空跑）
                        return
                    }
                    // 抢不到前台就整段重排：CGEvent 送不到时验的是"没送到"，不是功能（实测过 落点=0）
                    if tries > 0 && !NSApp.isActive {
                        NSApp.activate(ignoringOtherApps: true)
                        win.makeKeyAndOrderFront(nil)
                        runTrace(tries - 1)
                        return
                    }
                    // 必须自己抢到前台再投事件：CGEvent 是"真输入"，前台是谁就送给谁。
                    // ⚠️ 实测会偶发抢不到（那一轮落点=0、监视器一条都没收到）——所以要**等到真的
                    // isActive** 再开工，并在日志里把 active 状态写出来，避免再把"没送到"当成"功能坏"。
                    NSApp.activate(ignoringOtherApps: true)
                    win.makeKeyAndOrderFront(nil)
                    setCanvasTool(tr)
                    FileHandle.standardError.write(("UITRACE 前台=是（重试剩 " + String(tries) + "）\n").data(using: .utf8)!)
                    let scrH = NSScreen.main?.frame.height ?? 0
                    let contentTop = win.contentView?.frame.maxY ?? win.frame.height
                    // .global = 窗口内容坐标（左上原点）；CGEvent 用屏幕坐标（左上原点）
                    func post(_ t: CGEventType, _ contentPt: NSPoint, click: Int64 = 1,
                              flags: CGEventFlags = []) {
                        let baseY = contentTop - contentPt.y
                        let gp = CGPoint(x: win.frame.minX + contentPt.x, y: scrH - (win.frame.minY + baseY))
                        if let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                           mouseType: t, mouseCursorPosition: gp, mouseButton: .left) {
                            e.setIntegerValueField(.mouseEventClickState, value: click)
                            e.flags = flags
                            // 走真实 HID 通道。⚠️ 试过 postToPid（想绕开前台依赖）——**送不到 AppKit**，
                            // 落点依旧是 0；所以这里必须走 HID，并且**先等到 isActive** 再投。
                            e.post(tap: .cghidEventTap)
                        }
                    }
                    func cursorNote(_ tag: String) -> String {
                        let cur = NSCursor.current
                        let name = cur == NSCursor.crosshair ? "十字" : (cur == NSCursor.openHand ? "手" : (cur == NSCursor.closedHand ? "握拳" : "圈/其它"))
                        let sz = cur.image.size
                        return "UITRACE " + tag + "=" + name + " 尺寸 " + String(format: "%.0fx%.0f", sz.width, sz.height) + "\n"
                    }
                    // 真实的"会画几个圈"核算：拖动中只算当前这一笔（spotPoints.count - strokeStartSpot），
                    // 停下只留最后一个。上一版这里算的是"整个数组"，所以自检说 1、屏幕上是 3。
                    func drawnNote(_ tag: String) {
                        let n = strokeMarkLive ? max(0, spotPoints.count - strokeStartSpot) : min(1, spotPoints.count)
                        FileHandle.standardError.write(("UITRACE " + tag + " 落点=" + String(spotPoints.count)
                            + " 本笔起点=" + String(strokeStartSpot) + " 实时=" + (strokeMarkLive ? "开" : "关")
                            + " 会画的圈数=" + String(n) + " 工作区=" + (liquifyWorkspace ? "在" : "不在") + "\n").data(using: .utf8)!)
                    }
                    func ringNote(_ tag: String) {
                        let n = strokeMarkLive ? spotPoints.count : min(1, spotPoints.count)
                        FileHandle.standardError.write(("UITRACE " + tag + " 落点=" + String(spotPoints.count)
                            + " 实时标记=" + (strokeMarkLive ? "开" : "关") + " 画出的圈数=" + String(n) + "\n").data(using: .utf8)!)
                    }
                    let cf = canvasInput.canvasFrameGlobal
                    FileHandle.standardError.write(("UITRACE 工具=" + tr + " 辅助功能授权=" + (AXIsProcessTrusted() ? "是" : "否")
                        + " 画布=" + String(format: "%.0f,%.0f %.0fx%.0f", cf.minX, cf.minY, cf.width, cf.height)
                        + String(format: " 窗口=%.0f,%.0f %.0fx%.0f 缩放=%.0f", win.frame.minX, win.frame.minY,
                                 win.frame.width, win.frame.height, win.backingScaleFactor) + "\n").data(using: .utf8)!)
                    let cx = cf.midX, cy = cf.midY
                    let pts = [NSPoint(x: cx - 120, y: cy - 70), NSPoint(x: cx + 60, y: cy - 40), NSPoint(x: cx + 130, y: cy + 60)]
                    // 1) 光标：真鼠标移到画布中心，再读当前光标（这是用户眼睛看到的那一个）
                    post(.mouseMoved, NSPoint(x: cx, y: cy))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        FileHandle.standardError.write((cursorNote("画布上光标")).data(using: .utf8)!)
                        // 改一次笔刷范围，证明"圆圈能跟着大小变"
                        spotRadius = 6.0
                        post(.mouseMoved, NSPoint(x: cx + 20, y: cy + 20))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            FileHandle.standardError.write((cursorNote("改范围后")).data(using: .utf8)!)
                        }
                    }
                    // 2) 三次真点击 = 三次独立操作
                    for (i, p) in pts.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + 0.5 * Double(i)) {
                            post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                        ringNote("三次点击后")
                        // 3) 人为把它按成“卡住”的状态（用户遇到的就是这个），再做一次真点击 ——
                        //    修好后：点击一开始就复位，圈数应回到 1
                        strokeMarkLive = true
                        ringNote("人为卡住后")
                        let p4 = NSPoint(x: cx - 40, y: cy + 90)
                        post(.mouseMoved, p4); post(.leftMouseDown, p4); post(.leftMouseUp, p4)
                    }
                    // ③ 真拖动一笔（多落点）：拖动中只该画"当前这一笔"，不是整个历史
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
                        let a0 = NSPoint(x: cx - 150, y: cy + 120)
                        post(.mouseMoved, a0); post(.leftMouseDown, a0)
                        for i in 1...6 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08 * Double(i)) {
                                post(.leftMouseDragged, NSPoint(x: a0.x + CGFloat(i) * 18, y: a0.y + CGFloat(i) * 6))
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { drawnNote("拖动中") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { post(.leftMouseUp, NSPoint(x: a0.x + 108, y: a0.y + 36)) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { drawnNote("松手后") }
                    }
                    // ② 仿制图章：⌥ + 点击 = **中途随时换取样点**（用户要的快捷键+鼠标）
                    if tr == "clone" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            // 先留几个**污点修复**的落点，再切到仿制 —— 这正是用户遇到的情形：
                            // 用仿制时，污点/修补的提示圈不该跟着冒出来（第 3 条）。
                            spotActive = true
                            let s1 = NSPoint(x: cx - 60, y: cy - 90)
                            let s2 = NSPoint(x: cx + 40, y: cy - 20)
                            post(.mouseMoved, s1); post(.leftMouseDown, s1); post(.leftMouseUp, s1)
                            post(.mouseMoved, s2); post(.leftMouseDown, s2); post(.leftMouseUp, s2)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                spotActive = false; cloneActive = true
                                FileHandle.standardError.write(("UITRACE 切到仿制 污点落点=" + String(spotPoints.count)
                                    + "（接下来的叠加层判据里，污点应为不画）\n").data(using: .utf8)!)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                            func src() -> String {
                                cloneSource.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) } ?? "无"
                            }
                            func note(_ tag: String) {
                                let offs = cloneOffsets(clonePoints, epochs: cloneEpochs)
                                let o = offs.last.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "无"
                                let firstPt = clonePoints.first.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "无"
                                FileHandle.standardError.write(("UITRACE 仿制 " + tag + " 取样点=" + src()
                                    + " 首落点=" + firstPt + " 末点偏移=" + o
                                    + " 取样段数=" + String(cloneEpochs.count)
                                    + " 落点数=" + String(clonePoints.count) + "\n").data(using: .utf8)!)
                            }
                            note("开始")
                            let a = NSPoint(x: cx - 100, y: cy + 60)
                            let b = NSPoint(x: cx + 80, y: cy - 50)
                            post(.mouseMoved, a); post(.leftMouseDown, a); post(.leftMouseUp, a)   // 第一次点击 = 取样
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                let first = cloneSource
                                note("第一次点击后（应为取样点）")
                                // ⌥ + 点击 = 换取样点（带 .maskAlternate 的事件）
                                post(.mouseMoved, b, flags: .maskAlternate)
                                post(.leftMouseDown, b, flags: .maskAlternate)
                                post(.leftMouseUp, b, flags: .maskAlternate)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    note("⌥ 点击后（取样点应变，落点数不应增加）")
                                    FileHandle.standardError.write(("UITRACE 仿制 取样点已更换=" + (first != cloneSource ? "是" : "否") + "\n").data(using: .utf8)!)
                                }
                            }
                        }
                    }
                    // 111 「羽化/程度」这类工具属性必须真的进管线（原来缓存键漏了它们 → 改了画面纹丝不动）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 9.2) {
                        func sig(_ n: NSImage?) -> [UInt8]? {
                            guard let n, let cg = n.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                            let ci = CIImage(cgImage: cg)
                            let W = 96, H = max(1, Int(Double(W) * ci.extent.height / max(1, ci.extent.width)))
                            var buf = [UInt8](repeating: 0, count: W * H * 4)
                            let sc = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / ci.extent.width,
                                                                          y: CGFloat(H) / ci.extent.height))
                            sharedCtx.render(sc, toBitmap: &buf, rowBytes: W * 4,
                                             bounds: CGRect(x: 0, y: 0, width: W, height: H),
                                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                            return buf
                        }
                        let before = sig(outImage)
                        let useSpot = (tr == "spot")
                        if useSpot { spotFeather = 12 } else { cloneFeather = 12 }
                        refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            let after = sig(outImage)
                            if let a = before, let b = after {
                                var s = 0.0
                                for i in 0..<a.count { s += abs(Double(a[i]) - Double(b[i])) }
                                FileHandle.standardError.write(("UITRACE 改羽化后 工具=" + tr
                                    + String(format: " 画面平均差=%.2f（必须 > 0：0 就说明属性没进管线）", s / Double(a.count)) + "\n").data(using: .utf8)!)
                            }
                        }
                    }
                    // ① 修补/仿制：**关掉工具后效果必须还在**（用户报的正是"关闭后效果消失"）。
                    // ⚠️ 用直接置位来开关，不走 setCanvasTool 的"再点一次=关掉"逻辑 —— 上一版就是
                    // 被这个逻辑绕过去，结果比的是"开 vs 开"（差值 0.00 是空验，不是证据）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
                        func smallSig(_ n: NSImage?) -> [UInt8]? {
                            guard let n, let cg = n.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                            let ci = CIImage(cgImage: cg)
                            let W = 96, H = max(1, Int(Double(W) * ci.extent.height / max(1, ci.extent.width)))
                            var buf = [UInt8](repeating: 0, count: W * H * 4)
                            let sc = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / ci.extent.width,
                                                                          y: CGFloat(H) / ci.extent.height))
                            sharedCtx.render(sc, toBitmap: &buf, rowBytes: W * 4,
                                             bounds: CGRect(x: 0, y: 0, width: W, height: H),
                                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                            return buf
                        }
                        // 先确保"工具开着"，量一次
                        patchActive = (tr == "patch"); cloneActive = (tr == "clone"); spotActive = (tr == "spot")
                        refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            let on = smallSig(outImage)
                            let pts = tr == "patch" ? patchPoints.count : (tr == "clone" ? clonePoints.count : spotPoints.count)
                            // 再关掉工具，量一次
                            patchActive = false; cloneActive = false; spotActive = false; brushActive = false
                            refresh()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                let off = smallSig(outImage)
                                if let a = on, let b = off {
                                    var s = 0.0
                                    for i in 0..<a.count { s += abs(Double(a[i]) - Double(b[i])) }
                                    FileHandle.standardError.write(("UITRACE 关工具前后 落点数=" + String(pts)
                                        + " 工具开=" + String(realBrushActive) + " 画面平均差=" + String(format: "%.2f", s / Double(a.count))
                                        + "（0.00 = 效果完全保留；越大越说明效果丢了）\n").data(using: .utf8)!)
                                    // **反证**：把同一批落点清掉，画面必须变 —— 否则 0.00 是空验
                                    patchPoints = []; clonePoints = []; spotPoints = []
                                    refresh()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                        let cleared = smallSig(outImage)
                                        if let c2 = cleared, let o2 = off {
                                            var s2 = 0.0
                                            for i in 0..<c2.count { s2 += abs(Double(c2[i]) - Double(o2[i])) }
                                            FileHandle.standardError.write(("UITRACE 清空落点后 画面平均差=" + String(format: "%.2f", s2 / Double(c2.count))
                                                + "（必须明显 > 0，否则说明这批落点本来就没作用）\n").data(using: .utf8)!)
                                        }
                                    }
                                } else {
                                    FileHandle.standardError.write("UITRACE 关工具前后：拿不到图像\n".data(using: .utf8)!)
                                }
                            }
                        }
                    }
                    // ④ 开/关液化工作区：两套画布的落点标记不能互相串
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                        openLiquifyWorkspace()
                        // 在工作区里真推两笔：这样"退出后主画布不该留液化圈"才有东西可验
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            liquifyLastPoint = CGPoint(x: 0.5, y: 0.5)
                            pushAtLastPoint(dx: 1.0, dy: 0.3)
                            liquifyLastPoint = CGPoint(x: 0.55, y: 0.45)
                            pushAtLastPoint(dx: -0.8, dy: 0.4)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { drawnNote("液化工作区中") }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8.4) {
                        confirmLiquify()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { drawnNote("退出工作区后") }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                        ringNote("再点一次后")
                        // 4) 真双击滑杆：命中次数应该 +1（真输入，不是投队列）
                        let items = SliderResetStore.shared.debugItems()
                        let before = SliderResetStore.shared.hitCount
                        // 默认点最上面那根；CR_UITRACE_SLIDER=bottom 点最下面那根（用来验逐脸滑杆）
                        let pick = ProcessInfo.processInfo.environment["CR_UITRACE_SLIDER"] ?? "top"
                        if pick == "visible" { FileHandle.standardError.write(("UITRACE 可见滑杆 " + String(items.filter { $0.rect.midY > 0 && $0.rect.midY < contentTop }.count) + " / 登记 " + String(items.count) + "\n").data(using: .utf8)!) }
                        let inWindow = items.filter { $0.rect.midY > 0 && $0.rect.midY < contentTop }
                        let chosen = pick == "bottom" ? items.max(by: { $0.rect.minY < $1.rect.minY })
                                   : pick == "visible" ? inWindow.max(by: { $0.rect.minY < $1.rect.minY }) ?? items.min(by: { $0.rect.minY < $1.rect.minY })
                                   : items.min(by: { $0.rect.minY < $1.rect.minY })
                        if let top = chosen {
                            // 投 3 次：CGEvent 偶发投不中（前台/时序），一次没中不代表功能坏
                            let wp = NSPoint(x: top.rect.midX, y: top.rect.midY)
                            func attempt(_ n: Int) {
                                let b0 = SliderResetStore.shared.hitCount
                                post(.mouseMoved, wp)
                                post(.leftMouseDown, wp, click: 1); post(.leftMouseUp, wp, click: 1)
                                // 真人的两下之间是有间隔的（约 0.15s）。原来两下背靠背贴在一起，
                                // 和真人输入的事件序列可能根本不同 —— 这正是"自检过、手上坏"的温床。
                                // CR_UITRACE_SLOWDBL=1：第二下**只带 clickState=1**（系统不认它是双击，
                                // 正如手速稍慢的真实用户）—— 用来验证"自己记时间判断"那条路真的成立。
                                let slow = ProcessInfo.processInfo.environment["CR_UITRACE_SLOWDBL"] != nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + (slow ? 0.3 : 0.15)) {
                                    let c: Int64 = slow ? 1 : 2
                                    post(.leftMouseDown, wp, click: c); post(.leftMouseUp, wp, click: c)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                                    let d = SliderResetStore.shared.hitCount - b0
                                    FileHandle.standardError.write(("UITRACE 真双击滑杆=" + String(format: "%.0fx%.0f@%.0f,%.0f", top.rect.width, top.rect.height, top.rect.minX, top.rect.minY)
                                        + " 第" + String(n) + "次命中增量=" + String(d) + "（累计较开始时 " + String(SliderResetStore.shared.hitCount - before) + "）\n").data(using: .utf8)!)
                                    if d == 0 && n < 3 { attempt(n + 1) }
                                }
                            }
                            attempt(1)
                        } else {
                            FileHandle.standardError.write("UITRACE 没有任何滑杆登记\n".data(using: .utf8)!)
                        }
                    }
                }
                }
                runTrace(25)
            }
            // ② 自检：走"方向推动"这条保底通路推一笔（不经过鼠标拖动），并证明画面确实变了
            if ProcessInfo.processInfo.environment["CR_PUSH"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    openLiquifyWorkspace()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let before = outImage
                        liquifyLastPoint = CGPoint(x: 0.5, y: 0.5)
                        pushAtLastPoint(dx: 1.0, dy: 0.3)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            // 这里在 app 层，没有 coretest 的 diffMap：直接用图像的 mean 差
                            var changed = -1.0
                            // outImage 是 NSImage：先转成 CIImage 才能比像素
                            func ci(_ n: NSImage) -> CIImage? {
                                guard let cg = n.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                                return CIImage(cgImage: cg)
                            }
                            if let b0n = before, let a0n = outImage, let b = ci(b0n), let a = ci(a0n) {
                                // ⚠️ 别用 CIAreaAverage：整幅平均值对**局部**形变几乎不动
                                //（第一次就是这么得到 0.000 的，明明推了一笔）。缩到 96 宽逐像素比。
                                let W = 96, H = max(1, Int(Double(W) * a.extent.height / max(1, a.extent.width)))
                                func small(_ i: CIImage) -> [UInt8] {
                                    var buf = [UInt8](repeating: 0, count: W * H * 4)
                                    let sx = CGFloat(W) / i.extent.width
                                    let scaled = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
                                        .transformed(by: CGAffineTransform(scaleX: sx, y: sx))
                                    sharedCtx.render(scaled, toBitmap: &buf, rowBytes: W * 4,
                                                     bounds: CGRect(x: 0, y: 0, width: W, height: H),
                                                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                                    return buf
                                }
                                let b0 = small(b), a0 = small(a)
                                var s = 0.0
                                for i in 0..<(W * H) {
                                    s += (abs(Double(b0[i * 4]) - Double(a0[i * 4]))
                                          + abs(Double(b0[i * 4 + 1]) - Double(a0[i * 4 + 1]))
                                          + abs(Double(b0[i * 4 + 2]) - Double(a0[i * 4 + 2]))) / 3.0
                                }
                                changed = s / Double(max(1, W * H))
                            }
                            FileHandle.standardError.write(String(format:
                                "PUSH 自检：方向推动一笔 → 画面平均改动 %.3f（笔数 %d）\n",
                                changed, warpStrokes.count).data(using: .utf8)!)
                        }
                    }
                }
            }
            if ProcessInfo.processInfo.environment["CR_AUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { auditPipelineParameters() }
            }
            // 交互工具体检：导入在 1.5s 才把图装上，所以排到 4.0s（simulateTool 依赖 srcURL）
            if ProcessInfo.processInfo.environment["CR_TOOLAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditToolPipeline() }
            }
            if ProcessInfo.processInfo.environment["CR_UNDOAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditUndoRedo() }
            }
            if ProcessInfo.processInfo.environment["CR_STRIPAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditStripStates() }
            }
            if ProcessInfo.processInfo.environment["CR_PRESETAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditPresets() }
            }
            if ProcessInfo.processInfo.environment["CR_DCAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { auditDarkCircle() }
            }
            if ProcessInfo.processInfo.environment["CR_BIAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { auditBlemishItems() }
            }
            if ProcessInfo.processInfo.environment["CR_NOAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { auditNostril() }
            }
            if ProcessInfo.processInfo.environment["CR_MCAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditMaskCover() }
            }
            if ProcessInfo.processInfo.environment["CR_COLAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditColorChain() }
            }
            if ProcessInfo.processInfo.environment["CR_SHINEAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { auditShine() }
            }
            if ProcessInfo.processInfo.environment["CR_STROKEAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { auditStrokePerImage() }
            }
            if ProcessInfo.processInfo.environment["CR_SYNCAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { auditSyncToSelected() }
            }
            if ProcessInfo.processInfo.environment["CR_MASKREDUCE"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditMaskReduce() }
            }
            if ProcessInfo.processInfo.environment["CR_SMARTAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditSmartActions() }
            }
            if ProcessInfo.processInfo.environment["CR_REFAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditReference() }
            }
            if ProcessInfo.processInfo.environment["CR_SCENEAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditSceneSuggest() }
            }
            if ProcessInfo.processInfo.environment["CR_PARTAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditParts() }
            }
            if ProcessInfo.processInfo.environment["CR_LIMBSEG"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { auditLimbSeg() }
            }
            if let p = ProcessInfo.processInfo.environment["CR_DUMPLABELS"], !p.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { dumpLabelMap(p) }
            }
            if ProcessInfo.processInfo.environment["CR_STRESSAUDIT"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { auditStress() }
            }
            if selfCheckValue("--liquifyws") != nil || ProcessInfo.processInfo.environment["CR_LIQUIFYWS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { openLiquifyWorkspace() }
            }
            // 自检：--simulate=spot|patch|clone|crop|liquify —— 把「在图上涂一笔/拖一个裁剪框」
            // 这件事用代码做一遍，验证「工具 → 状态 → 渲染」这条链真的通（不是只验证核心函数）。
            if let sim = selfCheckValue("--simulate") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { simulateTool(sim) }
            }
            if let v = selfCheckValue("--splitpos"), let p = Double(v) { splitPos = min(1, max(0, p)) }
            if let v = selfCheckValue("--cropshape"), let c = Int(v) { cropShape = c }
            // 截图核对用：--facetab 0..3 直接切到人像美化的某个页签；--presetgroup 展开某个预设分类
            if let v = selfCheckValue("--facetab"), let t = Int(v) {
                faceTab = min(3, max(0, t))
            }
            if let v = selfCheckValue("--presetgroup") {
                openPresetGroup = v
                showPresets = true
            }
            // 预置一套人像参数，便于截图核对。同样支持环境变量（CR_PREVIEW=1）：
            // 裸的 "--preview" 也属于「会挡住窗口」的那类 argv（见 selfCheckValue 的说明）。
            if args.contains("--preview") || ProcessInfo.processInfo.environment["CR_PREVIEW"] == "1" {
                portrait.teeth = 60; portrait.eyes = 55; portrait.spotBlemish = 40
                portrait.darkCircle = 50; portrait.faceSlim = 30; portrait.lipColor = 25
                skinGrade = "medium"; skinTone = true
                // 「按人处理」要跑人物实例分割，慢；也放到下一轮 runloop，别挡住窗口上屏
                DispatchQueue.main.async {
                    let persons = ensurePersons()
                    if persons.count >= 2 {
                        personSkin = persons.enumerated().map { $0.offset == 0 ? 85.0 : 10.0 }
                        FileHandle.standardError.write("按人处理自检：\(persons.count) 人，强度 \(personSkin)\n".data(using: .utf8)!)
                    }
                    refresh()
                }
            }
    }










}
