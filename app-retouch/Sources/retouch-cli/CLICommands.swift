// CLICommands.swift：命令行的提前退出分支（--gpu-info / --model-check / --help）。
// 从 main.swift 的派发链搬出——原来它们是一串 `if args.contains(...) { ... }`，
// 主体（主流程）留在 main.swift 的顶层（Swift 只允许 main 文件有顶层可执行语句）。
import Foundation
import CoreImage
import Metal
import RetouchCore

/// CLI 的硬错误：**批处理"什么都没做"必须是失败**。
/// 为什么要有这个：`--in` 路径打错时，原来 `try?` 把"目录读不到"吃掉了，
/// 接着打印"输入 0 张 → 完成：成功 0 / 失败 0"并返回 **0** —— 脚本与 CI 会当成跑成功（第 148 节）。
enum CLIError: Error, CustomStringConvertible {
    case inputUnreadable(String)
    case noImages(String)

    var description: String {
        switch self {
        case .inputUnreadable(let p): return "输入目录读不到：\(p)"
        case .noImages(let p):        return "输入目录里没有可处理的图片：\(p)"
        }
    }
}

/// --gpu-info 硬件/算力自检
func cliGPUInfo() {
    print("== 硬件 ==")
    if let dev = MTLCreateSystemDefaultDevice() {
        print("  GPU：" + dev.name + "（统一内存：" + String(dev.hasUnifiedMemory) + "）")
    } else {
        print("  没有 Metal 设备（会退回软件渲染，慢 3 倍左右）")
    }
    print("  CPU 核数：" + String(ProcessInfo.processInfo.activeProcessorCount)
          + " ｜ 内存 " + String(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) + " GB")
    print("== 像素运算 ==")
    // 说明：这里只报事实，不下「快几倍」的结论。
    // 高斯这类可分离算子在 M 系芯片的 CPU 路径上本来就很快（实测 2160² 串 4 次模糊：Metal 7.3ms vs 软件 8.0ms，只差 1.1×），
    // 拿它当「GPU 有没有生效」的判据会误导。真正决定走不走 GPU 的是「有没有 Metal 设备」+「上下文是不是默认的 Metal 上下文」。
    print("  Core Image 默认上下文：" + (MTLCreateSystemDefaultDevice() != nil ? "Metal 驱动（GPU）" : "软件渲染（这台机器没有 Metal）"))
    let g = CIFilter(name: "CILinearGradient")
    g?.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
    g?.setValue(CIVector(x: 2160, y: 2160), forKey: "inputPoint1")
    g?.setValue(CIColor(red: 1, green: 0.2, blue: 0.1), forKey: "inputColor0")
    g?.setValue(CIColor(red: 0.1, green: 0.3, blue: 1), forKey: "inputColor1")
    let base = (g?.outputImage ?? CIImage(color: .gray)).cropped(to: CGRect(x: 0, y: 0, width: 2160, height: 2160))
    func t(_ ctx: CIContext) -> Double {
        let run = {
            var out = base
            for _ in 0..<4 {
                out = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 28]).cropped(to: base.extent)
            }
            _ = ctx.createCGImage(out, from: base.extent)
        }
        run()
        var best = Double.infinity
        for _ in 0..<3 { let s = Date(); run(); best = min(best, Date().timeIntervalSince(s) * 1000) }
        return best
    }
    let metal = t(sharedCtx)
    let soft = t(CIContext(options: [.useSoftwareRenderer: true]))
    print(String(format: "  参考：4x 高斯 r=28 @2160²  默认 %.1f ms ｜ 强制软件 %.1f ms", metal, soft))
    print("  （这个算子两边差距很小，说明它不该被当作 GPU 生效与否的判据；")
    print("    真正吃 GPU 的是带蒙版混合、色彩矩阵、多步滤镜链的实际管线）")
    print("== 模型算力 ==")
    print("  人脸解析 / SAM 都配了 computeUnits = .all（实测 .all 会挑到神经引擎：")
    print("    解析 all 10.9ms vs cpuOnly 74.5ms ｜ SAM 编码 all 50.4ms vs cpuOnly 116.7ms）")
    exit(0)
}

/// --model-check 模型是否可用
func cliModelCheck() {
    let url = FaceParser.modelURL()
    print("人脸解析模型：" + (url?.path ?? "未找到"))
    print("  可用：" + String(FaceParser.shared.isAvailable))
    if let u = url {
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        print(String(format: "  体积：%.1f MB", Double(size) / 1_048_576))
    }
    print("  皮肤掩膜策略：有模型用解析（每张脸 42 ms），没有就退回肤色阈值")
    exit(FaceParser.shared.isAvailable ? 0 : 1)
}

/// --help 用法
func cliHelp() {
    print("""
    retouch-cli：批量调色 + 人像全量 + 影调补充 + 按设置导出

      --in <目录>            原片目录（支持 RAW）
      --out <目录>           输出目录
      --style <json>         风格报告（默认 style_out/style_report.json）
      --cluster <n>          用第几个聚类（默认 2）
      --limit <n>            只处理前 n 张
      --iterations <n>       闭环轮数（默认 3）
      --skin-grade off|light|medium|strong   磨皮分档
      --smooth <0-100>       磨皮强度（直接给数）
      --no-texture-preserve  关掉保毛孔（退回线性柔化）
      --skin-tone            肤色统一（朝参考组暖冷靠）
      --portrait "k=v,k=v"   人像参数，键名同 PortraitOptions：
                             faceBlemish spotBlemish mole shine sweat darkCircle eyebag
                             nostril lipLine doubleChin jawLine teeth eyes lipColor blush
                             hands feet faceSlim eyeBig noseSlim chinShape forehead
      --sharpen/--denoise/--vignette/--grain/--light/--edge-refine/--bg-blur <0-100>
      --lens-distortion/--lens-ca <负100~100>  镜头畸变 / 横向色差校正
      --auto-wb <0-100>            自动白平衡（灰世界/高光白点）
      --auto-expose <0-100>        自动曝光/分级（按本图直方图拉黑白场）
      --auto-skin <0-100>          自动肤色（用皮肤掩膜朝目标色相微调）
      --auto-level                 自动摆正（梯度方向直方图量倾角后反向旋转）
      --auto-vignette              自动暗角（量四角/中心亮度比，按标定校正）
      --auto-denoise               自动降噪（估高频 MAD 得噪声 σ，按需降噪）
      --auto-lens                  按 EXIF 镜头型号自动套用镜头配置（配置放 lens_profiles/ 或 App Support）
      --sky <blue|sunset|grey|warm>   换天空（合成式，非生成）：检出天空才换
      --sky-amount <0-100>         换天空强度（默认 60）
      --auto-adapt                 场景自适应：场景识别 + 本图测量（逆光/噪声/肤色）→ 白平衡/曝光/降噪一次给全
      --auto-adapt-batch           整批统一：先测整批取中位数，所有图用同一套参数（同场片子观感一致）
      --group-report               连拍分组 + 组内选优（按文件名/EXIF 时间分组，输出每组推荐哪张）
      --index <out.jsonl>          抽要素建索引（分类词/人脸/人数/天空/色彩/构图），供秒级检索
      --search "<词 词>"           按索引检索（空格分隔多词=与关系），--search-in 指定索引文件
      --copy-to=<dir>              把命中的原图复制到目录（检索结果直接可用）
      --index-pose <jsonl>         增量补姿势特征（只重算这一维，不重跑整条索引）
      --index-fp <jsonl>           增量补「学习模型图像嵌入」（768 维，独立二进制文件）
      --similar <图> --fp <file>   以图搜图：拿一张图在嵌入表里找最近的若干张
      --reference <路径,路径>      参考图追色：多张参考图（文件或目录）折算成目标色，再闭环追过去
      --reference-url <链接>       参考图追色：从链接抓图（图片直链/带 og:image 的分享页）
      --reference-dir <dir>        抓下来的参考图存哪（默认 /tmp/retouch_refs）
      --stress                     大规模压测：整条链路跑一遍只统计，输出成功率/耗时分布/异常样本
      --stress-sample <n>          压测时每 n 张取 1（默认 0 = 全跑）
      --profile                    分阶段耗时剖析（读图/人脸/人像/衣物/补光/锐化/出图 各占多少）
      --smart-sharpen <0-100>      边缘感知锐化（只锐边缘，不放大平坦区噪声）
      --highlight-recover <0-100>  高光恢复
      --auto-fill <0-100>          按估计的光向往暗侧补光
      --lens-vignette <0-100>                  镜头暗角校正
      --perspective-h/--perspective-v <负100~100>  水平 / 垂直透视校正
      --purify-bg            背景纯化    --auto-crop  祛黑白边
      --format jpeg|tiff|png --bit-depth 8|16 --color-space sRGB|DisplayP3
      --max-long-edge <n>    长边缩放（0=原尺寸）
      --name-template "{date}_{name}_{seq}"   命名模板
      --watermark "文字"     水印（支持 {name}）
      --workers <n>          并行度（默认按 CPU 核数自适应，上限 8；1=最省内存）
      --raw-cache <dir>        RAW 预解码缓存（默认关）：一批 RAW 反复出片时第二次免解码；
                               16bit 无损 TIFF，2000px 约 16 MB/张，默认上限 8 GB（超了删最旧）
      --report <json>        参数报告
      --from-report <json>   回滚：按报告原样重现
      --dry-run              只算不写
    """)
    exit(0)
}

/// 主流程：原 main.swift 顶层的整段可执行代码（一行未改，只是搬进函数）。
