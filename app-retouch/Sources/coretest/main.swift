// coretest 入口：只看顺序调用。主体在 CoreTestSections*.swift，工具件在 TestSupport.swift。
import Foundation

// §286：本机可能装了可选的 LaMa 生成式修补模型 ⇒ 修复类断言会自动改走生成式分支 ✗，
// 而它们写的期望值是**样例修补**那条路（§285 实测：一装上就从 346/0 变 342/4）✗。
// 让这些断言**状态无关**：除非调用者显式指定 CR_LAMA_DIR，否则统一指向一个空目录，
// 这样「不装模型时也能修」这条契约被确定性地测到；要测装了模型的行为，显式传 CR_LAMA_DIR 即可 ✓。
if ProcessInfo.processInfo.environment["CR_LAMA_DIR"] == nil {
    let emptyDir = NSTemporaryDirectory() + "cr_coretest_lama_empty"
    try? FileManager.default.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
    setenv("CR_LAMA_DIR", emptyDir, 1)
}


runSections1()
runSections2()
runSections3()
runSections4()
runSections5()
runSections6()
runSections7()
runSections8()
runSections9()
runSections10()
runSections11()
runSections12()
runSections13()
runSections14()
runSections15()
runSections16()
runSections17()
runSections18()
// §324：第 60/61 节必须**在汇总之前**跑。§323 发现我把它们追加到了 main.swift 末尾 ✗，
// 于是它们排在汇总打印与 exit(1) **之后** ⇒ 失败只打印、不进计数、也不影响退出码 ——
// 这等于「断言能红但结论全绿」，是判据失效 ✗。移到这里，两者才真正进入判据 ✓。
runSections60()
runSections61()
runSections62()
runSections63()
runSections64()
runSections65()
runSections66()
runSections68()
runSections69()
runSections70()
runSections71()
runSections72()

print("")
// 跳过项要单独报：它们加进"通过"里的话，"跳过的检查"和"验过的检查"就分不出来了。
print("通过 " + String(nPass) + " 项，跳过 " + String(nSkip) + " 项，未通过 " + String(nFail) + " 项")
if nFail > 0 { exit(1) }
