// 预设：分类 + 子项（照像素蛋糕「预设」面板的结构）
//
// 诚实说明写在这儿，界面上也照原样显示：
//   **这些不是像素蛋糕的官方预设**。它的预设是官方拿数据训练出来的滤镜包，我们没有那个东西。
//   这里每一条都是**我们自己的经验模板**：给一个「目标影调（分位点 + 饱和度 + 暖冷）」，
//   再给一套起步参数；真正落到每张图上时仍然走闭环（按这张图自己的分布去凑那个目标），
//   所以同一条预设在不同光线的片子上会各自收敛——这一点比固定曲线更实用。
//
// 每条预设的目标都是**可核对的数字**（q5/q50/q95 = 阴影/中间调/高光在自身动态范围里的位置，
// sat = 平均饱和度，warmSh/warmHi = 阴影/高光的 R−B 色偏），界面里会把它们显示出来。
import Foundation

public struct PresetGroup {
    public var name: String
    public var note: String
    public var items: [StylePreset]
    public init(name: String, note: String, items: [StylePreset]) {
        self.name = name; self.note = note; self.items = items
    }
}

/// 造一条预设：目标分位点 + 饱和度 + 暖冷 → 目标 Stats，并按同样意图给一套起步参数。
/// 换算关系写在代码里，方便复核：
///   · cbSh/cbHi 的单位是「级」的 1.923 倍（见 paramsFromStats 里的推导：tint 是 R 加 B 减，差值翻倍，
///     且 cbGain=26），这里取 0.6 步长当起点，剩下的交给闭环；
///   · desat 按「典型饱和度 35 → 目标饱和度」的比例给（render 里 saturation = 1 − desat/100）。
func preset(_ index: Int, _ name: String, _ note: String,
            q5: Double, q50: Double, q95: Double, sat: Double,
            warmSh: Double, warmHi: Double,
            gamma: Double, tone: Double = 0) -> StylePreset {
    var t = Stats()
    t.q5 = q5; t.q50 = q50; t.q95 = q95
    t.p5 = q5 * 255; t.p50 = q50 * 255; t.p95 = q95 * 255
    t.p25 = t.p50 * 0.6; t.p75 = (t.p50 + t.p95) / 2; t.p99 = 250
    t.sat = sat; t.warmSh = warmSh; t.warmHi = warmHi
    var p = Params()
    p.gamma = gamma
    p.levelsOut = [tone, 250]
    p.desat = min(80, max(0, (1 - min(1.2, max(0.2, sat / 35))) * 100))
    let k = 1.923 * 0.6
    p.cbSh = [warmSh * k, 0, -warmSh * k]
    p.cbHi = [warmHi * k, 0, -warmHi * k]
    return StylePreset(index: index, name: name, target: t, params: p)
}

/// 内置预设分类（分类名照像素蛋糕的预设面板：无效果 / 肤质肤色 / 胶片 / 婚纱 / 婚礼跟拍 /
/// 儿童 / 新生儿 / 孕妇 / 全家福 / 写真 / 旅拍 / 毕业·证件照）
public func builtinPresetGroups(startIndex: Int = 1000) -> [PresetGroup] {
    var i = startIndex
    func next(_ name: String, _ note: String, q5: Double, q50: Double, q95: Double,
              sat: Double, warmSh: Double, warmHi: Double, gamma: Double = 1, tone: Double = 0) -> StylePreset {
        defer { i += 1 }
        return preset(i, name, note, q5: q5, q50: q50, q95: q95, sat: sat,
                      warmSh: warmSh, warmHi: warmHi, gamma: gamma, tone: tone)
    }
    var groups: [PresetGroup] = []

    groups.append(PresetGroup(name: "无效果", note: "复位：不套任何风格，保留人像/手动调整", items: [
        next("无效果", "把色调整体复位（人像参数与手动笔刷不动）",
             q5: 0.04, q50: 0.50, q95: 0.96, sat: 35, warmSh: 0, warmHi: 0, gamma: 1, tone: 0)
    ]))

    groups.append(PresetGroup(name: "肤质肤色", note: "目标都是「肤色干净、不假面」，差别在中调与饱和度", items: [
        next("原生肌", "保留原片对比，只把饱和压一点、肤色往中性拉",
             q5: 0.05, q50: 0.52, q95: 0.95, sat: 30, warmSh: 0, warmHi: 0, gamma: 1.0),
        next("通透", "整体提亮一档、降饱和，皮肤看起来更透",
             q5: 0.06, q50: 0.58, q95: 0.97, sat: 27, warmSh: 2, warmHi: 2, gamma: 1.12, tone: 4),
        next("暖白", "提亮 + 阴影加暖（R−B +8 级），室内暖光下人脸不脏",
             q5: 0.05, q50: 0.56, q95: 0.96, sat: 31, warmSh: 8, warmHi: 4, gamma: 1.08, tone: 3)
    ]))

    groups.append(PresetGroup(name: "胶片", note: "共同点：抬高黑位、压低饱和、给一点色彩分离", items: [
        next("柯达暖调", "黑位抬到 6 级、高光稍暖（+6），红色更沉",
             q5: 0.08, q50: 0.52, q95: 0.92, sat: 32, warmSh: 6, warmHi: 8, gamma: 0.98, tone: 6),
        next("富士冷调", "阴影偏青（−8），高光偏中性，对比略高",
             q5: 0.06, q50: 0.50, q95: 0.95, sat: 30, warmSh: -8, warmHi: -1, gamma: 1.02, tone: 5),
        next("黑白", "完全去色（desat 100），靠影调层次说话",
             q5: 0.04, q50: 0.50, q95: 0.96, sat: 0, warmSh: 0, warmHi: 0, gamma: 1.05)
    ]))

    groups.append(PresetGroup(name: "婚纱", note: "白纱是主角：高光要干净、整体要亮、饱和要低", items: [
        next("通透白纱", "整体提亮、高光略冷（−3），白纱不泛黄",
             q5: 0.08, q50: 0.60, q95: 0.98, sat: 24, warmSh: -1, warmHi: -3, gamma: 1.15, tone: 5),
        next("柔光", "压低对比、抬黑位，适合逆光纱裙",
             q5: 0.12, q50: 0.58, q95: 0.94, sat: 26, warmSh: 2, warmHi: 1, gamma: 1.06, tone: 10)
    ]))

    groups.append(PresetGroup(name: "婚礼跟拍", note: "现场光复杂，重点是红/金不脏、肤色不飘", items: [
        next("中式红", "压住红的饱和（避免溢出）、阴影加暖",
             q5: 0.05, q50: 0.48, q95: 0.92, sat: 38, warmSh: 8, warmHi: 2, gamma: 0.97),
        next("仪式暖金", "高光偏暖（+8），中调提一档",
             q5: 0.06, q50: 0.55, q95: 0.95, sat: 34, warmSh: 5, warmHi: 8, gamma: 1.06, tone: 3)
    ]))

    groups.append(PresetGroup(name: "儿童", note: "要亮、要清、要有一点血色", items: [
        next("清透", "提亮 + 略高饱和（+35），皮肤有血色",
             q5: 0.09, q50: 0.60, q95: 0.97, sat: 35, warmSh: 3, warmHi: 3, gamma: 1.12, tone: 4),
        next("柔和", "低对比、低饱和，室内弱光也不脏",
             q5: 0.11, q50: 0.56, q95: 0.93, sat: 29, warmSh: 4, warmHi: 2, gamma: 1.04, tone: 8)
    ]))

    groups.append(PresetGroup(name: "新生儿", note: "奶油感的共同点：抬黑位、低饱和、极低对比", items: [
        next("奶油柔", "大幅抬黑位（14 级）、降饱和，整体像奶油",
             q5: 0.16, q50: 0.62, q95: 0.92, sat: 22, warmSh: 5, warmHi: 2, gamma: 1.05, tone: 14)
    ]))

    groups.append(PresetGroup(name: "孕妇", note: "暖、亮、柔，重点是肤色通透", items: [
        next("暖柔", "提亮 + 阴影加暖（+7）",
             q5: 0.10, q50: 0.58, q95: 0.94, sat: 30, warmSh: 7, warmHi: 4, gamma: 1.08, tone: 6)
    ]))

    groups.append(PresetGroup(name: "全家福", note: "多人同框：优先整体均衡，不追风格化", items: [
        next("均衡", "中性白平衡、对比略提，各年龄肤色都不偏",
             q5: 0.06, q50: 0.54, q95: 0.95, sat: 31, warmSh: 2, warmHi: 2, gamma: 1.03),
        next("暖厅堂", "室内暖光下把阴影再暖一点",
             q5: 0.06, q50: 0.55, q95: 0.94, sat: 32, warmSh: 7, warmHi: 4, gamma: 1.04, tone: 3)
    ]))

    groups.append(PresetGroup(name: "写真", note: "可以风格化：电影感 / 高级灰", items: [
        next("电影感", "青橙分离：阴影偏青、高光偏暖，饱和压低",
             q5: 0.05, q50: 0.47, q95: 0.93, sat: 26, warmSh: -7, warmHi: 7, gamma: 0.97),
        next("高级灰", "低饱和 + 抬黑位 + 平对比",
             q5: 0.12, q50: 0.52, q95: 0.90, sat: 20, warmSh: 0, warmHi: 0, gamma: 1.0, tone: 10)
    ]))

    groups.append(PresetGroup(name: "旅拍", note: "风光与人像兼顾：一个偏艳、一个偏清新", items: [
        next("风光艳", "对比与饱和都提，天空蓝更透",
             q5: 0.03, q50: 0.48, q95: 0.97, sat: 42, warmSh: -2, warmHi: 2, gamma: 1.03),
        next("清新", "整体偏亮偏冷，适合海边/雪山",
             q5: 0.09, q50: 0.58, q95: 0.97, sat: 30, warmSh: -4, warmHi: -2, gamma: 1.10, tone: 4)
    ]))

    groups.append(PresetGroup(name: "毕业 / 证件照", note: "要标准：中性、干净、不风格化（背景色由换背景决定，本机不做生成式）", items: [
        next("标准证件", "中性白平衡、中对比、饱和略降，肤色不发灰",
             q5: 0.06, q50: 0.53, q95: 0.95, sat: 28, warmSh: 1, warmHi: 1, gamma: 1.02),
        next("毕业服", "深色袍子不糊、脸不暗，中调提一档",
             q5: 0.05, q50: 0.56, q95: 0.95, sat: 29, warmSh: 3, warmHi: 2, gamma: 1.07, tone: 3)
    ]))

    return groups
}
