// 直方图 + EXIF：修图时最常看的两个「信息」面板
//
// 直方图为什么放在核心里：measure() 已经为了算分位点建过一次直方图，但只用了亮度那一份、
// 也没往外暴露。这里独立做一份**四通道**（R/G/B/亮度）的，供界面画曲线；
// 采样口径与 measure 完全一致（256px、sRGB），否则「直方图看着正常但分位点对不上」又要查半天。
import Foundation
import CoreImage
import ImageIO

public struct Histogram {
    public var r = [Int](repeating: 0, count: 256)
    public var g = [Int](repeating: 0, count: 256)
    public var b = [Int](repeating: 0, count: 256)
    public var lum = [Int](repeating: 0, count: 256)
    public var clippedLow = 0.0    // 死黑像素占比 0~1
    public var clippedHigh = 0.0   // 死白像素占比 0~1
    public var samples = 0
}

/// 数格子：两种取数路径（CI 图 / 已有位图）共用的同一份统计，口径不会跑偏
func histogramTally(_ buf: [UInt8], w: Int, hgt: Int) -> Histogram {
    var h = Histogram()
    let n = w * hgt
    var low = 0, high = 0
    for i in 0..<n {
        let r = Int(buf[i * 4]), g = Int(buf[i * 4 + 1]), b = Int(buf[i * 4 + 2])
        h.r[r] += 1; h.g[g] += 1; h.b[b] += 1
        // 用**四舍五入**而不是截断：0.2126+0.7152+0.0722 在浮点里是 0.99999…，
        // 纯白的亮度会算成 254.9999 → 截断成 254，于是「纯白图的亮度直方图 255 号格是空的」
        //（这个坑是 coretest 用合成图抓出来的）。四舍五入既修了这个边界，也顺手消掉了整体偏低一级的偏差。
        let l = Int(max(0, min(255, (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)).rounded())))
        h.lum[l] += 1
        if r < 3 && g < 3 && b < 3 { low += 1 }
        if r > 252 && g > 252 && b > 252 { high += 1 }
    }
    h.samples = n
    h.clippedLow = Double(low) / Double(max(1, n))
    h.clippedHigh = Double(high) / Double(max(1, n))
    return h
}

/// 直方图（采样 256px，与 measure 同一口径）
public func histogram(_ img: CIImage, work: Int = 256) -> Histogram {
    let normalized = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    let scale = Double(work) / max(1, max(normalized.extent.width, normalized.extent.height))
    let small = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let w = max(1, Int(small.extent.width)), hgt = max(1, Int(small.extent.height))
    var buf = [UInt8](repeating: 0, count: w * hgt * 4)
    sharedCtx.render(small, toBitmap: &buf, rowBytes: w * 4,
                     bounds: CGRect(x: 0, y: 0, width: w, height: hgt), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return histogramTally(buf, w: w, hgt: hgt)
}

// ⚠️ 这里曾经有过一条"直接从 NSImage 位图算直方图"的路（想省掉一次管线求值），
// 实测**更慢**、已删：24MP@400% 下
//   拿 CI 图算（本文件上面那个函数）       ：34.9 ms
//   包成 CIImage(cgImage:) 再算            ：169.5 ms
//   纯 CGContext 把位图画进 256px 再数     ：148.6 ms
// 原因是那两条路都要先把整张 20.9MP 的位图搬/转一遍（位图是 16bit 宽色域格式）。
// 结论：直方图就用 CI 图算，但要**移出界面刷新的关键路径**（见 Portrait.swift 的 refresh）。

/// 读 EXIF 摘要（拍照参数，修图时的基本参照）
public func exifSummary(_ path: String) -> [(String, String)] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }
    var out: [(String, String)] = []
    func add(_ label: String, _ key: CFString, _ dict: [CFString: Any]? = nil) {
        guard let v = (dict ?? props)[key] else { return }
        out.append((label, "\(v)"))
    }
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
    if let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] {
        out.append(("尺寸", "\(w)×\(h)"))
    }
    add("相机", kCGImagePropertyTIFFModel, tiff)
    add("镜头", kCGImagePropertyExifLensModel, exif)
    // 光圈/快门/ISO 是拍照三要素，单独格式化
    if let f = exif?[kCGImagePropertyExifFNumber] as? Double {
        out.append(("光圈", String(format: "f/%.1f", f)))
    }
    if let t = exif?[kCGImagePropertyExifExposureTime] as? Double {
        out.append(("快门", t >= 1 ? String(format: "%.1fs", t) : String(format: "1/%.0fs", 1 / max(0.0001, t))))
    }
    if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = iso.first {
        out.append(("ISO", "\(first)"))
    }
    if let fl = exif?[kCGImagePropertyExifFocalLength] as? Double {
        out.append(("焦距", String(format: "%.0fmm", fl)))
    }
    if let eq = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
        out.append(("等效焦距", "\(eq)mm"))
    }
    if let d = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
        out.append(("拍摄时间", d))
    }
    if let wb = exif?[kCGImagePropertyExifWhiteBalance] as? Int {
        out.append(("白平衡", wb == 0 ? "自动" : "手动"))
    }
    return out
}
