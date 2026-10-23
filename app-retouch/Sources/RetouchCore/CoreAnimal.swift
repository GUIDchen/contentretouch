// CoreAnimal.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

// MARK: - 宠物美化（近似：动物姿态关键点 → 区域蒙版 → 柔化）
//
// VNDetectAnimalBodyPoseRequest（macOS 14+）给出动物各部位关键点；取所有点求包围框，
// 用**已验证过的蒙版写法**（白块 composited(over:) 黑底）生成羽化蒙版，区域内柔化 + 轻微提亮。
// ⚠️ 边界：这是「宠物区域柔化」，不做毛发重绘/去杂毛（那需要模型）。
public struct AnimalInfo {
    public var rect: CGRect
    public var points: Int
    public var maxConfidence: Float
}

public func detectAnimalInfos(_ cg: CGImage, extent: CGRect) -> [AnimalInfo] {
    guard #available(macOS 14.0, *) else { return [] }
    let req = VNDetectAnimalBodyPoseRequest()
    guard (try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])) != nil else { return [] }
    var out: [AnimalInfo] = []
    for a in (req.results ?? []) {
        guard let pts = try? a.recognizedPoints(.all) else { continue }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var n = 0; var maxC: Float = 0
        for (_, p) in pts where p.confidence > 0.2 {
            let x = p.location.x * extent.width, y = p.location.y * extent.height
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            n += 1; maxC = max(maxC, p.confidence)
        }
        guard n >= 4, maxX > minX else { continue }
        let pad = max(maxX - minX, maxY - minY) * 0.2
        out.append(AnimalInfo(rect: CGRect(x: minX - pad, y: minY - pad,
                                           width: (maxX - minX) + pad * 2,
                                           height: (maxY - minY) + pad * 2),
                              points: n, maxConfidence: maxC))
    }
    return out
}

public func smoothAnimals(_ src: CIImage, strength: Double = 60) -> CIImage {
    guard strength > 0.01, let cg = sharedCtx.createCGImage(src, from: src.extent) else { return src }
    let animals = detectAnimalInfos(cg, extent: src.extent)
    guard !animals.isEmpty else { return src }
    return softenRects(src, rects: animals.map { $0.rect }, strength: strength,
                       blurRadius: 6, brighten: 0.03)
}

// MARK: - 宠物美化（细化参数）
//
// 原来只有一个「强度」（高频压制 + 一点点提亮）。宠物照真正要调的是几件不同的事：
//   毛发柔顺 / 毛发光泽 / 白毛去黄 / 眼睛提亮 / 去泪痕 / 毛色统一。
// 这里把它们分开，各自的**作用位置**也不同（去泪痕只在眼周、白毛去黄只在浅色毛发上）。
//
// ⚠️ 边界（如实标注）：没有宠物专项分割模型，区域来自 Vision 的动物识别框 + 羽化，
// 所以"眼周"是按动物框的**上半部中央**估的，不是真正的眼睛关键点；
// 毛色统一是低频化（降局部色差），不是重绘毛色。
public struct PetOptions {
    public var soften = 0.0        // 毛发柔顺（原来的「强度」）
    public var gloss = 0.0         // 毛发光泽/提亮
    public var whiten = 0.0        // 白毛去黄
    public var eyeBright = 0.0     // 眼睛提亮
    public var tearStain = 0.0     // 去泪痕（眼周暗黄）
    public var unifyTone = 0.0     // 毛色统一
    public init() {}
    public var anyEnabled: Bool {
        soften > 0.5 || gloss > 0.5 || whiten > 0.5 || eyeBright > 0.5 || tearStain > 0.5 || unifyTone > 0.5
    }
}

public func applyPetDetailed(_ src: CIImage, _ o: PetOptions) -> CIImage {
    guard o.anyEnabled, let cg = sharedCtx.createCGImage(src, from: src.extent) else { return src }
    let animals = detectAnimalInfos(cg, extent: src.extent)
    guard !animals.isEmpty else { return src }
    let e = src.extent
    var out = src

    // 1) 毛发柔顺：沿用原来的 softenRects（它已经做过"只在动物框内压高频、顺带提一点亮"）
    if o.soften > 0.5 {
        out = softenRects(out, rects: animals.map { $0.rect }, strength: o.soften, blurRadius: 6, brighten: 0.03)
    }

    // 动物区域蒙版（羽化）
    var region = blackMask(e)
    for a in animals {
        let r = a.rect
        region = maskUnion(region, rectMask(extent: e, rect: r,
                                            feather: max(3, min(r.width, r.height) * 0.08), ellipse: true))
    }

    // 2) 毛发光泽：区域内提亮 + 轻微抬中间调
    if o.gloss > 0.5 {
        let k = o.gloss / 100
        var p = Params()
        p.brightness = 14 * k
        p.gamma = 1 - 0.18 * k
        let lit = render(out, p)
        out = lit.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(region, k)])
    }

    // 3) 白毛去黄：只在**浅色**毛发上（亮度 > 150）把黄压掉（R−B 差往零拉）
    if o.whiten > 0.5 {
        let k = o.whiten / 100
        let luma = out.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        // 浅色掩膜：把亮度减去 0.59 再放大，>0 的部分就是"偏亮"的毛发
        let bright = luma.applyingFilter("CIColorMatrix", parameters: [
            // 阈值原来取 luma > 0.60：实测在真实宠物照上这块掩膜几乎全空，去黄完全没效果。
            // 放宽到约 0.46（×2.4 − 1.1）
            "inputRVector": CIVector(x: 2.4, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2.4, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2.4, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -1.1, y: -1.1, z: -1.1, w: 0)])
        let m = region.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: bright])
        let neutral = out.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -0.10 * k, y: 0, z: 0.10 * k, w: 0)])
        out = neutral.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
    }

    // 4) 毛色统一：区域内把"低频道"拉回来一点（压局部色差，不是重绘）
    if o.unifyTone > 0.5 {
        let k = o.unifyTone / 100
        let low = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 14]).cropped(to: e)
        let mixed = low.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        out = mixed.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(region, k * 0.65)])
    }

    // 5) 眼睛提亮 / 6) 去泪痕：都在**动物框上半部中央**（眼周）的小区域里做
    if o.eyeBright > 0.5 || o.tearStain > 0.5 {
        var eyeArea = blackMask(e)
        for a in animals {
            let r = a.rect
            let eyeRect = CGRect(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.52,
                                 width: r.width * 0.56, height: r.height * 0.26)
            eyeArea = maskUnion(eyeArea, rectMask(extent: e, rect: eyeRect,
                                                  feather: max(2, r.width * 0.06), ellipse: true))
        }
        if o.eyeBright > 0.5 {
            let k = o.eyeBright / 100
            // 眼睛是**暗而高对比**的地方：先取暗部掩膜，再提亮
            let luma = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let dark = luma.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: -2, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -2, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1.1, y: 1.1, z: 1.1, w: 0)])
            let m = eyeArea.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: dark])
            var p = Params(); p.brightness = 26 * k; p.gamma = 1 - 0.22 * k
            out = render(out, p).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(m, 0.9)])
        }
        if o.tearStain > 0.5 {
            let k = o.tearStain / 100
            // 泪痕 = 眼周的**暗且偏黄**：把暗部（含偏黄）往中性拉，并提一点亮
            let luma = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            let shadow = luma.applyingFilter("CIColorMatrix", parameters: [
                // 暗部阈值从 luma < 0.48 放宽到 < 0.64（×−2.2 + 1.4）：泪痕不是纯黑，是灰黄的一小块
                "inputRVector": CIVector(x: -2.2, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: -2.2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: -2.2, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 1.4, y: 1.4, z: 1.4, w: 0)])
            let m = eyeArea.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: shadow])
            let fixed = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.08 * k, y: 0, z: 0.11 * k, w: 0)])
            out = fixed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: maskScaled(m, 0.85)])
        }
    }
    return out
}
