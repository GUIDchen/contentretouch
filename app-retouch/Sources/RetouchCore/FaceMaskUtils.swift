// FaceMaskUtils.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

public func blackMask(_ extent: CGRect) -> CIImage { CIImage(color: .black).cropped(to: extent) }

/// 蒙版整体乘系数
public func maskScaled(_ m: CIImage, _ k: Double) -> CIImage {
    guard abs(k - 1) > 0.001 else { return m }
    return m.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
}

/// 多边形 → 羽化蒙版。在小尺寸位图上画完再放大（省内存，边界也更柔）。
/// 注意：**不做 y 翻转**（见文件头实测结论）。
public func polygonMask(extent: CGRect, polygons: [[CGPoint]],
                        feather: Double = 4, maxDim: Double = 1200) -> CIImage {
    let polys = polygons.filter { $0.count >= 3 }
    guard !polys.isEmpty else { return blackMask(extent) }
    let scale = min(1.0, maxDim / max(extent.width, extent.height))
    let w = max(4, Int(extent.width * scale)), h = max(4, Int(extent.height * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return blackMask(extent) }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for poly in polys {
        let pts = poly.map { CGPoint(x: ($0.x - extent.minX) * scale, y: ($0.y - extent.minY) * scale) }
        ctx.beginPath()
        ctx.move(to: pts[0])
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.closePath()
        ctx.fillPath()
    }
    guard let cg = ctx.makeImage() else { return blackMask(extent) }
    var m = CIImage(cgImage: cg)
        .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        .cropped(to: extent)
    if feather > 0.5 {
        m = m.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: extent)
    }
    return m
}

/// 矩形（可圆角化 = 椭圆）→ 羽化蒙版，纯 Core Image 原生写法（规矩 12：只用验证过的写法）
public func rectMask(extent: CGRect, rect: CGRect, feather: Double = 8, ellipse: Bool = false) -> CIImage {
    let r = rect.intersection(extent)
    guard r.width > 2, r.height > 2 else { return blackMask(extent) }
    var white: CIImage
    if ellipse {
        // 径向渐变近似椭圆：中心 1、边缘 0
        let g = CIFilter.radialGradient()
        g.center = CGPoint(x: r.midX, y: r.midY)
        g.radius0 = Float(max(1.0, min(r.width, r.height) / 2 - max(1, feather)))
        g.radius1 = Float(max(2.0, min(r.width, r.height) / 2))
        white = (g.outputImage ?? CIImage(color: .black)).cropped(to: extent)
    } else {
        white = CIImage(color: .white).cropped(to: r)
            .composited(over: blackMask(extent))
    }
    if feather > 0.5 && !ellipse {
        white = white.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: extent)
    }
    return white
}

/// 在蒙版内做颜色调整，蒙版外一个像素都不动
public func adjustInMask(_ src: CIImage, mask: CIImage,
                         brightness: Double = 0, saturation: Double = 0, contrast: Double = 0,
                         warm: Double = 0, blueReduce: Double = 0, strength: Double = 1.0) -> CIImage {
    guard strength > 0.001 else { return src }
    var img = src
    if abs(saturation) > 0.001 || abs(brightness) > 0.001 || abs(contrast) > 0.001 {
        img = img.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness,
            kCIInputSaturationKey: Float(max(0, 1 + saturation)),
            kCIInputContrastKey: Float(max(0.1, 1 + contrast))])
    }
    if abs(warm) > 0.001 || abs(blueReduce) > 0.001 {
        img = img.applyingFilter("CIColorMatrix", parameters: [
            "inputBiasVector": CIVector(x: warm / 255.0, y: 0, z: -warm / 255.0 - blueReduce / 255.0, w: 0)])
    }
    return img.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(mask, strength)])
}

/// 区域内柔化（保住整体色调，只压高频）——手部/宠物/脚部/唇纹共用这一个
public func softenInMask(_ src: CIImage, mask: CIImage, radius: Double, strength: Double,
                         brighten: Double = 0) -> CIImage {
    let k = max(0.0, min(1.0, strength))
    guard k > 0.001, radius > 0.4 else { return src }
    var low = src.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .cropped(to: src.extent)
    if abs(brighten) > 0.001 {
        low = low.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brighten])
    }
    return low.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: src, kCIInputMaskImageKey: maskScaled(mask, k)])
}
