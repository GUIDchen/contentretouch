// CoreTestSections15.swift：换天空耗时分解（用户侧单张 74 秒，查清花在哪）。
// 拆分规则见 docs/功能账本_交接.md 第 115~119 节：一个分节文件 = 若干节的函数，入口只做顺序调用。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections15() {
// MARK: - 51. 换天空：耗时分解
head("51. 换天空耗时分解")
do {
    if let img = loadFixture("0184_7379189016593321253_05.webp", maxDim: 1400) {
        let e = img.extent
        // ⚠️ CIImage 是惰性的：必须落地（createCGImage）才量得到真实代价（本项目踩过的坑）
        func ms(_ n: Int = 1, _ f: () -> CIImage?) -> Double {
            let t0 = Date()
            for _ in 0..<n { if let o = f() { _ = sharedCtx.createCGImage(o, from: o.extent) } }
            return Date().timeIntervalSince(t0) / Double(n) * 1000
        }
        var o = SkyOptions(); o.amount = 60; o.style = "blue"
        let tScore = ms { skyScore(img) }
        let tSky = ms { skyImage(style: "blue", extent: e) }
        let tPerson = ms { personMask(img) }
        let tAll = ms { replaceSky(img, o).image }
        print(String(format: "  [实测] 图 %.0fx%.0f ｜ 天空评分 %.0f ms ｜ 生成天空 %.0f ms ｜ 人物分割 %.0f ms ｜ 整体 replaceSky %.0f ms",
                     e.width, e.height, tScore, tSky, tPerson, tAll))
        check("换天空单张 5 秒以内（否则批量不可用）", tAll < 5000, String(format: "实测 %.0f ms", tAll))
    } else { print("  （夹具不可用，跳过）") }
}
}
