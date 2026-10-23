// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ContentRetouch",
    platforms: [.macOS(.v14)],
    targets: [
        // 核心：度量 / 参数 / 出图 / 闭环 / 参考库检索（可被 CLI 与 App 共用）
        .target(name: "RetouchCore"),
        // 命令行闭环（M2）
        .executableTarget(name: "retouch-cli", dependencies: ["RetouchCore"]),
        // 图形界面（M3）
        .executableTarget(name: "ContentRetouch", dependencies: ["RetouchCore"]),
        .executableTarget(name: "coretest", dependencies: ["RetouchCore"]),
        // 临时探针：调试/校准用，不属于产品
        .executableTarget(name: "probe", dependencies: ["RetouchCore"]),
        // AI 挑图（近似）
        .executableTarget(name: "pick-cli", dependencies: ["RetouchCore"]),
    ]
)
