# 调研：做一款 macOS 端「多平台内容收集」App 是否可行

> 目标形态：登录指定账户（抖音 / 小红书 / B站 等）-> 选择性下载图片、视频、作品信息与文案 -> 按指定格式保存，保存后可转换格式。
> 结论先说：**可行**，但必须分层取舍——通用站点交给成熟引擎，重签名/重风控的平台做专门适配，且上架 App Store 基本不可行。

## 1. 结论摘要

| 判断 | 内容 |
| --- | --- |
| 技术可行性 | 高。单平台（B站）几乎零风险；抖音 / 小红书需要持续跟签名算法 |
| 最大风险 | 不是开发，而是平台签名与风控的持续变动，以及账号安全与合规 |
| 推荐架构 | yt-dlp / gallery-dl 作通用引擎 + 平台适配器（含浏览器登录态复用）+ 本地库 + UI |
| 推荐 UI 栈 | Tauri v2（跨平台、体积小、可复用现有 Node/Python 逻辑）或 SwiftUI（体验最好、仅 macOS） |
| 分发方式 | Developer ID 签名 + 公证，官网 / 自建分发；App Store 大概率被拒 |

## 2. 各平台接入难度与现实做法

| 平台 | 现状 | 现实做法 | 风险 |
| --- | --- | --- | --- |
| B站 | 官方 API 相对开放，扫码登录成熟 | BBDown（命令行，另有 Rust 版）/ yt-dlp 直接支持；扫码登录拿 cookie | 低 |
| 抖音 | Web 接口需 a_bogus / X-Bogus 签名，版本频繁变动 | 三条路：① yt-dlp 支持部分抖音链接；② 复用已登录浏览器会话（本项目路线）；③ 社区签名实现（douyin_sign 等，需跟版维护） | 中高 |
| 小红书 | Web 需 x-s / x-t 签名，社区有 TS 实现（xhshow-js）与 XHS-Downloader | 登录态复用 + 成熟开源采集器；搜索 / 收藏等签名接口风险最高 | 高 |
| YouTube / TikTok 等 1900+ 站点 | yt-dlp 生态成熟 | 内置 yt-dlp 作为 sidecar | 低 |

可复用的开源件（调研到，可组合进 App）：

- yt-dlp / gallery-dl：通用站点引擎，一套命令覆盖视频与图集。
- BBDown（含 Rust 版）：B站专用，扫码登录、充电视频、合集。
- XHS-Downloader（JoeanAmier / Gavin-Zhangg 等分支）：小红书作品采集与信息提取。
- Douyin_TikTok_Download_API（Evil0ctal）：自托管 REST API + MCP，抖音 / TikTok 采集。
- douyin_sign / xhshow-js：抖音、小红书 Web 签名实现（跟版维护）。
- 另有把多平台下载封装为 GUI/CLI 的项目（如 video_downloader、ClipVault）可参考其登录与队列设计。

安全提醒：调研中发现 Douyin_TikTok_Download_API 旧版本（<= 4.1.2）存在 SSRF 漏洞（CVE-2026-85608）。引入任何第三方服务组件前必须审代码、锁版本、隔离网络。

## 3. 推荐架构

    ┌────────────────────────── UI 层 ──────────────────────────┐
    │ 登录态管理 · 任务队列 · 下载进度 · 选择与筛选 · 格式与命名模板 │
    └──────────────▲───────────────────────────────▲────────────┘
                   │ 结构化事件(JSON over stdio/HTTP) │
    ┌──────────────┴─────────── 引擎层 ─────────────┴────────────┐
    │ 通用引擎: yt-dlp / gallery-dl（内置二进制，解析进度 JSON）    │
    │ 平台适配器: bilibili / douyin / xiaohongshu …（各自 collector）│
    │ 会话层: 内置 WebView 扫码 -> Cookie 注入到独立 profile        │
    └──────────────▲───────────────────────────────▲────────────┘
                   │                                │
    ┌──────────────┴────────── 数据层 ─────────────┴────────────┐
    │ SQLite: 平台/作品ID/标题/作者/文案/URL/本地路径/哈希/状态     │
    │ 文件库: 原始文件 + sidecar JSON 元数据 + 缩略图              │
    │ 转换: ffmpeg（视频/音频）、magick 或 vips（图片格式）         │
    └───────────────────────────────────────────────────────────┘

要点：

- 会话层用内置 WebView 扫码登录，不要把「导 cookie」丢给用户；登录态存 App 自己的 profile，与系统浏览器隔离——这正是本项目验证过的路线。
- 适配器只负责「拿到干净的资源 URL + 元数据」，下载、去重、命名、转码全部下沉到公共层，避免每个平台重复造轮子。
- 进度解析：yt-dlp 用 --newline 与 --progress-template 输出可解析进度，不要去截取终端 UI。

## 4. 技术栈对比（2026 视角）

| 维度 | SwiftUI（Swift 6） | Tauri v2 | Electron |
| --- | --- | --- | --- |
| 体验 / 原生感 | 最好（原生控件、低内存） | 较好（WebView 渲染） | 一般 |
| 安装包体积 | 最小（几 MB） | 小（约 5-15 MB + sidecar） | 大（100 MB+） |
| 复用已有 JS/Python 逻辑 | 差（需桥接） | 好（Rust 侧可跑 sidecar） | 最好（直接 Node） |
| 内置 WebView 登录 | WKWebView 原生，最顺 | 可用系统 WebView | 自带 Chromium（也可复用 CDP） |
| 多平台扩展 | 仅 Apple 生态 | Win / macOS / Linux 一套代码 | 同左 |
| 适合本项目的点 | 想要「精选 Mac 应用」体验 | 想快速复用已验证的 Node 脚本 | 团队全是前端时 |

建议：

- 只做 macOS、追求体验 -> SwiftUI + 内置 yt-dlp / ffmpeg sidecar（WebView 扫码，进度用 Process + Pipe 解析）。
- 想快速出活并可扩 Windows -> Tauri v2 + Rust 外壳 + 复用 Node/Python 采集脚本；本项目已有的 cdp.mjs / download.mjs 几乎可原样作为 sidecar 运行。
- Electron 仅在团队全是前端时选，代价是体积与内存。

## 5. 功能到实现的落点

| 需求 | 实现方式 |
| --- | --- |
| 登录指定账户 | 内置 WebView 打开平台登录页 -> 扫码或账密 -> Cookie 存 App 私有 profile（支持多账号） |
| 选择下载内容 | 列表页批量勾选（先收集链接清单，同本项目做法）+ 按类型过滤（图文 / 视频 / 合集） |
| 图片 + 文案 + 作品信息 | 详情页 DOM 或平台接口取标题、作者、发布时间、正文、话题、点赞等，落 SQLite + sidecar JSON |
| 指定格式保存 | 命名模板（平台/作者/日期_标题_序号.扩展名）+ 目录模板 + 元数据外挂（JSON / CSV） |
| 保存后转换 | ffmpeg（转 mp4 / hevc、抽音频）、vips 或 magick（webp 转 jpg/png、缩放、压质量） |
| 增量与去重 | 作品 ID 唯一索引 + 文件哈希；重复只更新元数据，不重复下载 |

## 6. 合规、分发与账号安全

1. App Store 基本走不通：下载第三方平台内容属于典型被拒理由，沙盒也限制外部进程。现实分发是 Developer ID 签名 + 公证 + 官网 / DMG。
2. 只下载你有权获取的内容：自己账号的收藏、自己发布的作品没问题；批量抓取他人内容再分发有法律风险。App 内应内置提示，并可提供「仅本人账号资产」模式。
3. 不绕过 DRM、不破解付费内容；不做验证码绕过——遇到验证即交还用户人工完成。
4. 账号安全：cookie 绝不上传服务端；本地加密存储；不要做「共享账号池」这类设计。
5. 签名算法属于灰色地带：跟版维护 a_bogus / x-s 有风险，这也是「优先复用登录态、少碰签名接口」更稳的原因。

## 7. 建议里程碑

| 阶段 | 内容 | 预估 |
| --- | --- | --- |
| M0 验证 | 用已验证的 CDP 路线做出可用 CLI：登录 + 单平台下载 + 元数据 | 已完成（抖音，1272 条 / 12269 张） |
| M1 MVP | 套壳 GUI + 任务队列 + 命名/格式模板 + ffmpeg/magick 转换 | 2-4 周 |
| M2 多平台 | 接入 B站（BBDown / yt-dlp）-> YouTube / TikTok（yt-dlp）-> 小红书 / 抖音（适配器） | 1-2 个月 |
| M3 体验 | 库管理（搜索 / 筛选 / 预览）、增量同步、断点续传、失败重试面板 | 2-4 周 |
| M4 分发 | Developer ID 签名 + 公证 + 自动更新（Sparkle 或 Tauri updater） | 1 周 |

## 8. 给本项目的直接建议

1. 别从零写下载引擎：UI 外壳 + yt-dlp / gallery-dl + 平台适配器是最小成本路线（本项目甚至没写引擎，只用 CDP + fetch 就完成了 12269 张图的采集）。
2. 把「会话」当一等公民：扫码登录 + 私有 profile + 多账号隔离，比任何签名逆向都稳定，也更容易过合规审查。
3. 先做「本人账号资产」场景（收藏 / 喜欢 / 自己作品）：合法、需求真实、风控最轻。
4. 对签名接口做隔离：凡是需要签名的能力，封装成独立可替换模块并标记「可能随平台变动」，避免一处失效拖垮整个 App。
5. 一行行验证，别信玄学：本项目的两个教训（后台标签不加载懒加载图、URL 拼接写错）说明——先跑 10 条、看数据、再放量，比一口气写 3000 行更省时间。

## 9. 参考来源（调研中实际查阅）

- yt-dlp / gallery-dl 支持站点与多平台下载工具项目（GitHub：zyipeng/video-downloader、higashitaniyume/video_downloader、kylesean/ClipVault）
- BBDown（github.com/AliverAnme/BBDown、Joey-Project/BBDown-rust）
- XHS-Downloader（github.com/JoeanAmier/XHS-Downloader、Gavin-Zhangg/XHS-Downloader）
- Douyin_TikTok_Download_API（github.com/Evil0ctal/Douyin_TikTok_Download_API）及其 SSRF 公告（vuldb.com/vuln/398825）
- 抖音签名实现（github.com/brock7/douyin_sign、7452323/douyin-sign）
- 小红书签名库（github.com/renmu123/xhshow-js）
- Apple 开发者文档：Developer ID、macOS 分发、公证（developer.apple.com）
- Tauri v2 与 Electron 的工程对比文章（dev.to、blog.gitcode.com 等）
