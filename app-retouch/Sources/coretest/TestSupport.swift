// TestSupport.swift：coretest 的顶层声明（工具函数、结构体、全局量表），从 main.swift 拆出。
// Swift 规定：非 main 文件只允许放声明——所以"线性脚本"必须包成函数，声明可以留在文件作用域。

import Foundation

import RetouchCore

import CoreImage

import CoreImage.CIFilterBuiltins

import Vision

import ImageIO

let root = "/Users/you/Documents/DeepSeek-Harness-Projects/dsh-xiutu"

let libDirs = ["douyin_favorites/images", "bilibili_library/images", "xiaohongshu_library/images"]

var nPass = 0, nFail = 0, nSkip = 0

func check(_ name: String, _ ok: Bool, _ detail: String) {
    if ok { nPass += 1; print("  [OK] " + name + " — " + detail) }
    else { nFail += 1; print("  [!!] " + name + " — " + detail) }
}

/// 前置条件不满足时的**显式跳过**。
/// 为什么要单独一个函数：以前这些地方写的是 `check(名字, true, "…跳过")` ——
/// 一律加进"通过"计数，于是"这张图没检出脸，跳过"和"真的验过了"在收尾行里长得一模一样。
/// 一个检查在它的前提不存在时报"通过"，等于没有这个检查（第 128 节那条规矩的测试版）。
func skip(_ name: String, _ why: String) {
    nSkip += 1; print("  [SKIP] " + name + " — " + why)
}

func head(_ s: String) { print(""); print("=== " + s + " ===") }

func fmt(_ v: Double, _ d: Int = 3) -> String { String(format: "%." + String(d) + "f", v) }

func renderable(_ i: CIImage) -> Bool { sharedCtx.createCGImage(i, from: i.extent.integral) != nil }

struct DiffMap {
    var w = 0, h = 0
    var d: [Double] = []
    var maxV = 0.0
    var sumTotal: Double { d.reduce(0, +) }
    var total: Double { sumTotal / Double(max(1, w * h)) }
    var maxValue: Double { maxV }
    var centroid: CGPoint {
        var sx = 0.0, sy = 0.0, s = 0.0
        for y in 0..<h { for x in 0..<w {
            let v = d[y * w + x]; if v <= 0.002 { continue }
            sx += Double(x) * v; sy += Double(y) * v; s += v
        } }
        guard s > 0 else { return .zero }
        return CGPoint(x: sx / s, y: Double(h) - sy / s)   // 位图行 0 = 图顶
    }
    func sum(in rect: CGRect) -> Double {
        let r = rect.standardized
        var s = 0.0
        for y in 0..<h { for x in 0..<w {
            let px = Double(x) + 0.5, py = Double(h) - Double(y) - 0.5
            if px >= r.minX && px <= r.maxX && py >= r.minY && py <= r.maxY { s += d[y * w + x] }
        } }
        return s
    }
    func avg(in rect: CGRect) -> Double {
        let r = rect.standardized
        let n = max(1.0, Double(r.width * r.height))
        return sum(in: rect) / n
    }
}

let portraitKeysForAudit: [(String, WritableKeyPath<PortraitOptions, Double>)] = [
    ("祛痘", \.faceBlemish), ("斑点", \.spotBlemish), ("痣", \.mole), ("油光", \.shine),
    ("汗孔", \.sweat), ("黑眼圈", \.darkCircle), ("眼袋", \.eyebag), ("鼻孔", \.nostril),
    ("唇纹", \.lipLine), ("双下巴", \.doubleChin), ("下颌", \.jawLine), ("牙齿", \.teeth),
    ("眼睛", \.eyes), ("唇色", \.lipColor), ("腮红", \.blush), ("手部", \.hands),
    ("脚部", \.feet), ("瘦脸", \.faceSlim), ("大眼", \.eyeBig), ("鼻翼", \.noseSlim),
    ("下巴形", \.chinShape), ("额头", \.forehead)
]

func diffMap(_ a: CIImage, _ b: CIImage) -> DiffMap {
    let na = a.transformed(by: CGAffineTransform(translationX: -a.extent.minX, y: -a.extent.minY))
    let nb = b.transformed(by: CGAffineTransform(translationX: -b.extent.minX, y: -b.extent.minY))
    let w = Int(na.extent.width), h = Int(na.extent.height)
    func render(_ i: CIImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(i, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return buf
    }
    let A = render(na), B = render(nb)
    var dm = DiffMap(); dm.w = w; dm.h = h
    var acc = [Double](repeating: 0, count: w * h)
    var mx = 0.0
    for i in 0..<(w * h) {
        let la = 0.2126 * Double(A[i * 4]) + 0.7152 * Double(A[i * 4 + 1]) + 0.0722 * Double(A[i * 4 + 2])
        let lb = 0.2126 * Double(B[i * 4]) + 0.7152 * Double(B[i * 4 + 1]) + 0.0722 * Double(B[i * 4 + 2])
        let v = abs(la - lb) / 255.0
        acc[i] = v; mx = max(mx, v)
    }
    dm.d = acc; dm.maxV = mx
    return dm
}

func verifyPortrait(_ name: String, src: CIImage, target: CGPoint, radius: Double, faceBox: CGRect,
                    apply: (CIImage) -> CIImage, minPeak: Double = 0.02) {
    let H = src.extent.height
    let out = apply(src)
    let mid = diffMap(src, out)
    let c = mid.centroid
    let dTarget = hypot(Double(c.x - target.x), Double(c.y - target.y))
    let mirror = CGPoint(x: target.x, y: H - target.y)
    let dMirror = hypot(Double(c.x - mirror.x), Double(c.y - mirror.y))
    let near = CGRect(x: faceBox.minX - faceBox.width * 0.6, y: faceBox.minY - faceBox.height * 0.6,
                      width: faceBox.width * 2.2, height: faceBox.height * 2.2)
    let insideFace = mid.avg(in: faceBox)
    let farSum = mid.sumTotal - mid.sum(in: near)
    let farArea = Double(mid.w * mid.h) - (near.width * near.height)
    let farAvg = farSum / max(1, farArea)
    check(name + "｜能出图", renderable(out), "extent " + String(Int(out.extent.width)) + "x" + String(Int(out.extent.height)))
    check(name + "｜有效果", mid.maxValue > minPeak, "峰值变化 " + fmt(mid.maxValue, 4) + "（要求 > " + fmt(minPeak, 3) + "）")
    check(name + "｜落点正确", dTarget < max(radius, 12) && dTarget < dMirror,
          "质心(" + String(Int(c.x)) + "," + String(Int(c.y)) + ") 距目标 " + fmt(dTarget, 1) + " px（容差 " + String(Int(max(radius, 12))) + "）距镜像 " + fmt(dMirror, 1))
    check(name + "｜不越界", insideFace > farAvg * 4,
          "脸区变化密度 " + fmt(insideFace, 6) + " vs 远处 " + fmt(farAvg, 6) + "（倍数 " + fmt(insideFace / max(farAvg, 1e-9), 1) + "）")
}

func loadFixture(_ name: String, maxDim: Int) -> CIImage? {
    for d in libDirs {
        let p = root + "/" + d + "/" + name
        if FileManager.default.fileExists(atPath: p) { return loadImage(p, maxDim: maxDim) }
    }
    let p = root + "/" + name
    return FileManager.default.fileExists(atPath: p) ? loadImage(p, maxDim: maxDim) : nil
}

let bigFace = "0002_7684050444133652337_04.webp"      // 脸占画面宽度约 70%

let handImg = "0001_7676844130508479842_18.webp"      // 两只手

let animalImg = "0001_7676844130508479842_23.webp"    // 两只动物

let wedding = "2604_wedding/00_RAW_readonly/wedding_01.jpg"

func detailP95(_ img: CIImage, region: CGRect, radius: Double) -> Double {
    let c = img.cropped(to: region)
    let low = c.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: region)
    let d = c.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: low])
    let inner = region.insetBy(dx: 6, dy: 6)
    guard inner.width > 4, inner.height > 4 else { return measure(d, work: 256).p95 }
    return measure(d.cropped(to: inner), work: 256).p95
}

func toneSpread(_ img: CIImage, region: CGRect, radius: Double) -> Double {
    let low = img.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: region)
    let st = measure(low, work: 256)
    return (st.p99 - st.p5) / 4.65
}

import Darwin

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func fullPipeline(_ input: CIImage) -> CIImage {
    var out = render(input, Params())
    var sk = SkinOptions(); sk.grade = "medium"; sk.unifyTone = true; sk.deltaWarm = 2
    out = applySkin(out, sk)
    var p = PortraitOptions()
    p.spotBlemish = 40; p.teeth = 50; p.eyes = 50; p.darkCircle = 40; p.faceSlim = 30
    out = applyPortrait(out, p)
    out = denoise(out, amount: 30)
    out = sharpen(out, amount: 40)
    return out
}

let f = ProjectStore.fileURL

let before = ProjectStore.load()

let after = ProjectStore.load()

let again = ProjectStore.load()

func synth(w: Int, h: Int) -> CIImage {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return CIImage.empty() }
    for x in 0..<w {
        let t = Double(x) / Double(w - 1)
        let v = 40.0 + t * 170.0                       // 暗 → 亮
        ctx.setFillColor(CGColor(srgbRed: v / 255.0 * 0.8, green: v / 255.0 * 0.9,
                                 blue: v / 255.0, alpha: 1))   // 偏蓝：R < B
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
    }
    guard let cg = ctx.makeImage() else { return CIImage.empty() }
    return CIImage(cgImage: cg)
}

let sg = synth(w: 256, h: 64)

let sBase = measure(sg)

var pWarm = Params()

let sWarm = measure(render(sg, pWarm))

var pWarm2 = pWarm

var pDesatOnly = Params()

let sWarm2 = measure(render(sg, pWarm2))

let sDesatOnly = measure(render(sg, pDesatOnly))

var target = Stats()

let pSolve = paramsFromStats(from: sBase, to: target)

let sSolved = measure(render(sg, pSolve))

let normal = [0.30, 0.31, 0.29].map { v -> CIImage in
    var p = Params(); p.brightness = 0; p.gamma = 1; p.levelsOut = [v * 255, 255]
    return render(sg, p)
}

let black = render(sg, { var p = Params(); p.levelsOut = [0, 12]; p.levelsIn = [250, 255]; return p }())

let (tAll, nAll, _) = referenceTarget(normal + [black])

let (tClean, _, _) = referenceTarget(normal)

let petCandidates: [String] = {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    let imgs = names.filter { n in
        let e = (n as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp", "heic"].contains(e)
    }.sorted()
    // 先用「能检出动物」的那张（下面还会再核实一次）
    return imgs
}()
