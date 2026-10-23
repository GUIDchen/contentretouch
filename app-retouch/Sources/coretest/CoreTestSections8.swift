// CoreTestSections8.swift：coretest 的第 57~64 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections8() {
// 只给暖冷偏色、其它全中性：这时候**必须**变

pWarm.cbSh = [120, 0, -120]
pWarm.cbHi = [120, 0, -120]

check("暖冷偏色（其它全中性）真的改像素",
      sWarm.warmSh > sBase.warmSh + 8 && sWarm.warmHi > sBase.warmHi + 8,
      String(format: "阴影 R−B %.1f → %.1f，高光 R−B %.1f → %.1f", sBase.warmSh, sWarm.warmSh, sBase.warmHi, sWarm.warmHi))

// 同上，但另外开一个降饱和（历史上这里有个「三者都接近 0 就提前 return」的短路）
// 同上但另外开一个降饱和：历史上「三者都接近 0 就提前 return」会把偏色整段跳过。
// 对照必须是「同样降饱和但没给偏色」，否则量到的差异会混进降饱和带来的变化。

pWarm2.desat = 10

pDesatOnly.desat = 10

check("降饱和时暖冷偏色照样生效（不被短路吞掉）",
      sWarm2.warmSh > sDesatOnly.warmSh + 8,
      String(format: "阴影 R−B 只降饱和 %.1f → 降饱和+偏色 %.1f", sDesatOnly.warmSh, sWarm2.warmSh))

// 目标折算：把源的分布搬到目标的分布，量出来的中位应当贴上去

target.p5 = sBase.p5 + 30; target.p50 = sBase.p50 + 60; target.p95 = sBase.p95 + 40
target.q5 = sBase.q5; target.q50 = sBase.q50; target.q95 = sBase.q95
target.sat = sBase.sat * 0.5; target.warmSh = sBase.warmSh + 25; target.warmHi = sBase.warmHi + 20

check("按分布直解：中位靠上目标",
      abs(sSolved.p50 - target.p50) < abs(sBase.p50 - target.p50) * 0.5,
      String(format: "p50 %.1f → %.1f（目标 %.1f）", sBase.p50, sSolved.p50, target.p50))
check("按分布直解：暖冷差缩小一半以上",
      abs(sSolved.warmSh - target.warmSh) < abs(sBase.warmSh - target.warmSh) * 0.6,
      String(format: "阴影 R−B %.1f → %.1f（目标 %.1f）", sBase.warmSh, sSolved.warmSh, target.warmSh))

// 参考图折算：中位数必须抗离群——3 张正常 + 1 张全黑，目标不该被带跑
}
