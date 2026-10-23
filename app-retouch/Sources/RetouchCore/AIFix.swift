// §325：AI 点修核心 —— 修掉 §323 量出的口径错误。
// 错误：之前把**整张图**交给解析器，再按整图映射 → 脸内处处解析成背景（命中率 0）✗。
// 正确（与产品口径一致，见 FaceParsing.parsedMaskForFace / §237/§266）：
//   1) 先按脸框取 side = max(w,h) * 1.7 的正方形裁剪；
//   2) 解析这个裁剪图；
//   3) 点 → 裁剪坐标 → 512 网格（y 需翻转，解析图自上而下）。
// 脸框由调用方传入：核心层不强制依赖 Vision 检测（App 与 coretest 都已有 detectFaceGeos ✓）。
import Foundation
import CoreImage

public struct AIFixDecision: Equatable {
    public let item: String
    public let strength: Double
    public let label: String
    public init(item: String, strength: Double, label: String) {
        self.item = item; self.strength = strength; self.label = label
    }
}

/// 点所在的解析类别（0~18）；点不在脸裁剪内或解析失败时返回 -1。
public func parsedClassAt(point p: CGPoint, image: CIImage, faceBox: CGRect) -> Int {
    let side = max(faceBox.width, faceBox.height) * 1.7
    guard side > 8 else { return -1 }
    let crop = CGRect(x: faceBox.midX - side / 2, y: faceBox.midY - side / 2, width: side, height: side)
    guard crop.contains(p) else { return -1 }
    let cropped = image.cropped(to: crop)
    guard let cg = sharedCtx.createCGImage(cropped, from: cropped.extent),
          let r = FaceParser.shared.parse(cg) else { return -1 }
    let n = max(1, Int(Double(r.labels.count).squareRoot().rounded()))
    let u = Double((p.x - crop.minX) / crop.width)          // 0..1 左到右
    let vTop = 1.0 - Double((p.y - crop.minY) / crop.height) // 解析图自上而下 ⇒ 翻 y
    let x = Int(min(Double(n - 1), max(0, u * Double(n))))
    let y = Int(min(Double(n - 1), max(0, vTop * Double(n))))
    return Int(r.labels[y * n + x])
}

/// 返回该点的点修决策；不在可修部位（背景/头发/衣服等）时返回 nil。
public func aiFixDecision(at p: CGPoint, image: CIImage, faceBox: CGRect) -> AIFixDecision? {
    switch parsedClassAt(point: p, image: image, faceBox: faceBox) {
    // §326：按**仓库自己的标签表**映射（背景0 皮肤1 眉2/3 眼4/5 鼻10 嘴11 上唇12 下唇13 颈14 衣16 发17）——
    // 上一轮我把 10/11 当成牙齿 ✗，而**仓库里没有牙齿类** ✗（牙齿在嘴内，属解析盲区）。
    case 4, 5:       return AIFixDecision(item: "eyes", strength: 40, label: "眼睛（大眼 40）")
    case 11, 12, 13: return AIFixDecision(item: "lipColor", strength: 30, label: "唇色（30）")
    case 10:         return AIFixDecision(item: "spotBlemish", strength: 35, label: "鼻部（祛瑕 35）")
    case 1:          return AIFixDecision(item: "spotBlemish", strength: 45, label: "皮肤（祛瑕 45）")
    default:     return nil
    }
}

/// §327：便捷重载 —— 自己检测第一张脸的脸框（UI 接线因此只需传点与图 ✓）。
public func aiFixDecision(at p: CGPoint, image: CIImage) -> AIFixDecision? {
    guard let cg = sharedCtx.createCGImage(image, from: image.extent),
          let f = detectFaceGeos(cg, size: image.extent.size).first else { return nil }
    return aiFixDecision(at: p, image: image, faceBox: f.box)
}
