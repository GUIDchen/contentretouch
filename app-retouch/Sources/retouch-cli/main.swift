// 命令行闭环（M2）：与 App 共用 RetouchCore
import Foundation
import CoreImage
import Metal
import RetouchCore

let args = CommandLine.arguments
func arg(_ n: String, _ d: String) -> String {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return d
}
// 模型自检：分发包里模型到底有没有被找到（排查「为什么这套没走人脸解析」最先看这个）
// GPU/算力自检：这台机器上像素与模型分别跑在哪
// 提前退出的命令（各自内部 exit）——主体见 CLICommands.swift
if args.contains("--gpu-info") { cliGPUInfo() }
if args.contains("--model-check") { cliModelCheck() }
if args.contains("--help") || args.contains("-h") { cliHelp() }

// 主流程（批量调色 + 人像 + 导出）。放在函数里是为了让顶层只要"派发"这一件事；
// 声明成 throws 是必须的：原来这些 try 写在 main.swift 顶层（脚本语义允许），搬进函数后必须有 throws 兜住。
// 错误要**干净退出**：批处理"一张都没跑"必须非零退出（见 CLIError），
// 别让它变成未捕获错误那样带一堆栈信息地崩掉。
do {
    try runPipeline()
} catch {
    FileHandle.standardError.write(("错误：" + String(describing: error) + "\n").data(using: .utf8)!)
    exit(2)
}
