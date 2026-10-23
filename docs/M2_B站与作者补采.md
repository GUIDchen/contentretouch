# M2：B站接入与历史作者补采

> 目标：把「多平台」从口号变成第二条可跑通的生产线，并还掉 M0 留下的作者数据债。

## 1. B站接入的三件套

| 工具 | 作用 | 依赖 |
| --- | --- | --- |
| tools/bilibili/collect.mjs | 复用浏览器登录态，在页面内直接调 B站官方 API（同源带 cookie），采集收藏夹与稍后再看清单 | CDP 会话 |
| tools/bilibili/cookies.mjs | 把浏览器会话里的 cookie 导成 Netscape 格式，供 yt-dlp / curl 等外部工具复用登录态 | CDP 会话 |
| tools/bilibili/download.mjs | 把 yt-dlp 当 sidecar 调，逐条下载并写台账（与抖音侧同结构） | yt-dlp（已装 2026.08.19） |

设计上延续 M1 的原则：**不重写下载引擎**（视频交给 yt-dlp，它覆盖 B站与 1800+ 站点），**不碰签名逆向**（清单走官方 API + 登录态），**产物结构统一**（预览 JSON、manifest.csv、命名模板三处与抖音侧完全一致）。

命名模板这次做了重构：抽到 tools/lib/naming.mjs，抖音与 B站两个下载器共用同一实现，避免规则漂移（抖音侧自检已回归通过）。

## 2. B站验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 采集器解析逻辑 | node tools/bilibili/collect.mjs --selftest | 通过（过滤无 bvid 条目、剥 HTML 标签、URL 拼装、作者与点赞解析） |
| cookie 导出器 | node tools/bilibili/cookies.mjs --selftest + 真跑 | 通过；Netscape 七列格式正确，实测导出 0 条（尚未登录 B站，符合预期） |
| 下载器参数拼装 | node tools/bilibili/download.mjs --selftest | 通过（清晰度、cookie 有无、命名模板） |
| 未登录时的行为 | 直接跑采集 | 退出码 3，并提示「先用 App 的拉起并登录打开 B站登录页扫码」，不抛原始异常 |
| 真实下载 | yt-dlp 搜索真实视频 -> 本下载器 360p 下载 | 成功 1/1，118.8 MB mp4 + info.json 侧车，台账写入正确（下完即清理，避免占盘） |
| 台账可入库 | library.mjs --ingest-manifest --platform bilibili | 通过；顺带修掉 platform 字段被写死 douyin 的 bug |
| 侧车元数据入库 | library.mjs --ingest-info <目录> --platform bilibili | 实测 info.json 含 title/uploader/duration/upload_date/view/like，可回填作品字段 |

**需要你做的一步**：B站的清单采集需要登录态。在 App 里点「拉起并登录」，选 B站 平台，扫码后就能采集自己的收藏夹。

## 3. 历史作者补采

### 3.1 背景

M0 阶段的作者提取取到了导航栏文字「我的」，导致历史条目作者字段几乎全空（2264 条）。T5 修好了提取规则，M2 用它把历史数据补回来。

### 3.2 工具

    node tools/douyin/backfill_authors.mjs --db <library.db> --limit 60 [--port 9222] [--dry-run]
    node tools/douyin/backfill_authors.mjs --selftest

行为：查库里缺作者的条目 -> 逐条打开笔记页 -> 用修复后的规则提取作者 -> 写回库并记一条 runs 流水 -> 打印进度与剩余数量。可反复执行，每次处理一批。

### 3.3 验证与实测

| 项 | 结果 |
| --- | --- |
| 自检 | 通过（导航词过滤、空格清洗、超长拒绝、缺作者查询、回填写入） |
| 小批量真跑 | 首次 5 条：作者从 4 位增加到 9 位 |
| 批量真跑 | 后台跑 60 条时观察到作者数从 9 位继续增长到 59 位（仍在跑） |
| 剩余 | 可用同一条命令分批继续，直到「仍缺作者」归零 |

### 3.4 顺带修掉的一个真问题

library.mjs 的 works.platform 字段被写死为 douyin：B站作品入库后 platform 仍然显示 douyin。已改为 `--platform` 参数（默认 douyin），并由 B站下载器与入库命令显式传入，实测入库后 platform=bilibili。

## 4. UI 接线（Rust 侧零改动）

App 的「2.5 平台操作」区块新增五个按钮，全部通过既有的 start_job 走任务队列：

 - 采集 B站收藏清单 / 导出 B站 cookies / 下载 B站清单 / 入库 B站侧车元数据
 - 补采抖音历史作者（可填条数）

这正是 M1 那套架构的价值：新平台只是新脚本 + 新按钮，Rust 命令层一行没改。

## 5. 未做与后续

 - B站清单采集的完整验证需要你的账号扫码；当前只验证到「未登录会明确提示」与「下载器真能下」
 - B站视频的封面/时长已进预览 JSON，但入库时未写入 assets 之外的字段（duration 等留待需要时再加列）
 - 小红书尚未接入（签名成本最高，建议放到最后）
 - 作者补采目前是串行的，2264 条需要分批跑；如需加速可加并行标签页（与下载器同一套思路）

## 6. 扫码后的实测（B站 全链路已跑通）

账号扫码登录后，B站 这条链一次跑通：

| 步骤 | 命令 | 实测结果 |
| --- | --- | --- |
| 登录态确认 | 直接读 nav 接口 | isLogin=true，昵称 GUIDIT，mid 206924607 |
| 采集清单 | node tools/bilibili/collect.mjs --out <目录>/preview.json | 313 条视频，来自 25 个收藏夹（默认收藏夹 106、花生十三考公 11、调色原理 6、军队文职 4、spss 1 …） |
| 导出 cookie | node tools/bilibili/cookies.mjs --domain bilibili.com --out <目录>/bili_cookies.txt | 18 条 cookie，Netscape 格式 |
| 命名预览 | node tools/bilibili/download.mjs --limit 3 --dry-run --quality 360 | 路径形如 images/小菲在努力/2027最新公考…mp4，作者与标题都正确落入模板 |

### 6.1 这一轮修掉的一个真 bug

collect.mjs 最初用相对路径调接口（/x/web-interface/nav），结果请求落到 www.bilibili.com，那里没有这些接口，返回的是 HTML 错误页。改为绝对地址 https://api.bilibili.com 后一次通过。教训：跨站接口必须写绝对地址，否则「同源」反而变成了打错主机。

## 7. 作者补采最终结果

| 指标 | 数值 |
| --- | --- |
| 本批处理 | 成功 1551 / 未取到 5 / 失败 28 / 用时 3952 秒（约 66 分钟） |
| 收尾方式 | 浏览器连接断开，脚本按新逻辑带着已完成结果正常收尾（退出码 0），而不是像上次那样崩溃 |
| 整体作者覆盖率 | 1662 / 2265 = 73.4% |
| **已下载作品的作者覆盖率** | **1253 / 1277 = 98.1%**（只剩 24 条，多为已失效笔记） |
| 剩余缺口 | 603 条，其中 579 条是尚未下载的作品——它们会在下载时由修复后的提取器自动回填 |

结论：**「历史作者缺失」这个债基本还清了**。剩下的缺口不再是数据质量问题，而是「还没下载」——把 988 条待下载的作品下下来，作者自然就齐了。剩余 603 条也已放后台继续补（tools/douyin/backfill_authors.mjs --limit 700）。

## 8. 库结构顺带扩展

B站的 info.json 侧车里有丰富字段，元数据库新增三列并在打开旧库时自动迁移：

| 列 | 来源 | 实测 |
| --- | --- | --- |
| duration | info.json 的 duration | 123（秒） |
| view_count | info.json 的 view_count | 12345 |
| media_type | info.json 的 ext | mp4 |

迁移是幂等的（PRAGMA table_info 检查后按需 ALTER TABLE），老库直接打开即可升级。
