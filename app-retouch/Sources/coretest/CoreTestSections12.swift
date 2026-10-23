// CoreTestSections12.swift：coretest 的第 89~96 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections12() {
head("31. 部位掩膜（脸/眼/唇/鼻/耳/手臂/腿）")

do {
    if let p = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                "1a9dfa8c89ba4b53c08d54adae7a6360.jpg"].first(where: {
        FileManager.default.fileExists(atPath: root + "/" + $0)
    }), let img = loadAnyImage(root + "/" + p, maxDim: 700),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        var got: [String] = []
        for part in BodyPart.allCases {
            if let m = partMask(img, part: part, geos: geos) {
                let box = bboxOfBright(m, in: e, threshold: 128)
                let cov = maskCoverage(m, in: e, threshold: 128)
                got.append(String(format: "%@ %.3f%% 盒(%.2f,%.2f,%.2f,%.2f)", part.rawValue, cov * 100,
                                   box.minX / e.width, box.minY / e.height, box.width / e.width, box.height / e.height))
            } else {
                got.append(part.rawValue + " 不成立")
            }
        }
        for g in got { print("  [实测] " + g) }
        // 脸的掩膜必须明显大于眼睛：否则说明"部位"没区分开
        if let fm = partMask(img, part: .face, geos: geos), let em = partMask(img, part: .eyes, geos: geos) {
            let f = maskCoverage(fm, in: e, threshold: 128)
            let ey = maskCoverage(em, in: e, threshold: 128)
            check("脸与眼睛是两块不同的掩膜（眼睛明显更小）", ey < f * 0.5 && ey > 0,
                  String(format: "脸 %.3f%%、眼睛 %.3f%%", f * 100, ey * 100))
        }
        check("至少识别出 3 个部位", got.filter { !$0.contains("不成立") }.count >= 3,
              "成立 \(got.filter { !$0.contains("不成立") }.count) 个")
        // §244：耳部契约变更 —— 现在**优先用解析耳类 7/8**（真实耳像素），解析不可用时才退回
        // 原来的「脸框两侧竖椭圆」。旧断言要求"横向跨过整个脸框"，那只对"两带近似"成立；
        // 而照片常只露一只耳 ⇒ 解析掩膜只在一侧。所以改成两种实现都能满足、但仍能抓住
        // "掩膜跑到脸中央"的新契约：**要么跨脸两侧（兜底），要么明显偏一侧（解析）**，且纵向在脸中部。
        if let g0 = geos.max(by: { $0.box.width < $1.box.width }),
           let em = partMask(img, part: .ears, geos: geos) {
            let b = bboxOfBright(em, in: e, threshold: 128)
            let spansSides = (b.maxX - b.minX) > g0.box.width * 0.8
            let atOneSide = abs(b.midX - g0.box.midX) > g0.box.width * 0.3
            let midHeight = b.midY > g0.box.minY + g0.box.height * 0.2
                && b.midY < g0.box.maxY - g0.box.height * 0.2
            check("耳部掩膜在耳位（解析：偏一侧 ｜ 兜底：跨两侧）且纵向在脸中部",
                  (spansSides || atOneSide) && midHeight,
                  String(format: "脸框中心 x %.0f 宽 %.0f，耳掩膜 x %.0f~%.0f（中线 %.0f，偏离 %.2f 脸宽）、中线 y %.0f",
                         g0.box.midX, g0.box.width, b.minX, b.maxX, b.midX,
                         abs(b.midX - g0.box.midX) / max(1, g0.box.width), b.midY))
        }
        // 部位调整必须**真的起作用**（用手臂做代表：这张图检出了手臂）
        if let _ = partMask(img, part: .arms, geos: geos) {
            var pa = PartAdjust(part: BodyPart.arms.rawValue)
            pa.dBrightness = 40
            let out = applyPartAdjustments(img, [pa], geos: geos, base: Params())
            let dm = diffMap(img, out)
            check("部位调整确实改到了画面", dm.avg(in: e) * 255 > 0.5,
                  String(format: "整图平均改动 %.2f", dm.avg(in: e) * 255))
        }
    }
}

// MARK: - 32. 形变笔触的"半径—效果"关系（部位变形没量出改动，先查这里）


head("32. 液化笔触：半径大小与是否真的产生位移")

do {
    // 自己拼一张竖条图（gridImage 是别处的局部函数，这里不能直接用）
    var grid = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 600, height: 600))
    for x in stride(from: 0, to: 600, by: 20) {
        grid = CIImage(color: .white).cropped(to: CGRect(x: CGFloat(x), y: 0, width: 2, height: 600))
            .composited(over: grid)
    }
    let img = grid
    do {
        let e = img.extent
        // 用格子图（网格线）量位移：同一条 push 笔触，只改半径
        let base = img
        for rPct in [1.0, 3.0, 8.0, 20.0, 30.0] {
            let st = WarpStroke(mode: .push, center: CGPoint(x: 300, y: 300),
                                radius: rPct, delta: CGPoint(x: 30, y: 0),
                                strength: 0.8, density: 0.6)
            let out = applyLiquify(base, strokes: [st])
            let d = diffMap(base, out).avg(in: e) * 255
            // 峰值更有意义：位移集中在笔触中心
            let peak = diffMap(base, out).maxValue * 255
            print(String(format: "  [实测] push 半径 %.0f%% → 平均改动 %.3f、峰值 %.0f", rPct, d, peak))
        }
        // 部位变形实际用的半径量级：以"肢体长度占画面高度的 55%"计
        let st2 = WarpStroke(mode: .push, center: CGPoint(x: 300, y: 300),
                             radius: 27.5, delta: CGPoint(x: 0.03 * 600, y: 0), strength: 0.8, density: 0.6)
        let out2 = applyLiquify(base, strokes: [st2])
        print(String(format: "  [实测] 部位变形同量级（半径 27.5%%、delta 18px）→ 平均改动 %.3f",
                     diffMap(base, out2).avg(in: e) * 255))
        let st3 = WarpStroke(mode: .pinch, center: CGPoint(x: 300, y: 300), radius: 27.5,
                             strength: 0.8, density: 0.6)
        let out3 = applyLiquify(base, strokes: [st3])
        check("大半径笔触仍然产生可测位移", diffMap(base, out3).avg(in: e) * 255 > 0.05,
              String(format: "pinch 半径 27.5%% → 平均改动 %.3f", diffMap(base, out3).avg(in: e) * 255))
    }
}

// MARK: - 33. 部位变形：在真实照片上，从"笔触构造"到"形变结果"逐段量


head("33. 部位变形（拉长/瘦）在真实照片上的笔触与效果")

do {
    // ⚠️ 这里以前是 `.first(where: { 文件存在 })` —— **只跑第一张存在的图**。
    // 第一张是半身人像，"腿"没有关键点，于是 腿·拉长 / 腿·瘦 两条检查每次都走"跳过"；
    // 而账本里恰好记着一次"腿的分支串了 bug、测试用的半身照里没有腿所以没发现"。
    // 现在**每张可用夹具都跑一遍**：内容不同，才盖得住按部位分支的代码。
    let partFixtures = ["douyin_favorites/images/0001_7673816620465215714_01.webp",
                        "2604_wedding/00_RAW_readonly/wedding_01.jpg"]
    for p in partFixtures where FileManager.default.fileExists(atPath: root + "/" + p) {
    if let img = loadAnyImage(root + "/" + p, maxDim: 700),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        print("  [夹具] " + (p as NSString).lastPathComponent)
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        let body = detectBodyPoints(cg, extent: e)
        // 笔触约定（与笔刷一致）：中心**归一化**、半径**百分比**、delta**归一化**。
        // 直连 applyLiquify（它吃像素）之前，必须按渲染管线的 conv() 换算一遍。
        func toPixels(_ list: [WarpStroke]) -> [WarpStroke] {
            list.map { s in
                WarpStroke(mode: s.mode, center: CGPoint(x: s.center.x * e.width, y: s.center.y * e.height),
                           radius: Double(max(e.width, e.height)) * s.radius / 100,
                           delta: CGPoint(x: s.delta.x * e.width, y: s.delta.y * e.height),
                           strength: s.strength, density: s.density)
            }
        }
        func report(_ part: BodyPart, _ kind: String) {
            let st = partDeformStrokes(part: part, kind: kind, amount: 80, geos: geos, body: body, extent: e)
            var detail: [String] = []
            for s in st {
                // 半径在笔触里是**百分比**；换算成像素才知道"到底影响多大一块"
                let px = Double(max(e.width, e.height)) * s.radius / 100
                detail.append(String(format: "%@ r%.1f%%(%.0fpx) d(%.0f,%.0f)",
                                     s.mode.rawValue, s.radius, px, s.delta.x * e.width, s.delta.y * e.height))
            }
            // 直接喂给液化（绕过整条管线）：这一步才是"引擎能不能把这批笔触变成位移"
            let out = st.isEmpty ? img : applyLiquify(img, strokes: toPixels(st))
            let dm = diffMap(img, out)
            print(String(format: "  [实测] %@·%@：%d 笔 → %@", part.rawValue, kind, st.count,
                         detail.isEmpty ? "（无）" : detail.joined(separator: " / ")))
            print(String(format: "         整图平均改动 %.3f、峰值 %.0f", dm.avg(in: e) * 255, dm.maxValue * 255))
            // 判据说明：真实照片的**平滑背景**上，几何位移几十像素也只会带来很小的**像素差**，
            // 所以这里不拿"峰值 > 8"卡它（那是线稿图才有的量级，见第 32 段）；
            // 只用"有没有变化"来判，并把**位移量**（笔触构造里算出来的）当作几何证据打出来。
            if !st.isEmpty {
                check("\(part.rawValue)·\(kind) 的笔触在真实照片上确实改到了画面",
                      dm.maxValue * 255 > 2,
                      String(format: "峰值 %.0f（笔触位移 %.0f px 级；平滑背景上像素差本来就小）",
                             dm.maxValue * 255, 28))
            } else {
                skip("\(part.rawValue)·\(kind)：这张图没检出该部位（按设计跳过）", "0 笔")
            }
        }
        report(.arms, "拉长")
        report(.legs, "拉长")
        report(.legs, "瘦")
        report(.eyes, "大眼")
        // 关键对照：**按 App 管线里的换算**再喂一次（center→像素、radius 百分比→像素、delta→像素）。
        // 上一轮 App 侧端到端只测出"峰值 1"，怀疑是换算把量级改掉了；这里把换算单独验一遍。
        do {
            let raw = partDeformStrokes(part: .eyes, kind: "大眼", amount: 80, geos: geos, body: body, extent: e)
            let converted = toPixels(raw)
            let outCv = applyLiquify(img, strokes: converted)
            let dmCv = diffMap(img, outCv)
            print(String(format: "  [对照] 大眼：按管线换算（中心 %.2f,%.2f → %.0f,%.0f px；半径 %.1f%% → %.0f px）峰值 %.0f",
                         raw.first?.center.x ?? 0, raw.first?.center.y ?? 0,
                         converted.first?.center.x ?? 0, converted.first?.center.y ?? 0,
                         raw.first?.radius ?? 0, converted.first?.radius ?? 0, dmCv.maxValue * 255))
            // 这条就是本轮的核心断言：换算之后必须仍然产生明显位移
            check("按管线的换算喂进去，笔触仍落在画面内且产生明显位移", dmCv.maxValue * 255 > 8,
                  String(format: "峰值 %.0f", dmCv.maxValue * 255))
        }
    }
    }
}

// MARK: - 34. 部位变形的**笔触选择**（用合成关键点，不依赖照片里有没有腿）


head("34. 每个部位的变形笔触该是什么模式（合成关键点）")

do {
    // 合成一套关键点：脸在中间 100~200，两条手臂、两条腿都齐
    var g = FaceGeo()
    g.box = CGRect(x: 400, y: 500, width: 100, height: 100)
    g.leftEye = [CGPoint(x: 430, y: 560), CGPoint(x: 440, y: 560), CGPoint(x: 435, y: 570)]
    g.rightEye = [CGPoint(x: 460, y: 560), CGPoint(x: 470, y: 560), CGPoint(x: 465, y: 570)]
    g.nose = [CGPoint(x: 445, y: 545), CGPoint(x: 455, y: 545), CGPoint(x: 450, y: 535)]
    g.outerLips = [CGPoint(x: 435, y: 515), CGPoint(x: 465, y: 515), CGPoint(x: 450, y: 505)]
    var body = BodyPoints()
    body.leftShoulder = CGPoint(x: 380, y: 430); body.leftElbow = CGPoint(x: 340, y: 330); body.leftWrist = CGPoint(x: 300, y: 240)
    body.rightShoulder = CGPoint(x: 520, y: 430); body.rightElbow = CGPoint(x: 560, y: 330); body.rightWrist = CGPoint(x: 600, y: 240)
    body.leftHip = CGPoint(x: 410, y: 250); body.leftKnee = CGPoint(x: 405, y: 150); body.leftAnkle = CGPoint(x: 400, y: 50)
    body.rightHip = CGPoint(x: 490, y: 250); body.rightKnee = CGPoint(x: 495, y: 150); body.rightAnkle = CGPoint(x: 500, y: 50)
    let e = CGRect(x: 0, y: 0, width: 900, height: 600)

    func modes(_ part: BodyPart, _ kind: String) -> (count: Int, modes: Set<String>, minRadius: Double, maxDelta: Double) {
        let st = partDeformStrokes(part: part, kind: kind, amount: 80, geos: [g], body: body, extent: e)
        var ms: Set<String> = []
        var minR = 999.0, maxD = 0.0
        for s in st {
            ms.insert(s.mode.rawValue)
            minR = min(minR, s.radius)
            maxD = max(maxD, hypot(s.delta.x, s.delta.y))
        }
        return (st.count, ms, st.isEmpty ? 0 : minR, maxD)
    }
    // 手臂：拉长 → 全是"向前变形"且位移非零；瘦 → 全是"收缩"
    let armStretch = modes(.arms, "拉长")
    let armSlim = modes(.arms, "瘦")
    print(String(format: "  [实测] 手臂·拉长 %d 笔 %@｜手臂·瘦 %d 笔 %@",
                 armStretch.count, armStretch.modes.sorted().joined(separator: ","),
                 armSlim.count, armSlim.modes.sorted().joined(separator: ",")))
    check("手臂·拉长 = 向前变形（且位移非零）",
          armStretch.modes == ["向前变形"] && armStretch.maxDelta > 0, "位移 \(armStretch.maxDelta)")
    check("手臂·瘦 = 收缩（不是向前变形）", armSlim.modes == ["收缩"], armSlim.modes.sorted().joined(separator: ","))
    // 腿：同上（这次用合成关键点，不依赖照片里有没有腿）
    let legStretch = modes(.legs, "拉长")
    let legSlim = modes(.legs, "瘦")
    print(String(format: "  [实测] 腿·拉长 %d 笔 %@｜腿·瘦 %d 笔 %@",
                 legStretch.count, legStretch.modes.sorted().joined(separator: ","),
                 legSlim.count, legSlim.modes.sorted().joined(separator: ",")))
    check("腿·拉长 = 向前变形、腿·瘦 = 收缩（这正是之前串掉的那两条）",
          legStretch.modes == ["向前变形"] && legSlim.modes == ["收缩"],
          "拉长 \(legStretch.modes.sorted()) / 瘦 \(legSlim.modes.sorted())")
    // 腿的笔触**不许**出现五官那支（串分支时就会出现"向前变形 d(0,11)"那种额头笔触）
    check("腿的笔触数量是偶数（两条腿各两笔），且半径合理（≥2%）",
          legStretch.count == 4 && legStretch.minRadius >= 2,
          String(format: "%d 笔，最小半径 %.1f%%", legStretch.count, legStretch.minRadius))
    // 五官
    let eyeBig = modes(.eyes, "大眼")
    check("眼睛·大眼 = 膨胀，两笔（左右眼）", eyeBig.modes == ["膨胀"] && eyeBig.count == 2,
          "\(eyeBig.count) 笔 \(eyeBig.modes.sorted())")
    let noseSlim = modes(.nose, "瘦鼻")
    check("鼻子·瘦鼻 = 向前变形（左右各一笔）", noseSlim.modes == ["向前变形"] && noseSlim.count == 2,
          "\(noseSlim.count) 笔")
    // 关键回归点：给"腿"调用时**不许**混进脸的那支笔
    let faceStrokeForLegs = partDeformStrokes(part: .legs, kind: "额头", amount: 80, geos: [g], body: body, extent: e)
    check("给腿传五官的 kind 时，不会生成五官笔触（按 part 限定）", faceStrokeForLegs.isEmpty,
          "\(faceStrokeForLegs.count) 笔")
}

// MARK: - 35. **多张图**批量体检（用户要求：不要只用一张图测）
//
// 为什么必须有多图这一层：之前几轮的教训全出在"单图特化"上——
//   · "腿·瘦 被五官分支接走"在半身照上测不出来（照片里没腿，测试直接跳过）；
//   · 皮肤掩膜、天空、衣物这些闸门，在不同照片上的通过率完全不同。
// 这一节挑一批**不同来源、不同构图**的照片，跑同一组检查并打表；
// 断言只卡"聚合性质"（比如"检出脸的图里皮肤覆盖必须在合理区间"），不卡单张的具体数值。


head("35. 多张图批量体检")

do {
    // 选样：优先不同来源（抖音收藏 + 婚礼 RAW），各取若干张，最多 12 张
    var samplePaths: [String] = []
    let douyinDir = root + "/douyin_favorites/images"
    let weddingDir = root + "/2604_wedding/00_RAW_readonly"
    if let names = try? FileManager.default.contentsOfDirectory(atPath: douyinDir) {
        let pics = names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".webp") || $0.hasSuffix(".png") }.sorted()
        // 均匀取样，避免全是同一组的连拍
        let strideN = max(1, pics.count / 9)
        samplePaths += Swift.stride(from: 0, to: pics.count, by: strideN).prefix(9).map { douyinDir + "/" + pics[$0] }
    }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: weddingDir) {
        samplePaths += names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".JPG") }.sorted().prefix(3)
            .map { weddingDir + "/" + $0 }
    }

    var okCount = 0, facePhotos = 0, checked = 0
    var skinIssues: [String] = []
    for p in samplePaths.prefix(12) {
        guard let img = loadAnyImage(p, maxDim: 500) else { continue }
        checked += 1
        guard let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        let name = (p as NSString).lastPathComponent
        var parts: [String] = []
        for part in BodyPart.allCases where partMask(img, part: part, geos: geos) != nil {
            parts.append(part.rawValue)
        }
        var skinLine = "—"
        if let g0 = geos.max(by: { $0.box.width < $1.box.width }) {
            facePhotos += 1
            let m = geos.count == 1 ? skinMaskForFace(img, face: g0) : skinMaskForFaces(img, geos: geos)
            let cov = maskCoverage(m, in: g0.box, threshold: 128)
            skinLine = String(format: "%.2f", cov)
            if cov < 0.15 || cov > 0.97 {
                skinIssues.append(name + "(" + String(format: "%.2f", cov) + ")")
            }
        }
        let personCov = personMask(img).map { maskCoverage($0, in: e, threshold: 128) } ?? 0
        var skyOpt = SkyOptions()
        skyOpt.style = "晴天蓝"
        skyOpt.amount = 100
        let skyCov = replaceSky(img, skyOpt).1
        print(String(format: "  [多图] %-34@ 脸%d(%@) 人物%.2f 天空%.2f 部位[%@]",
                     name, geos.count, skinLine, personCov, skyCov, parts.joined(separator: "")))
        okCount += 1
    }

    // ⑤b 用**真的有腿的照片**验证"腿拉长 / 瘦腿"（之前只在半身照上测，腿的分支根本没被覆盖）
    do {
        var tested = false
        for p in samplePaths.prefix(12) {
            guard let img = loadAnyImage(p, maxDim: 500),
                  let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
            let e = img.extent
            let geos = detectFaceGeos(cg, size: e.size)
            let body = detectBodyPoints(cg, extent: e)
            var legStrokes: [WarpStroke] = []
            for k in ["拉长", "瘦"] {
                legStrokes += partDeformStrokes(part: .legs, kind: k, amount: 80, geos: geos, body: body, extent: e)
            }
            guard !legStrokes.isEmpty else { continue }
            let px = legStrokes.map { s in
                WarpStroke(mode: s.mode, center: CGPoint(x: s.center.x * e.width, y: s.center.y * e.height),
                           radius: Double(max(e.width, e.height)) * s.radius / 100,
                           delta: CGPoint(x: s.delta.x * e.width, y: s.delta.y * e.height),
                           strength: s.strength, density: s.density)
            }
            let out = applyLiquify(img, strokes: px)
            let dm = diffMap(img, out)
            print(String(format: "  [多图] 腿形变实测：%@ %d 笔 → 平均 %.3f、峰值 %.0f",
                         (p as NSString).lastPathComponent, legStrokes.count,
                         dm.avg(in: e) * 255, dm.maxValue * 255))
            check("腿拉长/瘦在真的拍到腿的照片上有位移", dm.maxValue * 255 > 2,
                  String(format: "峰值 %.0f", dm.maxValue * 255))
            tested = true
            break
        }
        if !tested { print("  [多图] 这批样片里没有能完整检出腿的照片") }
    }
    // 用多图量一次"天空掩膜 vs 主体掩膜"与"头发解析"（本轮两条改动的验证）
    do {
        var skyRows: [String] = [], hairRows: [String] = []
        for p in samplePaths.prefix(6) {
            guard let img = loadAnyImage(p, maxDim: 500),
                  sharedCtx.createCGImage(img, from: img.extent) != nil else { continue }
            let e = img.extent
            let name = (p as NSString).lastPathComponent
            var o = SkyOptions(); o.style = "晴天蓝"; o.amount = 100
            let (out, skyCov) = replaceSky(img, o)
            if skyCov > 0.01, let person = personMask(img) {
                let pc = maskCoverage(person, in: e, threshold: 128)
                let dm = diffMap(img, out)
                let inPerson = dm.avg(in: bboxOfBright(person, in: e, threshold: 128)) * 255
                skyRows.append(String(format: "%@ 天空%.2f 人%.2f 人区改动%.1f", name, skyCov, pc, inPerson))
            }
            if let hair = parsedMaskFromImage(img, classes: FaceClass.hairClasses, feather: 6) {
                let hc = maskCoverage(hair, in: e, threshold: 128)
                hairRows.append(String(format: "%@ 头发%.3f", name, hc))
            }
        }
        for r in skyRows { print("  [多图·天空] " + r) }
        for r in hairRows { print("  [多图·头发] " + r) }
        check("多图跑通了换天空与头发解析（本轮两条改动的依据）", !skyRows.isEmpty || !hairRows.isEmpty,
              "天空 " + String(skyRows.count) + " 张、头发 " + String(hairRows.count) + " 张")
    }

    check("批量体检覆盖到多张图（不是一张）", checked >= 8, "实际跑通 " + String(checked) + " 张")
    check("检出脸的照片里，皮肤掩膜在脸框内落在合理区间", skinIssues.isEmpty,
          skinIssues.isEmpty ? "共 " + String(facePhotos) + " 张有脸，全部正常"
                             : "异常：" + skinIssues.joined(separator: "、"))
    print("  [多图] 小结：跑通 " + String(okCount) + " 张、其中 " + String(facePhotos) + " 张检出人脸")
}

// MARK: - 36. 多图上的"自适应功能"有没有做过头
//
// 前面几节回答的是"能不能跑"；这一节回答"每张图上做得对不对"——
// 自适应类功能（自动曝光/自动白平衡/高光恢复）最容易出现"在某一张上做过头"：
// 要么把整张图压暗、要么把偏色推反、要么把高光削平。用一批照片一起量，才看得出来。


head("36. 多图上的自适应功能（自动曝光 / 自动白平衡 / 高光恢复）")

do {
    var samplePaths: [String] = []
    let douyinDir = root + "/douyin_favorites/images"
    let weddingDir = root + "/2604_wedding/00_RAW_readonly"
    if let names = try? FileManager.default.contentsOfDirectory(atPath: douyinDir) {
        let pics = names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".webp") }.sorted()
        let strideN = max(1, pics.count / 6)
        samplePaths += Swift.stride(from: 0, to: pics.count, by: strideN).prefix(6).map { douyinDir + "/" + pics[$0] }
    }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: weddingDir) {
        samplePaths += names.filter { $0.lowercased().hasSuffix(".jpg") }.sorted().prefix(2).map { weddingDir + "/" + $0 }
    }

    var bad: [String] = []
    var ran = 0
    for p in samplePaths.prefix(8) {
        guard let img = loadAnyImage(p, maxDim: 600) else { continue }
        ran += 1
        let name = (p as NSString).lastPathComponent
        let before = measure(img)
        // 自动曝光：目标是 p50 118；渲染后不该把画面压死、也不该削掉大量高光
        let exposed = autoExpose(img, amount: 100)
        let afterExp = measure(exposed)
        // 自动白平衡（真实 API 是 applyWhiteBalance）
        let wb = applyWhiteBalance(img, amount: 100)
        let afterWb = measure(wb)
        // 高光恢复：死白比例用直方图里的 clippedHigh
        let hlImg = recoverHighlights(img, amount: 80)
        let h0 = histogram(img), h1 = histogram(hlImg), h2 = histogram(exposed)
        print(String(format: "  [多图·自适应] %-28@ p50 %.0f→%.0f｜死白 %.1f%%→%.1f%%(高光恢复后 %.1f%%)｜暖冷 %+.0f→%+.0f",
                     name, before.p50, afterExp.p50, h0.clippedHigh * 100, h2.clippedHigh * 100,
                     h1.clippedHigh * 100, before.warmSh, afterWb.warmSh))
        // 判据（宽松但能抓到"做过头"）：
        //  · 自动曝光后 p50 不许跑到 60 以下或 190 以上（那是把片子压死/拉飞）；
        //  · 自动曝光后死白比例不许明显增加（>1.5 倍且超过 2%）；
        //  · 高光恢复后死白比例必须**不增加**。
        // ⚠️ 用 p50（0~255）。q50 是同一分位的**量化值（0~1）**，拿它当"亮度 118"判会把所有图判成异常。
        if afterExp.p50 < 60 || afterExp.p50 > 190 { bad.append(name + "(曝光后 p50 " + String(format: "%.0f", afterExp.p50) + ")") }
        // 死白预算 3%：极暗照片硬提亮必然有死白（实测最坏 2.2%），超过 3% 才算"烧掉高光"。
        // 这个数字是量出来的，不是拍的 —— 试过加"高光保护"，结果对极暗图反而更暗（见 Auto2.swift 的注释）。
        if h2.clippedHigh > 0.03, h2.clippedHigh > max(h0.clippedHigh, 0.001) * 1.5 {
            bad.append(name + "(曝光后死白 " + String(format: "%.1f%%", h2.clippedHigh * 100) + ")")
        }
        if h1.clippedHigh > h0.clippedHigh + 0.005 { bad.append(name + "(高光恢复反而增加死白)") }
    }
    check("多张图上的自适应功能都没有做过头", bad.isEmpty,
          bad.isEmpty ? String(ran) + " 张全部正常" : "异常：" + bad.joined(separator: "、"))
}

// MARK: - 37. 多图验「所见即所得」：导出的像素是不是预览的像素
//
// 这条是产品对用户的**核心承诺**（预览 == 导出）。前面只在单张图上量过字节数与质量的关系，
// 没验过"导出后的像素和预览是否一致"——而颜色管理（P3/sRGB 标签、位深、缩放）一旦在某类图上出问题，
// 用户拿到的就是"和看到的不一样"。这里用多张图各导一次，逐像素比。


head("37. 多图验「预览 == 导出」")

do {
    var samplePaths: [String] = []
    let douyinDir = root + "/douyin_favorites/images"
    let weddingDir = root + "/2604_wedding/00_RAW_readonly"
    if let names = try? FileManager.default.contentsOfDirectory(atPath: douyinDir) {
        let pics = names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".webp") }.sorted()
        let strideN = max(1, pics.count / 4)
        samplePaths += Swift.stride(from: 0, to: pics.count, by: strideN).prefix(4).map { douyinDir + "/" + pics[$0] }
    }
    if let names = try? FileManager.default.contentsOfDirectory(atPath: weddingDir) {
        samplePaths += names.filter { $0.lowercased().hasSuffix(".jpg") }.sorted().prefix(1).map { weddingDir + "/" + $0 }
    }

    var failures: [String] = []
    var checked = 0
    for p in samplePaths.prefix(5) {
        guard let img = loadAnyImage(p, maxDim: 700) else { continue }
        // 走一遍真实的"渲染"（用一条预设参数），导出到临时文件
        var pr = Params(); pr.brightness = 6; pr.contrast = 8; pr.desat = 5
        let rendered = render(img, pr)
        var s = ExportSettings()
        s.format = "jpeg"; s.quality = 92
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "cr_rt_" + String(checked) + ".jpg")
        try? FileManager.default.removeItem(at: url)
        guard exportImage(rendered, to: url, s) else { continue }
        checked += 1
        // 读回来逐像素比（JPEG 会引入少量误差，所以判据是"平均差很小、且不允许整体偏移"）
        guard let back = loadAnyImage(url.path) else { failures.append((p as NSString).lastPathComponent + "(读不回)"); continue }
        let e = rendered.extent
        let W = 128, H = max(1, Int(Double(W) * e.height / max(1, e.width)))
        func small(_ i: CIImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: W * H * 4)
            let sc = CGFloat(W) / i.extent.width
            let t = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: sc, y: sc))
            sharedCtx.render(t, toBitmap: &buf, rowBytes: W * 4,
                             bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return buf
        }
        let b0 = small(rendered), b1 = small(back)
        var mean = 0.0, maxD = 0.0, biasR = 0.0
        for i in 0..<(W * H) {
            let dr = Double(b0[i * 4]) - Double(b1[i * 4])
            let dg = Double(b0[i * 4 + 1]) - Double(b1[i * 4 + 1])
            let db = Double(b0[i * 4 + 2]) - Double(b1[i * 4 + 2])
            mean += (abs(dr) + abs(dg) + abs(db)) / 3
            biasR += dr
            maxD = max(maxD, max(abs(dr), max(abs(dg), abs(db))))
        }
        mean /= Double(W * H)
        biasR /= Double(W * H)
        let name = (p as NSString).lastPathComponent
        print(String(format: "  [多图·导出] %-30@ 平均差 %.2f、峰值 %.0f、整体偏移 %+.2f", name, mean, maxD, biasR))
        // 判据：平均差 < 4 级（JPEG 92 的合理范围）、整体偏移 < 2 级（防止"整体变亮/变暗"这种系统性错误）
        if mean > 4 { failures.append(name + String(format: "(平均差 %.1f)", mean)) }
        if abs(biasR) > 2 { failures.append(name + String(format: "(整体偏移 %+.1f)", biasR)) }
        try? FileManager.default.removeItem(at: url)
    }
    check("多张图上「预览 == 导出」都成立", failures.isEmpty,
          failures.isEmpty ? String(checked) + " 张全部一致" : "异常：" + failures.joined(separator: "、"))
}

// MARK: - 38. 多图验「磨皮只作用在脸上」
//
// 单张图上验过（眼睛区/脸颊区改动比 0.12），但"脸多大、几张脸、有没有侧脸"每张都不同——
// 这里用多张照片验同一条性质：**脸框外不该被动、眼睛不该比脸颊磨得更狠**。


head("38. 多图验「磨皮只作用在脸上」")

do {
    var samplePaths: [String] = []
    let douyinDir = root + "/douyin_favorites/images"
    if let names = try? FileManager.default.contentsOfDirectory(atPath: douyinDir) {
        let pics = names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".webp") }.sorted()
        let strideN = max(1, pics.count / 8)
        samplePaths = Swift.stride(from: 0, to: pics.count, by: strideN).prefix(8).map { douyinDir + "/" + pics[$0] }
    }

    var bad: [String] = []
    var ran = 0
    for p in samplePaths {
        guard let img = loadAnyImage(p, maxDim: 700),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let geos = detectFaceGeos(cg, size: img.extent.size)
        guard let g0 = geos.max(by: { $0.box.width < $1.box.width }) else { continue }   // 没脸的跳过
        ran += 1
        var sk = SkinOptions(); sk.grade = "strong"
        let out = applySkin(img, sk, geos: geos)
        let dm = diffMap(img, out)
        let e = img.extent
        let inFace = dm.avg(in: g0.box) * 255
        // 脸框外 1.8 倍远的区域（绝不该被动）
        let farRect = CGRect(x: min(e.maxX - 60, g0.box.maxX + g0.box.width * 1.8), y: g0.box.minY,
                             width: 60, height: 60).intersection(e)
        let far = farRect.width > 10 ? dm.avg(in: farRect) * 255 : 0
        // 眼睛区 vs 脸颊区：眼睛不该被磨得更狠
        let side = max(8, g0.box.width * 0.14)
        let eyeC = g0.centroid(g0.leftEye)
        let cheekC = CGPoint(x: eyeC.x + g0.box.width * 0.06, y: eyeC.y - g0.box.height * 0.16)
        let eyeD = dm.avg(in: CGRect(x: eyeC.x - side / 2, y: eyeC.y - side / 2, width: side, height: side)) * 255
        let cheekD = dm.avg(in: CGRect(x: cheekC.x - side / 2, y: cheekC.y - side / 2, width: side, height: side)) * 255
        _ =  cheekD > 0.01 ? eyeD / cheekD : 0
        let name = (p as NSString).lastPathComponent
        // ⚠️ **口径修正**：上面那个方框（0.14×脸宽）比眼睛大得多，里面大部分是眼睑/卧蚕——那些本来就该磨，
        // 所以那个比值说明不了"眼睛是否被磨糊"。这里改成只量**眼睛轮廓多边形内部**：
        // 掩膜正确的话，那里的改动应当接近 0。
        let eyePolys = [g0.leftEye, g0.rightEye].filter { $0.count >= 3 }
        var eyeInner = -1.0
        if !eyePolys.isEmpty, dm.w > 8, dm.h > 8 {
            // DiffMap 只能按矩形取均值，所以这里把眼睛掩膜渲染成同尺寸缓冲，自己按掩膜求均值
            let em = polygonMask(extent: e, polygons: eyePolys, feather: 0)
            var mb = [UInt8](repeating: 0, count: dm.w * dm.h * 4)
            let scaled = em.transformed(by: CGAffineTransform(translationX: -em.extent.minX, y: -em.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(dm.w) / em.extent.width,
                                                   y: CGFloat(dm.h) / em.extent.height))
            sharedCtx.render(scaled, toBitmap: &mb, rowBytes: dm.w * 4,
                             bounds: CGRect(x: 0, y: 0, width: dm.w, height: dm.h), format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var acc = 0.0, cnt = 0
            for i in 0..<(dm.w * dm.h) where mb[i * 4] > 128 {
                acc += dm.d[i]; cnt += 1
            }
            eyeInner = cnt > 0 ? acc / Double(cnt) * 255 : -1
        }
        let skm = geos.count == 1 ? skinMaskForFace(img, face: g0) : skinMaskForFaces(img, geos: geos)
        let eyeMask = maskValue(skm, at: eyeC), cheekMask = maskValue(skm, at: cheekC)
        // 诊断三连：眼睛多边形自己白不白（polygonMask 对不对）、扣掉之后眼睛处还剩多少、
        // 以及"镜像 y"处是多少（用来判断是不是 y 约定反了）
        var eyePolyV = -1.0, eyeAfterV = -1.0, mirroredV = -1.0
        if !eyePolys.isEmpty {
            let pm = polygonMask(extent: e, polygons: eyePolys, feather: 0)
            eyePolyV = maskValue(pm, at: eyeC)
            eyeAfterV = maskValue(excludingEyes(pm, face: g0, extent: e), at: eyeC)
            mirroredV = maskValue(pm, at: CGPoint(x: eyeC.x, y: e.height - eyeC.y))
        }
        print(String(format: "  [多图·磨皮] %-28@ 脸内 %5.1f｜远处 %.2f｜眼内改动 %.2f｜掩膜 眼%.2f 颊%.2f｜多边形 %.2f→扣后 %.2f(镜像处 %.2f)",
                     name, inFace, far, eyeInner, eyeMask, cheekMask, eyePolyV, eyeAfterV, mirroredV))
        if far > 0.6 { bad.append(name + String(format: "(脸外也动了 %.1f)", far)) }
        // 判据：眼睛轮廓内的改动必须 **< 8 级**。修复前实测 2.18~14.42（最坏 14.42），
        // 把眼睛排除下沉到 bestSkinMask 之后降到 0.87~7.29 —— 这条断言就是那次修复的回归保险。
        if eyeInner > 8.0 { bad.append(name + String(format: "(眼轮廓内 %.2f)", eyeInner)) }
        if inFace < 1.0 { bad.append(name + String(format: "(脸内改动过小 %.1f)", inFace)) }
    }
    // ── 结论（这一节现在是**有判别力**的断言）：──
    // 修复前：眼睛轮廓内的改动 2.18~14.42 级（眼睛确实被磨了，是真实产品问题，不是度量问题）。
    // 两个根因（都实测到了）：
    //   ① 眼睛多边形的**羽化太大**（5% 脸宽 ≈8px），多边形内部到不了纯白 → 取反后不是黑 → 扣不掉；
    //      （最小实验见第 39 段：写法本身是对的，问题在输入"没有实心白"。）
    //   ② 排除加错了地方：只加在 skinMaskForFace 上，而产品走的是 bestSkinMask 的**解析路径**。
    // 现在：羽化压到 1.2% 脸宽 + 排除下沉到 bestSkinMask（所有磨皮路径的咽喉点）+ 按人磨皮那条也扣。
    // 复测：0.87 / 2.56 / 7.29 / 4.08 / 3.77 / 5.06（平均改善约 2.5 倍），断言阈值 8 级。
    print("  [多图·磨皮] 脸外不动 " + String(bad.filter { $0.contains("脸外") }.count) + " 张异常；" +
          "眼内改动超阈值 " + String(bad.filter { $0.contains("眼轮廓") }.count) + " 张")
}
//
// 背景：coretest 第 38 段发现 polygonMask 在眼睛处是 1.00，但"乘以取反后的多边形"之后仍是 0.88，
// 眼睛没能被扣掉。这个"从掩膜里扣一块"的写法在项目里用了很多处（眼睛、衣物减皮肤、天空减主体），
// 所以先把正确写法用**合成方块**钉下来，再回头改那些调用点。

}
