// CoreTestSections2.swift：coretest 的第 9~16 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections2() {
head("1. 面部关键点口径（必须落在人脸框内、嘴在眼睛下方）")
for (label, name, dim) in [("大脸图", bigFace, 900), ("婚礼照", wedding, 0)] {
    guard let img = loadFixture(name, maxDim: dim) else { check("素材 " + label, false, "文件不存在：" + name); continue }
    guard let cg = sharedCtx.createCGImage(img, from: img.extent) else { continue }
    let geos = detectFaceGeos(cg, size: img.extent.size)
    guard !geos.isEmpty else { check("检出人脸 " + label, false, "没检出人脸"); continue }
    var ok = true, detail = ""
    for g in geos {
        let eye = g.centroid(g.leftEye + g.rightEye)
        let mouth = g.centroid(g.innerLips)
        let inBox = g.box.contains(eye) && g.box.contains(mouth)
        let below = mouth.y < eye.y
        ok = ok && inBox && below
        detail += "框" + String(Int(g.box.width)) + "x" + String(Int(g.box.height))
            + " 眼(" + String(Int(eye.x)) + "," + String(Int(eye.y)) + ")"
            + " 嘴(" + String(Int(mouth.x)) + "," + String(Int(mouth.y)) + ")"
            + " 内/低于眼 " + String(inBox) + "/" + String(below) + "；"
    }
    check("关键点口径 " + label + "（" + String(Int(img.extent.width)) + "x" + String(Int(img.extent.height)) + "，" + String(geos.count) + " 脸）", ok, detail)
}


head("2. 位图蒙版 y 方向（合成图判定：不翻 y 才对）")
do {
    let e = CGRect(x: 0, y: 0, width: 400, height: 600)
    let rect = CGRect(x: 40, y: 60, width: 90, height: 70)     // 只在下半部分，镜像位置 (y≈470) 不重叠
    let mask = polygonMask(extent: e, polygons: [[
        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
        CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]], feather: 0)
    func value(_ r: CGRect) -> Double {
        var buf = [UInt8](repeating: 0, count: 4)
        sharedCtx.render(mask, toBitmap: &buf, rowBytes: 4, bounds: r, format: .RGBA8,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return Double(buf[0]) / 255.0
    }
    let atRect = value(CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1))
    let atMirror = value(CGRect(x: rect.midX, y: e.height - rect.midY, width: 1, height: 1))
    check("多边形蒙版不翻 y", atRect > 0.9 && atMirror < 0.1,
          "矩形中心 " + fmt(atRect, 3) + "（应≈1），镜像位置 " + fmt(atMirror, 3) + "（应≈0）")
}


head("3. 唇部/牙齿蒙版内部必须够实（羽化不许把效果吃没）")
if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let geos = detectFaceGeos(cg, size: img.extent.size)
    if let g = geos.first {
        let e = img.extent
        func value(_ m: CIImage, _ p: CGPoint) -> Double {
            var v = [UInt8](repeating: 0, count: 4)
            sharedCtx.render(m, toBitmap: &v, rowBytes: 4, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                             format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return Double(v[0]) / 255.0
        }
        let mc = g.centroid(g.innerLips)
        let lb = g.bbox(g.outerLips)
        let lip = polygonMask(extent: e, polygons: [g.outerLips], feather: max(0.8, min(lb.width, lb.height) * 0.18))
        let tb = g.bbox(g.innerLips)
        let teeth = polygonMask(extent: e, polygons: [g.innerLips], feather: max(0.8, min(tb.width, tb.height) * 0.25))
        let eb = g.bbox(g.leftEye)
        let eye = polygonMask(extent: e, polygons: [g.leftEye, g.rightEye], feather: max(0.8, min(eb.width, eb.height) * 0.25))
        let ec = g.centroid(g.leftEye)
        check("唇部蒙版够实", value(lip, mc) > 0.7, "嘴心 " + fmt(value(lip, mc), 2))
        check("牙齿蒙版够实", value(teeth, mc) > 0.7, "嘴心 " + fmt(value(teeth, mc), 2))
        check("眼部蒙版够实", value(eye, ec) > 0.7, "左眼心 " + fmt(value(eye, ec), 2))
    }
}

// MARK: - 4. 人像逐项


head("4. 人像功能逐项（落点 + 强度 + 不越界）")
if let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let geos = detectFaceGeos(cg, size: img.extent.size)
    if let g = geos.first {
        let e = img.extent
        let mouth = g.centroid(g.innerLips)
        let eyes = g.centroid(g.leftEye + g.rightEye)
        let eyeBoxL = g.bbox(g.leftEye)
        let nose = g.centroid(g.nose)
        let box = g.box
        print("  人脸框 " + String(Int(box.width)) + "x" + String(Int(box.height)) + " @(" + String(Int(box.minX)) + "," + String(Int(box.minY))
              + ") 眼(" + String(Int(eyes.x)) + "," + String(Int(eyes.y)) + ") 嘴(" + String(Int(mouth.x)) + "," + String(Int(mouth.y))
              + ") 鼻(" + String(Int(nose.x)) + "," + String(Int(nose.y)) + ") 质量 " + fmt(Double(g.quality), 2)
              + " 图 " + String(Int(e.width)) + "x" + String(Int(e.height)))
        func opts(_ setup: (inout PortraitOptions) -> Void) -> PortraitOptions {
            var o = PortraitOptions(); setup(&o); return o
        }
        let W = box.width, Hh = box.height
        let cases: [(String, CGPoint, Double, PortraitOptions, Double)] = [
            ("牙齿美白", mouth, W * 0.2, opts { $0.teeth = 90 }, 0.03),
            ("唇色（妆容）", mouth, W * 0.2, opts { $0.lipColor = 90 }, 0.03),
            ("唇纹修整", mouth, W * 0.2, opts { $0.lipLine = 90 }, 0.02),
            ("眼睛增强", eyes, W * 0.25, opts { $0.eyes = 90 }, 0.02),
            ("祛黑眼圈", CGPoint(x: eyes.x, y: eyeBoxL.minY - Hh * 0.065), W * 0.25, opts { $0.darkCircle = 90 }, 0.02),
            ("祛眼袋", CGPoint(x: eyes.x, y: eyeBoxL.minY - Hh * 0.11), W * 0.3, opts { $0.eyebag = 90 }, 0.02),
            ("祛鼻孔瑕疵", nose, W * 0.2, opts { $0.nostril = 90 }, 0.02),
            ("祛油光（脸部）", CGPoint(x: box.midX, y: box.midY), W * 0.6, opts { $0.shine = 90 }, 0.03),
            ("祛汗孔（脸部）", CGPoint(x: box.midX, y: box.midY), W * 0.6, opts { $0.sweat = 90 }, 0.02),
            ("腮红", CGPoint(x: eyes.x - W * 0.12, y: eyes.y - Hh * 0.30), W * 0.35, opts { $0.blush = 90 }, 0.02),
            ("下颌线增强", CGPoint(x: box.midX, y: box.minY + Hh * 0.18), W * 0.35, opts { $0.jawLine = 90 }, 0.02),
            ("祛双下巴", CGPoint(x: box.midX, y: box.minY - Hh * 0.15), W * 0.35, opts { $0.doubleChin = 90 }, 0.02),
            ("面部重塑·大眼", eyes, W * 0.3, opts { $0.eyeBig = 80 }, 0.02),
            ("面部重塑·瘦脸", CGPoint(x: box.midX, y: box.minY + Hh * 0.42), W * 0.4, opts { $0.faceSlim = 80 }, 0.02),
            ("面部祛瑕疵", CGPoint(x: box.midX, y: box.midY), W * 0.6, opts { $0.faceBlemish = 80 }, 0.02),
            ("祛斑祛痘", CGPoint(x: box.midX, y: box.midY), W * 0.6, opts { $0.spotBlemish = 80 }, 0.02),
            ("祛痣", CGPoint(x: box.midX, y: box.midY), W * 0.6, opts { $0.mole = 80 }, 0.02)
        ]
        for (name, target, radius, o, peak) in cases {
            verifyPortrait(name, src: img, target: target, radius: radius, faceBox: box,
                           apply: { applyPortrait($0, o) }, minPeak: peak)
        }
    }
}

// MARK: - 5. 笔刷落点


head("5. 笔刷落点（合成图：灰底 + 已知位置的黑块）")
do {
    let W = 400, H = 400
    let dot = CGRect(x: 90, y: 110, width: 40, height: 40)
    let base = CIImage(color: CIColor(red: 0.6, green: 0.6, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    let img = CIImage(color: .black).cropped(to: dot).composited(over: base)
    let p = CGPoint(x: dot.midX, y: dot.midY)
    for (name, out) in [("污点修复", healSpots(img, points: [p], radius: 30)),
                        ("修补", patch(img, points: [p], radius: 30))] {
        let m = diffMap(img, out)
        let c = m.centroid
        let dTarget = hypot(Double(c.x - p.x), Double(c.y - p.y))
        let mirror = CGPoint(x: p.x, y: CGFloat(H) - p.y)
        check(name + "落点 = 笔刷点", dTarget < hypot(Double(c.x - mirror.x), Double(c.y - mirror.y)) && dTarget < 12,
              "笔刷点(" + String(Int(p.x)) + "," + String(Int(p.y)) + ") 变化质心(" + String(Int(c.x)) + "," + String(Int(c.y)) + ") 距 " + fmt(dTarget, 1) + " px")
    }
}

// MARK: - 6. 手部 / 宠物


head("6. 手部 / 宠物美化（区域外不许动）")
if let img = loadFixture(handImg, maxDim: 1000), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let hands = detectHandInfos(cg, extent: img.extent)
    if hands.isEmpty {
        check("手部美化", false, "该素材没检出人手")
    } else {
        var hb = CGRect.null
        for h in hands { hb = hb.union(h.rect) }
        let m = diffMap(img, smoothHands(img, strength: 80))
        let inside = m.avg(in: hb)
        let outside = (m.sumTotal - m.sum(in: hb)) / max(1, Double(m.w * m.h) - hb.width * hb.height)
        check("手部美化", hb.contains(m.centroid) && m.maxValue > 0.02 && inside > outside * 3,
              "手部框 " + String(Int(hb.width)) + "x" + String(Int(hb.height)) + "｜质心(" + String(Int(m.centroid.x)) + "," + String(Int(m.centroid.y))
              + ") 框内 " + String(hb.contains(m.centroid)) + "｜峰值 " + fmt(m.maxValue, 4)
              + "｜框内密度 " + fmt(inside, 6) + " vs 框外 " + fmt(outside, 6) + "（" + fmt(inside / max(outside, 1e-9), 1) + " 倍）")
    }
}
if let img = loadFixture(animalImg, maxDim: 1000), let cg = sharedCtx.createCGImage(img, from: img.extent) {
    let animals = detectAnimalInfos(cg, extent: img.extent)
    if animals.isEmpty {
        check("宠物美化", false, "该素材没检出动物")
    } else {
        var ab = CGRect.null
        for a in animals { ab = ab.union(a.rect) }
        let m = diffMap(img, smoothAnimals(img, strength: 80))
        let inside = m.avg(in: ab)
        let outside = (m.sumTotal - m.sum(in: ab)) / max(1, Double(m.w * m.h) - ab.width * ab.height)
        check("宠物美化", ab.contains(m.centroid) && m.maxValue > 0.02 && inside > outside * 3,
              "动物框 " + String(Int(ab.width)) + "x" + String(Int(ab.height)) + "｜质心(" + String(Int(m.centroid.x)) + "," + String(Int(m.centroid.y))
              + ")｜峰值 " + fmt(m.maxValue, 4) + "｜框内密度 " + fmt(inside, 6) + " vs 框外 " + fmt(outside, 6))
    }
}

// MARK: - 6a2. 皮肤掩膜（肤色检测 vs 脸框椭圆）


head("6a2. 皮肤掩膜：肤色检测比脸框椭圆准在哪")
do {
    guard let img = loadFixture(bigFace, maxDim: 900), let cg = sharedCtx.createCGImage(img, from: img.extent) else { exit(1) }
    let e = img.extent
    let geos = detectFaceGeos(cg, size: e.size)
    if let g = geos.max(by: { $0.box.width < $1.box.width }) {
        let box = g.box
        let eyeL = g.centroid(g.leftEye), eyeR = g.centroid(g.rightEye)
        let cheek = CGPoint(x: box.midX, y: box.minY + box.height * 0.30)
        let skin = skinMaskForFace(img, face: g)
        let eyeV = (maskValue(skin, at: eyeL) + maskValue(skin, at: eyeR)) / 2
        let cheekV = maskValue(skin, at: cheek)
        check("皮肤掩膜：眼睛不算皮肤、脸颊算", eyeV < 0.35 && cheekV > 0.6,
              String(format: "眼睛处 %.2f、脸颊处 %.2f（脸框 %dpx）", eyeV, cheekV, Int(box.width)))

        // 落点质量：磨皮后「眼睛区变化 / 脸颊区变化」（椭圆掩膜≈1.3，肤色掩膜应显著更低）
        let ellipse = rectMask(extent: e, rect: box.insetBy(dx: -box.width * 0.10, dy: -box.height * 0.10),
                               feather: max(3, min(box.width, box.height) * 0.16), ellipse: true)
        func ratio(_ mask: CIImage) -> Double {
            let out = smoothSkin(img, mask: mask, radius: max(2.0, box.width * 0.04), strength: 80)
            let m = diffMap(img, out)
            let eye = (m.avg(in: CGRect(x: eyeL.x - 8, y: eyeL.y - 8, width: 16, height: 16))
                       + m.avg(in: CGRect(x: eyeR.x - 8, y: eyeR.y - 8, width: 16, height: 16))) / 2
            let ch = m.avg(in: CGRect(x: cheek.x - 12, y: cheek.y - 12, width: 24, height: 24))
            return eye / max(ch, 1e-9)
        }
        let rEllipse = ratio(ellipse), rSkin = ratio(skin)
        check("皮肤掩膜：磨皮不磨眼睛", rSkin < rEllipse * 0.6 && rSkin < 0.5,
              String(format: "眼睛区/脸颊区 变化比：椭圆 %.2f → 肤色 %.2f（越低越好）", rEllipse, rSkin))

        // 小脸（80px）必须自动退回椭圆：肤色判定在那个尺度不可靠
        var sg = FaceGeo()
        sg.box = CGRect(x: 100, y: 100, width: 80, height: 80)
        sg.leftEye = [CGPoint(x: 120, y: 150), CGPoint(x: 130, y: 155), CGPoint(x: 140, y: 150)]
        sg.rightEye = [CGPoint(x: 160, y: 150), CGPoint(x: 170, y: 155), CGPoint(x: 180, y: 150)]
        let smallMask = skinMaskForFace(img, face: sg)
        check("小脸自动退回脸框椭圆", maskValue(smallMask, at: CGPoint(x: sg.box.midX, y: sg.box.midY)) > 0.6,
              String(format: "80px 的脸：掩膜中心值 %.2f（回退椭圆时应接近 1）", maskValue(smallMask, at: CGPoint(x: sg.box.midX, y: sg.box.midY))))
    }
}

// MARK: - 6b. 皮肤：保毛孔磨皮（频域分离）与肤色统一


head("6b. 皮肤处理：保毛孔磨皮 vs 线性柔化（同一张脸、同一强度）")
/// 高频细节量（p95）。量的是**内缩 6 px 之后**的区域：
/// 直接量小矩形会被「裁剪边界 + 高斯模糊的边界效应」占满高位分位，
/// 于是不管怎么磨，p95 都停在 30 左右（这个坑让 6b 一度给出「线性柔化保留了 100% 细节」）。
}
