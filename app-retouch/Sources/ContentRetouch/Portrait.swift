// Portrait.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// **全管线参数有效性体检**：把 app 层的每个参数拉满，看画面动没动。
    ///
    /// 为什么要单独做一份：coretest 只能体检核心层（render / applyPortrait），
    /// 而 renderPipeline 里还有几十个参数是**只有 app 层才有**的（自动白平衡、降噪、暗角、
    /// 镜头校正、宠物、换天空…）。这些参数一旦在某处被短路，界面上同样"拖了没反应"。
    /// 上一轮就是在核心层抓到「中间调 0.00」的，这个器子换个层面继续用。
    func auditPipelineParameters() {
        guard let img = workImage() else {
            FileHandle.standardError.write("AUDIT 没有工作图，先 --import 一张\n".data(using: .utf8)!); return
        }
        let e = img.extent
        let W = Int(e.width), H = Int(e.height)
        func rgb(_ i: CIImage) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: W * H * 4)
            sharedCtx.render(i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)),
                             toBitmap: &b, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return b
        }
        let baseBuf = rgb(renderPipeline(img, geos: cachedGeos))
        func diff() -> Double {
            let b = rgb(renderPipeline(img, geos: cachedGeos))
            var s = 0.0
            for i in 0..<(W * H) {
                s += Double(abs(Int(baseBuf[i * 4]) - Int(b[i * 4]))
                            + abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1]))
                            + abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2]))) / 3.0
            }
            return s / Double(max(1, W * H))
        }
        // ⚠️ 度量必须两个都报：**全图平均**会把局部效果稀释成 0。
        // 收腰/宽肩只动肩腰那一小块（约 1% 像素），就算那里变化 30 级，全图平均也只有 0.2 ——
        // 上一版体检就因此把它们判成"几乎没动"，实际是"动了但很局部"。
        var rows: [(String, Double, Double)] = []
        func localPeak() -> Double {
            let b = rgb(renderPipeline(img, geos: cachedGeos))
            var dv = [Double](repeating: 0, count: W * H)
            for i in 0..<(W * H) {
                    dv[i] = Double(max(abs(Int(baseBuf[i * 4]) - Int(b[i * 4])),
                                   max(abs(Int(baseBuf[i * 4 + 1]) - Int(b[i * 4 + 1])),
                                       abs(Int(baseBuf[i * 4 + 2]) - Int(b[i * 4 + 2])))))
            }
            var best = 0.0
            for v in dv where v > best { best = v }
            return best
            // ⚠️ 这里曾经试过"3×3 均值之后再取峰值"（想压掉开关任一参数带来的重采样底噪），
            // 但**没有量到收益**：那套推理建立在"参数门看不见 §191 的改动"上，后来查明真正原因是
            // **这个门压根不测人像祛瑕那 10 项**（它覆盖的是影调/几何/工具/磨皮/祛油光共 28 项，§193）。
            // 按本项目的规矩：没量到收益的复杂度不留 —— 已还原成单点最大差，基线不受影响。
        }
        func probe(_ name: String, _ on: () -> Void, _ off: () -> Void) {
            on()
            let d = diff()
            let peak = localPeak()
            off()
            rows.append((name, d, peak))
        }
        // 影调补充
        probe("自动白平衡", { autoWB = 80 }, { autoWB = 0 })
        probe("自动曝光", { autoExposeAmount = 80 }, { autoExposeAmount = 0 })
        // 高光恢复只作用于**接近过曝**的像素（阈值 0.90）。如果这张图压根没有那样的像素，
        // 它测出来必然是 0——那不是 bug。所以先量一下"过曝像素占比"再一起报出来。
        do {
            var clipped = 0
            for i in 0..<(W * H) where baseBuf[i * 4] > 230 && baseBuf[i * 4 + 1] > 230 && baseBuf[i * 4 + 2] > 230 {
                clipped += 1
            }
            let frac = Double(clipped) / Double(max(1, W * H))
            probe("高光恢复", { highlightRecover = 80 }, { highlightRecover = 0 })
            rows[rows.count - 1].0 = String(format: "高光恢复(过曝像素仅%.1f%%)", frac * 100)
        }
        probe("降噪", { denoiseAmount = 80 }, { denoiseAmount = 0 })
        probe("锐化", { sharpenAmount = 80 }, { sharpenAmount = 0 })
        probe("智能锐化", { smartSharpen = 80 }, { smartSharpen = 0 })
        probe("自动补光", { autoFill = 80 }, { autoFill = 0 })
        probe("背景虚化", { bgBlur = 80 }, { bgBlur = 0 })
        // 边缘优化**必须配着虚化测**：没有虚化时它无事可做（这是修好之后的正确行为）。
        // 这里量的是"在虚化之上"的增量，所以基准要换成"只虚化"那一版。
        probe("边缘优化", { edgeRefine = 80 }, { edgeRefine = 0 })
        rows[rows.count - 1].0 = "边缘优化(无虚化时无事可做)"
        do {
            bgBlur = 60
            let blurBuf = rgb(renderPipeline(img, geos: cachedGeos))
            edgeRefine = 80
            let both = rgb(renderPipeline(img, geos: cachedGeos))
            var s = 0.0
            for i in 0..<(W * H) {
                s += Double(abs(Int(blurBuf[i * 4]) - Int(both[i * 4]))
                            + abs(Int(blurBuf[i * 4 + 1]) - Int(both[i * 4 + 1]))
                            + abs(Int(blurBuf[i * 4 + 2]) - Int(both[i * 4 + 2]))) / 3.0
            }
            edgeRefine = 0; bgBlur = 0
            // 这一行是手工算的增量（基准换成"只虚化"那一版），所以峰值也给一份
            var peakB = 0
            for i in 0..<(W * H) {
                let d = max(abs(Int(blurBuf[i * 4]) - Int(both[i * 4])),
                            max(abs(Int(blurBuf[i * 4 + 1]) - Int(both[i * 4 + 1])),
                                abs(Int(blurBuf[i * 4 + 2]) - Int(both[i * 4 + 2]))))
                peakB = max(peakB, d)
            }
            rows.append(("边缘优化(配虚化，增量)", s / Double(max(1, W * H)), Double(peakB)))
        }
        probe("暗角", { vignetteAmount = 60 }, { vignetteAmount = 0 })
        probe("颗粒", { grainAmount = 80 }, { grainAmount = 0 })
        probe("补光(方向)", { lightAmount = 80 }, { lightAmount = 0 })
        // 几何
        probe("镜头畸变", { lensDistortion = 30 }, { lensDistortion = 0 })
        probe("暗角校正", { lensVignette = 50 }, { lensVignette = 0 })
        probe("色差校正", { lensCA = 50 }, { lensCA = 0 })
        probe("透视-水平", { perspH = 30 }, { perspH = 0 })
        probe("透视-垂直", { perspV = 30 }, { perspV = 0 })
        // 人像与身体
        // ⚠️ 磨皮/自动肤色都按**皮肤掩膜**走，没有脸时它们必然是 0——不是死控件。
        // 体检表的每一行都该知道自己为什么是 0（第 128 节立的规矩），所以把检出脸数写进标签。
        let faceCount = cachedGeos.count
        probe("磨皮强度", { skinStrength = 80 }, { skinStrength = 0 })
        // 祛油光（对标像素蛋糕「祛除瑕疵 · 祛油光（脸部）」）：只压高光顶，
        // 变化应当集中在画面**亮部**。先让它进参数矩阵成为"活的"参数，亮部判据随后补（§188）
            probe("祛黑眼圈", { portrait.darkCircle = 80 }, { portrait.darkCircle = 0 })
        rows[rows.count - 1].0 = "磨皮强度(依皮肤掩膜｜检出脸 \(faceCount))"
        probe("自动肤色", { autoSkinAmount = 80 }, { autoSkinAmount = 0 })
        rows[rows.count - 1].0 = "自动肤色(依肤色掩膜｜检出脸 \(faceCount))"
        // 身体塑形依赖 2D 人体姿态的关键点：**检测不到关节时它就是 0，那不是死控件**。
        // 所以先把检出量打出来，让 0 能自证（体检表的每一行都该知道自己为什么是 0）。
        var joints = 0
        if let cgA = sharedCtx.createCGImage(img, from: e) {
            let bp = detectBodyPoints(cgA, extent: e)
            for p in [bp.leftShoulder, bp.rightShoulder, bp.leftElbow, bp.rightElbow,
                      bp.leftWrist, bp.rightWrist, bp.leftHip, bp.rightHip,
                      bp.leftKnee, bp.rightKnee, bp.leftAnkle, bp.rightAnkle] where p != nil { joints += 1 }
        }
        probe("收腰", { slimWaist = 80 }, { slimWaist = 0 })
        rows[rows.count - 1].0 = "收腰(检出关节 \(joints)/12)"
        probe("宽肩", {
            wideShoulders = 80
            // 对质：同一状态下的两个度量必须一致（签名在变、逐像素却不变 → 度量本身有问题）
            let sigBase = diagSig(img)
            // 这里原来还有一行 sigNow = diagSig(renderPipeline(...))：算完没用过（还白跑一次渲染），
            // 下面用 sig80/sig0 做一对一对比，2026-09-26 删。
            let bufNow = rgb(renderPipeline(img, geos: cachedGeos))
            var dsum = 0.0
            for i in 0..<(W * H) { dsum += abs(Double(baseBuf[i * 4]) - Double(bufNow[i * 4])) }
            // 一对一对比：**同一处**只改宽肩，量两次（避免把别探针的样本混看 —— 上一版就是这么误判的）
            let out80 = renderPipeline(img, geos: cachedGeos)
            let sig80 = diagSig(out80)
            let ext80 = out80.extent
            wideShoulders = 0
            let out0 = renderPipeline(img, geos: cachedGeos)
            let sig0 = diagSig(out0)
            wideShoulders = 80
            FileHandle.standardError.write(String(format:
                "XCHECK 宽肩一对一：80→%d ｜ 0→%d ｜ 差 %d ｜ extent %.0fx%.0f vs 工作图 %.0fx%.0f ｜ 签名基准 %d\n",
                sig80, sig0, sig80 - sig0, ext80.width, ext80.height, e.width, e.height, sigBase).data(using: .utf8)!)
            // 指标互相矛盾时，**把图存下来直接看**（比继续猜哪个指标对更省事）。
            // 默认不写盘，需要时用 CR_AUDIT_DUMP=1。
            if ProcessInfo.processInfo.environment["CR_AUDIT_DUMP"] == "1" {
                _ = write(out80, to: URL(fileURLWithPath: "/tmp/xc_ws80.png"), format: "png", quality: 100)
                _ = write(out0, to: URL(fileURLWithPath: "/tmp/xc_ws0.png"), format: "png", quality: 100)
                FileHandle.standardError.write("XCHECK 已写出 /tmp/xc_ws80.png 与 /tmp/xc_ws0.png\n".data(using: .utf8)!)
            }
            FileHandle.standardError.write(String(format: "XCHECK 逐像素：平均差 %.3f ｜ 缓冲 %d/%d\n",
                dsum / Double(W * H), bufNow.count, baseBuf.count).data(using: .utf8)!)
        }, { wideShoulders = 0 })
        rows[rows.count - 1].0 = "宽肩(检出关节 \(joints)/12)"
        // 对照：**绕过管线**直接调 reshapeBody —— 用来区分"管线没走到"与"reshapeBody 本身没效果"
        do {
            var peakDirect = 0
            let direct = reshapeBody(img, slimWaist: 0, wideShoulders: 80)
            let a = rgb(direct)
            for i in 0..<(W * H) {
                peakDirect = max(peakDirect, Int(abs(Int(baseBuf[i * 4]) - Int(a[i * 4]))))
            }
            rows.append(("宽肩(直接调 reshapeBody)", 0, Double(peakDirect)))
            FileHandle.standardError.write(String(format: "AUDIT 对照：reshapeBody 直接调用峰值 %d ｜ bodyDeformFactor %.2f ｜ bodyYaw %@\n",
                peakDirect, bodyDeformFactor, bodyYawText).data(using: .utf8)!)
        }
        // 整体液化是「对**最大的一张脸**做膨胀」（见 finishStage）——没脸时 0 是正确行为。
        probe("整体液化", { liquifyAmount = 60 }, { liquifyAmount = 0 })
        rows[rows.count - 1].0 = "整体液化(依最大一张脸｜检出脸 \(faceCount))"
        // 衣物/宠物/背景/天空
        probe("衣物平整", { clothesStrength = 80 }, { clothesStrength = 0 })
        probe("宠物美化", { petStrength = 80 }, { petStrength = 0 })
        do {
            // 宠物美化要先"认出宠物"：这张图没有宠物就必然是 0（不是死控件）
            var pets = 0
            if let cgP = sharedCtx.createCGImage(img, from: e) { pets = detectAnimalInfos(cgP, extent: e).count }
            rows[rows.count - 1].0 = "宠物美化(检出宠物 \(pets) 只)"
        }
        probe("背景纯化", { bgPurify = 80 }, { bgPurify = 0 })
        probe("换天空", { sky.amount = 100; sky.style = "晴天蓝" }, { sky.amount = 0 })
        do {
            // 换天空要先"认出天空"（亮度+位置+蓝度+主体扣除）。没天空的照片必然是 0，
            // 所以先量一次可换面积，写进标签让 0 自证。
            var s = SkyOptions(); s.amount = 100; s.style = "晴天蓝"
            let cov = replaceSky(img, s).coverage
            rows[rows.count - 1].0 = String(format: "换天空(可换面积 %.1f%%)", cov * 100)
        }
        let sorted = rows.sorted { $0.1 > $1.1 }
        var out = String(format: "AUDIT 上下文：工作图 %.0fx%.0f，cachedGeos %d 个，faces %d 个，有 srcURL %@\n",
                         e.width, e.height, cachedGeos.count, faces.count, srcURL == nil ? "否" : "是")
        out += "AUDIT 全管线参数有效性（全图平均差 ｜ 局部峰值=99分位）\n"
        var deadList: [String] = []
        for (n, v, peak) in sorted {
            // **判死标准是两者都≈0**：局部类控件（收腰/宽肩/宠物）平均差天然很小，
            // 只要局部峰值起来了就是好的；两个都趴着才是真死。
            let dead = v < 0.05 && peak < 2   // 平均与最大**都**趴着才算死（局部效果平均必然很小）
            if dead { deadList.append(n) }
            out += String(format: "AUDIT %-16@ 均值 %.2f ｜ 峰值 %.0f%@\n", n, v, peak,
                          dead ? "   <== 疑似没动" : "")
        }
        out += deadList.isEmpty ? "AUDIT 结论：全部参数都能改变画面 ✅\n"
                                : "AUDIT 结论：疑似没动 —— " + deadList.joined(separator: "、") + "\n"
        FileHandle.standardError.write(out.data(using: .utf8)!)
    }

    ///   · 大眼/瘦鼻/唇形/额头/下巴 = 在对应关键点位置做膨胀/收缩/推移一笔。
    ///
    /// ⚠️ 笔触构造**已抽到 RetouchCore.partDeformStrokes**（纯函数）：
    /// 这里只负责"检关键点 + 入历史 + 触发重渲"。
    /// 之前 App 里自己有一份构造逻辑，与 coretest 测的那份**不是同一份**——
    /// 结果 coretest 里修好的"腿·瘦 被五官分支接走"那个 bug，在 App 里一直还在。
    func applyPartDeform(_ part: BodyPart, kind: String, amount: Double) {
        guard amount > 0.01, let img = workImage() else { return }
        let e = img.extent
        var strokes: [WarpStroke] = []
        if let cg = sharedCtx.createCGImage(img, from: e) {
            let geos = detectFaceGeos(cg, size: e.size)
            let body = detectBodyPoints(cg, extent: e)
            strokes = partDeformStrokes(part: part, kind: kind, amount: amount,
                                        geos: geos, body: body, extent: e)
        }
        guard !strokes.isEmpty else { status = "这一部位在这张图上没有可用关键点（换个能看清该部位的照片试试）"; return }
        pushHistory("部位变形·" + kind)
        warpStrokes.append(contentsOf: strokes)
        status = String(format: "%@ %@：已作用 %d 笔（可进液化工作区继续调）", part.rawValue, kind, strokes.count)
        refresh()
    }

    /// 检查一遍各部位在这张图上是否有掩膜（按下按钮才算，避免每次重绘都跑）
    func checkParts() {
        guard let img = workImage() else { return }
        var ok: Set<String> = []
        for p in BodyPart.allCases where partMask(img, part: p, geos: cachedGeos) != nil { ok.insert(p.rawValue) }
        partAvailable = ok
        partChecked = Set(BodyPart.allCases.map { $0.rawValue })
        status = "部位检查完成：可用 " + (ok.isEmpty ? "（一个都没检出）" : ok.sorted().joined(separator: "、"))
    }

    /// 需要时才给某个部位建一条调整记录
    func ensurePart(_ raw: String) {
        if !partAdjusts.contains(where: { $0.part == raw }) { partAdjusts.append(PartAdjust(part: raw)) }
    }

    /// 装配「按脸参数」：single=只给选中的那张脸；all=每张脸同一份；partial=只给勾选的若干张
    func perFaceParams() -> [Int: Params] {
        var out: [Int: Params] = [:]
        for fa in faces {
            if faceScope == "single" && fa.index != selectedFace { continue }
            if faceScope == "partial" && !selectedFaces.contains(fa.index) { continue }
            let b = faceBrightness[fa.index] ?? 0
            let w = faceWarmth[fa.index] ?? 0
            if abs(b) < 0.01 && abs(w) < 0.01 { continue }
            var p = params
            p.brightness = max(-50, min(50, p.brightness + b))
            p.cbSh = [p.cbSh[0] + w / 2, p.cbSh[1], p.cbSh[2] - w / 2]
            p.cbHi = [p.cbHi[0] + w / 2, p.cbHi[1], p.cbHi[2] - w / 2]
            out[fa.index] = p
        }
        return out
    }

    // MARK: 工作图缓存（性能：滑杆交互只跑预览分辨率）
    //
    // 整条链路的耗时随像素数增长，而滑杆是连续拖的；所以预览用降采样工作图，
    // 导出/批量仍走全分辨率。人脸与关键点按 URL 缓存一次，拖滑杆不再重复跑 Vision。
    func workImage() -> CIImage? {
        guard let u = srcURL else { return nil }
        if let c = cachedImage, cachedURL == u, cachedMaxDim == previewMaxDim { return c }
        guard let img = loadAnyImage(u.path, maxDim: previewMaxDim) else { return nil }
        cachedURL = u; cachedImage = img; cachedMaxDim = previewMaxDim
        versions = VersionStore.versions(of: u.path)      // 换图才读一次版本列表
        if bodyYawURL != u {
            // 3D 姿态是一次完整的 Vision 推理（几十~几百毫秒），而它只服务于「全身美型」那一栏。
            // 放在主线程的 refresh 里，导入一张图就要卡住好几百毫秒——启动时更是会把窗口上屏一起拖住。
            // 所以：先置空，扔到后台算，算完再回主线程填。
            bodyYawURL = u
            bodyYaw = (0, false)
            let cgForYaw = sharedCtx.createCGImage(img, from: img.extent)
            DispatchQueue.global(qos: .utility).async {
                let r = cgForYaw.map { bodyYaw3D($0) } ?? (0, false)
                DispatchQueue.main.async {
                    if bodyYawURL == u { bodyYaw = r }
                }
            }
        }
        if cachedFaceURL != u {
            if let cg = sharedCtx.createCGImage(img, from: img.extent) {
                let e = img.extent
                cachedGeos = detectFaceGeos(cg, size: e.size)
                faces = cachedGeos.map { g in
                    FaceInfo(index: g.index,
                             rect: CGRect(x: g.box.minX / max(1, e.width), y: g.box.minY / max(1, e.height),
                                          width: g.box.width / max(1, e.width), height: g.box.height / max(1, e.height)),
                             quality: g.quality, geo: g)
                }
                faceCount = faces.count
                if let first = faces.first, !faces.contains(where: { $0.index == selectedFace }) {
                    selectedFace = first.index
                }
            }
            cachedFaceURL = u
        }
        return img
    }

    /// 归一化坐标（画布上存的落点一律用 0~1）→ 当前工作图的像素坐标。
    /// 这样预览与导出（分辨率不同）的笔刷落点完全一致。
    func denorm(_ p: CGPoint, _ e: CGRect) -> CGPoint {
        CGPoint(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height)
    }

    /// 半径按长边百分比存
    func radiusPx(_ ratio: Double, _ e: CGRect) -> Double {
        ratio / 100.0 * Double(max(e.width, e.height))
    }

    /// 诊断用：把一张图缩成 64 宽后的字节和（用来判断"中间结果有没有被后面的步骤丢掉"）
    func diagSig(_ i: CIImage) -> Int {
        let W2 = 64, H2 = max(1, Int(Double(W2) * i.extent.height / max(1, i.extent.width)))
        var o = [UInt8](repeating: 0, count: W2 * H2 * 4)
        let sc = i.cropped(to: i.extent).transformed(by: CGAffineTransform(scaleX: CGFloat(W2) / i.extent.width,
                                                                         y: CGFloat(H2) / i.extent.height))
        sharedCtx.render(sc, toBitmap: &o, rowBytes: W2 * 4,
                         bounds: CGRect(x: 0, y: 0, width: W2, height: H2),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var s = 0
        for v in o { s += Int(v) }
        return s
    }

    /// 后台算一次直方图并回主线程应用；期间如果又刷新过，就算完再补一次（最多补一次）。
    /// 为什么要"单飞"：直方图要**求值一遍整条管线**（20.9MP 时几十毫秒），
    /// 拖滑杆时每秒几十次刷新 → 后台任务无界排队 → 一起抢 CIContext、把主线程拖住（§173）。
    func runHistogram(_ out: CIImage) {
        let seq = histSeq
        DispatchQueue.global(qos: .utility).async {
            let h = histogram(out)
            DispatchQueue.main.async {
                if seq == histSeq { hist = h }
                histBusy = false
                if histPending {
                    histPending = false
                    if let ci = workImage() {
                        histSeq += 1
                        histBusy = true
                        runHistogram(renderPipeline(ci, geos: cachedGeos))
                    }
                }
            }
        }
    }

    func refresh() {
        guard let u = srcURL, let ci = workImage() else { return }
        // 逐块 RSS 探针（§230）：上一轮已把"换图涨内存"压到"切图后的首帧刷新"这一整块，
        // 这里把它再拆成五小段，直接点名到底是哪一段留下东西（不依赖 xctrace）。
        let mt = ProcessInfo.processInfo.environment["CR_MEMTRACE"] == "1"
        var m0 = mt ? auditRSSMB() : 0
        func mtb(_ tag: String) {
            guard mt else { return }
            let now = auditRSSMB()
            FileHandle.standardError.write(String(format: "MEMT %@ %.0f %+.0f\n", tag, now, now - m0).data(using: .utf8)!)
            m0 = now
        }
        mtb("入口")
        srcStats = measure(ci)
        // 「原图」窗用**和效果窗同一张工作图**渲染，不再 NSImage(contentsOf:) 去解一遍整张原图：
        // 那是 24MP 的完整解码（一张 100+ MB），而画布上显示的本来就是降到预览尺寸的图。
        if let cgSrc = sharedCtx.createCGImage(ci, from: ci.extent.integral) {
            srcImage = NSImage(cgImage: cgSrc, size: NSSize(width: cgSrc.width, height: cgSrc.height))
        }
        mtb("量统计+原图NSImage")
        let out = renderPipeline(ci, geos: cachedGeos)
        mtb("管线渲染")
        if let cg = sharedCtx.createCGImage(out, from: out.extent.integral) {
            outImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        mtb("出图+包装NSImage")
        // 直方图**移出关键路径**（它要把管线再求值一遍：20.9MP 时几十毫秒，而画布刷新就是滑杆手感），
        // 并且**有界**：单飞 + 待算标记，任何时刻最多一个后台任务（原来只做序号合并，
        // 全量结果被丢弃、但任务照排，拖动时会堆起来 —— §173 那个 931 秒就怀疑与它有关）。
        histSeq += 1
        if histBusy {
            histPending = true
        } else {
            histBusy = true
            runHistogram(out)
        }
        mtb("直方图派发")
        if exifURL != u {
            exifRows = exifSummary(u.path)     // EXIF 一次读取，换图才重读
            exifURL = u
        }
        mtb("EXIF")
        status = String(format: "误差 %.3f（越低越接近参考组）· %d 张脸 · 预览 %d×%d",
                        srcStats.distance(to: target), faceCount,
                        Int(ci.extent.width), Int(ci.extent.height))
    }

    func lipReset() {
        warpStrokes = []; freezeStrokes = []; spotPoints = []; clonePoints = []; patchPoints = []; cloneSource = nil
        cloneEpochs = []
        cropRect = nil; rotateDeg = 0; flipH = false; quarterTurns = 0; autoCropOn = false
    }

    /// 人物属性 → 推荐参数（像素蛋糕的「人物类型」背后是不同人群的模型；我们没有模型，
    /// 但可以把经验值落成真的参数改动，而不是只留一个标签）
    func applyAttributeDefaults(_ attr: String, face: Int) {
        pushHistory("按属性推荐：\(attr)")
        switch attr {
        case "儿童":
            portrait.spotBlemish = 20; portrait.shine = 30; portrait.darkCircle = 40
            portrait.faceSlim = 10; portrait.eyeBig = 25; portrait.teeth = 20; portrait.blush = 25
            skinGrade = "light"; skinTone = true
        case "男":
            portrait.spotBlemish = 45; portrait.shine = 55; portrait.darkCircle = 45
            portrait.faceSlim = 20; portrait.noseSlim = 15; portrait.jawLine = 30
            portrait.teeth = 25; portrait.eyes = 25; portrait.blush = 0
            skinGrade = "medium"; skinTone = false
        case "长辈女":
            portrait.spotBlemish = 60; portrait.darkCircle = 70; portrait.eyebag = 70
            portrait.mole = 30; portrait.lipLine = 45; portrait.doubleChin = 45; portrait.jawLine = 40
            portrait.faceSlim = 45; portrait.chinShape = 30; portrait.teeth = 45
            skinGrade = "strong"; skinTone = true
        case "长辈男":
            portrait.spotBlemish = 60; portrait.darkCircle = 65; portrait.eyebag = 65
            portrait.shine = 50; portrait.jawLine = 45; portrait.doubleChin = 40
            portrait.faceSlim = 30; portrait.teeth = 45
            skinGrade = "medium"; skinTone = false
        default:  // 女
            portrait.spotBlemish = 45; portrait.shine = 45; portrait.darkCircle = 55
            portrait.eyeBig = 30; portrait.faceSlim = 40; portrait.noseSlim = 25
            portrait.teeth = 40; portrait.eyes = 35; portrait.lipColor = 25; portrait.blush = 30
            portrait.hands = 30
            skinGrade = "medium"; skinTone = true
        }
        attrs[face] = attr
        refresh()
        status = "已按「\(attr)」推荐参数（%@，可继续手动微调）".replacingOccurrences(of: "%@", with: applyMode == 1 ? "替换" : "叠加")
    }
}
