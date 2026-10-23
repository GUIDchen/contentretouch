// DecodeCache：把「解码 + 缩放」的结果缓存在内存里（**只做内存，不做磁盘**）
//
// 实测（抖音库）：webp 解码 82.5~152.6 ms/张，而同样输出大小的 jpg 只要 23.1 ms —— webp 解码器就是慢，
// 换路径没用（ImageIO 的缩略图解码对 webp 是 83.1 ms，基本没差别）。
// 所以能做的不是「更快地解码」，而是「**别重复解码**」：命中后 1.9 ms/张（约 80×）。
//
// ⚠️ 曾经做过磁盘层（把解码结果存成 JPEG 复用），**已经撤掉**：
// 存成有损 JPEG 意味着第二次打开的预览是「重新编码过的像素」，
// 对修图软件是硬伤（用户在拿这张预览做曝光/色彩判断），实测也让界面截图回归全线飘红
//（同一份代码两次跑，画布像素不一致）。内存缓存是零损失地复用同一个 CIImage，够了。
import Foundation
import CoreImage
import ImageIO
import CommonCrypto

public final class DecodeCache {
    public static let shared = DecodeCache()
    public static var disabled = ProcessInfo.processInfo.environment["CR_NO_DECODE_CACHE"] == "1"

    private let lock = NSLock()
    private var memory: [String: CIImage] = [:]
    private var memoryOrder: [String] = []
    private let memoryLimit = 12

    public private(set) var hits = 0
    public private(set) var misses = 0

    public static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ContentRetouch/previews", isDirectory: true)
    }

    /// 键 = 路径 + 修改时间 + 目标尺寸（任何一项变了就重新解码）
    private func key(_ path: String, _ maxDim: Int) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(Int(mtime))|\(maxDim)"
    }

    private func hash(_ s: String) -> String {
        let d = Array(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        d.withUnsafeBufferPointer { p in
            _ = CC_SHA256(p.baseAddress, CC_LONG(d.count), &digest)
        }
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 取（内存 → 磁盘 → 现场解码 + 回填）
    public func image(_ path: String, maxDim: Int, decode: () -> CIImage?) -> CIImage? {
        guard !DecodeCache.disabled, maxDim > 0 else { return decode() }
        let k = key(path, maxDim)
        lock.lock()
        if let v = memory[k] {
            hits += 1
            lock.unlock()
            return v
        }
        lock.unlock()
        lock.lock(); misses += 1; lock.unlock()
        guard let img = decode() else { return nil }
        lock.lock(); memory[k] = img; memoryOrder.append(k)
        while memoryOrder.count > memoryLimit { memory.removeValue(forKey: memoryOrder.removeFirst()) }
        lock.unlock()
        return img
    }

    /// 只清内存（测磁盘缓存时要用这个：clear() 会把磁盘缓存也删掉，那就永远测不到磁盘命中）
    public func clearMemory() {
        lock.lock(); memory.removeAll(); memoryOrder.removeAll(); hits = 0; misses = 0; lock.unlock()
    }

    public func clear() {
        clearMemory()
        try? FileManager.default.removeItem(at: DecodeCache.cacheDir)
    }

    public var diskBytes: Int64 {
        let e = FileManager.default.enumerator(at: DecodeCache.cacheDir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
