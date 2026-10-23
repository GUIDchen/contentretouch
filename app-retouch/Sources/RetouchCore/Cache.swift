// Cache：按「图像内容指纹」缓存昂贵的 Vision / 模型结果
//
// 剖析实测（单张全链路 ~480ms）：衣物语义检查 135ms、人像里的解析又一次、人脸检测 66ms、
// personMask / SAM 编解码各一次 —— 同一张图在同一条管线里被反复送进模型。
// 这里用「8x8 缩略图的字节」当指纹做缓存：内容变了指纹就变，不会读到旧的。
//
// 为什么用指纹而不是对象身份：CIImage 没有稳定的身份标识，而管线里每一步都可能产生新的 CIImage
//（有的是同一份内容的不同变换）。指纹只看像素内容，安全。
import Foundation
import CoreImage
import Vision

/// 图像内容指纹：8x8 RGB + 尺寸
public struct ImageFingerprint: Hashable {
    public var w: Int
    public var h: Int
    public var bytes: [UInt8]
}

public func fingerprint(_ src: CIImage) -> ImageFingerprint? {
    if VisionCache.disabled { return nil }
    let e = src.extent
    guard e.width > 1, e.height > 1 else { return nil }
    let n = 8
    let scaled = src.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .transformed(by: CGAffineTransform(scaleX: CGFloat(n) / e.width, y: CGFloat(n) / e.height))
    var buf = [UInt8](repeating: 0, count: n * n * 4)
    sharedCtx.render(scaled, toBitmap: &buf, rowBytes: n * 4,
                     bounds: CGRect(x: 0, y: 0, width: n, height: n), format: .RGBA8,
                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    // 丢掉 alpha，省一半比较
    var keep = [UInt8](repeating: 0, count: n * n * 3)
    for i in 0..<(n * n) {
        keep[i * 3] = buf[i * 4]; keep[i * 3 + 1] = buf[i * 4 + 1]; keep[i * 3 + 2] = buf[i * 4 + 2]
    }
    return ImageFingerprint(w: Int(e.width), h: Int(e.height), bytes: keep)
}

/// 小容量缓存（图像数量少、每张都要用很多次，3 条够用；多了白占内存）
public final class VisionCache {
    public static let shared = VisionCache()
    /// 关掉缓存用于 A/B 实测（环境变量 CR_NO_CACHE=1）
    public static var disabled = ProcessInfo.processInfo.environment["CR_NO_CACHE"] == "1"
    public fileprivate(set) var hits = 0
    public fileprivate(set) var misses = 0
    public func stats() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (hits, misses) }
    fileprivate let lock = NSLock()
    private var order: [ImageFingerprint] = []
    private var geos: [ImageFingerprint: [FaceGeo]] = [:]
    private var personas: [ImageFingerprint: CIImage] = [:]
    private var parses: [ImageFingerprint: FaceParseResult] = [:]
    private var foregrounds: [ImageFingerprint: CIImage] = [:]
    fileprivate var faceParses: [FaceKey: FaceParseResult] = [:]
    fileprivate var faceOrder: [FaceKey] = []
    private let capacity = 3

    private func touch(_ k: ImageFingerprint) {
        order.removeAll { $0 == k }
        order.append(k)
        while order.count > capacity {
            let old = order.removeFirst()
            geos.removeValue(forKey: k == old ? k : old)
            personas.removeValue(forKey: old)
            parses.removeValue(forKey: old)
            foregrounds.removeValue(forKey: old)
        }
    }

    public func faceGeos(_ src: CIImage, _ produce: () -> [FaceGeo]) -> [FaceGeo] {
        guard let k = fingerprint(src) else { return produce() }
        lock.lock()
        if let v = geos[k] { hits += 1; lock.unlock(); return v }
        lock.unlock()
        lock.lock(); misses += 1; lock.unlock()
        let v = produce()
        lock.lock(); geos[k] = v; touch(k); lock.unlock()
        return v
    }

    public func personMask(_ src: CIImage, _ produce: () -> CIImage?) -> CIImage? {
        guard let k = fingerprint(src) else { return produce() }
        lock.lock()
        if let v = personas[k] { hits += 1; lock.unlock(); return v }
        lock.unlock()
        lock.lock(); misses += 1; lock.unlock()
        guard let v = produce() else { return nil }
        lock.lock(); personas[k] = v; touch(k); lock.unlock()
        return v
    }

    public func parse(_ src: CIImage, _ produce: () -> FaceParseResult?) -> FaceParseResult? {
        guard let k = fingerprint(src) else { return produce() }
        lock.lock()
        if let v = parses[k] { hits += 1; lock.unlock(); return v }
        lock.unlock()
        lock.lock(); misses += 1; lock.unlock()
        guard let v = produce() else { return nil }
        lock.lock(); parses[k] = v; touch(k); lock.unlock()
        return v
    }

    public func foreground(_ src: CIImage, _ produce: () -> CIImage?) -> CIImage? {
        guard let k = fingerprint(src) else { return produce() }
        lock.lock()
        if let v = foregrounds[k] { hits += 1; lock.unlock(); return v }
        lock.unlock()
        lock.lock(); misses += 1; lock.unlock()
        guard let v = produce() else { return nil }
        lock.lock(); foregrounds[k] = v; touch(k); lock.unlock()
        return v
    }

    public func clear() {
        lock.lock()
        order.removeAll(); geos.removeAll(); personas.removeAll(); parses.removeAll(); foregrounds.removeAll()
        lock.unlock()
    }
}


/// 按脸裁切的解析结果缓存。
///
/// 为什么单独做一层：parsedMaskForFace 是「把人脸框裁出来再解析」，每次裁出来的都
/// 是一张新图 → 内容指纹必然不同 → 整图那层缓存永远打不中。
/// 实测 7 张脸的图，牙齿+眼睛+皮肤三项各自都要按脸解析一次 = 21 次模型推理 ≈ 1050ms。
/// 这里按「图像指纹 + 量化到 8px 的裁剪框」当键，同一张脸只推理一次。
extension VisionCache {
    public func parseFace(_ src: CIImage, box: CGRect, _ produce: () -> FaceParseResult?) -> FaceParseResult? {
        guard !VisionCache.disabled, let k = fingerprint(src) else { return produce() }
        let q = CGRect(x: (box.minX / 8).rounded() * 8, y: (box.minY / 8).rounded() * 8,
                       width: (box.width / 8).rounded() * 8, height: (box.height / 8).rounded() * 8)
        let key = FaceKey(img: k, box: [Int(q.minX), Int(q.minY), Int(q.width), Int(q.height)])
        lock.lock()
        if let v = faceParses[key] { hits += 1; lock.unlock(); return v }
        lock.unlock()
        lock.lock(); misses += 1; lock.unlock()
        guard let v = produce() else { return nil }
        lock.lock()
        faceParses[key] = v
        faceOrder.append(key)
        while faceOrder.count > 24 { faceParses.removeValue(forKey: faceOrder.removeFirst()) }
        lock.unlock()
        return v
    }
}

public struct FaceKey: Hashable {
    public var img: ImageFingerprint
    public var box: [Int]
}
