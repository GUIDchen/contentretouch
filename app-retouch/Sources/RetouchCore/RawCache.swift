// RawCache：RAW 预解码缓存（**可选开启**）
//
// 场景：一批 RAW 反复出片（换风格、改参数、重导），每次都要重新解码。
// 实测（240 张 24MP CR3）：解码占批量的大头 —— 8 线程下每张读图 1.3~3.2 s，整批约 1.9 张/秒。
//
// 代价必须说清楚：
//   · 缓存是 16bit TIFF（无损，交付级），2000px 一张约 16 MB → 240 张约 3.8 GB；
//   · 8bit 无损（PNG/TIFF）约 8 MB/张，但 16bit 管线降成 8bit 会丢数据；
//   · 有损（JPEG/HEIF）体积小但**不能用于交付**，只能当代理。
// 所以这里做成：**默认关闭**，显式 --raw-cache <dir> 才开，并且带容量上限自动淘汰。
import Foundation
import CoreImage
import ImageIO

public final class RawCache {
    public init(directory: String, limitBytes: Int64 = 8 * 1024 * 1024 * 1024, bitDepth: Int = 16) {
        self.dir = URL(fileURLWithPath: directory)
        self.limitBytes = limitBytes
        self.bitDepth = bitDepth
    }
    private let dir: URL
    private let limitBytes: Int64
    private let bitDepth: Int
    private let lock = NSLock()
    public private(set) var hits = 0
    public private(set) var misses = 0
    /// 诊断：写失败（落盘没成功）/ 读失败（文件在但读不回来）。缓存是可再生的，
    /// 失败只意味着重新解码；但**必须能看见**，否则"缓存生效"就是一句空话。
    public private(set) var writeFailures = 0
    public private(set) var readFailures = 0
    public private(set) var writes = 0

    private func key(_ path: String, _ maxDim: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? Int64) ?? 0
        var h = UInt64(1469598103934665603)
        for b in "\(path)|\(Int(mtime))|\(size)|\(maxDim)".utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(format: "%016llx", h)
    }

    public func image(_ path: String, maxDim: Int, produce: () -> CIImage?) -> CIImage? {
        let file = dir.appendingPathComponent(key(path, maxDim) + ".tif")
        lock.lock()
        let exists = FileManager.default.fileExists(atPath: file.path)
        lock.unlock()
        if exists, let src = CGImageSourceCreateWithURL(file as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            lock.lock(); hits += 1; lock.unlock()
            return CIImage(cgImage: cg)
        }
        if exists { lock.lock(); readFailures += 1; lock.unlock() }
        lock.lock(); misses += 1; lock.unlock()
        guard let img = produce() else { return nil }
        let e = img.extent
        let fmt: CIFormat = bitDepth == 16 ? .RGBA16 : .RGBA8
        if let cg = sharedCtx.createCGImage(img, from: e, format: fmt, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var wrote = false
            // 先写临时文件再原子改名：否则半个 TIFF 留在缓存里，下次会当成"有效"读回一张烂图
            let tmp = file.appendingPathExtension("tmp")
            if let d = CGImageDestinationCreateWithURL(tmp as CFURL, "public.tiff" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, [kCGImagePropertyTIFFCompression: 5] as CFDictionary)   // LZW
                if CGImageDestinationFinalize(d) {
                    wrote = (try? FileManager.default.moveItem(at: tmp, to: file)) != nil
                }
            }
            if wrote { lock.lock(); writes += 1; lock.unlock() }
            else { try? FileManager.default.removeItem(at: tmp); lock.lock(); writeFailures += 1; lock.unlock() }
        }
        sweep()
        return img
    }

    /// 超上限就按修改时间删最旧的（简单但够用；缓存本来就是可再生的）
    private func sweep() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int64, Date)] = []
        var total: Int64 = 0
        while let f = en.nextObject() as? URL {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let sz = Int64(v?.fileSize ?? 0)
            files.append((f, sz, v?.contentModificationDate ?? .distantPast))
            total += sz
        }
        guard total > limitBytes else { return }
        for (u, sz, _) in files.sorted(by: { $0.2 < $1.2 }) {
            try? FileManager.default.removeItem(at: u)
            total -= sz
            if total <= limitBytes { break }
        }
    }

    public var bytes: Int64 {
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let f = en?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
