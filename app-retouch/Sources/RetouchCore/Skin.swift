// Skin：真正的皮肤掩膜（经典 CV 肤色检测，不用模型）
//
// 现在磨皮/祛瑕疵用的是「脸框椭圆」——那会把眼睛、眉毛、头发、耳环一起磨了。
// 这里用 RGB 肤色规则（Kovac 那套工程常用判据）做像素级皮肤判定，再与「人脸区域」相乘
// 把误判挡在脸外（肤色相近的木家具、墙面）。
//
// 掩膜值：皮肤≈1，非皮肤≈0，边缘羽化。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins


/// 掩膜并集（逐像素取大）。
///
/// ⚠️ 必须用这个，不能用 composited(over:)：掩膜的 alpha 通常都是 1，
/// 在同一个 extent 上做 SourceOver 是**替换**而不是并集 —— 实测多人时只剩最后一个人的掩膜
///（SAM 多提示点那次的「新娘在、新郎没了」就是这个原因；同一处写法在代码里还有 4 个）。
public func maskUnion(_ a: CIImage, _ b: CIImage) -> CIImage {
    a.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: b])
        .cropped(to: a.extent.union(b.extent))
}


private let skinKernelSource = """
kernel vec4 skinDetect(__sample s) {
    float r = s.r, g = s.g, b = s.b;
    float mx = max(r, max(g, b));
    float mn = min(r, min(g, b));
    float sum = max(0.001, r + g + b);
    float rg = r / sum;
    // 1) 亮度下限（太暗的像素不可靠）
    float m1 = step(0.33, r) * step(0.13, g) * step(0.06, b);
    // 2) 不能是灰的（皮肤有饱和度）
    float m2 = step(0.055, mx - mn);
    // 3) R 明显大于 G（皮肤的第一特征）
    float m3 = step(0.045, r - g);
    // 4) R 是三通道最大的
    float m4 = step(g, r) * step(b, r);
    // 5) 归一化红比例落在皮肤带里
    float m5 = step(0.335, rg) * step(rg, 0.56);
    // 6) G/B 不能倒挂太厉害（排除纯红/纯橙的衣物与道具）
    float m6 = step(0.02, g - b * 0.55);
    float m = m1 * m2 * m3 * m4 * m5 * m6;
    // 边缘软化：给一点过渡，避免硬边界
    return vec4(m, m, m, 1.0);
}
"""

let skinKernel: CIColorKernel? = CIColorKernel(source: skinKernelSource)

/// 整幅图上的肤色概率图（0/1，硬判）
public func skinColorMask(_ src: CIImage) -> CIImage {
    let e = src.extent
    guard let k = skinKernel, let out = k.apply(extent: e, arguments: [src]) else {
        return CIImage(color: .black).cropped(to: e)
    }
    return out.cropped(to: e)
}

/// 人脸区域内的皮肤掩膜：肤色图 × 人脸区域（外扩版）。
/// 返回 (掩膜, 皮肤占比)。占比太低（<8%，比如重妆/低光）时调用方应回退到脸框椭圆。
public func skinMask(_ src: CIImage, faceRegions: [CIImage], feather: Double = 3) -> (mask: CIImage, coverage: Double) {
    let e = src.extent
    guard !faceRegions.isEmpty else { return (blackMask(e), 0) }
    var region = blackMask(e)
    for r in faceRegions { region = maskUnion(r, region) }
    let color = skinColorMask(src)
    let combined = color.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: region])
        .cropped(to: e)
    // 统计：脸区里有多少像素被判为皮肤（以脸区蒙版的覆盖面积为分母）
    let faceArea = maskCoverage(region, in: e, threshold: 128)
    let skinArea = maskCoverage(combined, in: e, threshold: 128)
    let cov = faceArea > 0.0001 ? min(1.0, skinArea / faceArea) : 0
    // 只保留主要连通区域：把碎点用一次小半径中值/模糊去掉再取阈值
    var m = combined.applyingFilter("CIMedianFilter").cropped(to: e)
    if feather > 0.5 {
        m = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: e)
    }
    // 羽化会把蒙版往外扩一点，再乘回脸区把它夹住（老规矩：羽化后要夹回）
    m = m.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: region]).cropped(to: e)
    return (m, cov)
}

/// 单张脸的皮肤掩膜：能用肤色检测就用，不能用就退回脸框椭圆。
///
/// 为什么要按脸判断大小：实测同一套规则下，
///   490px 的大脸 → 眼睛处 0.00、脸颊 0.99（眼睛/头发被正确排除）
///    88px 的小脸 → 眼睛处 0.65、脸颊 0.28（判定不可靠）
/// 所以只有脸够大（默认 ≥150px）才用肤色检测，小脸老实退回椭圆 —— 宁粗勿错。
/// 掩膜"最多在多大分辨率上算"。超过就先降采样、算完再放大回去（见 skinMaskForFace 的说明）。
/// 环境变量可覆盖，方便 A/B 与体检（CR_SKINMASK_MAX=0 表示不降采样，即老行为）。
public var skinMaskWorkMax: Double = {
    if let s = ProcessInfo.processInfo.environment["CR_SKINMASK_MAX"], let v = Double(s) { return v }
    return 1600
}()

/// 掩膜在低分辨率上算的**公共入口**：低于阈值就直接原样算，高于阈值就缩放 → 递归 → 放回。
/// 为什么要这样：掩膜是**低频**的（一大片脸 + 几个像素宽的羽化边），可它的构造里有 4~5 次
/// "按 128px / 1px 采样"的渲染 —— 每次采样都得把整张掩膜按**全分辨率**求值。
/// 20.9MP（24MP 源片放大到 400%）上实测"自动肤色"这条路要 94 ms，降采样后同样的采样只要 1/k² 的时间（§169）。
func atMaskWorkScale(_ src: CIImage, _ build: (CIImage, CGFloat) -> CIImage) -> CIImage {
    let e = src.extent
    let longEdge = Double(max(e.width, e.height))
    guard skinMaskWorkMax > 1, longEdge > skinMaskWorkMax else { return build(src, 1) }
    let k = CGFloat(skinMaskWorkMax / longEdge)
    let small = src.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .transformed(by: CGAffineTransform(scaleX: k, y: k))
    let m = build(small, k)
    return m.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
        .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        .cropped(to: e)
}

public func skinMaskForFace(_ src: CIImage, face: FaceGeo, feather: Double = 3,
                            minFaceWidth: Double = 150) -> CIImage {
    let e = src.extent
    return atMaskWorkScale(src) { small, k in
        skinMaskForFaceSmall(small, face: face.transformed(scale: k, offsetX: e.minX, offsetY: e.minY),
                             feather: k < 1 ? max(0.5, feather * k) : feather,
                             minFaceWidth: k < 1 ? minFaceWidth * k : minFaceWidth)
    }
}

private func skinMaskForFaceSmall(_ src: CIImage, face: FaceGeo, feather: Double = 3,
                                  minFaceWidth: Double = 150) -> CIImage {
    let e = src.extent
    let box = face.box
    let ellipse = rectMask(extent: e,
                           rect: box.insetBy(dx: -box.width * 0.10, dy: -box.height * 0.10),
                           feather: max(3, min(box.width, box.height) * 0.16), ellipse: true)
    // 兜底掩膜：**优先用脸轮廓多边形**，没有轮廓点才退椭圆。
    // 依据是 coretest 第 24 段的实测：椭圆有 **34% 的面积落在真正的皮肤之外**（头发/背景被误磨），
    // 而脸轮廓多边形只有 15%、且一样不漏脸（相对少误磨 70%）。
    // 小脸照片只能走这条兜底，所以这直接是画质差别。
    let region = contourFaceMask(extent: e, face: face) ?? ellipse
    // ⚠️ 兜底路径（小脸走轮廓/椭圆）**同样要扣掉眼睛**：椭圆/轮廓都把眼睛包在里面，
    // 而这是"脸不够大"时唯一走的路——不扣的话小脸照片的眼睛照样被磨糊。
    guard box.width >= minFaceWidth else { return excludingEyes(region, face: face, extent: e) }
    let (m, cov) = skinMask(src, faceRegions: [region], feather: feather)
    // 覆盖率异常（太稀 / 几乎全中）说明判定失效
    guard cov > 0.15, cov < 0.85 else { return region }    // 判定失效 → 退回轮廓/椭圆兜底
    // ⚠️ 这里原来有两行 `_ = (maskValue(m, at: eyeL), ...)`：算完就丢，什么也不判。
    // 而每次 maskValue 都是**一次渲染**（要把整张掩膜按全分辨率求值），20.9MP 上两次就是几十毫秒 ——
    // 2026-09-26 删掉（§169）。眼睛靠下面 excludingEyes 硬扣，与"眼周肤色判得准不准"无关。
    // 原来这里是 guard eyeAvg < 0.35 else { return region } —— 也就是"眼周判不准就整张脸退回椭圆"，
    // 而椭圆同样盖住眼睛，等于没解决。多图体检（coretest 第 38 段）实测：6 张里 5 张的眼睛中心掩膜
    // 仍高达 0.80~0.87，于是"眼睛被磨得比脸颊狠"（比值 1.56~4.73）——用户说的"眼睛被磨糊"就是这个。
    // 现在改成**直接扣掉眼睛**：不管肤色判定准不准，眼睛都不会再被磨。
    return excludingEyes(m, face: face, extent: e)
}

/// 从皮肤掩膜里**硬性扣掉眼睛**（用眼睛关键点多边形 + 羽化）。
///
/// 为什么不靠肤色判定：多图实测肤色掩膜在多数照片上并没有把眼睛排除掉（眼睛中心 0.80~0.87），
/// 而眼睛一旦被磨糊是**不可逆**的。这里用关键点画排除区，与肤色判定是否准确无关。
public func excludingEyes(_ mask: CIImage, face: FaceGeo, extent: CGRect) -> CIImage {
    var polys: [[CGPoint]] = []
    if face.leftEye.count >= 3 { polys.append(face.leftEye) }
    if face.rightEye.count >= 3 { polys.append(face.rightEye) }
    guard !polys.isEmpty else { return mask }
    // ⚠️ **羽化不能大**：眼睛多边形很小（左右眼各几个点、尺寸约 0.2 脸宽），
    // 用 5% 脸宽（≈8px）的羽化时，多边形内部**永远到不了纯白**——
    // 实测眼心处 polygonMask=1.00（单点采样），但同一个多边形经羽化后整体只有 0.12 左右，
    // 取反就是 0.88，乘完眼睛没被扣掉（这正是第 38 段"眼内改动 2~14 级"的原因）。
    // 现在把羽化压到 1.2% 脸宽（≈2px）：够软边，又能保证内部是实心白。
    // 用共享的 featureMask（多边形 ∪ 包围盒椭圆），羽化按眼睛尺寸给（1.2% 脸宽 ≈2px，
    // 保证内部实心；给大了内部就到不了纯白，扣不掉）。
    let eyeEx = featureMask(extent: extent, polygons: polys,
                            feather: max(0.8, face.box.width * 0.012))
    let inv = eyeEx.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: -1, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: -1, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0)])
    return mask.applyingFilter("CIMultiplyBlendMode", parameters: [
        kCIInputBackgroundImageKey: inv])
}

/// 采样某点的蒙版值
public func maskValue(_ mask: CIImage, at p: CGPoint) -> Double {
    var buf = [UInt8](repeating: 0, count: 4)
    sharedCtx.render(mask, toBitmap: &buf, rowBytes: 4,
                     bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1),
                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return Double(buf[0]) / 255.0
}

/// 多张脸：每张脸各自决定用肤色掩膜还是椭圆，再取并集
public func skinMaskForFaces(_ src: CIImage, geos: [FaceGeo], minFaceWidth: Double = 150) -> CIImage {
    let e = src.extent
    guard !geos.isEmpty else { return blackMask(e) }
    var out = blackMask(e)
    for g in geos {
        out = maskUnion(skinMaskForFace(src, face: g, minFaceWidth: minFaceWidth), out)
    }
    return out
}
