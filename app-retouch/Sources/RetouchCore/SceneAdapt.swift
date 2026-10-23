// SceneAdapt：把「场景识别」和「对这张图的测量」接起来，给出自动参数建议
//
// 早先的核心是 suggestParams(for: SceneInfo)：按场景类别给一套参数（婚礼/人像/宠物/风光…）。
// 但同一类场景里，逆光和顺光该给的补光量差很远；高噪片和干净片该给的降噪量也差很远。
// 这里补上「对这张图本身的测量」，再和场景类别合起来出建议。
import Foundation
import CoreImage

public struct SceneAdaptivePlan {
    public var category = ""
    // 测量值
    public var backlight = 1.0        // 背景亮度 / 主体亮度（>1 = 背景更亮 = 逆光）
    public var subjectLuma = 0.0
    public var backgroundLuma = 0.0
    public var noiseSigma = 0.0
    public var skinShare = 0.0        // 肤色占比（解析优先，拿不到就用肤色阈值）
    public var faceCount = 0
    // 建议值（0~100，0 表示不启用）
    public var denoise = 0.0
    public var fillLight = 0.0
    public var exposure = 0.0
    public var wb = 0.0
    public var skinGrade = "medium"
    public var reasons: [String] = []
}

/// 逆光比：主体（人脸/显著性主体）亮度 vs 画面四周（背景）亮度。
/// 用中心/边缘的对比而不是直方图，是因为逆光的定义就是「主体比背景暗」。
public func measureBacklight(_ src: CIImage, subject: CGRect? = nil) -> (ratio: Double, subject: Double, bg: Double) {
    let e = src.extent
    let w = 96
    let h = max(8, Int(round(Double(w) * Double(e.height) / max(1, Double(e.width)))))
    let small = src.transformed(by: CGAffineTransform(scaleX: CGFloat(w) / e.width, y: CGFloat(w) / e.width))
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = (y * w + x) * 4
        return 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
    }
    // 主体区（给的是原图坐标，换算到小图）
    let sx = Int((subject?.midX ?? e.midX) / e.width * Double(w))
    let sy = Int((subject?.midY ?? e.midY) / e.height * Double(h))
    let rw = max(2, Int((subject?.width ?? e.width * 0.35) / e.width * Double(w)) / 2)
    let rh = max(2, Int((subject?.height ?? e.height * 0.35) / e.height * Double(h)) / 2)
    var subj = 0.0, subjN = 0.0, bg = 0.0, bgN = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let inSubject = abs(x - sx) <= rw && abs(y - sy) <= rh
            if inSubject { subj += lum(x, y); subjN += 1 } else { bg += lum(x, y); bgN += 1 }
        }
    }
    let s = subjN > 0 ? subj / subjN : 0
    let b = bgN > 0 ? bg / bgN : 0
    return (s > 1 ? b / s : 1, s, b)
}

/// 场景 + 本图测量 → 一套自动参数建议
public func planSceneAdaptive(_ src: CIImage, scene: SceneInfo?, faceBox: CGRect? = nil,
                              skinMask: CIImage? = nil) -> SceneAdaptivePlan {
    var plan = SceneAdaptivePlan()
    plan.category = scene?.category ?? "未知"

    // 1) 逆光
    let bl = measureBacklight(src, subject: faceBox)
    plan.backlight = bl.ratio
    plan.subjectLuma = bl.subject
    plan.backgroundLuma = bl.bg
    if bl.ratio > 1.35 && bl.subject < 150 {
        // 逆光：补光 + 抬曝光（强度随逆光比增加，上限 70）
        plan.fillLight = min(70, 25 + (bl.ratio - 1.35) * 60)
        plan.exposure = min(60, 20 + (bl.ratio - 1.35) * 45)
        plan.reasons.append(String(format: "逆光（背景/主体 = %.2f）→ 补光 %.0f、自动曝光 %.0f", bl.ratio, plan.fillLight, plan.exposure))
    } else if bl.subject < 90 {
        plan.exposure = min(50, (95 - bl.subject) * 0.9)
        plan.reasons.append(String(format: "主体偏暗（%.0f）→ 自动曝光 %.0f", bl.subject, plan.exposure))
    }

    // 2) 噪声 → 降噪
    let dn = planAutoDenoise(src)
    plan.noiseSigma = dn.noiseSigma
    if dn.needed {
        plan.denoise = dn.amount
        plan.reasons.append(String(format: "噪声 σ ≈ %.2f → 降噪 %.0f", dn.noiseSigma, dn.amount))
    }

    // 3) 肤色占比 → 磨皮档（人像/合影才动）
    if let m = skinMask ?? parsedMaskFromImage(src, classes: FaceClass.skinClasses, feather: 6) {
        plan.skinShare = maskCoverage(m, in: src.extent, threshold: 128)
    }
    let isPortrait = (scene?.category.contains("人像") ?? false) || (scene?.category.contains("婚礼") ?? false)
        || (scene?.category.contains("合影") ?? false) || (scene?.category.contains("儿童") ?? false)
    if isPortrait {
        if plan.skinShare > 0.25 { plan.skinGrade = "strong" } else if plan.skinShare > 0.08 { plan.skinGrade = "medium" } else { plan.skinGrade = "light" }
        plan.reasons.append(String(format: "肤色占比 %.1f%% → 磨皮档 %@", plan.skinShare * 100, plan.skinGrade))
    }

    // 4) 色偏 → 自动白平衡（逆光/室内常见）
    let wbp = estimateWhiteBalance(src)
    let cast = abs(wbp.castR)
    if cast > 12 {
        plan.wb = min(80, cast * 3)
        plan.reasons.append(String(format: "色偏 R-B %.1f → 自动白平衡 %.0f", wbp.castR, plan.wb))
    }
    return plan
}


/// 整组（同一场拍摄）的**统一**方案：每张分别测量，逐项取中位数。
///
/// 为什么要统一：单张自适应会让同场片子参数各不相同 —— 实测 wedding_01 的补光是 0、
/// wedding_02 是 51，一交付就看出「这一张亮了那一张没亮」。整组取中位数 = 观感一致，
/// 同时仍然尊重「这场光比大」这个整体事实。
public func planGroupAdaptive(_ srcs: [CIImage], scene: SceneInfo?) -> SceneAdaptivePlan {
    guard !srcs.isEmpty else { return SceneAdaptivePlan() }
    let plans = srcs.map { planSceneAdaptive($0, scene: scene) }
    func median(_ vals: [Double]) -> Double {
        guard !vals.isEmpty else { return 0 }
        let s = vals.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    var out = SceneAdaptivePlan()
    out.category = scene?.category ?? plans[0].category
    out.backlight = median(plans.map { $0.backlight })
    out.noiseSigma = median(plans.map { $0.noiseSigma })
    out.skinShare = median(plans.map { $0.skinShare })
    out.faceCount = plans.map { $0.faceCount }.max() ?? 0
    out.fillLight = median(plans.map { $0.fillLight })
    out.exposure = median(plans.map { $0.exposure })
    out.denoise = median(plans.map { $0.denoise })
    out.wb = median(plans.map { $0.wb })
    // 档位取「出现次数最多」的
    var counts: [String: Int] = [:]
    for p in plans { counts[p.skinGrade, default: 0] += 1 }
    out.skinGrade = counts.max(by: { $0.value < $1.value })?.key ?? "medium"
    out.reasons = ["整组 " + String(srcs.count) + " 张取中位数 → 补光 " + String(format: "%.0f", out.fillLight)
                   + "、曝光 " + String(format: "%.0f", out.exposure)
                   + "、降噪 " + String(format: "%.0f", out.denoise)
                   + "、白平衡 " + String(format: "%.0f", out.wb)
                   + "、磨皮 " + out.skinGrade]
    return out
}
