// Export：导出设置（格式/质量/长边/位深/色彩空间/水印/重命名）+ RAW 入口
//
// 对应像素蛋糕的「导出图片设置」与「16bit AI Raw 引擎」两块。
// 全部落在 Core Image / ImageIO / CoreText 上，不引外部依赖。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import CoreText

// MARK: - 导出设置

public struct ExportSettings {
    public var format = "jpeg"          // jpeg | tiff | png
    public var quality = 95.0           // jpeg 质量（**0~100**，界面滑杆就是这个刻度）
    /// 交给 ImageIO/Core Image 的质量：它们要的是 **0.0~1.0**。
    ///
    /// ⚠️ 这里踩过一个真坑：直接把 0~100 的值传进去，>1 一律被钳成 1.0，
    /// 于是**不管滑杆放在哪，导出的都是最高质量**（实测 95/75/50 三档产出的文件字节数一模一样）。
    /// 用户问"导出质量选择时的图片大小"就是因为这件事——选什么都没变。
    public var qualityUnit: Double { max(0.0, min(1.0, quality / 100.0)) }
    public var maxLongEdge = 0          // 0 = 保持原尺寸；否则按长边缩放
    public var bitDepth = 8             // 8 | 16（tiff/png 支持 16）
    public var colorSpace = "sRGB"      // sRGB | DisplayP3
    public var nameTemplate = "{name}"  // {name} {index} {seq} {date}
    public var startIndex = 1
    public var watermarkText = ""
    public var watermarkImagePath = ""       // LOGO / 图片水印（PNG 带透明通道最好）
    public var watermarkImageScale = 0.14    // LOGO 宽度占画面长边的比例
    public var watermarkOpacity = 0.45
    public var watermarkScale = 0.035   // 相对长边的字号比例
    public var watermarkPosition = "bottom-right"   // top-left | top-right | bottom-left | bottom-right | center
    public init() {}

    public var space: CGColorSpace {
        colorSpace == "DisplayP3"
            ? (CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpace(name: CGColorSpace.sRGB)!
    }
    public var uti: String {
        switch format {
        case "tiff": return UTType.tiff.identifier
        case "png": return UTType.png.identifier
        default: return UTType.jpeg.identifier
        }
    }
    public var fileExtension: String {
        switch format {
        case "tiff": return "tif"
        case "png": return "png"
        default: return "jpg"
        }
    }
}

/// 按模板生成导出文件名（{name}=原文件名，{index}/{seq}=序号，{date}=今天）
public func exportName(_ template: String, source: String, index: Int) -> String {
    // 必须只取文件名：deletingPathExtension 对整条路径返回的是「去掉扩展名的整条路径」，
    // 里面还带斜杠，拼进输出目录会造出子路径 → 写盘必失败（coretest 批量导出因此抓到过 written=0）
    let base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
    var s = template.isEmpty ? "{name}" : template
    s = s.replacingOccurrences(of: "{name}", with: base)
    s = s.replacingOccurrences(of: "{index}", with: String(index))
    s = s.replacingOccurrences(of: "{seq}", with: String(format: "%03d", index))
    s = s.replacingOccurrences(of: "{date}", with: f.string(from: Date()))
    s = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    return s.isEmpty ? base : s
}

/// 批量导出时的重名消解。
///
/// 相机最常见的产出是 IMG_0001.CR2 + IMG_0001.JPG（RAW+JPEG 成对），
/// 同名不同扩展名进同一个输出目录会**互相覆盖**：实测 14 个 sample.* 只落地 1 个，静默丢了 13 张。
/// 这里记录「本批已用过的名字」，冲突时补 _2、_3…
public final class ExportNameAllocator {
    private var used: Set<String> = []
    private let lock = NSLock()
    public init() {}
    public func allocate(_ desired: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let ext = (desired as NSString).pathExtension
        let base = (desired as NSString).deletingPathExtension
        var candidate = desired
        var n = 2
        while used.contains(candidate) {
            candidate = ext.isEmpty ? base + "_" + String(n) : base + "_" + String(n) + "." + ext
            n += 1
        }
        used.insert(candidate)
        return candidate
    }
}

// MARK: - 水印（CoreText 直接画，不依赖 AppKit）

func watermarkImage(text: String, fontSize: CGFloat, color: CGColor) -> CGImage? {
    guard !text.isEmpty, fontSize > 1 else { return nil }
    let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, fontSize, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorAttributeName as String): color,
        .init(kCTKernAttributeName as String): fontSize * 0.02
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
    let pad = fontSize * 0.3
    let w = Int(ceil(width + pad * 2)), h = Int(ceil(asc + desc + pad * 2))
    guard w > 1, h > 1 else { return nil }
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0, alpha: 0))
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.textPosition = CGPoint(x: pad, y: desc + pad)
    CTLineDraw(line, ctx)
    return ctx.makeImage()
}

/// 把水印贴到图上（位置按比例算，尺寸按长边算——这样 4K 与 1080p 的观感一致）。
/// 支持文字水印与 LOGO（图片）水印，两个都填就叠加。
public func applyWatermark(_ src: CIImage, _ s: ExportSettings, sourceName: String) -> CIImage {
    var base = src
    if !s.watermarkImagePath.isEmpty, let logo = loadWatermarkImage(s, canvas: src.extent) {
        let e = src.extent
        let m = max(e.width, e.height) * 0.025
        var x = e.minX + m, y = e.minY + m
        switch s.watermarkPosition {
        case "top-left": x = e.minX + m; y = e.maxY - logo.extent.height - m
        case "top-right": x = e.maxX - logo.extent.width - m; y = e.maxY - logo.extent.height - m
        case "bottom-right": x = e.maxX - logo.extent.width - m; y = e.minY + m
        case "center": x = e.midX - logo.extent.width / 2; y = e.midY - logo.extent.height / 2
        default: break
        }
        base = logo.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: src).cropped(to: e)
    }
    guard !s.watermarkText.isEmpty else { return base }
    return applyTextWatermark(base, s, sourceName: sourceName)
}

/// 水印"配了但用不了"时返回原因（调用方据此**如实告知**，不要静默跳过）。
///
/// 为什么需要它：LOGO 路径写错、或文件被移走/改名时，导出会**静默地不打水印**并报"导出完成"——
/// 实测（§177）：日志里一句提示都没有，产物与"完全没设水印"逐像素一致。
/// 对"给客户交付带水印的成片"这个用法来说，这是**最坏的一种失败**（看起来成功了）。
public func watermarkTrouble(_ s: ExportSettings) -> String? {
    let hasText = !s.watermarkText.trimmingCharacters(in: .whitespaces).isEmpty
    let hasImg = !s.watermarkImagePath.isEmpty
    if !hasText && !hasImg { return nil }               // 本来就没要水印
    if hasText { return nil }                            // 文字水印不依赖外部文件
    if !FileManager.default.fileExists(atPath: s.watermarkImagePath) {
        return "水印 LOGO 文件不存在（" + s.watermarkImagePath + "）—— 这一批**没有**打上水印"
    }
    if loadImageWithAlpha(s.watermarkImagePath) == nil {
        return "水印 LOGO 解不开（" + s.watermarkImagePath + "）—— 这一批**没有**打上水印"
    }
    return nil
}

/// LOGO 读图 + 按比例缩放（保持长宽比；带 alpha 的 PNG 直接叠）
public func loadWatermarkImage(_ s: ExportSettings, canvas: CGRect) -> CIImage? {
    // 显式走"保留 alpha"的读图路：透明通道是 LOGO 的语义，不该依赖"碰巧没被丢掉"。
    // ⚠️ **更正**（§181）：这里原来写着"用 loadImage 会把透明背景变成实心黑" —— 那是**错的**。
    // 突变测试（把这一行换回 loadImage、重新编译、跑导出门）显示两次导出只差 **510 个像素**（羽化边），
    // 透明区并没有变黑；当初那个"黑板"读数来自一张用错的夹具（见 §175 的更正）。
    // 保留这条显式路径的理由**不是"修了个 bug"**，而是把意图写清楚。
    guard !s.watermarkImagePath.isEmpty,
          let img = loadImageWithAlpha(s.watermarkImagePath) else { return nil }
    let targetW = max(16, max(canvas.width, canvas.height) * CGFloat(s.watermarkImageScale))
    let scale = targetW / max(1, img.extent.width)
    var logo = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    logo = logo.cropped(to: CGRect(x: 0, y: 0, width: logo.extent.width.rounded(.down),
                                   height: logo.extent.height.rounded(.down)))
    if s.watermarkOpacity < 0.999 {
        logo = logo.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0.02, min(1, s.watermarkOpacity))))])
    }
    return logo
}

/// 文字水印（内部：applyWatermark 已经把 LOGO 叠好了）
func applyTextWatermark(_ src: CIImage, _ s: ExportSettings, sourceName: String) -> CIImage {
    let e = src.extent
    let fontSize = max(8, max(e.width, e.height) * CGFloat(s.watermarkScale))
    let text = s.watermarkText.replacingOccurrences(of: "{name}",
        with: ((sourceName as NSString).lastPathComponent as NSString).deletingPathExtension)
    guard let wm = watermarkImage(text: text, fontSize: fontSize, color: CGColor(gray: 1, alpha: 1)) else { return src }
    let w = CGFloat(wm.width), h = CGFloat(wm.height)
    let m = max(e.width, e.height) * 0.025
    var x = e.maxX - w - m, y = e.minY + m
    switch s.watermarkPosition {
    case "top-left": x = e.minX + m; y = e.maxY - h - m
    case "top-right": x = e.maxX - w - m; y = e.maxY - h - m
    case "bottom-left": x = e.minX + m; y = e.minY + m
    case "center": x = e.midX - w / 2; y = e.midY - h / 2
    default: break
    }
    // 白色文字 + 一层轻微暗描边，浅背景上也看得见
    let white = CIImage(cgImage: wm)
        .transformed(by: CGAffineTransform(translationX: x, y: y))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.watermarkOpacity))])
    let dark = CIImage(cgImage: wm)
        .transformed(by: CGAffineTransform(translationX: x + 1.5, y: y - 1.5))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(s.watermarkOpacity * 0.5))])
    return white.composited(over: dark.composited(over: src)).cropped(to: e)
}

/// 缩放（按长边）——用 Lanczos，比默认的双线性锐利
public func resizeLongEdge(_ src: CIImage, maxLongEdge: Int) -> CIImage {
    guard maxLongEdge > 0 else { return src }
    let long = max(src.extent.width, src.extent.height)
    guard long > CGFloat(maxLongEdge) else { return src }
    let scale = CGFloat(maxLongEdge) / long
    let f = CIFilter.lanczosScaleTransform()
    f.inputImage = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
    f.scale = Float(scale)
    f.aspectRatio = 1
    guard let out = f.outputImage else { return src }
    let w = (out.extent.width).rounded(.down), h = (out.extent.height).rounded(.down)
    return out.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

/// 按当前导出设置**真的编一遍**，返回文件大小（不是用公式估的）。
///
/// 为什么直接量而不是估：JPEG 的体积与质量、画面细节、分辨率都是非线性的，
/// 任何"bps 模型"在真实照片上都会偏 30% 以上；而用户问的是"导出到底多大"，
/// 给个准数才有意义。代价是一次真正的编码——所以调用方要自己做防抖。
/// 实现上直接落到临时文件再读大小，保证与真实导出**走的是同一条路径**（含缩放/位深/色彩空间）。
public func measureExportBytes(_ src: CIImage, _ s: ExportSettings, sourceURL: URL? = nil) -> Int? {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("cr_estsize_\(UUID().uuidString).\(s.fileExtension)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    guard exportImage(src, to: tmp, s, sourceURL: sourceURL) else { return nil }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: tmp.path) else { return nil }
    return (attrs[.size] as? NSNumber)?.intValue
}

// MARK: - 写盘（8/16 位、三格式、色彩空间可选）

public func exportImage(_ src: CIImage, to url: URL, _ s: ExportSettings,
                        sourceURL: URL? = nil) -> Bool {
    let space = s.space
    var img = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
    img = resizeLongEdge(img, maxLongEdge: s.maxLongEdge)
    if s.format == "jpeg" {
        // JPEG 无 alpha：压到白底
        img = img.composited(over: CIImage(color: .white).cropped(to: img.extent))
    }
    let fmt: CIFormat = (s.bitDepth == 16 && s.format != "jpeg") ? .RGBA16 : .RGBA8
    // 8bit JPEG 走 CIContext 直接编码：实测 21MP 大图 83ms → 45ms（快 1.8 倍、体积与画质一致），
    // 因为省掉了「GPU→CPU 整张回读成一个 CGImage」的那一步。
    // 需要带上 EXIF/方向等属性、或 16bit 时，仍走 CGImageDestination。
    let inherited = sourceURL != nil
    if s.format == "jpeg", !inherited, s.bitDepth == 8, s.maxLongEdge == 0 || img.extent.width <= CGFloat(s.maxLongEdge) {
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): s.qualityUnit
        ]
        if (try? sharedCtx.writeJPEGRepresentation(of: img, to: url, colorSpace: space, options: opts)) != nil {
            return true
        }
    }
    guard let cg = sharedCtx.createCGImage(img, from: img.extent, format: fmt, colorSpace: space),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, s.uti as CFString, 1, nil) else { return false }
    var props: [CFString: Any] = [:]
    if s.format == "jpeg" { props[kCGImageDestinationLossyCompressionQuality] = s.qualityUnit }
    if s.format == "tiff" { props[kCGImagePropertyTIFFCompression] = 5 }   // LZW
    // EXIF 继承：把原片的拍摄信息带过去（方向已经烘进像素，所以强制 1）
    if let src2 = sourceURL, let s2 = CGImageSourceCreateWithURL(src2 as CFURL, nil),
       let p = CGImageSourceCopyPropertiesAtIndex(s2, 0, nil) as? [CFString: Any] {
        if let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] { props[kCGImagePropertyExifDictionary] = exif }
        if let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] { props[kCGImagePropertyTIFFDictionary] = tiff }
        if let gps = p[kCGImagePropertyGPSDictionary] as? [CFString: Any] { props[kCGImagePropertyGPSDictionary] = gps }
    }
    props[kCGImagePropertyOrientation] = 1
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}



/// 抽 RAW 内嵌预览（相机拍 RAW 时同时存的 JPEG 缩略图）。网格/胶片栏用它，快 8 倍。
/// 失败返回 nil，调用方会退回 CIRAWFilter。
public func rawThumbnail(_ path: String, maxDim: Int) -> CIImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceShouldCacheImmediately: true
          ] as CFDictionary) else { return nil }
    var img = CIImage(cgImage: cg)
    let w = img.extent.width.rounded(.down), h = img.extent.height.rounded(.down)
    img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    return img
}

// MARK: - RAW 入口（CIRAWFilter）

/// RAW 扩展名。清单对着 ImageIO 能读的 RAW 类型逐个列（用 `CGImageSourceCopyTypeIdentifiers` 校对过），
/// 覆盖 Canon / Nikon / Sony / Fuji / Olympus / Panasonic / Pentax / Samsung / Hasselblad / Phase One /
/// Epson / Kodak / Leaf / Minolta / Sigma 这些常见家族。
public let rawExtensions: Set<String> = [
    // Canon
    "cr2", "cr3", "crw", "ciff",
    // Nikon
    "nef", "nrw", "nefx",
    // Sony
    "arw", "srf", "sr2", "axr",
    // Fujifilm / Olympus / Panasonic / Pentax / Samsung / Minolta / Sigma
    "raf", "orf", "rw2", "pef", "srw", "mrw", "x3f",
    // 通用 / 厂商专有
    "dng", "tif", "tiff", "raw", "3fr", "fff", "mos", "iiq", "erf", "dcr", "kdc", "rwl", "nksc"
]

/// 能进管线的图片扩展名（含 RAW）。界面、命令行、批量扫描**共用这一份**，避免两边清单漂移
///（踩过：命令行里自己写了一份 [jpg,png,webp,tif]，导致 heic / avif / 所有 RAW 在批量里直接看不见）。
public let imageExtensions: Set<String> = Set([
    "jpg", "jpeg", "jpe", "png", "webp", "tif", "tiff",
    "heic", "heif", "avif",
    "gif", "bmp", "jp2", "j2k", "jpf", "psd", "tga", "exr", "ico",
    "pbm", "pgm", "ppm", "pnm", "dds"
]).union(rawExtensions)

/// 统一读图：RAW 走 CIRAWFilter（16bit 管线 → sRGB 位图），其余走 loadImage
public func loadAnyImage(_ path: String, maxDim: Int = 0) -> CIImage? {
    let ext = (path as NSString).pathExtension.lowercased()
    guard rawExtensions.contains(ext) else { return loadImage(path, maxDim: maxDim) }
    // RAW 的**小图请求**走内嵌预览：实测同一张 24MP CR3，缩到长边 1600 时
    //   CIRAWFilter 全解码 458 ms ｜ 抽内嵌 JPEG 预览 58 ms（8×）
    // 代价是颜色来自机身的 JPEG 渲染（跟 RAW 解码差约 17 级）—— 网格/缩略图用它是行业惯例，
    // 而工作预览和导出仍走 CIRAWFilter，保证「所见即所得」。
    if maxDim > 0, maxDim <= 1024, let thumb = rawThumbnail(path, maxDim: maxDim) { return thumb }
    // ⚠️ 这里的兜底不止一种：CIRAWFilter 可能「打开成功但什么都没解出来」
    //（实测自造的 DNG：nativeSize 为 0、outputImage 的 extent 是 inf，这时不能直接返回 nil，
    //  否则一个能被 ImageIO 正常当 TIFF 读的文件就整个读不到了）。
    var image: CIImage? = nil
    if let f = CIRAWFilter(imageURL: URL(fileURLWithPath: path)) {
        // 关掉草稿模式：草稿快但细节差（对标像素蛋糕那种「16bit 引擎」走的是非草稿）
        f.isDraftModeEnabled = false
        f.isGamutMappingEnabled = true          // 广色域相机数据映射到工作空间，避免过饱和
        // 目标尺寸远小于原生时，让解码器**一开始就解小一点**（scaleFactor）。
        // 实测同一张 24MP CR3 缩到长边 1600：478 ms → 358 ms（−25%），
        // 而在这个输出尺寸上颜色差 0.0 级、细节差 0% —— 因为最终反正要缩。
        if maxDim > 0 {
            let native = Double(max(f.nativeSize.width, f.nativeSize.height))
            if native > 1 {
                let ratio = Double(maxDim) / native
                if ratio < 0.9 { f.scaleFactor = Float(max(0.25, min(1.0, ratio))) }
            }
        }
        f.isLensCorrectionEnabled = true        // 机身/镜头校正（有的话）
        if let out = f.outputImage, out.extent.width > 1, out.extent.height > 1 {
            image = out
        }
    }
    guard let raw0 = image else { return loadImage(path, maxDim: maxDim) }   // RAW 解不了 → 当普通图像读
    let out = raw0
    // RAW 是线性数据，直接进 sRGB 图形栈会偏亮；用一次到 sRGB 的位图渲染把它定标
    guard let cg = sharedCtx.createCGImage(out, from: out.extent, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
        return loadImage(path, maxDim: maxDim)   // 渲染不出来也退回普通读图
    }
    var img = CIImage(cgImage: cg)
    if maxDim > 0 {
        let long = max(img.extent.width, img.extent.height)
        if long > CGFloat(maxDim) {
            let sc = CGFloat(maxDim) / long
            img = img.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
        }
    }
    let w = img.extent.width.rounded(.down), h = img.extent.height.rounded(.down)
    return img.cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
}

// MARK: - 批量导出（一次跑完整目录）

public struct BatchExportResult {
    public var written = 0
    public var skipped = 0
    public var skippedExisting = 0     // 已经导出过、这次直接跳过（断点续跑）
    public var cancelled = false       // 用户中途取消
    public var seconds = 0.0
    public var bytes: Int64 = 0
}

/// 把一个目录里的图按设置导出到 outDir（原图不动）。
/// workers = 1 时逐张（内存峰值最小）；>1 时按张切块并行。
///
/// `skipExisting` 是给大批量用的**断点续跑**：一万张跑到一半退出了，再点一次只补没出的那些，
/// 而不是把已经出好的全部重做一遍（24MP 的片子一张几秒，重做就是几小时）。
/// `shouldCancel` 每张前问一次：取消后不再派新任务，在跑的几张跑完即止。
public func exportBatch(files: [String], outDir: String, _ s: ExportSettings,
                        makeImage: @escaping (String) -> CIImage?, workers: Int = 1,
                        skipExisting: Bool = false,
                        shouldCancel: (() -> Bool)? = nil,
                        progress: ((Int, Int) -> Void)? = nil) -> BatchExportResult {
    var res = BatchExportResult()
    let t0 = Date()
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let lock = NSLock()
    let allocator = ExportNameAllocator()
    let total = files.count
    var done = 0
    func handle(_ i: Int, _ f: String) {
        autoreleasepool {
            let desired0 = exportName(s.nameTemplate, source: f, index: s.startIndex + i) + "." + s.fileExtension
            // 断点续跑：目标文件已经在，就跳过（不重新解码/渲染，省下的是几秒钟一张的成本）
            if skipExisting {
                let candidate = URL(fileURLWithPath: outDir).appendingPathComponent(desired0)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    lock.lock(); res.skippedExisting += 1; done += 1; let d = done; lock.unlock()
                    progress?(d, total)
                    return
                }
            }
            guard let img = makeImage(f) else { lock.lock(); res.skipped += 1; lock.unlock(); return }
            let desired = exportName(s.nameTemplate, source: f, index: s.startIndex + i) + "." + s.fileExtension
            let name = allocator.allocate(desired)      // 重名消解：同名不同扩展名不能互相覆盖
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
            var out = img
            // ⚠️ 判据必须**同时看文字和 LOGO**：原来只判 `watermarkText`，
            // 于是"只设 LOGO、不填文字"时批量导出一个水印都不加，而单张导出（Export.swift:102）
            // 判的是两者之一 —— 同一个功能两条路行为不一致（第 147 节）。
            if !s.watermarkText.isEmpty || !s.watermarkImagePath.isEmpty {
                out = applyWatermark(out, s, sourceName: f)
            }
            let ok = exportImage(out, to: url, s, sourceURL: URL(fileURLWithPath: f))
            lock.lock()
            if ok {
                res.written += 1
                res.bytes += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            } else { res.skipped += 1 }
            done += 1
            let d = done
            lock.unlock()
            progress?(d, total)
        }
    }
    if workers <= 1 {
        // 串行分支也要查取消：早先只在并行分支里查，于是把并行度设成 1 的用户「取消」完全没用
        //（coretest 用「一开始就取消」的用例当场抓出来的）
        for (i, f) in files.enumerated() {
            if shouldCancel?() == true { res.cancelled = true; break }
            handle(i, f)
        }
    } else {
        let sem = DispatchSemaphore(value: max(1, min(workers, 8)))
        let group = DispatchGroup()
        for (i, f) in files.enumerated() {
            // 取消检查放在派任务之前：取消后不再开新的，正在跑的几张跑完即止
            if shouldCancel?() == true { res.cancelled = true; break }
            sem.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                handle(i, f)
                sem.signal()
                group.leave()
            }
        }
        group.wait()
    }
    res.seconds = Date().timeIntervalSince(t0)
    return res
}
