# ContentRetouch · 像素蛋糕对标的 macOS 修图 App

> 一个纯 Swift / SwiftUI + Core Image + Vision + Core ML 的 macOS 人像精修 App。
> 目标不是"看起来像"，而是**每一项功能都能被量化验证**：有探针、有断言、有真值对比。

## 亮点

- **全链路可测**：`coretest` 一个可执行文件跑 388 条断言（含落点正确性、不越界、收益倍数等），另有 20 张界面截图基线门（SSIM/RMSE 比对）。
- **模型可替换**：人脸解析、精细分割（SAM）、生成式修补（LaMa）、上色（DDColor）、人脸修复（GFPGAN）都可替换；支持**从清单自动下载安装**并做**许可证把关**。
- **诚实结论**：对效果更差的候选（LaMa 修补）按数据**默认关闭**；对无法验证的功能（人物类型）**宁可不做**。
- **RAW 支持**：CR3 等 RAW 走缩略图快路径（比整图解码快 7.4 倍）。

## 功能一览

| 类别 | 能力 |
|------|------|
| 人像 | 祛瑕疵、祛斑痘、祛痣、祛油光、祛汗孔、祛黑眼圈、祛眼袋、祛鼻孔瑕疵、唇纹、双下巴、牙齿美白、眼神光 |
| 皮肤 | 保毛孔的色调均匀化（低频/高频分离）、质感保留、降噪 |
| 重塑 | 瘦脸、大眼、鼻翼收窄、下巴、额头、发际线（液化，带区域约束） |
| 妆容 | 唇色、腮红、眼影、修容、眉毛 |
| 创意 | **一键上色**（DDColor Tiny，可选下载）、**人脸修复**（GFPGAN，可选下载） |
| 工具 | 智能消除（SAM 圈选）、AI 点修（点一下自动判部位与强度）、画笔修补、仿制图章、局部液化、衣物/宠物/图像类调整 |
| 工作流 | 预设、历史、工程保存、批量导出、挑图（清晰度/人脸质量/曝光/笑容/姿态/闭眼排序）、按星级交付 |

## 架构

```
app-retouch/
├── Sources/RetouchCore/          # 纯函数 + 图像管线（无 UI 依赖，可被 coretest 直接测）
│   ├── Pipeline.swift            # 渲染管线：人像 → 皮肤 → 重塑 → 手动编辑
│   ├── FaceParsing.swift         # 人脸解析（Vision + Core ML，ANE 16.9 ms）
│   ├── SamStore.swift / SamPrompt.swift   # MobileSAM：安装 + 点提示分割
│   ├── LaMa.swift / CoreHeal.swift        # 生成式修补 + 样例修补兜底
│   ├── Colorize.swift / Gfpgan.swift      # 上色 / 人脸修复（含 warmUp 预热）
│   ├── ModelRegistry.swift       # 多模型注册表（models.json，同槽位互斥启用）
│   ├── ModelCatalog.swift        # 模型商店清单：许可把关 + 断点续传下载 + 安装
│   └── ...                       # 液化、调色、蒙版、肤质、导出……
├── Sources/ContentRetouch/       # SwiftUI + AppKit 界面
├── Sources/coretest/             # 388 条断言的验证程序（含探针）
└── Sources/retouch-cli/、probe/  # 命令行与探针工具
```

## 构建与验证

```bash
cd app-retouch
swift build -c release            # 构建（macOS 14+，Swift 5.9）
./.build/release/coretest         # 388 条断言：0 失败是硬要求
sh ../tools/dist/ui_baseline.sh check   # 20 张界面截图门
```

打包 dmg：`sh tools/dist/release.sh <版本号>`（内含 24 步预检：编译 / 核心断言 / 界面门 / 参数指纹 / 打包与产物体积）。

## 模型管理（可下载 + 许可把关）

模型商店清单来自 [mlboydaisuke/coreml-zoo](https://huggingface.co/mlboydaisuke/coreml-zoo) 的 `models.json`，App 内「待开发 → 模型选择设置」可一键拉取、下载、登记、启用。

**许可自动把关**：清单里每个模型自带 `license.name`，判定规则（有 9 条断言守着）：

```
含 non-commercial / NC / research / AGPL / GPL  ⇒ 只评测，不进产品默认路径
含 Apache / MIT / BSD / CC BY                    ⇒ 可入库
缺失或未知                                        ⇒ 只评测
```

已接入且许可干净：`face_parsing`(MIT)、`mobilesam`(Apache-2.0)、`lama`(Apache-2.0)、`ddcolor`(Apache-2.0)、`gfpgan`(Apache-2.0)、`realesrgan`(BSD-3-Clause)。

## 效果验证（不是主观评分，是量化判据）

| 项目 | 判据 | 结果 |
|------|------|------|
| 精细分割 SAM | 同掩膜区内覆盖 ≥ 单点 × 1.05 | 图心 6.0–9.5×；脸框中心 **3.11×** ⇒ 默认开 |
| 生成式修补 LaMa | 同洞真值误差 | 比本机样例修补**差 1.5–2.7 倍** ⇒ 默认关 |
| 上色低饱和掩膜 | 彩色图色度不应下降 | 修复前 **-12.84** ⇒ 修复后 **0.00**（灰度图仍 +34.19） |
| AI 点修命中率 | 脸框内网格可修覆盖率 | 4 张夹具均值 **0.710** |
| 人脸解析候选 | 同口径排序 | 现用 6.72 ≈ yakhyo 6.67 > SegFormer 6.60 ⇒ 不换 |

## 已知边界（诚实说明）

- **不提供人物类型识别**（女/男/儿童/长辈）：手上信号无类型判别力、且无标注数据可验证 ⇒ 不做，避免误导性功能。
- **四肢语义分割未接**：human-parsing 候选许可均不干净 ⇒ 宁可"诚实标注未检出"。
- **生成式填充**：采用本机样例修补 + LaMa 兜底；LaMa 在该真值集上更差，默认关闭。
- 应用体积约 25 MB（人脸解析模型 13.4 MB 内置）；SAM / LaMa / DDColor / GFPGAN 为可选下载。

## 数据与隐私

仓库**不包含任何用户照片**。评测用的照片来自项目作者自有素材，且其原始文件不随仓库分发；
`docs/eval_set_final*.json` 只记录**路径与统计量**，实际图片不提交。

## 许可

代码：MIT（待定，见仓库 LICENSE）。
内置与可选模型各自遵循其原始许可（见上文"模型管理"）。

## 致谢

- [MobileSAM](https://github.com/ChaoningZhang/MobileSAM)、[LaMa](https://github.com/advimman/lama)、[DDColor](https://github.com/piddnad/DDColor)、[GFPGAN](https://github.com/TencentARC/GFPGAN)、[face-parsing](https://github.com/zllrunning/face-parsing.PyTorch)
- Core ML 模型打包：[mlboydaisuke/coreml-zoo](https://huggingface.co/mlboydaisuke/coreml-zoo)
