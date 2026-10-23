# M3：SPM 工程 + 四区界面

## 1. 工程结构（已建）

    app-retouch/
      Package.swift                        三个 target：RetouchCore（库）/ retouch-cli / ContentRetouch（GUI）
      Sources/RetouchCore/RetouchCore.swift  度量 / 参数 / 出图 / 闭环 / 风格与索引 / 推荐 / 写盘
      Sources/retouch-cli/main.swift         M2 的命令行闭环（现在与 App 共用同一份核心）
      Sources/ContentRetouch/ContentRetouchApp.swift  四区界面
      build_app.sh                          打包成 dist/ContentRetouch.app

**为什么抽 RetouchCore**：M2 的命令行、M4a 的检索、M3 的界面，三处用的是同一套度量与出图逻辑。
抽成库之后只有一份实现，CLI 与 App 不会各走各的。

## 2. 四区界面（照像素蛋糕实测的骨架）

    ┌ 顶栏：智能修图 / 参考组名 · 批量导出 ─────────────────────────────┐
    ├ 左竖排 ┬──────── 画布 ────────┬ 窄栏 ┬ 参数面板 ────────────────┤
    │ 适合   │  原图   ｜   效果    │ 参考组│ 参考组列表（6 种风格）      │
    │ 看效果 │  （单图/对比可切）    │ 参数  │ gamma / 抬黑 / 降饱和 各带 ↺ │
    │ 单图   │                      │ 队列  │ 高光暖 / 阴影暖 / 本图度量   │
    │ 重置   │                      │       │                             │
    ├────────┴──────────────────────┴───────┴─────────────────────────────┤
    │ 底栏：载入示例 · 选择原片 · 选择文件夹批量 · 状态（误差 / 人脸数）    │
    └─────────────────────────────────────────────────────────────────────┘

落地了复查清单里的几件事：

- **滑杆带单条复位 ↺**（像素蛋糕的交互细节，直接照做）；
- **原图 ↔ 效果切换**、单图 ↔ 对比；
- **参考组选择**直接读 style_report.json；
- **参数面板区分来源**：风格项来自参考组、安全项（曝光/gamma）按本图自适应；
- **批量结果表**列出逐张「误差 before → after」与「未套用」标记；
- **人脸计数**：进入界面即测，为下一步「参数按脸组织」铺路。

## 3. 打包

    sh app-retouch/build_app.sh release
    → dist/ContentRetouch.app（GUI + CLI 一起打进去，ad-hoc 签名）

## 3.5 界面已确认可用（用户手动打开验证）

我把窗口截图补上了（docs/shots/M3_四区界面.png，2240×1504）：顶栏、左竖排（含「2 张脸」）、
原图/效果对比画布、右侧参考组列表（6 种风格带统计）、底栏状态「误差 0.830 · 检测到 2 张脸」全部正常。
之前抓不到窗口是**我的截图只拿到当前 Space**，不是代码问题。

**但同一天的色彩管理校验抓到一个真 bug（见 M3_色彩管理校验_发现与修复状态.md）**：
恒等参数渲染比原图亮约 13 级，判断是读图没按 sRGB 打标签导致的双重伽马，**尚未修完**。

## 4. 验证情况（如实）

| 项 | 结果 |
| --- | --- |
| swift build -c release | 通过（ContentRetouch 551 KB / retouch-cli 237 KB） |
| CLI 回归 | 通过：与 M2 独立版本数字一致（wedding_01 误差 1.109→0.523，3 张 0.3 秒） |
| .app 打包 + 签名 | 通过 |
| **GUI 窗口** | **未确认**：进程启动、无崩溃、无日志，但我的自动化截图没抓到窗口 |

关于窗口这条，我做了两次尝试：① 把 `main.swift` 改名为 `ContentRetouchApp.swift`（`@main` 在 main.swift 里不生效）；
② 加 AppDelegate 设 `setActivationPolicy(.regular)` + `activate`。两次之后进程仍在跑但窗口未出现；
同时这台机器上窗口分散在多个 Space，截图只能拿到当前 Space，**所以也可能是窗口在另一个 Space 而我没抓到**，
不排除是我的验证手段问题而不是代码问题。

**请你手动双击 dist/ContentRetouch.app 看一眼**：

- 如果窗口正常出现 → 那就是我截图没抓到，M3 界面直接可用；
- 如果确实不出窗口 → 这是 SPM 可执行文件做 GUI 的已知坑，改用 Xcode 的 macOS App 模板生成工程壳
  （把 Sources 里的同一份代码拖进去），或显式调用 NSApplicationMain。
