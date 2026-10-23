# 在 Xcode 里开发界面（推荐路线：SPM 骨架 + Xcode 调界面 + 脚本交付）

## 为什么不是「三选一」

| 工具 | 用在哪 |
| --- | --- |
| **SPM / 命令行** | 核心库 `RetouchCore` 与三个命令行工具（`retouch-cli` / `pick-cli` / `coretest`）。编译快、可脚本化、**23 项功能的验证全走这条路** |
| **Xcode** | **界面**：SwiftUI Preview、断点调试、Instruments、签名归档 |
| **VSCode / 任意编辑器** | 写核心代码够用（Swift 插件 + SourceKit-LSP），但没有 Preview/Instruments，调界面难受 |

## 怎么开

    Xcode → File → Open → 选 app-retouch 目录（含 Package.swift）

Xcode 原生支持打开 SPM 包，会直接列出四个 target：

    RetouchCore（库）· retouch-cli · pick-cli · ContentRetouch（GUI）· coretest（验证）

选 scheme `ContentRetouch` 按 ▶ 就能跑界面，改 SwiftUI 代码可实时看 Preview。

## 跑之前设一个环境变量（可选但推荐）

界面默认从源码树读参考库与风格报告。若在 Xcode 里跑且想换数据目录：

    Scheme → Edit Scheme → Run → Arguments → Environment Variables
    DSH_XIUTU_ROOT = /Users/you/Documents/DeepSeek-Harness-Projects/dsh-xiutu

（代码里的优先级：环境变量 → UserDefaults → 源码树默认路径。）

## 交付仍然走脚本

    sh app-retouch/build_app.sh release                      # 出 .app（Info.plist 最低系统 14.0）
    hdiutil create -volname ContentRetouch -srcfolder dist/ContentRetouch.app -ov -format UDZO dist/ContentRetouch_0.1.0_aarch64.dmg
    tools/dist/sign_and_notarize.sh dist/ContentRetouch.app   # 拿到 Developer ID 后签名+公证

**不建议**为了用 Xcode 去生成 .xcodeproj：手写工程文件不可维护，而 Xcode 本来就能直接打开这个包。

## 最该用 Xcode 补的三件事（这一轮的痛点）

1. **界面手势的端到端验证**：液化笔刷落点、裁剪框拖拽、抓手平移——自动化测不了，Preview + 断点能看
2. **性能与内存**：批量 500 张的峰值内存、长时间运行的泄漏（Instruments）
3. **签名与公证**：Xcode 的 Archive + Organizer 比手写脚本稳
