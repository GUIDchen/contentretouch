# M1 MVP：macOS App 外壳选型与任务拆解

> 对应里程碑 M1：套壳 GUI + 任务队列 + 命名/格式模板 + 转换。
> 本文记录选型决策（含环境证据）、已落地的骨架、以及剩余任务的验收口径。

## 1. 选型决策：Tauri v2（ADR-001）

### 1.1 环境实测（决策依据）

| 工具链 | 本机状态 | 对选型的影响 |
| --- | --- | --- |
| Rust / cargo | 1.97.1 已安装 | Tauri 可直接开工 |
| Node / pnpm | Node 24.19 / pnpm 11.22 | 前端与既有脚本零改造 |
| Swift / swiftc | 6.3.3（随 Command Line Tools） | 能写代码，但没有完整 Xcode |
| xcodebuild | 缺失（active dir 指向 CommandLineTools） | **无法构建/签名 macOS .app 包** |
| 磁盘可用 | 约 30 GB | 装 Xcode（7-10 GB）+ 模拟器会吃紧 |

### 1.2 决策

**采用 Tauri v2。**理由按权重排序：

1. **本机可立即构建**：Rust 工具链已就绪；SwiftUI 路线要先装完整 Xcode（数 GB、耗时长），当前环境连 xcodebuild 都没有。
2. **复用已验证资产**：M0 已经跑通了 tools/douyin/ 下的 Node 采集与下载脚本。Tauri 的 Rust 外壳可以直接把 node 当子进程拉起，脚本一行不用改；SwiftUI 侧则要写进程桥接与打包 Node 运行时的额外工作。
3. **包体与内存**：Tauri 静态资源走系统 WebView，包体 5-15 MB 量级，远小于 Electron 的 100 MB+。
4. **跨平台不额外花钱**：以后要 Windows 版同样是这套代码。

代价（如实记录）：WebView 渲染的原生感不如 SwiftUI；Rust 侧多一层学习成本；生态比 Electron 小。若日后要求「Mac 精品体验」且团队熟悉 Swift，可在 M3 之后重做 UI 层——引擎层与脚本层不需要动。

## 2. 架构（M1 落地形态）

    ┌──────────────── Tauri App（macOS） ────────────────┐
    │ 前端 html/（纯静态，无构建链）                       │
    │   index.html / app.js / style.css                  │
    │        │ invoke()                 ▲ job://log 事件  │
    │        ▼                          │                 │
    │ Rust 命令层 src-tauri/src/lib.rs                    │
    │   platforms()        平台清单（含难度与备注）        │
    │   session_status()   探测 CDP 端口是否就绪           │
    │   start_job()        拉起 node 脚本，逐行转发输出     │
    │   cancel_job()       杀子进程                       │
    │   open_path()        打开输出目录                   │
    │   convert()          magick / ffmpeg 转换任务        │
    └──────────┬──────────────────────────────────────────┘
               │ std::process::Command("node")
               ▼
    tools/douyin/*.mjs   采集 / 下载 / 补漏 / 索引（M0 已验证）
    tools/*.sh           浏览器拉起、命令 shim

关键设计：**Rust 侧不写业务**。它只负责「起进程、转发输出、管生命周期」，所有平台差异留在脚本里。新增平台 = 新增 collector 脚本 + 前端一个按钮。

## 3. 已落地（本次实际写入的文件）

| 文件 | 作用 | 状态 |
| --- | --- | --- |
| app/html/index.html | 四块界面：会话 / 平台 / 任务 / 日志 | 已写 |
| app/html/app.js | 调 invoke、监听 job://log 与 job://state | 已写 |
| app/html/style.css | 样式（浅色/深色自适应） | 已写 |
| app/src-tauri/src/lib.rs | 7 个命令 + 子进程管理 + 事件推送（294 行） | 已写 |
| app/src-tauri/Cargo.toml / build.rs / main.rs | Tauri v2 工程骨架 | 已写 |
| app/src-tauri/tauri.conf.json | frontendDist=../html、withGlobalTauri、resources 打包含脚本 | 已写 |
| app/src-tauri/capabilities/default.json | 只开 core:default，不开 shell/fs 插件 | 已写 |
| app/src-tauri/icons/icon.png | 占位图标（正式图标待设计） | 占位 |
| tools/convert.sh | 供 App 复用统一任务面板的 shim（launch_browser.sh 已于 v0.3.0 删除：App 直接拉起 Chrome，该 shim 从未被调用） | 已写 |
| app/README.md、app/package.json | 运行方式与脚本 | 已写 |

## 4. M1 任务拆解

| # | 任务 | 产出 | 验收口径 | 预估 | 依赖 |
| --- | --- | --- | --- | --- | --- |
| T1 | Rust 侧编译通过 | cargo check 无错误 | 命令与结构体全部编译通过 | 0.5 天 | 已启动验证 |
| T2 | 会话模块 | 一键拉起专用浏览器 + 登录态探测 + 多账号 profile 切换 | 冷启动到「会话就绪」绿灯；两个账号互不串号 | 1 天 | T1 |
| T3 | 任务队列 | 任务列表、状态、取消、并发上限（下载默认 2 窗口） | 同时排队 3 个任务不互相阻塞；取消能真正杀进程 | 1.5 天 | T1 |
| T4 | 选择式下载 | 清单预览（列表 + 缩略图 + 勾选）后再下载 | 可只下载勾选项；预览来自 M0 的 collect 结果 | 2 天 | T3 |
| T5 | 命名 / 目录模板 | 模板编辑器（作者/日期/标题/序号/扩展名） | 改模板后产物路径按模板落盘；非法字符自动清洗 | 1 天 | T3 |
| T6 | 元数据落库 | SQLite：作品ID、平台、标题、作者、文案、URL、本地路径、哈希 | 每个作品一行；重复下载只更新不新增 | 1.5 天 | T3 |
| T7 | 格式转换 | 保存后批量转 jpg/png/webp/mp3/mp4，任务面板可看进度 | 转完抽查文件有效；失败项单独列出 | 1 天 | T3 |
| T8 | 打包与分发准备 | 正式图标、Developer ID 签名、公证、DMG | 新机器双击可打开且不报「已损坏」 | 1.5 天 | 全部 |
| T9 | B站适配器（M2 前置试点） | 内置 yt-dlp sidecar + 扫码登录 | 用本人账号下载 10 个作品，元数据入库 | 3 天 | T3/T6 |

合计约 13 人日（不含 M2 其余平台）。

## 5. 验收标准（M1 何时算做完）

1. 打开 App，选平台 → 检测会话 → 一键采集清单 → 勾选 → 下载 → 生成索引，全流程不碰终端。
2. 输出目录、命名模板、目标格式三项均可配置并生效。
3. 任一任务失败时，界面能看到失败原因，且能一键重跑（复用补漏清单）。
4. 关闭 App 再打开，未完成任务可断点续跑（进度来自 manifest.csv）。
5. 产物与 M0 CLI 完全一致（可对比 manifest.csv 行数与 index.html 卡片数）。

## 6. 风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 平台页面改版 | 采集脚本失效 | 脚本与 App 解耦，用户可单独更新 tools/ 目录；App 内置版本提示 |
| 打包后脚本路径变化 | 找不到 tools/ | tauri.conf 已把 tools/** 作为 resource；Rust 侧 repo_root() 需在打包模式改为 resource 解析（T8 必办） |
| 大体量下载占满磁盘 | 用户磁盘告警 | 任务开始前检查可用空间，低于 10 GB 拒绝启动并提示 |
| 账号风控 | 临时限流/验证码 | 并发上限 2、随机间隔；遇到验证即暂停任务并弹提示，不自动重试 |
| 合规 | 上架与法律风险 | 只做本人账号资产；App Store 不作为分发渠道；隐私政策里写明「凭据只存本地」 |

## 7. 下一步（本次之后的第一件事）

跑通 T1（cargo check）→ 用 pnpm tauri dev 起界面 → 按 T2 做会话模块（把当前「启动专用浏览器」按钮升级为「扫码登录 + 就绪探测 + 多账号」）。

## 8. 本次实际验证结果（截至写这份文档）

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| Rust 侧可编译 | cd app/src-tauri && cargo check | 通过（仅剩无警告输出，Finished dev profile） |
| 资源打包路径 | 首次失败：glob ../tools/**/* 找不到，因为脚本在仓库根而非 app/ 下 | 改为 ../../tools/**/* 后通过 |
| 应用图标 | 首次失败：tauri 要求 RGBA，magick 默认生成 16bit RGB | 改成 PNG32 8bit 后通过 |
| 应用能启动 | cargo run | 通过，生成 33 MB debug 可执行文件并打开窗口 |
| 界面渲染 | screencapture 截图核对 | 通过：四个区块（会话 / 平台 / 任务 / 日志）全部正常显示 |
| IPC 双向通路 | 界面上的三张平台卡片（抖音 / B站 / 小红书，含难度标签与备注）是前端 invoke("platforms") 拿到的 Rust 返回值 | **证明命令层与前端已打通** |
| 会话探测与任务按钮 | 试图用 AppleScript AX 点击按钮 | 未验证：WKWebView 内的按钮不通过 AX 暴露，需要手动点击确认 |

未验证项（下次接手先做）：手动点一次「检测浏览器会话」「采集清单」，确认子进程拉起与日志流式输出在真实交互下正常。

## 9. T2 会话模块：已完成（含验证记录）

### 9.1 设计

一个账号 = 一个独立 user-data-dir + 一个独立调试端口。

- 多账号并行：两个 profile 同时开着，互不串号；切账号 = 切 profile，而不是反复登出登录
- 会话隔离：App 自己的 profile 目录（默认 ~/Library/Application Support/ContentHarvester/profiles/<id>），与用户日常浏览器分开
- 一键扫码：拉起浏览器时直接打开该平台的登录页（douyin / passport.bilibili.com / xiaohongshu.com）
- 就绪探测：调 tools/session_probe.mjs，借 CDP 读取 cookie 判定登录态，并给出**账号指纹**（session cookie 的 sha256 前 8 位）用于区分不同账号；不打印任何 cookie 明文

### 9.2 新增文件与命令

| 位置 | 内容 |
| --- | --- |
| app/src-tauri/src/session.rs | Profile 结构、profiles.json 持久化、Chrome 拉起、CDP 就绪判定、open_tab、probe（+3 个单元测试） |
| app/src-tauri/src/lib.rs | 新增命令：list_profiles / create_profile / remove_profile / launch_profile / probe_profile / open_in_profile |
| tools/session_probe.mjs | 会话探测脚本：--port，返回 cdp / 各平台登录态 / 指纹 / 有效期 |
| app/html/* | 会话区块重做：账号卡片（状态、端口、目录、登录态）、新建 / 拉起并登录 / 探测 / 打开收藏页 / 删除 |
| ~/Library/Application Support/ContentHarvester/profiles.json | 账号清单；首次启动自动把已登录的 ~/.dsh/douyin-profile 登记为「抖音主号」 |

### 9.3 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 探测脚本本身 | node tools/session_probe.mjs --port 9222 | 抖音已登录，指纹 d6467b43，有效期 2026-11-16，via sid_tt |
| Rust 单元测试 | cargo test --lib | 2 passed（seed profile、各平台登录页 URL） |
| Rust → node → CDP 全链路 | cargo test --lib -- --ignored --nocapture | passed：返回 cdp=true 且 douyin.loggedIn=true |
| 界面渲染 | 截屏 | 账号卡片正确显示「浏览器已运行 / 端口 9222 / 指纹状态位」 |
| 多账号隔离 | 另起 9223 + 全新 user-data-dir 再探测 | A（9222）已登录指纹 d6467b43；B（9223）未登录、仅 33 条匿名 cookie —— 证明账号互不串号 |
| 切换账号 | 设计上等价于切 profile；界面按 profile 选择任务端口 | 未做「一键热切换」按钮（当前为切下拉即可，属可选优化） |

### 9.4 仍未做（T2 的余项）

- profile 重命名 / 编辑主用平台（当前只在创建时指定）
- 登录态到期提醒（探测结果里已有 expires 字段，未做主动提醒）
- 凭据加密存储：当前依赖浏览器自身的 cookie 加密，App 不额外保存任何凭据（这是有意的设计）

## 10. T3 任务队列：已完成（含自检记录）

### 10.1 状态机

    queued --pump--> running --(exit 0)----> done
                               --(exit != 0)-> failed
                               --(kill)------> cancelled
    （cancelled 是终态：进程被杀后 waiter 线程不会把它覆写成 failed）

### 10.2 设计要点

| 点 | 做法 |
| --- | --- |
| 并发上限 | Hub 持有 max_concurrent（默认 2，可调 1-8）与 running 计数；每次提交与每次结束都调用 pump() 补位 |
| 排队 | 超出并发的任务进 VecDeque，状态为 queued；pump 按 FIFO 拉起 |
| 取消 | 排队中：从队列摘掉，状态置 cancelled；运行中：kill 子进程，状态置 cancelled |
| 失败重跑 | 每个 Job 保存自己的 spec，rerun 用原 spec 建一个新任务（旧记录保留便于对比） |
| 事件 | job://state 与 job://log 推给前端；emitter 是可选的，自检模式无需 GUI |
| 不自造轮子 | 任务脚本仍走 tools/ 下的 .mjs 与 .sh，Rust 只按扩展名选解释器（node / /bin/sh） |

### 10.3 自检：这个模块有可运行的验证

    cd app/src-tauri && ./target/debug/content-harvester --selftest

实测输出：

    1) 投 5 个任务 -> running=2 queued=3 max=2
       5 个任务结束，成功 5/5
    2) 取消运行中任务: 已终止（运行中） -> state=cancelled
    3) 排队快照 before={"max":2,"queued":1,"running":2} / after={"max":2,"queued":0,"running":2}；取消排队任务: 已取消（排队中） -> state=cancelled
    4) 失败任务 job-10 state=failed；重跑 -> 新任务 job-11 state=failed
    5) clear_finished 清理 11 条历史记录
    队列自检通过

**自检抓到并修掉的真 bug**：第一版在 waiter 线程里写成
`*hub.running.lock().unwrap() = hub.running.lock().unwrap().saturating_sub(1);`
——同一个表达式里对同一把 std::sync::Mutex 上两次锁，直接死锁，结果是前两个任务跑完后再也不补位，排队任务永远不动。自检第一次就报「等待超时，当前状态 done/done/queued/queued/queued」，改成先取锁再赋值后通过。这类问题只有真跑才会暴露。

### 10.4 未做（T3 余项）

- 任务持久化：App 重启后队列不恢复（进度仍由 manifest.csv 承担断点）
- 任务日志落盘：目前只在内存里保留最近 2000 行
- 超时控制：没有「单任务最长运行时间」，长任务只能手动取消

## 11. T4 清单预览与选择式下载：已完成

### 11.1 数据链路

    采集（collect.mjs，含封面/标题/点赞）
        -> preview.json { notes:[url], items:[{id,url,cover,title,likes}] }
        -> load_preview 标记「已下载」（比对 输出目录/manifest.csv）
        -> 界面筛选勾选（搜索 / 只看未下载 / 全选当前）
        -> download_selected：filter_list 写出 {notes:[url]} -> 交给 download.mjs 进队列
        -> 下载完成后刷新预览即可看到「已下载」标记

### 11.2 新增与改动

| 位置 | 内容 |
| --- | --- |
| tools/douyin/collect.mjs | 改为输出含封面与标题的 items；并修掉两处导致采集不全的问题（见 11.4） |
| tools/douyin/filter_list.mjs | 勾选 -> 下载清单；纯函数 pick()/downloadedIds() 可自检 |
| app/src-tauri/src/preview.rs | load / write_selection / select / normalize / downloaded_ids + 5 个单元测试 |
| app/src-tauri/src/lib.rs | 新增命令 load_preview / save_selection / download_selected |
| app/html | 新增「清单预览与勾选下载」区块：封面网格、勾选、搜索、筛选、全选、下载选中 |

### 11.3 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 勾选过滤逻辑 | node filter_list.mjs --selftest | 通过（勾选 / 排除已下载 / 空勾选=全选 / 已下载解析） |
| Rust 预览逻辑 | cargo test --lib | 7 passed（含 5 个 preview 测试：按 id 选、空选=全选、跳过已下载、URL 归一化、标注已下载） |
| 端到端「勾选 -> 下载」 | 真人操作路径的命令行等价物：filter_list 生成 2 条清单 -> download.mjs 下载 | 成功 2/2，落地 9 张图 |
| 采集器含封面 | node collect.mjs | 2019 条，每条带 id/url/cover/title/likes |

### 11.4 顺带修掉的两个采集器问题（重要）

1. **收藏页现在必须显式点一次「收藏」标签才会渲染网格**——旧脚本直接滚动拿不到任何卡片（本次实测：不点 = 0 条，点后 = 50 条起步）。
2. **只滚 window 不够**，必须同时滚内部滚动容器，否则永远停在第一页。

修完这两点后，同一台机器、同一个账号采集到 **2019 条**，而 M0 当时只采到 **1272 条**（默认列表 1031 + 收藏夹 241）。

对账结果：

| 项 | 数量 |
| --- | --- |
| 新采集清单 | 2019 |
| M0 清单 | 1272 |
| 两者交集 | 1026 |
| 只在 M0（收藏夹专有，新采集没遍历收藏夹） | 246 |
| 新采集多出 | 993 |
| 其中已下载（说明 M0 确实抓过） | 1028 |

**结论：M0 报告里的「1272 / 1272 = 100%」只对 M0 自己那份清单成立，不等于「收藏里全部图文」。**改进后的采集器还能多拿到 993 条，其中一部分可能是 M0 未滚到底，也可能混入了别的列表（例如「喜欢」），需要再核对归属；T4 的预览界面正是为这种核对准备的：先看清单、再勾选。

### 11.5 未做（T4 余项）

- 缩略图是抖音的签名封面 URL，会过期；长期本地预览需要在下载后改用本地文件生成缩略图
- 预览网格目前最多渲染 120 条（靠搜索/筛选收窄），未做虚拟滚动
- 未做「按作者/时间/点赞」排序

## 12. 993 条多出条目的归属核对：结论已确定

用封面 URL 的来源标记做了数据归因（抖音在封面链接里带 s=PackSourceEnum_xxx）：

| 集合 | 条数 | 封面来源标记 |
| --- | --- | --- |
| 新采集的收藏清单 | 2019 | PackSourceEnum_COLLECTION（全部） |
| 其中 M0 已有的 | 1026 | PackSourceEnum_COLLECTION |
| 其中 M0 没有的「多出条目」 | 993 | PackSourceEnum_COLLECTION |
| 另外单独采集的「喜欢」标签 | 91 | PackSourceEnum_FAVORITE |

- 多出的 993 条与「喜欢」清单的交集 = 0 条
- 页面内抽查：任取一条多出条目，确认它出现在「我的 -> 收藏」页面上

结论：993 条确实是收藏内容，不是从别的列表混进来的。M0 当时漏采的原因是页面结构变化——收藏网格必须显式点一次「收藏」标签才会继续加载，旧脚本没点，滚动到第一页后就停了。所以 M0 的「1272 / 1272 = 100%」只对那份清单成立；对照真实收藏，覆盖率约 1272 / 2019 = 63%（若把收藏夹里的 246 条也算进口径，则 1272 / 2265 = 56%）。

## 13. T5 命名与目录模板：下载器侧已完成并验证，App 侧待接

### 13.1 模板语法

    变量：{id} {title} {author} {date} {seq}
    目录模板示例：by-author/{author}      结果：images/by-author/摄影师春树/
    命名模板示例：{date}_{title}          结果：2026-09-17_新中式晨袍｜被这抹红拿捏住了✨。#婚礼新中式造型 #新娘旗袍_05.webp
    默认：目录模板为空、命名模板 {seq}_{id}  结果：images/0001_7686437103396019121_05.webp

规则：模板里的斜杠表示目录层级；每个路径片段单独清洗（去掉路径分隔符、冒号、星号、问号、引号、尖括号、竖线与控制字符，折叠空格，去首尾点，限长 60，空则回退）；未知变量原样保留。

### 13.2 已实现（tools/douyin/download.mjs）

| 能力 | 说明 |
| --- | --- |
| --dir-template | 目录模板，为空则仍写 images/ 根目录 |
| --name-template | 命名模板，文件名 = 渲染结果 + 下划线两位图片序号 + 扩展名 |
| --dry-run | 只打印将要写入的路径，不下载（用于预览命名效果） |
| --selftest | 模板渲染 / 清洗 / 多级目录 / 未知变量 的自检 |

### 13.3 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 模板渲染自检 | node download.mjs --selftest | 通过：默认 0001_7686_03.webp；模板 by-author/IT摄影/2026-09-06_新中式晨袍..._01.jpg；非法字符与超长截断均正确 |
| 真实页面 dry-run | --dry-run --force 对两条真实笔记 | 打印 images/by-author/摄影师春树/2026-09-17_新中式晨袍…_05.webp，作者与日期均正确提取 |
| 采集字段 | 笔记页取作者（排除 /user/self 的「我的」）与发布时间 | 作者=摄影师春树，日期=2026-09-17 |

### 13.4 顺带修掉的一个隐蔽 bug

EXTRACT 是 JS 模板字符串，新写的正则用了单反斜杠（反斜杠 s、反斜杠 d、反斜杠 n），模板字符串会把它吃掉——其中反斜杠 n 直接变成真实换行，导致页面里的正则字面量断裂、求值抛错，而轮询逻辑把异常吞掉后表现为「未取到图片」。修法：模板字符串内的正则一律写双反斜杠。这个 bug 只在真跑时才暴露。

### 13.5 App 侧接线（本轮已完成）

- 命令层：download_selected 增加 dirTemplate / nameTemplate / dryRun 三个可选参数；参数拼装下沉为 preview::download_args 纯函数
- 界面：预览区块新增「目录模板」「命名模板」两个输入框与「预览命名」按钮（dryRun=true 时自动带 --dry-run --force，看到全部路径）
- 单元测试：download_args_with_and_without_templates 覆盖「无模板 / 有模板 / 空白模板忽略 / 预览带 force」

验证：cargo test --lib -> 8 passed（含该测试）；cargo build 通过；node --check app/html/app.js 通过。

### 13.6 尚未完成（T5 剩余）

- 未做「按模板预览整批路径」的批量预览（当前预览走队列日志，逐条打印）
- 收藏夹（folder）采集尚未纳入新的列表结构，仍是单独脚本
- 模板变量还没有 {likes} {platform} 等扩展项

## 14. T6 作品元数据落库：已完成

### 14.1 表结构（SQLite，用 Node 24 自带 node:sqlite，无第三方依赖）

    works    作品主表：id(PK) / platform / url / title / author / publish_date / likes / cover
             / list_source / image_count / downloaded / first_seen_at / updated_at
    assets   图片明细：(work_id, seq) 联合主键 / file / bytes / url / created_at
    folders  收藏夹归属：(work_id, folder) 联合主键
    runs     入库流水：kind / source / added / updated / assets / at

索引：works(author)、works(downloaded)、assets(work_id)。库文件放在产物目录：<out>/library.db，跟着数据走。

### 14.2 增量与去重规则

| 场景 | 规则 |
| --- | --- |
| 同一作品重复入库 | 主键冲突走 UPDATE，只刷新元数据与 updated_at，不产生重复行，也不改 first_seen_at |
| 预览清单入库 | 允许用非空值覆盖（列表页的标题最新） |
| manifest 入库 | 只填空字段，绝不覆盖已有值（manifest 里的标题/作者是历史数据） |
| 图片明细 | 按 (work_id, seq) upsert，重下同一张只更新路径与字节数 |
| 脏值 | 导航栏文字（我的/关注/粉丝…）一律视为空；标题里的「- 抖音」后缀剥掉 |

### 14.3 命令

    node tools/douyin/library.mjs --db <library.db> --init
    node tools/douyin/library.mjs --db <library.db> --ingest-preview <preview.json> [--list-source collection]
    node tools/douyin/library.mjs --db <library.db> --ingest-manifest <out>/manifest.csv
    node tools/douyin/library.mjs --db <library.db> --fix-bad
    node tools/douyin/library.mjs --db <library.db> --stats [--json]
    node tools/douyin/library.mjs --db <library.db> --find <作品id>
    node tools/douyin/library.mjs --selftest

App 侧：一条命令 library_sync（submit 到任务队列）跑 tools/library_sync.sh 全流程，另加只读的 library_stats 供界面显示。

### 14.4 真实入库结果（本机实测）

| 指标 | 数值 |
| --- | --- |
| 作品总数 | 2265（= 预览 2019 + 预览里没有的 246 条收藏夹作品） |
| 已下载 | 1274 |
| 待下载 | 991 |
| 图片明细 | 12278 条（去重后） |
| 体积 | 4244.2 MB |
| 作者 | 1 位（原因见 14.5） |

### 14.5 两个必须记下来的发现

1. 作者字段几乎全缺：M0 当时的作者提取取到了导航栏的「我的」，本次把这类脏值全部清空（1274 条），标题也清了 61 条。修复后的提取器（T5）已经能把作者取对；已经重下的那条笔记已回填为「摄影师春树」。历史条目的作者需要重下或专门补采。
2. manifest 是脏数据的来源：历史 manifest 里作者=「我的」、标题带「- 抖音」。所以 manifest 入库被刻意限制为「只填空不覆盖」，避免脏值盖掉预览里的干净标题。

### 14.6 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 库逻辑自检 | node library.mjs --selftest | 通过：重复入库只更新、空值不覆盖、脏作者被拒、图片明细去重、统计口径正确 |
| 真实入库 | library_sync.sh 对真实数据跑全流程 | 2265 作品 / 12278 明细 / 4244.2 MB，二次运行 0 新增（幂等） |
| 单条查询 | library.mjs --find <id> | 返回作品字段 + 7 条图片明细路径 |
| Rust 侧 | cargo test --lib | 8 passed |
| 编译 | cargo build | 通过（新增 library_sync / library_stats 两个命令） |

### 14.7 环境事故记录（重要）

本轮中途项目目录被改名：会话工作目录是 .../dsh-xiuti，而实际项目在 .../dsh-xiutu（多一个 u）。改名瞬间我写的两个文件落到了旧路径，导致后续 read/glob 报「文件不存在」。处理方式：确认两处内容后，把 tools/douyin/library.mjs 与 tools/library_sync.sh 复制回真实项目并重新自检通过。结论：数据没有丢失，但后续所有操作都应使用绝对路径 .../dsh-xiutu，不要依赖会话 cwd。

### 14.8 未做（T6 余项）

 - 作者补采：对历史 2264 条做一次专门的作者回填（需要逐条打开笔记页，成本较高）
 - 元数据导出：从库里导出 CSV / JSON 供外部使用
 - 界面区块（元数据库统计）未截图确认（osascript 辅助功能权限仍被拒）

## 15. T7 格式转换：已完成

### 15.1 能力

| 项 | 说明 |
| --- | --- |
| 目标格式 | jpg / png / webp（图片，走 magick）、mp3 / m4a（抽音轨，走 ffmpeg） |
| 输入扫描 | 递归扫描目录；jpg/png/webp 互转，音频从 mp4/mov/webm 抽取；已是目标扩展名的自动跳过 |
| 输出位置 | 默认原地（只新增目标文件），--out 可输出到别处并保持相对目录结构 |
| 幂等 | 目标文件已存在则跳过，--force 才重转 |
| 源文件 | **默认保留**；只有显式 --replace 才删除（不可逆操作不设默认） |
| 进度 | 逐条打印：[序号/总数] OK 相对路径 -> 文件名 大小KB |
| 失败清单 | 失败写入 <目录>/convert_failed.txt（源路径 + 原因），有失败时退出码 1 |
| 试运行 | --dry-run 只列出将要转换的文件 |

### 15.2 命令与 App 接线

    node tools/douyin/convert.mjs --dir <目录> --to jpg [--quality 92] [--out <目录>] [--force] [--dry-run] [--replace]
    node tools/douyin/convert.mjs --selftest

App 侧：convert 命令改为调用 convert.mjs（不再用拼 shell 字符串的老实现），参数拼装下沉为 convert::build_args 纯函数；界面新增「质量」输入与「预览将要转换的文件」按钮，提交后走统一任务队列，进度显示在日志面板。

### 15.3 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 转换器自检 | node convert.mjs --selftest | 通过：3 成功 / 1 坏文件被记入失败 / 已存在则跳过 / 默认保留源文件 / --replace 才删源 |
| 真实目录试运行 | --dry-run 对 by-author 目录 | 正确列出 7 个待转换文件与目标路径 |
| 真实转换 | 7 个 webp -> jpg（输出到临时目录） | 成功 7/7，产出 5.8 MB，耗时 1.1 s |
| 源文件安全 | 转换后检查 | 7 个 webp 全部保留 |
| 产出有效性 | file 命令 | JPEG image data（有效） |
| Rust 参数拼装 | cargo test --lib | 11 passed（新增 3 个 convert 用例） |

### 15.4 设计取舍

1. 源文件默认保留：转换是「复制并转码」，不是「替换」。批量误删原始素材不可逆，因此把删除做成显式开关。
2. 失败不中断：单个文件失败只记清单继续跑，最后用退出码表达结果，方便在任务队列里看到「完成但有失败」。
3. 不做转码之外的加工：不裁剪、不调色、不改名——那些属于上游环节（T5 命名模板负责改名）。

### 15.5 未做（T7 余项）

 - 并行转换：目前是单进程顺序执行（1.1 s / 7 张，暂不构成瓶颈；上千张时可加工作池）
 - 失败重试：失败清单已产出，但没有「只重跑失败项」的入口（可直接用 --force 重跑整个目录）
 - 视频转码（mp4/hevc）尚未接入，目前只做抽音轨

## 16. T8 打包与分发：本机能做的都做完并验证了

### 16.1 结论先给

本机 **没有 Developer ID 证书，也没有公证凭据**（security find-identity 显示 0 valid identities），所以「签名 + 公证」这两步无法在此机器执行。能做且已经做完的是：正式图标、打包配置、entitlements、打包脚本、失败时的明确中止、以及**未签名包能否真正跑起来**的验证。

### 16.2 已完成

| 项 | 结果 |
| --- | --- |
| 正式图标 | magick 生成 1024 RGBA 源图（蓝紫渐变 + 下载箭头）；派生 icon.icns（89 KB）+ 32/128/128@2x/1024 PNG；已接入 bundle.icon |
| 打包 | pnpm tauri build（Tauri CLI 2.11.4）产出 ContentHarvester.app 与 ContentHarvester_0.1.0_aarch64.dmg |
| DMG 校验 | hdiutil verify 通过（CRC32 有效），体积 1.8 MB |
| Info.plist | CFBundleName=ContentHarvester、CFBundleShortVersionString=0.1.0、CFBundleIconFile=icon.icns、LSMinimumSystemVersion=11.0 |
| entitlements | app/src-tauri/entitlements.plist：JIT、unsigned executable memory、disable library validation、network client（因为要拉外部进程与浏览器） |
| 签名脚本 | tools/dist/sign_and_notarize.sh：codesign（硬化运行时 + 时间戳 + entitlements）-> notarytool submit --wait -> stapler staple -> spctl / stapler validate |
| 分发文档 | docs/分发与签名指南.md：证书获取、两种公证凭据（Apple ID 专用密码 / API Key）、常见坑、渠道对比、验收清单 |

### 16.3 打包后才发现并修掉的两个真问题

1. **脚本没有被正确放置**：resources 原本写成 ../../tools/**/*，Tauri 把 ../ 编码成 _up_，脚本落到 Contents/Resources/_up_/_up_/tools/。改成映射形式 { "../../tools": "tools" } 后变成干净的 Contents/Resources/tools/。
2. **从 Finder 启动会找不到 node / magick / ffmpeg**：GUI 启动的 App 只有 /usr/bin:/bin:/usr/sbin:/sbin，而 node 在 /opt/homebrew/bin。新增 app/src-tauri/src/tools.rs：把所有外部命令解析成绝对路径（/opt/homebrew/bin 优先），并给子进程补一份 PATH；同时 find_root() 增加「打包态退回 Contents/Resources」的分支（并兼容旧的 _up_ 布局）。

### 16.4 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 产物存在 | pnpm tauri build | .app 与 .dmg 均已产出 |
| DMG 完整性 | hdiutil verify | checksum is VALID |
| 包结构 | find + PlistBuddy | Contents/MacOS、Resources、Info.plist 字段正确 |
| 签名状态 | codesign -dv | adhoc, linker-signed（未签名，符合预期） |
| 资源布局 | ls Resources | tools/ 目录就位（不再是 _up_） |
| 打包态路径解析 | env -i PATH=/usr/bin:/bin 从 /tmp 执行 --where | 脚本根目录指向 App 内 Resources；node/magick/ffmpeg 均解析为绝对路径 |
| 打包态功能 | 同一环境下跑 --selftest | 队列自检通过 |
| 签名脚本失败路径 | 无证书直接执行 | 明确中止并打印现有身份，不会产出「看起来成功」的包 |
| 单元测试 | cargo test --lib | 13 passed |

### 16.5 需要证书才能做的（未做，步骤见分发文档）

 - Developer ID Application 证书导入钥匙串
 - codesign 签名与公证（notarytool）
 - stapler 装订票据 + spctl 校验
 - 在第二台干净 Mac 上的安装验证

### 16.6 分发形态建议

| 渠道 | 建议 | 理由 |
| --- | --- | --- |
| 官网 / 自建 DMG | 推荐 | Developer ID + 公证即可，无审核 |
| Homebrew Cask | 可行 | 适合开源与自动化安装 |
| Mac App Store | 不建议 | 下载第三方内容属典型拒审理由，且沙盒限制外部进程 |
