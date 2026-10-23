// CoreTestSections4.swift：coretest 的第 25~32 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections4() {
head("6g. 自动能力：白平衡 / 智能锐化 / 高光恢复 / 补光方向")
do {
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 400)
    func meanRGB(_ img: CIImage, _ rect: CGRect) -> (Double, Double, Double) {
        var buf = [UInt8](repeating: 0, count: Int(rect.width) * Int(rect.height) * 4)
        sharedCtx.render(img, toBitmap: &buf, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var r = 0.0, g = 0.0, b = 0.0
        let n = Double(Int(rect.width) * Int(rect.height))
        for i in 0..<Int(n) { r += Double(buf[i * 4]); g += Double(buf[i * 4 + 1]); b += Double(buf[i * 4 + 2]) }
        return (r / n, g / n, b / n)
    }
    // 1) 自动白平衡：造 15% 暖偏的灰阶图
    var gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
    for (i, v) in [0.25, 0.4, 0.55, 0.7, 0.85].enumerated() {
        gray = CIImage(color: CIColor(red: v, green: v, blue: v))
            .cropped(to: CGRect(x: CGFloat(i * 80), y: 0, width: 80, height: 400)).composited(over: gray)
    }
    let warm = gray.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 1.15, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0.92, w: 0)]).cropped(to: canvas)
    let wb = estimateWhiteBalance(warm)
    let (r0, _, b0) = meanRGB(warm, canvas)
    let corrected = applyWhiteBalance(warm, amount: 100)
    let (r1, _, b1) = meanRGB(corrected, canvas)
    check("自动白平衡：色偏被拉回", (r0 - b0) > 20 && abs(r1 - b1) < (r0 - b0) * 0.15,
          String(format: "R-B 偏差 %.1f → %.1f（降到 %.0f%%，增益 R%.3f G%.3f B%.3f，来源 %@）",
                 r0 - b0, r1 - b1, abs(r1 - b1) / max(0.001, r0 - b0) * 100, wb.rGain, wb.gGain, wb.bGain, wb.source))

    // 2) 边缘感知锐化：真实人像上「平坦皮肤 vs 纹理头发」的提升比
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
        func detail(_ i: CIImage, _ r: CGRect) -> Double {
            let c = i.cropped(to: r)
            let low = c.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: r)
            let d = c.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: low])
            return measure(d.cropped(to: r.insetBy(dx: 6, dy: 6)), work: 192).p95
        }
        if let g = detectFaceGeos(cg, size: img.extent.size).first {
            let face = g.box
            let skin = CGRect(x: face.midX - face.width * 0.16, y: face.minY + face.height * 0.22,
                              width: face.width * 0.32, height: face.height * 0.20)
            let hair = CGRect(x: face.minX, y: face.maxY - face.height * 0.22,
                              width: face.width * 0.5, height: face.height * 0.20)
            let s0 = detail(img, skin), h0 = detail(img, hair)
            let plain = sharpen(img, amount: 80), aware = sharpenEdgeAware(img, amount: 80)
            let skinPlain = detail(plain, skin) / max(0.01, s0)
            let skinAware = detail(aware, skin) / max(0.01, s0)
            let hairPlain = detail(plain, hair) / max(0.01, h0)
            let hairAware = detail(aware, hair) / max(0.01, h0)
            // 比的是**提升量**（ratio-1），不是 ratio 本身：ratio 1.4 vs 2.0 的提升是 40% vs 100%
            check("智能锐化：少放大平坦区、照锐纹理区",
                  (skinAware - 1) < (skinPlain - 1) * 0.6 && (hairAware - 1) > (hairPlain - 1) * 0.7,
                  String(format: "平坦皮肤提升 %.0f%%（普通 %.0f%%）；纹理头发提升 %.0f%%（普通 %.0f%%）",
                         (skinAware - 1) * 100, (skinPlain - 1) * 100, (hairAware - 1) * 100, (hairPlain - 1) * 100))
        }
    }

    // 3) 高光恢复：左半纯白（已溢出）
    let whiteHalf = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
    let darkHalf = CIImage(color: CIColor(red: 0.4, green: 0.42, blue: 0.45))
        .cropped(to: CGRect(x: 200, y: 0, width: 200, height: 400))
    let clipped = whiteHalf.composited(over: darkHalf)
    let hotRect = CGRect(x: 20, y: 80, width: 60, height: 40)
    let coldRect = CGRect(x: 300, y: 80, width: 60, height: 40)
    let hot0 = meanRGB(clipped, hotRect).0, cold0 = meanRGB(clipped, coldRect).0
    let recovered = recoverHighlights(clipped, amount: 80)
    let hot1 = meanRGB(recovered, hotRect).0, cold1 = meanRGB(recovered, coldRect).0
    check("高光恢复：只拉溢出区", hot0 > 250 && hot1 < hot0 - 15 && abs(cold1 - cold0) < 1,
          String(format: "溢出区 R %.0f → %.0f，相邻暗区 %.0f → %.0f（应不变）", hot0, hot1, cold0, cold1))

    // 4) 补光方向：右亮左暗 → 估计 dx>0，补光应更着重暗的左边
    let lg = CIFilter.linearGradient()
    lg.point0 = CGPoint(x: 0, y: 200); lg.point1 = CGPoint(x: 400, y: 200)
    lg.color0 = CIColor(red: 0.15, green: 0.15, blue: 0.15)
    lg.color1 = CIColor(red: 0.85, green: 0.85, blue: 0.85)
    let rightBright = (lg.outputImage ?? CIImage(color: .black)).cropped(to: canvas)
    let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: canvas)
    let dir = estimateLightDirection(rightBright)
    let leftRect = CGRect(x: 20, y: 190, width: 60, height: 20)
    let rightRect = CGRect(x: 320, y: 190, width: 60, height: 20)
    let lf0 = meanRGB(flat, leftRect).0, rf0 = meanRGB(flat, rightRect).0
    let filled = autoFillLight(flat, amount: 80)
    let lf1 = meanRGB(filled, leftRect).0, rf1 = meanRGB(filled, rightRect).0
    check("自动补光：方向取自光向", dir.dx > 0.2 && (lf1 - lf0) > (rf1 - rf0) * 1.5,
          String(format: "估计光向 dx %.2f（右亮图应 >0）；补光后左 +%.1f、右 +%.1f", dir.dx, lf1 - lf0, rf1 - rf0))
    // 4) 自动暗角 / 自动降噪（本轮新增）
    let flatPlate = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: canvas)
    let cleanVig = planAutoVignette(flatPlate)
    check("自动暗角：干净平场不动", !cleanVig.needed,
          cleanVig.detail + " → 需要动 " + String(cleanVig.needed))
    let vigged = vignette(flatPlate, amount: 80)
    let vigPlan = planAutoVignette(vigged)
    let vigFixed = correctVignetting(vigged, amount: vigPlan.amount)
    let vigAfter = planAutoVignette(vigFixed)
    check("自动暗角：量出比值并按标定校正",
          vigPlan.needed && vigPlan.cornerToCenter < 0.9 && vigAfter.cornerToCenter > vigPlan.cornerToCenter + 0.1,
          String(format: "人为暗角 80：%@ → 建议 %.0f → 校正后 %.3f", vigPlan.detail, vigPlan.amount, vigAfter.cornerToCenter))

    // 合成噪声：确定性伪随机，便于复现
    func noisyPlate(_ amplitude: Double, seed: Int) -> CIImage {
        let w = 400, h = 400
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var state = UInt64(seed)
        for i in 0..<(w * h) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Double((state >> 33) % 1000) / 1000.0
            let v = max(0, min(255, 153 + (r - 0.5) * 2 * amplitude * 60))
            bytes[i * 4] = UInt8(v); bytes[i * 4 + 1] = UInt8(v); bytes[i * 4 + 2] = UInt8(v); bytes[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return flatPlate }
        return CIImage(cgImage: cg)
    }
    let cleanNoise = planAutoDenoise(flatPlate)
    check("自动降噪：干净图不动", !cleanNoise.needed, cleanNoise.detail)
    let noisyPlate = noisyPlate(1.0, seed: 7)
    let noisePlan = planAutoDenoise(noisyPlate)
    let denoised = denoise(noisyPlate, amount: noisePlan.amount)
    let noiseAfter = planAutoDenoise(denoised)
    check("自动降噪：估出噪声并压下去",
          noisePlan.needed && noisePlan.noiseSigma > 5 && noiseAfter.noiseSigma < noisePlan.noiseSigma * 0.7,
          String(format: "噪声 σ %.2f → 建议 %.0f → 降噪后 σ %.2f（降 %.0f%%）",
                 noisePlan.noiseSigma, noisePlan.amount, noiseAfter.noiseSigma,
                 (1 - noiseAfter.noiseSigma / max(0.001, noisePlan.noiseSigma)) * 100))
}

// MARK: - 6h. 自动曝光 / 自动摆正 / 自动肤色


head("6h. 自动曝光 / 自动摆正 / 自动肤色")
do {
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 400)
    func stats(_ img: CIImage) -> (Double, Double, Double) {
        let w = 200, h = 200
        let e = img.extent
        let scaled = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(h) / e.height))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        sharedCtx.render(scaled, toBitmap: &buf, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                         format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var vals: [Double] = []
        for i in 0..<(w * h) {
            vals.append(0.2126 * Double(buf[i * 4]) + 0.7152 * Double(buf[i * 4 + 1]) + 0.0722 * Double(buf[i * 4 + 2]))
        }
        let s = vals.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
        return (q(0.05), q(0.5), q(0.95))
    }
    // 1) 自动曝光：低对比灰图 → 中调落到目标、跨度拉开
    let lg = CIFilter.linearGradient()
    lg.point0 = CGPoint(x: 0, y: 200); lg.point1 = CGPoint(x: 400, y: 200)
    lg.color0 = CIColor(red: 60 / 255.0, green: 60 / 255.0, blue: 60 / 255.0)
    lg.color1 = CIColor(red: 180 / 255.0, green: 180 / 255.0, blue: 180 / 255.0)
    let flatLow = (lg.outputImage ?? CIImage(color: .black)).cropped(to: canvas)
    let (a5, a50, a95) = stats(flatLow)
    let fixed = autoExpose(flatLow)
    let (b5, b50, b95) = stats(fixed)
    check("自动曝光：中调到位、跨度拉开", abs(b50 - 118) < 12 && (b95 - b5) > (a95 - a5) * 1.5,
          String(format: "p5/p50/p95 %.0f/%.0f/%.0f（跨度 %.0f）→ %.0f/%.0f/%.0f（跨度 %.0f，目标中调 118）",
                 a5, a50, a95, a95 - a5, b5, b50, b95, b95 - b5))
    // 曝光正常的图不该被动
    let normal = CIImage(color: CIColor(red: 118 / 255.0, green: 118 / 255.0, blue: 118 / 255.0)).cropped(to: canvas)
    let planN = planAutoExposure(normal)
    check("自动曝光：不碰已经正常的图", !planN.changed,
          String(format: "p50=118 的图判定「需要动」= %@（应为 false）", planN.changed ? "true" : "false"))

    // 2) 自动摆正：量出的倾角要准（这是「自动」能否用起来的关键）
    var grid = CIImage(color: .black).cropped(to: canvas)
    for i in stride(from: 0, to: 400, by: 40) {
        grid = CIImage(color: .white).cropped(to: CGRect(x: CGFloat(i), y: 0, width: 6, height: 400)).composited(over: grid)
        grid = CIImage(color: .white).cropped(to: CGRect(x: 0, y: CGFloat(i), width: 400, height: 6)).composited(over: grid)
    }
    var tiltOK = true, tiltDetail = ""
    for deg in [5.0, -4.0, 8.0, -9.0] {
        let rot = grid.transformed(by: CGAffineTransform(rotationAngle: deg * .pi / 180))
        let est = estimateTiltAngle(rot) ?? -999
        if abs(est - deg) > 1.5 { tiltOK = false }
        tiltDetail += String(format: "%+.0f°→%+.1f°；", deg, est)
    }
    check("自动摆正：倾角估计误差 < 1.5°", tiltOK, "真值→估计：" + tiltDetail)
    let straight = estimateTiltAngle(grid) ?? -999
    check("自动摆正：正放的图不报假倾角", abs(straight) < 1.5, String(format: "正放网格估计 %.2f°（应≈0）", straight))

    // 3) 自动肤色：把偏色朝目标带（26°）拉，且只在皮肤区生效
    if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent),
       let g = detectFaceGeos(cg, size: img.extent.size).first {
        let mask = skinMaskForFace(img, face: g)
        if let base = measureSkinTone(img, mask: mask) {
            let cast = img.applyingFilter("CIHueAdjust", parameters: ["inputAngle": 15.0 * .pi / 180])
                .cropped(to: img.extent)
            let (fx, before, shift) = autoSkinTone(cast, mask: mask)
            if let after = measureSkinTone(fx, mask: mask), let b = before {
                func distToTarget(_ h: Double) -> Double {
                    let d = abs(h - 26); return min(d, 360 - d)
                }
                check("自动肤色：朝目标带收敛", distToTarget(after.hue) < distToTarget(b.hue) - 0.5,
                      String(format: "偏色后 %.1f° → 校正 %+.2f° → %.1f°（离目标 26° 的距离 %.1f → %.1f；原图 %.1f°）",
                             b.hue, shift, after.hue, distToTarget(b.hue), distToTarget(after.hue), base.hue))
            }
        }
    }
}

// MARK: - 6i. 人脸解析（Core ML 模型）


head("6i. 人脸解析：皮肤掩膜该不该用模型")
do {
    let modelPath = FaceParser.modelURL()?.path ?? "未找到"
    let available = FaceParser.shared.isAvailable
    check("人脸解析模型可用", available, "模型：" + modelPath)
    if available, let img = loadFixture(bigFace, maxDim: 900),
       let cg = sharedCtx.createCGImage(img, from: img.extent),
       let g = detectFaceGeos(cg, size: img.extent.size).max(by: { $0.box.width < $1.box.width }) {
        let color = skinMaskForFace(img, face: g)
        guard let parsed = parsedSkinMaskForFace(img, face: g) else { exit(1) }
        func avg(_ m: CIImage, _ r: CGRect) -> Double {
            let rr = r.intersection(m.extent).integral
            guard rr.width > 1, rr.height > 1 else { return -1 }
            var b = [UInt8](repeating: 0, count: Int(rr.width) * Int(rr.height) * 4)
            sharedCtx.render(m, toBitmap: &b, rowBytes: Int(rr.width) * 4, bounds: rr, format: .RGBA8,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var s = 0.0
            for i in 0..<Int(rr.width * rr.height) { s += Double(b[i * 4]) }
            return s / Double(Int(rr.width * rr.height)) / 255.0
        }
        func small(_ c: CGPoint, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }
        let box = g.box
        let nose = g.bbox(g.nose)
        let noseBox = small(CGPoint(x: nose.midX, y: nose.midY), nose.width * 0.6, nose.height * 0.6)
        let lipBox = small(g.centroid(g.innerLips), box.width * 0.22, box.height * 0.08)
        let cheek = CGRect(x: box.minX + box.width * 0.14, y: box.minY + box.height * 0.16,
                           width: box.width * 0.20, height: box.height * 0.16)
        let cNose = avg(color, noseBox), pNose = avg(parsed, noseBox)
        let cLip = avg(color, lipBox), pLip = avg(parsed, lipBox)
        let cCheek = avg(color, cheek), pCheek = avg(parsed, cheek)
        // 判据写成「解析明显低于肤色阈值」而不是绝对值：肤色阈值的具体数值依赖那一块的颜色，
        // 但「它把鼻子/嘴唇当皮肤、解析不当」这个差异是稳定的
        check("解析掩膜把鼻子和嘴唇排除在皮肤之外",
              pNose < 0.15 && pLip < 0.15 && pCheek > 0.4 && cLip > pLip + 0.3 && cNose > pNose + 0.15,
              String(format: "鼻子：肤色阈值 %.2f → 解析 %.2f；嘴唇：%.2f → %.2f；脸颊两边都高：%.2f / %.2f",
                     cNose, pNose, cLip, pLip, cCheek, pCheek))
        // 解析耗时（含每张脸一次推理）
        let t0 = Date()
        for _ in 0..<3 { _ = parsedSkinMaskForFace(img, face: g) }
        let ms = Date().timeIntervalSince(t0) / 3 * 1000
        // ⚠️ 这是**回归红线**，不是性能基准：正常 42 ms 左右，但机器负载高时 Vision 推理会涨到几倍。
        // 原来写 400 ms（10× 余量），实测在负载 20+ 的机器上会假红 —— 而假红会训练人忽略红灯。
        // 1200 ms 仍能抓住"慢了 30 倍"这种真回归。
        check("解析耗时可用（回归红线 1200ms）", ms < 1200, String(format: "每张脸一次解析 + 映射：%.0f ms", ms))
    }
}

// MARK: - 6j. 牙齿 / 唇色 / 眼睛：解析掩膜 vs 关键点多边形


head("6j. 五官专项掩膜：解析 vs 关键点多边形")
if FaceParser.shared.isAvailable,
   let img = loadFixture(bigFace, maxDim: 900),
   let cg = sharedCtx.createCGImage(img, from: img.extent),
   let g = detectFaceGeos(cg, size: img.extent.size).first {
    let e = img.extent
    func avg(_ m: CIImage, _ r: CGRect) -> Double {
        let rr = r.intersection(m.extent).integral
        guard rr.width > 1, rr.height > 1 else { return -1 }
        var b = [UInt8](repeating: 0, count: Int(rr.width) * Int(rr.height) * 4)
        sharedCtx.render(m, toBitmap: &b, rowBytes: Int(rr.width) * 4, bounds: rr, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var s = 0.0
        for i in 0..<Int(rr.width * rr.height) { s += Double(b[i * 4]) }
        return s / Double(Int(rr.width * rr.height)) / 255.0
    }
    func grow(_ pts: [CGPoint], _ k: Double) -> CGRect {
        let b = g.bbox(pts)
        return b.insetBy(dx: -b.width * k, dy: -b.height * k)
    }
    let mouthBox = grow(g.innerLips, 0), lipBox = grow(g.outerLips, 0)
    let eyeBox = grow(g.leftEye + g.rightEye, 0)
    let chin = CGRect(x: g.box.midX - g.box.width * 0.15, y: g.box.minY + g.box.height * 0.04,
                      width: g.box.width * 0.30, height: g.box.height * 0.08)
    let brow = CGRect(x: g.box.minX + g.box.width * 0.2, y: eyeBox.maxY,
                      width: g.box.width * 0.6, height: g.box.height * 0.06)

    // 牙齿：解析的口腔掩膜不该盖到嘴唇/下巴
    let teethPoly = polygonMask(extent: e, polygons: [g.innerLips],
                                feather: max(0.8, min(mouthBox.width, mouthBox.height) * 0.25))
    let teethParsed = parsedMaskForFace(img, face: g, classes: FaceClass.mouthClasses)
    let pMouth = teethParsed.map { avg($0, mouthBox) } ?? -1
    let pLip = teethParsed.map { avg($0, lipBox) } ?? -1
    let pChin = teethParsed.map { avg($0, chin) } ?? -1
    check("牙齿掩膜：只盖口腔，不盖嘴唇和下巴",
          pMouth > 0.25 && pLip < 0.15 && pChin < 0.05,
          String(format: "口腔 %.2f ｜ 嘴唇 %.2f（多边形 %.2f）｜ 下巴 %.2f", pMouth, pLip, avg(teethPoly, lipBox), pChin))

    // 唇色：解析的唇掩膜覆盖不该低于多边形（多边形是「圈个大概」，会漏掉唇缘）
    let lipPoly = polygonMask(extent: e, polygons: [g.outerLips],
                              feather: max(0.8, min(lipBox.width, lipBox.height) * 0.18))
    let lipParsed = parsedMaskForFace(img, face: g, classes: FaceClass.lipClasses)
    let lpPoly = avg(lipPoly, lipBox), lpParsed = lipParsed.map { avg($0, lipBox) } ?? -1
    let cheekBox = CGRect(x: g.box.minX + g.box.width * 0.12, y: g.box.minY + g.box.height * 0.18,
                          width: g.box.width * 0.20, height: g.box.height * 0.16)
    let lpCheek = lipParsed.map { avg($0, cheekBox) } ?? -1
    check("唇掩膜：覆盖不低于多边形、且不越过嘴唇",
          lpParsed >= lpPoly * 0.95 && lpCheek < 0.1,
          String(format: "唇区覆盖 多边形 %.2f → 解析 %.2f；解析在脸颊上 %.2f", lpPoly, lpParsed, lpCheek))

    // 眼睛：解析的眼掩膜不该漏到眉毛上方
    let eyePoly = polygonMask(extent: e, polygons: [g.leftEye, g.rightEye],
                              feather: max(0.8, min(eyeBox.width, eyeBox.height) * 0.25))
    let eyeParsed = parsedMaskForFace(img, face: g, classes: FaceClass.eyeClasses)
    let ePoly = avg(eyePoly, brow), eParsed = eyeParsed.map { avg($0, brow) } ?? -1
    let eyeCover = eyeParsed.map { avg($0, eyeBox) } ?? -1
    check("眼掩膜：不漏到眉毛上方",
          eParsed <= ePoly * 0.6 + 1e-6 && eyeCover > 0.15,
          String(format: "眉上方泄漏 多边形 %.2f → 解析 %.2f；眼区覆盖 %.2f", ePoly, eParsed, eyeCover))
}

// MARK: - 6k. 场景自适应（场景识别 + 本图测量）


head("6k. 场景自适应：逆光/噪声/肤色占比 → 自动参数")
do {
    let canvas = CGRect(x: 0, y: 0, width: 400, height: 400)
    func flat(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v)).cropped(to: canvas)
    }
    // 逆光：四周亮、中间暗；顺光反过来
    let backlit = flat(0.22).cropped(to: CGRect(x: 120, y: 120, width: 160, height: 160)).composited(over: flat(0.85))
    let frontlit = flat(0.55).cropped(to: CGRect(x: 120, y: 120, width: 160, height: 160)).composited(over: flat(0.25))
    let pb = planSceneAdaptive(backlit, scene: SceneInfo(category: "人像"))
    let pf = planSceneAdaptive(frontlit, scene: SceneInfo(category: "人像"))
    check("场景自适应：逆光才补光",
          pb.backlight > 1.35 && pb.fillLight > 30 && pb.exposure > 20 && pf.fillLight == 0,
          String(format: "逆光 背景/主体 %.2f → 补光 %.0f 曝光 %.0f；顺光 %.2f → 补光 %.0f 曝光 %.0f",
                 pb.backlight, pb.fillLight, pb.exposure, pf.backlight, pf.fillLight, pf.exposure))

    // 噪声 → 降噪；干净图不给降噪（复用 planAutoDenoise 的合成噪声）
    func noisyPlate(_ amplitude: Double, seed: Int) -> CIImage {
        let w = 400, h = 400
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var state = UInt64(seed)
        for i in 0..<(w * h) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = Double((state >> 33) % 1000) / 1000.0
            let v = max(0, min(255, 153 + (r - 0.5) * 2 * amplitude * 60))
            bytes[i * 4] = UInt8(v); bytes[i * 4 + 1] = UInt8(v); bytes[i * 4 + 2] = UInt8(v); bytes[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return flat(0.6) }
        return CIImage(cgImage: cg)
    }
    let pn = planSceneAdaptive(noisyPlate(1.2, seed: 3), scene: SceneInfo(category: "人像"))
    let pc = planSceneAdaptive(flat(0.6), scene: SceneInfo(category: "人像"))
    check("场景自适应：噪声大才降噪", pn.denoise > 50 && pc.denoise == 0,
          String(format: "高噪 σ %.2f → 降噪 %.0f；干净 σ %.2f → 降噪 %.0f", pn.noiseSigma, pn.denoise, pc.noiseSigma, pc.denoise))

    // 真实图：肤色占比决定磨皮档
    if let img = loadFixture(bigFace, maxDim: 900),
       let cg = sharedCtx.createCGImage(img, from: img.extent) {
        let scene = classifyScene(cg)
        let face = detectFaceGeos(cg, size: img.extent.size).max(by: { $0.box.width < $1.box.width })?.box
        let p = planSceneAdaptive(img, scene: scene, faceBox: face)
        check("场景自适应：真实人像给出合理档位",
              p.skinShare > 0.1 && p.skinGrade == "strong",
              String(format: "肤色占比 %.1f%% → 磨皮档 %@（场景 %@）", p.skinShare * 100, p.skinGrade, p.category))
    }
}

// MARK: - 6l. 挑图打分：笑容 / 姿态 / 闭眼


head("6l. 挑图打分细化：笑容 / 头部姿态 / 多人闭眼")
do {
    let base = root
    let smiling = scoreImage(base + "/2604_wedding/00_RAW_readonly/wedding_02.jpg")
    let neutral = scoreImage(base + "/douyin_favorites/images/" + bigFace)
    let group = scoreImage(base + "/2604_wedding/00_RAW_readonly/wedding_01.jpg")
    if let sm = smiling, let nt = neutral, let gp = group {
        check("挑图：笑容强度分得开", sm.smile > nt.smile * 2 && sm.smile > 0.4,
              String(format: "张嘴那张 %.2f vs 抿嘴那张 %.2f", sm.smile, nt.smile))
        check("挑图：头部姿态取自 Vision（不是猜的）", gp.headYaw > 25,
              String(format: "双人合影里最大扭头 %.0f°", gp.headYaw))
        check("挑图：多人里能数出闭眼的脸", gp.closedEyes >= 1 && gp.judgedFaces >= 2 && sm.closedEyes == 0,
              String(format: "合影闭眼 %d/%d 张脸；单人不报闭眼（%d）", gp.closedEyes, gp.judgedFaces, sm.closedEyes))
    }
}

// MARK: - 6m. 背景虚化的消光晕


head("6m. 背景虚化：消光晕（边缘不再被主体颜色染）")
if let img = loadFixture(wedding, maxDim: 700), foregroundMask(img) != nil {
    let noDe = backgroundBlur(img, radius: 20, strength: 80, dehalo: false)
    let withDe = backgroundBlur(img, radius: 20, strength: 80, dehalo: true)
    let h0 = measureHalo(noDe), h1 = measureHalo(withDe)
    check("消光晕：近环与远环的亮度差下降", h0 > 0 && h1 < h0 * 0.95,
          String(format: "光晕 不消 %.4f → 消 %.4f（降 %.0f%%）", h0, h1, (1 - h1 / max(0.0001, h0)) * 100))
    func detail(_ i: CIImage, _ r: CGRect) -> Double {
        let c = i.cropped(to: r)
        let low = c.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: r)
        let d = c.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: low])
        return measure(d.cropped(to: r.insetBy(dx: 5, dy: 5)), work: 160).p95
    }
    if let fg = foregroundMask(img) {
        let b = bboxOfBright(fg, in: img.extent)
        if !b.isNull {
            let core = b.insetBy(dx: b.width * 0.3, dy: b.height * 0.3)
            let d0 = detail(noDe, core), d1 = detail(withDe, core)
            check("消光晕：主体清晰度不能丢", d1 >= d0 * 0.9,
                  String(format: "主体细节 不消 %.1f → 消 %.1f", d0, d1))
        }
    }
}

// MARK: - 6n. 姿态分级 + 连拍同组选优


head("6n. 姿态分级 + 连拍同组选优")
do {
    let grades = [0.0: "正面", 12.0: "正面", 30.0: "3/4 侧脸", 45.0: "侧脸", 60.0: "侧脸", 85.0: "背身/扭头过度"]
    var ok = true, detail = ""
    for (yaw, want) in grades.sorted(by: { $0.key < $1.key }) {
        let got = poseGrade(yawDeg: yaw, faces: 1)
        if got != want { ok = false }
        detail += String(format: "%.0f°→%@；", yaw, got)
    }
    check("姿态分级：按 yaw 分四档", ok && poseGrade(yawDeg: 0, faces: 0) == "无脸", detail)
    if let s = scoreImage(root + "/2604_wedding/00_RAW_readonly/wedding_01.jpg") {
        check("姿态分级：真实素材能落到档位上", s.headYaw > 25 && poseGrade(yawDeg: s.headYaw, faces: s.faces) == "侧脸",
              String(format: "%@ 的 yaw %.0f° → %@", s.file, s.headYaw, poseGrade(yawDeg: s.headYaw, faces: s.faces)))
    }
    // 连拍分组：造 5 个文件，前 3 个相邻 1 秒、后 2 个在 60 秒后
    let tmp = NSTemporaryDirectory() + "cr_burst"
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let names = ["IMG_100_01.jpg", "IMG_100_02.jpg", "IMG_100_03.jpg", "IMG_200_01.jpg", "IMG_200_02.jpg"]
    for n in names { FileManager.default.createFile(atPath: tmp + "/" + n, contents: Data([0])) }
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    var t = base
    for n in names.prefix(3) {
        try? FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: tmp + "/" + n)
        t = t.addingTimeInterval(1)
    }
    t = base.addingTimeInterval(60)
    for n in names.suffix(2) {
        try? FileManager.default.setAttributes([.modificationDate: t], ofItemAtPath: tmp + "/" + n)
        t = t.addingTimeInterval(1)
    }
    let paths = names.map { tmp + "/" + $0 }
    let groups = groupBursts(paths: paths, window: 3.0)
    check("连拍分组：按时间窗分成两组", groups.count == 2 && groups[0].indices.count == 3 && groups[1].indices.count == 2,
          groups.map { "[" + $0.indices.map { String($0) }.joined(separator: ",") + "]" }.joined(separator: " "))
    // 组内选最优：分值最高的那张
    // 用真正的图片打分结果做成组对象（ImageScore 的构造器是内部的，不另造）
    let realPaths = [root + "/2604_wedding/00_RAW_readonly/wedding_01.jpg",
                     root + "/2604_wedding/00_RAW_readonly/wedding_02.jpg",
                     root + "/2604_wedding/00_RAW_readonly/wedding_03.jpg",
                     root + "/2604_wedding/00_RAW_readonly/wedding_04.jpg",
                     root + "/2604_wedding/00_RAW_readonly/wedding_05.jpg"]
    let realScores = realPaths.compactMap { scoreImage($0) }
    let fake = realScores
    let picked = pickBestPerGroup(fake, groups: groups)
    // 组内选出来的必须是该组分数最高的下标
    var correct = picked.count == 2
    for g in picked {
        let bestTotal = g.indices.compactMap { $0 < fake.count ? fake[$0].total : nil }.max() ?? -1
        if g.best >= fake.count || fake[g.best].total < bestTotal - 0.001 { correct = false }
    }
    check("连拍选优：组内取最高分", correct && fake.count >= 2,
          picked.map { $0.reason }.joined(separator: " ｜ "))
}

// MARK: - 6o. 批量场景一致性

}
