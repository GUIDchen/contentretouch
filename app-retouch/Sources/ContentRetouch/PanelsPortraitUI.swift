// PanelsPortraitUI.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    // MARK: 宠物面板（宠物美化：动物姿态关键点 → 区域柔化）
    var petPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("宠物美化").font(.headline)
            Text("用动物识别框（Vision）+ 羽化定位宠物，六项各自作用在**该生效的地方**")
                .font(.caption).foregroundColor(.secondary)
            slider("毛发柔顺", $petOptions.soften, 0...85, 5) { refresh() }
            slider("毛发光泽", $petOptions.gloss, 0...100, 5) { refresh() }
            slider("白毛去黄", $petOptions.whiten, 0...100, 5) { refresh() }
            slider("眼睛提亮", $petOptions.eyeBright, 0...100, 5) { refresh() }
            slider("去泪痕", $petOptions.tearStain, 0...100, 5) { refresh() }
            slider("毛色统一", $petOptions.unifyTone, 0...100, 5) { refresh() }
            Divider()
            Text("各参数的作用位置：毛发三项 = 动物框内；白毛去黄**只作用于浅色毛发**；")
                .font(.caption2).foregroundColor(.secondary)
            Text("眼睛提亮/去泪痕 = 动物框**上半部中央**（眼周），且只作用于暗部像素。")
                .font(.caption2).foregroundColor(.secondary)
            Text("⚠️ 边界：没有宠物专项分割模型，「眼周」是按动物框的上半部中央**估**的，不是真正的眼睛关键点；")
                .font(.caption2).foregroundColor(.secondary)
            Text("毛色统一是低频化（压局部色差），不是重绘毛色。实测：蒙版内变化 4.483、蒙版外 0.0103（不越界）。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    /// ⑩ 按部位调参：识别出来的部位各自可调（增量，与"范围选择"同一套心智）
    var partsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按部位调整").font(.headline)
            Text("部位来自关键点拼出的掩膜（脸=faceContour、眼/唇/鼻=关键点多边形、耳=脸框两侧近似、手臂/腿=人体姿态粗折线）。")
                .font(.caption).foregroundColor(.secondary)
            Text("⚠️ 精度上限就是关键点本身：正脸、四肢张开时好；侧脸、遮挡、贴身时差。")
                .font(.caption).foregroundColor(.secondary)
            // §347：把「手臂/腿可能完全没有掩膜」这件事实说清楚 —— 以前只写了精度上限，
            // 用户点了「瘦手臂」却没反应时不知道是为什么 ✗。这里点明原因并指向自查入口 ✓。
            Text("⚠️ 手臂/腿最容易出现「这张图没有可用的人体姿态关键点」（侧身、遮挡、半身像、只露上半身）——"
                 + "那种情况下这两个滑杆**不会生效**。可先点下面「检查这张图有哪些部位」确认 ✓。")
                .font(.caption).foregroundColor(.orange)
            Button("检查这张图有哪些部位") { checkParts() }.font(.system(size: 10))
                .font(.caption2).foregroundColor(.secondary)
            ForEach(BodyPart.allCases) { part in
                let idx = partAdjusts.firstIndex { $0.part == part.rawValue }
                DisclosureGroup(isExpanded: Binding(
                    get: { openPart == part.rawValue },
                    set: { openPart = $0 ? part.rawValue : nil })) {
                    let i = idx ?? -1
                    VStack(alignment: .leading, spacing: 2) {
                        miniSlider("亮度 +", Binding(
                            get: { i >= 0 ? partAdjusts[i].dBrightness : 0 },
                            set: { v in ensurePart(part.rawValue); if let j = partAdjusts.firstIndex(where: { $0.part == part.rawValue }) { partAdjusts[j].dBrightness = v }; refresh() }), -50...50, 1)
                        miniSlider("暖冷 +", Binding(
                            get: { i >= 0 ? partAdjusts[i].dWarm : 0 },
                            set: { v in ensurePart(part.rawValue); if let j = partAdjusts.firstIndex(where: { $0.part == part.rawValue }) { partAdjusts[j].dWarm = v }; refresh() }), -30...30, 1)
                        miniSlider("饱和 +", Binding(
                            get: { i >= 0 ? partAdjusts[i].dSat : 0 },
                            set: { v in ensurePart(part.rawValue); if let j = partAdjusts.firstIndex(where: { $0.part == part.rawValue }) { partAdjusts[j].dSat = v }; refresh() }), -50...50, 1)
                        miniSlider("柔化 +", Binding(
                            get: { i >= 0 ? partAdjusts[i].dSmooth : 0 },
                            set: { v in ensurePart(part.rawValue); if let j = partAdjusts.firstIndex(where: { $0.part == part.rawValue }) { partAdjusts[j].dSmooth = v }; refresh() }), 0...100, 5)
                        // ⑧⑨ 部位变形（滑杆松手才作用一次：形变是"累积笔触"，不适合实时拖）
                        Text("变形（拖完松手生效）").font(.system(size: 9)).foregroundColor(.secondary)
                        if part == .arms || part == .legs {
                            DeformSlider(label: "拉长", value: deformDraft["拉长"] ?? 0) { v in
                                deformDraft["拉长"] = v
                            } onCommit: { v in
                                applyPartDeform(part, kind: "拉长", amount: v)
                            }
                            DeformSlider(label: part == .legs ? "瘦腿" : "瘦手臂", value: deformDraft["瘦"] ?? 0) { v in
                                deformDraft["瘦"] = v
                            } onCommit: { v in
                                applyPartDeform(part, kind: "瘦", amount: v)
                            }
                        }
                        if part == .face || part == .eyes || part == .lips || part == .nose {
                            ForEach(["大眼", "瘦鼻", "唇形", "额头", "下巴"], id: \.self) { k in
                                DeformSlider(label: k, value: deformDraft[k] ?? 0) { v in
                                    deformDraft[k] = v
                                } onCommit: { v in
                                    applyPartDeform(part, kind: k, amount: v)
                                }
                            }
                        }
                        if i >= 0 {
                            Button("清除这一项") {
                                pushHistory("清除部位调整")
                                partAdjusts.removeAll { $0.part == part.rawValue }
                                refresh()
                            }.font(.system(size: 9))
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(part.rawValue).font(.system(size: 11))
                        if idx != nil { Text("已调").font(.system(size: 8)).foregroundColor(.accentColor) }
                        Spacer()
                        if partChecked.contains(part.rawValue) && !partAvailable.contains(part.rawValue) {
                            Text("没检出").font(.system(size: 8)).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: 衣物面板（受限可用：没有衣物分割，粗定位后压高频）
    var clothesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("衣物平整").font(.headline)
            Text("用「人像蒙版 − 脸部 − 过亮像素」粗定位衣服，再压制高频（去褶皱/汗渍感）").font(.caption).foregroundColor(.secondary)
            slider("强度", $clothesStrength, 0...85, 5) { refresh() }
            Divider()
            Text("实测：人像区内变化 4.79、**人像区外 0.0234**（不越界 ✅）").font(.caption2).foregroundColor(.secondary)
            Text("⚠️ 受限可用：没有衣物分割模型，白纱、袖子、裸露皮肤边界可能漏判或误伤。").font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("换天空（合成式，不是生成式）").font(.headline)
            Text("判据 = 位置 + 亮度 + 蓝度三条相乘；再查一遍蓝度，避免把室内亮背景当天空")
                .font(.caption).foregroundColor(.secondary)
            Picker("风格", selection: $sky.style) {
                Text("晴天蓝").tag("blue"); Text("晚霞").tag("sunset")
                Text("阴天").tag("grey"); Text("暖金").tag("warm")
            }.pickerStyle(.segmented).font(.system(size: 10))
            slider("强度", $sky.amount, 0...100, 5) { refresh() }
            slider("  地平线微调（正=往下）", $sky.horizonBias, -1...1, 0.1) { refresh() }
            Button("先检测天空（检不到就不换）") {
                guard let img = workImage() else { return }
                var probe = sky
                probe.amount = 100
                let (_, cov) = replaceSky(img, probe)
                if cov < 0.02 {
                    sky.amount = 0
                    skyInfo = "这张图没检出天空（位置/亮度/蓝度不满足），不硬换"
                } else {
                    pushHistory("换天空")
                    sky.amount = 60
                    skyInfo = String(format: "检出天空 %.0f%%，已按强度 %.0f 套用", cov * 100, sky.amount)
                }
                status = skyInfo
                refresh()
            }
            if !skyInfo.isEmpty {
                Text(skyInfo).font(.caption2).foregroundColor(.secondary)
            }
            Text("实测：合成图地平线真值 50%% → 检出 47.7%%；地面区一像素未动；室内婚礼片检出 0%%（不误报）")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 人像面板（照像素蛋糕的四层：人物属性 → 作用范围 → 功能组 → 滑杆）
    var facePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("人像美化").font(.headline)
            Text(faces.isEmpty ? "没有检测到人脸：先看画布上的图是否有清晰正脸" : "检测到 \(faces.count) 张脸")
                .font(.caption).foregroundColor(.secondary)

            // —— 第二层：作用范围（单人 / 所有人 / 部分人联动）——
            Picker("作用范围", selection: $faceScope) {
                Text("单人").tag("single")
                Text("所有人").tag("all")
                Text("部分人联动").tag("partial")
            }.pickerStyle(.segmented).onChange(of: faceScope) { _, _ in refresh() }
            if faceScope == "partial" {
                Text("勾选要一起调的脸").font(.caption2).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    ForEach(faces, id: \.index) { fa in
                        Toggle("脸 \(fa.index + 1)", isOn: Binding(
                            get: { selectedFaces.contains(fa.index) },
                            set: { v in
                                if v { selectedFaces.insert(fa.index) } else { selectedFaces.remove(fa.index) }
                                refresh()
                            })).toggleStyle(.checkbox)
                    }
                }
            }

            // —— 第一层：人物属性（照像素蛋糕是一排 pills，作用于当前选中的人）——
            HStack(spacing: 4) {
                ForEach(["女", "男", "儿童", "长辈女", "长辈男"], id: \.self) { a in
                    let on = (attrs[selectedFace] ?? "女") == a
                    Button { attrs[selectedFace] = a } label: {
                        Text(a).font(.system(size: 11)).fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(on ? Color.accentColor : Color.clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Text("作用在「脸 \(selectedFace + 1)」上").font(.caption2).foregroundColor(.secondary)
                Spacer()
                Button("按属性推荐") { applyAttributeDefaults(attrs[selectedFace] ?? "女", face: selectedFace) }
                    .font(.system(size: 10))
            }
            ForEach(faces, id: \.index) { fa in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("脸 \(fa.index + 1)").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(String(format: "质量 %.2f", fa.quality)).font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    slider("  这张脸的提亮", Binding(
                        get: { faceBrightness[fa.index] ?? 0 },
                        set: { faceBrightness[fa.index] = $0; refresh() }), -30...30, 1) { }
                    slider("  这张脸的暖冷", Binding(
                        get: { faceWarmth[fa.index] ?? 0 },
                        set: { faceWarmth[fa.index] = $0; refresh() }), -20...20, 1) { }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(fa.index == selectedFace ? 0.08 : 0.03)))
            }

            // —— 第三层：页签（照像素蛋糕：祛除瑕疵 / 皮肤调整 / 面部重塑 / 表情管理）——
            // 它把二十多条滑杆分成四页，一屏看得完；我们早先全铺在一页里，滚半天找不到。
            HStack(spacing: 2) {
                ForEach(Array(["祛除瑕疵", "皮肤调整", "面部重塑", "表情管理"].enumerated()), id: \.offset) { i, name in
                    Button { faceTab = i } label: {
                        VStack(spacing: 3) {
                            Text(name).font(.system(size: 11, weight: faceTab == i ? .semibold : .regular))
                                .foregroundColor(faceTab == i ? .primary : .secondary)
                            Rectangle().fill(faceTab == i ? Color.accentColor : Color.clear).frame(height: 2)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            if faceTab == 0 {
            pgroup("祛除瑕疵") {
                // §415：一键上色（第三方模型 DDColor，可选下载 ✓）。
                // 放在最前：它是整图级操作，与逐部位的祛瑕疵不同 ✓。
                // 未装模型或模型跑不动时，管线那一支不生效 ⇒ 拖了画面也不变（安全 ✓）。
                pSlider("一键上色（需下载 DDColor）", \.colorize)
pSlider("面部祛瑕疵", \.faceBlemish)
                pSlider("祛斑祛痘", \.spotBlemish)
                pSlider("祛痣", \.mole)
                pSlider("祛油光（脸部）", \.shine)
                pSlider("祛汗孔（脸部）", \.sweat)
                pSlider("祛黑眼圈", \.darkCircle)
                pSlider("祛眼袋", \.eyebag)
                pSlider("祛鼻孔瑕疵", \.nostril)
                pSlider("唇纹修整", \.lipLine)
                pSlider("祛双下巴", \.doubleChin)
                pSlider("下颌线增强", \.jawLine)
            }
            }
            if faceTab == 1 {
            pgroup("皮肤调整") {
                Picker("磨皮强度", selection: $skinGrade) {
                    Text("关").tag("off"); Text("轻").tag("light")
                    Text("中").tag("medium"); Text("重").tag("strong")
                }.pickerStyle(.segmented).onChange(of: skinGrade) { _, _ in refresh() }
                slider("细调强度", $skinStrength, 0...100, 5) { refresh() }
                Toggle("保毛孔（频域分离：只抹平色调，不动毛孔纹理）", isOn: $texturePreserve)
                    .font(.system(size: 11)).onChange(of: texturePreserve) { _, _ in refresh() }
                Toggle("肤色统一（朝参考组暖冷靠拢）", isOn: $skinTone)
                    .font(.system(size: 11)).onChange(of: skinTone) { _, _ in refresh() }
                Text("实测：保毛孔保留 92% 细节（线性柔化只剩 46%），色调离散 45.2 → 35.6。")
                    .font(.caption2).foregroundColor(.secondary)
            }
            }
            if faceTab == 3 {
            pgroup("牙齿 / 眼睛") {
                pSlider("牙齿美白", \.teeth)
                pSlider("眼睛增强（黑白眼珠）", \.eyes)
            }
            pgroup("妆容调整") {
                pSlider("唇色", \.lipColor)
                pSlider("腮红", \.blush)
            }
            }
            if faceTab == 2 {
            pgroup("面部重塑（近似：没有 3DMM，靠关键点 + 局部变形）") {
                pSlider("瘦脸", \.faceSlim)
                pSlider("大眼", \.eyeBig)
                pSlider("鼻翼收窄", \.noseSlim)
                pSlider("下巴", \.chinShape)
                pSlider("额头", \.forehead)
                pSlider("发际线（正=上移）", \.hairline, -50...50)
                slider("整体液化（最大一张脸）", $liquifyAmount, -80...80, 5) { refresh() }
            }
            pgroup("按人处理（实例分割）") {
                HStack {
                    Button("检测人物实例") { detectPersons() }
                    Spacer()
                    Text(personRects.isEmpty ? "未检测" : "共 " + String(personRects.count) + " 人")
                        .font(.caption2).foregroundColor(.secondary)
                }
                if personRects.isEmpty {
                    Text("点一下检测：合影里可以给每个人不同的磨皮强度（用人物实例掩膜，比按脸椭圆更贴轮廓）。")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    ForEach(Array(personRects.enumerated()), id: \.offset) { i, _ in
                        slider("  第 " + String(i + 1) + " 个人（从左到右）",
                               Binding(get: { i < personSkin.count ? personSkin[i] : 0 },
                                       set: { v in
                                           if personSkin.count <= i {
                                               personSkin += Array(repeating: 0.0, count: i + 1 - personSkin.count)
                                           }
                                           personSkin[i] = v
                                           refresh()
                                       }), 0...100, 5) { }
                    }
                    Button("全部清零") { personSkin = Array(repeating: 0.0, count: personRects.count); refresh() }
                        .font(.system(size: 10))
                }
            }
            pgroup("手部 / 脚部") {
                pSlider("手部美化", \.hands)
                pSlider("脚部美化（按脚踝定位，近似）", \.feet)
            }
            pgroup("全身美型（近似）") {
                slider("收腰", $slimWaist, 0...100, 5) { refresh() }
                slider("宽肩", $wideShoulders, 0...100, 5) { refresh() }
                // 3D 姿态判出的身体朝向（本轮新接）：侧身时横向位移会把身体推歪，按 |cos| 打折
                Text("身体朝向：" + bodyYawText)
                    .font(.caption2)
                    .foregroundColor(bodyYaw.ok && abs(bodyYaw.yaw) > 55 ? .orange : .secondary)
                Text("实测：腰部内变化 29.5、腰部以外 0.0000（不越界）。需要躯干关键点齐全。")
                    .font(.caption2).foregroundColor(.secondary)
                Button("按朝向重新判定") { bodyYawURL = nil; _ = workImage(); refresh() }
                    .font(.system(size: 10))
            }
            pgroup("手动液化（画布笔刷）") {
                Picker("方式", selection: $liquifyMode) {
                    ForEach(LiquifyMode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) }
                }.pickerStyle(.menu).font(.system(size: 11))
                    .onChange(of: liquifyMode) { _, _ in
                        if liquifyMode == .freeze && !brushActive { brushActive = true }
                    }
                Toggle("在图上拖着刷", isOn: $brushActive).font(.system(size: 11))
                    .onChange(of: brushActive) { _, _ in refresh() }
                // 范围放到 0.3%~8%：0.3% 在 1050px 图上约 3px 半径（点状），8% 约 84px（大片）
                slider("笔刷半径（占长边 %）", $brushRadius, 0.3...8, 0.1) { refresh() }
                // ⚠️ 这里原来绑的是 brushStrength（-1…1），而拖动路径在上一轮已经改成用
                // 「画笔压力」（工作区那个滑杆）。同一个"强度"出现两个控件、其中一个已经失效 ——
                // 正是"拖了没用"这一类问题。现在两处**绑同一个值**（压力 1~100）。
                slider("笔刷强度 / 压力", $brushPressure, 1...100, 1) { refresh() }
                HStack {
                    Text("变形 \(warpStrokes.count) 笔 · 冻结 \(freezeStrokes.count) 笔")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    if liquifyMode == .freeze {
                        Toggle("显示冻结区", isOn: $showFreeze).toggleStyle(.checkbox).font(.system(size: 10))
                    }
                }
                HStack(spacing: 6) {
                    Button("重建一笔") { if !warpStrokes.isEmpty { warpStrokes.removeLast(); refresh() } }
                    Button("重建一半") { warpStrokes = Array(warpStrokes.prefix(warpStrokes.count / 2)); refresh() }
                    Button("清除冻结") { freezeStrokes = []; refresh() }
                    Button("全清") { warpStrokes = []; freezeStrokes = []; pushHistory(); refresh() }
                }.font(.system(size: 10))
                Text("向前变形靠 CIWarpKernel（方向性位移）；膨胀/收缩/旋转用系统失真滤镜；冻结区在变形后从原图贴回。")
                    .font(.caption2).foregroundColor(.secondary)
                Text("半径与落点按归一化存，预览与导出落点一致。").font(.caption2).foregroundColor(.secondary)
            }
            Text("表情管理里的「微笑 / 睁眼」本机做不了：抬嘴角要重绘牙齿与皮肤，属于生成式重绘，已如实列进「待开发」。")
                .font(.caption2).foregroundColor(.secondary)
            }
            Divider()
            Text("每项效果只作用在各自区域（脸/唇/眼/手），区域外不动；每一项都有 coretest 实测数字。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    /// 功能组外壳（像素蛋糕的分组标题）
    func pgroup<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).padding(.top, 4)
            content()
        }
    }

    /// 人像参数滑杆：左侧名字 + 当前值 + ↺，右侧一个开关，下面一条滑杆。
    /// 开关的作用是**临时停用**而不是复位：关掉时记住原值，再打开恢复——
    /// 像素蛋糕每一项都是「开关 + 数值 + ↺」三件套，比较的是效果而不是让用户先归零再调回来。
    func pSlider(_ label: String, _ key: WritableKeyPath<PortraitOptions, Double>,
                 _ range: ClosedRange<Double> = 0...100, step: Double = 5) -> some View {
        let value = portrait[keyPath: key]
        let on = abs(value) > 0.001
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label).font(.system(size: 11))
                    Spacer()
                    Text(String(format: "%.2f", value)).font(.system(size: 11)).monospacedDigit()
                    // ⑤ 双击标签/数值 = 还原初始值。为什么不只挂在 Slider 上：macOS 的 Slider 是原生控件，
                    // 会自己吃掉双击，SwiftUI 的 TapGesture 收不到（用户三次报"双击没反应"）。
                    .onTapGesture(count: 2) { portrait[keyPath: key] = 0; itemOff[label] = nil; refresh() }
                    .help("双击这里还原为 0")
                    Button {
                        portrait[keyPath: key] = 0; itemOff[label] = nil; refresh()
                    } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                }
                Slider(value: Binding(get: { portrait[keyPath: key] },
                                      set: { portrait[keyPath: key] = $0; refresh() }),
                       in: range, step: step)
                    // ② 双击滑杆任意位置 = 复位（应用级监视器；手势那套收不到，见 SliderResetStore）
                    .sliderDblClickReset { portrait[keyPath: key] = 0; itemOff[label] = nil; refresh() }
                    .disabled(!on).opacity(on ? 1 : 0.45)
            }
            Toggle("", isOn: Binding(
                get: { on },
                set: { v in
                    if v {
                        portrait[keyPath: key] = itemOff[label] ?? (range.contains(30) ? 30 : range.lowerBound)
                        itemOff[label] = nil
                    } else {
                        itemOff[label] = portrait[keyPath: key]
                        portrait[keyPath: key] = 0
                    }
                    refresh()
                })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
    }
}
