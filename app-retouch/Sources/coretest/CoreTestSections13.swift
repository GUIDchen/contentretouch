// CoreTestSections13.swift：coretest 的第 97~104 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections13() {
head("39. 掩膜扣一块：几种写法的对照")

do {
    let e = CGRect(x: 0, y: 0, width: 200, height: 200)
    let a = CIImage(color: .white).cropped(to: e)                                  // 待扣的大掩膜
    let b = CIImage(color: .white).cropped(to: CGRect(x: 80, y: 80, width: 40, height: 40))  // 要扣掉的小块
    let center = CGPoint(x: 100, y: 100), outside = CGPoint(x: 20, y: 20)
    func invertRGB(_ m: CIImage) -> CIImage {
        m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)])
    }
    let candidates: [(String, CIImage)] = [
        ("① CIColorInvert + MultiplyBlend",
         a.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: b.applyingFilter("CIColorInvert")])),
        ("② colorMatrix 取反 + MultiplyBlend",
         a.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: invertRGB(b)])),
        ("③ CIBlendWithMask（用 1−b 当蒙版，底图黑）",
         blackMask(e).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: a,
                                                                      kCIInputMaskImageKey: invertRGB(b)])),
        ("④ CISubtractBlend（a − b）",
         a.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: b])),
        ("⑤ CIMinimumCompositing",
         a.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: invertRGB(b)])),
    ]
    for (name, out) in candidates {
        let c = out.cropped(to: e)
        print(String(format: "  [掩膜扣块] %-38@ 洞心 %.2f｜洞外 %.2f（期望 洞心 0、洞外 1）",
                     name, maskValue(c, at: center), maskValue(c, at: outside)))
    }
    // 断言：至少要有一种写法是"洞心 0、洞外 1"
    let good = candidates.filter { maskValue($0.1.cropped(to: e), at: center) < 0.05
                                   && maskValue($0.1.cropped(to: e), at: outside) > 0.95 }
    check("存在一种正确的「掩膜扣一块」写法", !good.isEmpty,
          good.isEmpty ? "五种写法都没有做到（需要继续查）" : "可用：" + good.map { $0.0 }.joined(separator: "、"))
}

// MARK: - 40. 护栏：小特征的"多边形掩膜"必须内部实心
//
// 眼睛那次问题的普适教训：**多边形掩膜一旦被羽化到内部不实心，取反/相乘之后就等于没扣**。
// 而"眼睛/嘴唇/牙齿/鼻孔"这些特征的多边形都很小，羽化只要给大一点就会踩到。
// 所以这里对每个小特征都量一次"多边形内部的实心程度"，把这条规则变成自动检查。


head("40. 小特征多边形掩膜的内部实心度")

do {
    var samplePaths: [String] = []
    let douyinDir = root + "/douyin_favorites/images"
    if let names = try? FileManager.default.contentsOfDirectory(atPath: douyinDir) {
        let pics = names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".webp") }.sorted()
        let strideN = max(1, pics.count / 6)
        samplePaths = Swift.stride(from: 0, to: pics.count, by: strideN).prefix(6).map { douyinDir + "/" + pics[$0] }
    }
    var worst: [(String, Double)] = []
    var ran = 0
    for p in samplePaths {
        guard let img = loadAnyImage(p, maxDim: 700),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let geos = detectFaceGeos(cg, size: img.extent.size)
        guard let g0 = geos.max(by: { $0.box.width < $1.box.width }) else { continue }
        ran += 1
        let name = (p as NSString).lastPathComponent
        // ⚠️ 这里量的是**产品最终用的那个排除区**，而不是"裸的多边形"。
        // 原因（第 40 段第一版就是栽在这）：Vision 的 eyes 关键点是一条细长曲线，
        // 3/6 张照片上它的**质心落在多边形之外**，当填充掩膜用根本盖不住眼睛内部 ——
        // 所以产品的 excludingEyes 用的是"多边形 ∪ 眼睛包围盒椭圆"。这里也按同样的口径量。
        let eyeEx = excludingEyes(blackMask(img.extent), face: g0, extent: img.extent)
        let eyeAlsoMask = geos.count == 1 ? skinMaskForFace(img, face: g0) : skinMaskForFaces(img, geos: geos)
        let eyeC = g0.centroid(g0.leftEye)
        worst.append((name + "·眼(排除区外必须为黑)", 1 - maskValue(eyeEx, at: eyeC)))
        worst.append((name + "·眼(皮肤掩膜必须排除)", 1 - maskValue(eyeAlsoMask, at: eyeC)))
    }
    for (k, v) in worst.sorted(by: { $0.1 < $1.1 }).prefix(6) {
        print(String(format: "  [小特征掩膜] %-34@ %.2f（<0.9 说明该特征没被正确排除）", k, v))
    }
    let bad = worst.filter { $0.1 < 0.9 }
    check("眼睛处的排除区与皮肤掩膜都正确（内部实心）", bad.isEmpty,
          bad.isEmpty ? String(worst.count) + " 项全部 ≥0.9" : "偏软：" + bad.map { $0.0 }.joined(separator: "、"))
}

// MARK: - 41. 多图验人像各项：每项在**至少一张照片**上有明显反应
//
// 第 27 段只在单张照片上量过（而且已经证明"单张会骗人"：那张图上没有斑点，斑点类全被判成没反应）。
// 这里换一个问法：**每项在所有样片里的最大峰值**是多少——
// 如果一项在 5 张照片上峰值都接近 0，那才是真的"没实现"，而不是"这张图没有该特征"。


head("41. 多图验人像各项（最大峰值）")

do {
    var samplePaths: [String] = []
    let douyinDir = root + "/douyin_favorites/images"
    if let names = try? FileManager.default.contentsOfDirectory(atPath: douyinDir) {
        let pics = names.filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".webp") }.sorted()
        let strideN = max(1, pics.count / 10)
        samplePaths = Swift.stride(from: 0, to: pics.count, by: strideN).prefix(10).map { douyinDir + "/" + pics[$0] }
    }
    // 只看那些"有局部特征"的项（面积型的大眼/瘦脸在第 27 段已经量过）
    let items: [(String, WritableKeyPath<PortraitOptions, Double>)] = [
        ("祛痘", \.faceBlemish), ("斑点", \.spotBlemish), ("痣", \.mole),
        ("黑眼圈", \.darkCircle), ("眼袋", \.eyebag), ("唇色", \.lipColor),
        ("腮红", \.blush), ("牙齿", \.teeth), ("眼睛", \.eyes), ("双下巴", \.doubleChin),
    ]
    var peaks: [String: [Double]] = [:]
    var photos = 0
    for p in samplePaths {
        guard let img = loadAnyImage(p, maxDim: 700),
              let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
        let geos = detectFaceGeos(cg, size: img.extent.size)
        guard let g0 = geos.max(by: { $0.box.width < $1.box.width }) else { continue }
        photos += 1
        let base = render(img, Params())
        for (label, kp) in items {
            var o = PortraitOptions(); o[keyPath: kp] = 85
            let out = applyPortrait(base, o, geos: [g0])
            let peak = diffMap(base, out).maxValue * 255
            peaks[label, default: []].append(peak)
        }
        if photos >= 6 { break }
    }
    var dead: [String] = []
    for (label, _) in items {
        let v = peaks[label] ?? []
        let mx = v.max() ?? 0, avg = v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count)
        print(String(format: "  [多图·人像] %-8@ %d 张｜最大峰值 %5.0f｜平均峰值 %5.1f", label, v.count, mx, avg))
        // 判据：最大峰值必须 > 3。一项若在 6 张照片上都动不了 3 级，基本等于没实现。
        if mx <= 3 { dead.append(label + String(format: "（最大峰值 %.0f）", mx)) }
    }
    check("人像各项在至少一张照片上有明显反应", dead.isEmpty,
          dead.isEmpty ? String(photos) + " 张照片、" + String(items.count) + " 项全部有反应"
                        : "疑似没实现：" + dead.joined(separator: "、"))
}


// MARK: - 42. 逐脸蒙版用**脸缘轮廓**（用户报的"脸面提亮范围不准确"）

head("42. 逐脸提亮范围：轮廓 ≥ 外推椭圆")
do {
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        if let g = geos.first {
            let fi = FaceInfo(index: g.index,
                              rect: CGRect(x: g.box.minX / e.width, y: g.box.minY / e.height,
                                           width: g.box.width / e.width, height: g.box.height / e.height),
                              quality: g.quality, geo: g)
            let mask = faceMask(extent: e, face: fi)
            // 把蒙版在某个点上采样成 0~1（1 = 完全作用，0 = 完全不动）
            func at(_ p: CGPoint) -> Double {
                var buf = [UInt8](repeating: 0, count: 4)
                sharedCtx.render(mask, toBitmap: &buf, rowBytes: 4,
                                 bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return Double(buf[0]) / 255.0
            }
            let box = g.box
            let center = at(CGPoint(x: box.midX, y: box.midY))
            let below  = at(CGPoint(x: box.midX, y: box.minY - box.height * 0.7))   // 脖子以下
            let side   = at(CGPoint(x: box.maxX + box.width * 0.7, y: box.midY))   // 脸外侧（背景）
            check("逐脸蒙版：脸心为实、脸外为虚", center > 0.7 && below < 0.3 && side < 0.25,
                  String(format: "脸心 %.2f ｜ 脸下方 %.2f ｜ 脸外侧 %.2f", center, below, side))
            // 覆盖率：既要盖住脸（不是内切圆那种只盖中间一小块），也不能糊到脸框之外一大圈
            var inside = 0, total = 0
            var xx = box.minX
            while xx < box.maxX {
                var yy = box.minY
                while yy < box.maxY {
                    total += 1; if at(CGPoint(x: xx, y: yy)) > 0.5 { inside += 1 }
                    yy += box.height / 24
                }
                xx += box.width / 24
            }
            let cover = total > 0 ? Double(inside) / Double(total) : 0
            check("逐脸蒙版：覆盖脸框 45%~95%（不是中间一小块、也不是糊满）",
                  cover > 0.45 && cover < 0.95, String(format: "脸框内覆盖率 %.0f%%", cover * 100))
        } else {
            check("逐脸蒙版：夹具上检到了脸", false, "\\(bigFace) 没检到脸")
        }
    } else {
        print("  （夹具 \(bigFace) 不可用，跳过）")
    }
}

// MARK: - 43. 仿制图章：来源跟着笔走（不是把取样点那块反复盖）

head("43. 仿制：来源跟着笔走")
do {
    // 横向渐变底图：每个 x 的亮度都不同，于是"复制了哪一列"可以用**读一个像素**判定。
    let W = 400, H = 200
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var buf = [UInt8](repeating: 0, count: W * H * 4)
    for y in 0..<H {
        for x in 0..<W {
            let v = UInt8(min(255, x * 255 / W))
            let i = (y * W + x) * 4
            buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255
        }
    }
    let grad = CIImage(bitmapData: Data(buf), bytesPerRow: W * 4,
                       size: CGSize(width: W, height: H), format: .RGBA8, colorSpace: cs)
    func gray(_ im: CIImage, _ p: CGPoint) -> Double {
        var b = [UInt8](repeating: 0, count: 4)
        sharedCtx.render(im, toBitmap: &b, rowBytes: 4,
                         bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                         format: .RGBA8, colorSpace: cs)
        return Double(b[0])
    }
    let S = CGPoint(x: 40, y: 100)          // 取样点
    let p0 = CGPoint(x: 250, y: 100)        // 第一个落点
    let p1 = CGPoint(x: 290, y: 100)        // 第二个落点（同一笔，向右 40px）
    let off = CGPoint(x: p0.x - S.x, y: p0.y - S.y)
    let out = cloneAligned(grad, points: [p0, p1], offsets: [off, off],
                           radius: 20, feather: 0, opacity: 1.0)
    let v0 = gray(out, p0), v1 = gray(out, p1)
    let s0 = gray(grad, S), s40 = gray(grad, CGPoint(x: S.x + 40, y: S.y))
    check("仿制：第一个落点复制的就是取样点那块", abs(v0 - s0) < 2,
          String(format: "落点处 %.0f ｜ 取样点 %.0f", v0, s0))
    // 这一条是**证伪旧实现**的关键：旧实现每个点都复制取样点那块，于是 v1 会等于 s0 而不是 s40。
    check("仿制：第二个落点复制的是平移后的那块（来源跟着笔走）",
          abs(v1 - s40) < 2 && abs(s40 - s0) > 20,
          String(format: "落点处 %.0f ｜ 应为 %.0f（若为 %.0f 就是旧的\"反复盖同一块\"）", v1, s40, s0))
}

// MARK: - 44. 逐脸出图的代价（每张脸整张重渲？）

head("44. 逐脸出图耗时：全局 vs N 张脸")
do {
    if let img = loadFixture(bigFace, maxDim: 1200), let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let e = img.extent
        let geos = detectFaceGeos(cg, size: e.size)
        var p = Params()
        p.brightness = 8
        func ms(_ n: Int, _ f: () -> Void) -> Double {
            let t0 = Date(); for _ in 0..<n { f() }; return Date().timeIntervalSince(t0) / Double(n) * 1000
        }
        // ⚠️ CIImage 是**惰性**的：只构图不计时（第一次测出来是 0 ms）。
        // 必须在上下文里落地才量得到真实代价。
        func materialize(_ out: CIImage) { _ = sharedCtx.createCGImage(out, from: out.extent) }
        // 预热：Core Image 会缓存滤镜输出，不预热的话量到的是"首次成本"
        materialize(render(img, p))
        let tGlobal = ms(3) { materialize(render(img, p)) }
        // 造 N 张脸：把真实检到的脸复制 N 份（逐脸参数的应用代价只与脸数有关）
        var faces: [FaceInfo] = []
        var perFace: [Int: Params] = [:]
        for i in 0..<5 {
            let src = geos.isEmpty ? CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2) : geos[i % max(1, geos.count)].box
            let dx = Double(i % 3) * 0.22, dy = Double(i / 3) * 0.3
            let r = CGRect(x: min(0.7, src.minX + dx), y: min(0.6, src.minY + dy),
                           width: src.width, height: src.height)
            faces.append(FaceInfo(index: i, rect: CGRect(x: r.minX / e.width, y: r.minY / e.height,
                                                          width: r.width / e.width, height: r.height / e.height),
                                  quality: 0.9))
            var fp = p; fp.brightness = 14 + Double(i)
            perFace[i] = fp
        }
        materialize(renderWithFaces(img, global: p, faces: faces, perFace: perFace))
        let t5 = ms(3) { materialize(renderWithFaces(img, global: p, faces: faces, perFace: perFace)) }
        let tGlobal2 = ms(3) { materialize(render(img, p)) }
        print(String(format: "  [实测] 全局 render %.0f ms ｜ 5 张脸 renderWithFaces %.0f ms ｜ 再测全局 %.0f ms ｜ 倍数 %.2fx",
                     tGlobal, t5, tGlobal2, tGlobal2 > 0 ? t5 / tGlobal2 : 0))
    } else { print("  （夹具不可用，跳过）") }
}

// MARK: - 45. 修复类操作的耗时随落点数怎么涨（预览每次重绘都要跑一遍）

head("45. 修复耗时 vs 落点数（预览重绘的代价）")
do {
    if let img = loadFixture(bigFace, maxDim: 1200) {
        let e = img.extent
        let cx = e.midX, cy = e.midY
        func pts(_ n: Int) -> [CGPoint] {
            (0..<n).map { CGPoint(x: cx + CGFloat(($0 % 5) - 2) * 40, y: cy + CGFloat($0 / 5) * 40) }
        }
        func ms(_ f: () -> Void) -> Double {
            let t0 = Date(); f(); return Date().timeIntervalSince(t0) * 1000
        }
        _ = sharedCtx.createCGImage(healSpots(img, points: pts(1), radius: 20), from: e)   // 预热
        for n in [1, 5, 20, 60] {
            // 关键：这些落点到底走的是**样例补洞**还是悄悄退回**模糊填**？（成本差一个量级）
            let m = strokeMask(extent: e, points: pts(n), radius: 20)
            let roi = strokeBounds(pts(n), radius: 20, extent: e)
            let ex = m.flatMap { inpaintExemplar(img, mask: $0, roi: roi) }
            let t = ms { _ = sharedCtx.createCGImage(healSpots(img, points: pts(n), radius: 20), from: e) }
            let holes = Double(n) * Double.pi * 400
            print(String(format: "  [实测] %2d 个落点：%.0f ms ｜ ROI %.0fx%.0f ｜ 洞占比 %.2f%% ｜ 样例补洞 %@",
                         n, t, roi.width, roi.height, holes / Double(e.width * e.height) * 100,
                         ex == nil ? "失败→退回模糊填" : String(format: "成功(%.0f ms)", ex!.stats.millis)))
            // **这条断言守住一个真 bug**（第 112 节）：上限原来按 ROI 面积算，
            // ROI 被刻意收紧后，两个落点以上就会 return nil、悄悄退回模糊填（质量 29.2 → 40.9）。
            // 5 / 20 个落点属于最常见的"涂一条"，必须仍走样例补洞。
            if n == 5 || n == 20 {
                check("\(n) 个落点的笔触仍走样例补洞（不退化成模糊填）", ex != nil,
                      ex == nil ? "退化成模糊填了" : String(format: "样例补洞 %.0f ms", ex!.stats.millis))
            }
        }
        let tClone = ms { _ = sharedCtx.createCGImage(
            cloneAligned(img, points: pts(20), offsets: Array(repeating: CGPoint(x: 60, y: 0), count: 20),
                         radius: 20), from: e) }
        print(String(format: "  [实测] 仿制（取样复制）20 个落点：%.0f ms", tClone))
    } else { print("  （夹具不可用，跳过）") }
}

// MARK: - 46. 修复类工具属性必须真的改变结果（羽化/程度/不透明度）

head("46. 修复参数（羽化/程度）确实改变输出")
do {
    if let img = loadFixture(bigFace, maxDim: 900) {
        let e = img.extent
        let pts = [CGPoint(x: e.midX, y: e.midY)]
        func meanDiff(_ a: CIImage, _ b: CIImage) -> Double {
            // 全分辨率局部比较：缩略图会把小差别抹平（上一版就是因此看不出来）
            let box = CGRect(x: e.midX - 80, y: e.midY - 80, width: 160, height: 160)
            let n = 64
            func small(_ i: CIImage) -> [UInt8] {
                var buf = [UInt8](repeating: 0, count: n * n * 4)
                let c = i.cropped(to: box).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
                let sc = c.transformed(by: CGAffineTransform(scaleX: CGFloat(n) / box.width, y: CGFloat(n) / box.height))
                sharedCtx.render(sc, toBitmap: &buf, rowBytes: n * 4,
                                 bounds: CGRect(x: 0, y: 0, width: n, height: n),
                                 format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                return buf
            }
            let x = small(a), y = small(b)
            var s = 0.0
            for i in 0..<x.count { s += abs(Double(x[i]) - Double(y[i])) }
            return s / Double(x.count)
        }
        let f10 = healSpots(img, points: pts, radius: 20, strength: 1.0, feather: 0.10)
        let f90 = healSpots(img, points: pts, radius: 20, strength: 1.0, feather: 0.90)
        // ⚠️ 阈值为什么这么低（0.02）：羽化**只影响洞边的过渡带**（补进去的内容两版相同），
        // 所以全图平均差天然很小。原来我拿 0.5 当阈值 → 误判成"死滑杆"。
        // 判据改成"必须有变化"，并把数值打出来（实测 0.1x 量级）。
        check("羽化确实改变输出（只影响过渡带，故幅度小但是非零）", meanDiff(f10, f90) > 0.02,
              String(format: "羽化 0.10 vs 0.90 局部平均差 %.2f（只改边缘过渡带，所以小是正常的）", meanDiff(f10, f90)))
        let s50 = healSpots(img, points: pts, radius: 20, strength: 0.5, feather: 0.55)
        let s100 = healSpots(img, points: pts, radius: 20, strength: 1.0, feather: 0.55)
        // ⚠️ 阈值 0.2：这个数会随**底下跑的是哪条路**变。原先量到 0.59 时走的是模糊填，
        // 第 112 节修好"上限单位"后这里改走样例补洞 → 变成 0.45。判据只要求"明显非零"。
        check("程度确实改变输出", meanDiff(s50, s100) > 0.2,
              String(format: "程度 0.5 vs 1.0 局部平均差 %.2f（样例补洞路径下量到）", meanDiff(s50, s100)))
    } else { print("  （夹具不可用，跳过）") }
}

// MARK: - 47. 大面积兜底：自然纹理上到底该用哪种填（模糊填 vs 取样复制）
}
