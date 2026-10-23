import Foundation
import CoreImage
import RetouchCore

// 纯核心层复现：反复"渲染 + 出图 + 直方图"，看常驻内存涨不涨；并对照 cacheIntermediates: false
func rss() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let ok = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { q in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), q, &count)
        }
    }
    return ok == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}
let root = "/Users/you/Documents/DeepSeek-Harness-Projects/dsh-xiutu"
let path = root + "/douyin_favorites/images/0001_7673816620465215714_01.webp"
guard let img = loadImage(path, maxDim: 1400) else { print("载入失败"); exit(1) }

let noCache = CIContext(options: [.useSoftwareRenderer: false,
                                 .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 .cacheIntermediates: false])
func loop(_ label: String, _ ctx: CIContext, _ n: Int) {
    let start = rss()
    var peak = start
    for _ in 1...n {
        let out = render(img, Params())
        _ = ctx.createCGImage(out, from: out.extent)
        _ = histogram(out)
        peak = max(peak, rss())
    }
    print(String(format: "%@：起始 %.0f MB → 结束 %.0f MB（峰值 %.0f，%d 轮漂移 %+.0f MB）",
                 label, start, rss(), peak, n, rss() - start))
}
loop("sharedCtx（现状：默认缓存）  ", sharedCtx, 20)
loop("新建 ctx + cacheIntermediates=false", noCache, 20)
loop("sharedCtx 再来一轮            ", sharedCtx, 20)
