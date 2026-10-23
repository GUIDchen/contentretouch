// §317：AI 点修的小工具 —— 返回该点在人脸解析标签图里的类别（0~18），取不到返回 -1。
// 为什么放核心层：coretest（独立目标）以后要用它量命中率（§316.4 第 1 条），App 目标里看不到 ✗。
import Foundation
import CoreImage

public func parsedClassAt(point p: CGPoint, image: CIImage) -> Int {
    guard let cg = sharedCtx.createCGImage(image, from: image.extent),
          let r = FaceParser.shared.parse(cg) else { return -1 }
    let side = max(1, Int(Double(r.labels.count).squareRoot().rounded()))
    let w = max(1, image.extent.width), h = max(1, image.extent.height)
    let x = Int(min(Double(side - 1), max(0, Double(p.x) / Double(w) * Double(side))))
    // ⚠️ 解析图的行序是自上而下，而图像坐标是自下而上 —— 必须翻 y（§189 的老坑）。
    let yTop = Int(min(Double(side - 1), max(0, (1.0 - Double(p.y) / Double(h)) * Double(side))))
    return Int(r.labels[yTop * side + x])
}
