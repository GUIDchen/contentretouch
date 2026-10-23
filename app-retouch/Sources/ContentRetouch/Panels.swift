// Panels.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {







    var rightPanels: some View {
        HStack(spacing: 0) {
            // 左侧栏：预设 / 历史 共用同一个位置，各自可开可关（#2：历史原来只能切到「历史面板」看，
            // 现在和预设一样是一条常驻可开关的列，位置也一样）
            if showPresets {
                presetColumn
                Divider()
            } else if showHistoryColumn {
                historyColumn
                Divider()
            } else {
                // 预设列与历史列都关掉时**留一条等宽的占位**：否则右侧功能区会整体左移，
                // 画布宽度一跳（用户要求：关闭后右侧功能区不要向左扩展，保持宽度不变）。
                Color.clear.frame(width: 215)
                Divider()
            }
            VStack(spacing: 0) {
                // #1 直方图**固定**在这里：原来它跟着「后调色」面板一起滚走，
                // 调别的面板时想看片子影调还得切回去。现在常驻在参数区顶部，不随面板滚动。
                if srcURL != nil {
                    HStack {
                        histogramView
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    Divider()
                }
                // 画布工具激活时，把**该工具自己的属性**顶到参数列最上面（直方图下方）：
                // 原来是各面板里各写一遍，而且有些属性（羽化/程度）根本没有。
                if activeCanvasTool != "" { toolPropertiesPanel }
                ScrollView { panelView.padding(12) }.frame(maxWidth: .infinity)
                // #4：历史回滚常驻在精修页底部，不用切面板就能撤销/回退。
                historyStrip
            }
            Divider()
            // 窄栏用 ScrollView 包住，不是装饰：加按钮让这一列超过窗口高度时，
            // VStack 会向上一层「要地方」，把上面那条工具条挤到画布上去
            // （实测：新加「追色/检索」两个按钮后，工具条整条下移压在画布上，自截图一眼可见）。
            // 内容放不下就自己滚动，绝不向上要空间。
            ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                // 分类名照像素蛋糕的窄栏：人像/图像/衣物/宠物/后调色/裁剪/历史/自定义
                colBtn("square.grid.2x2", "预设", 0)
                colBtn("person.crop.circle", "人像", 3)
                colBtn("photo", "图像", 9)
                colBtn("photo.on.rectangle.angled", "挑图", 5)
                colBtn("wand.and.stars", "追色", 12)
                colBtn("magnifyingglass", "检索", 13)
                colBtn("tshirt", "衣物", 8)
                colBtn("pawprint", "宠物", 10)
                colBtn("slider.horizontal.3", "后调色", 1)
                colBtn("person.crop.rectangle", "部位", 17)
                // ⑤ 裁剪只在**上方工具条**里有（用户要求右侧那个去掉），所以这里不再放裁剪入口
                // 「历史」已与上方那条历史列重复（内容一致：撤销/重做/清空 + 步骤列表 + 版本 + 批量结果），
                // 按要求只保留上方那一份；右侧「导出」也已移进右上角弹窗，两个入口都不在这里重复。
                // 「导出」已移到右上角的导出按钮弹窗里（用户要求），这里不再重复一个入口
                colBtn("trash", "回收站", 18)
                colBtn("clock.badge.questionmark", "待开发", 6)
                Divider().frame(width: 28)
                colBtn("books.vertical", "参照库", 16)
                colBtn("questionmark.circle", "帮助", 14)
                colBtn("envelope", "反馈", 15)
                Spacer(minLength: 0)
                // ⚠️ 容器宽度必须与 colBtn 的按钮宽度一致（§240）：§238 把按钮放宽到 56 却留着容器 54，
                // 汉字最后一点会被横向切掉。两处一起改，别再各写一份。
            }.frame(width: 56).padding(.vertical, 12)
            }
            .frame(width: 56)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// 常驻预设列（照像素蛋糕：分类 → 子项，另有「推荐 / 我的」两个页签）
    @ViewBuilder var presetColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("预设").font(.headline)
                Spacer()
                Button { showPresets = false } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
            // 推荐 / 我的（照参照物的两个页签）
            HStack(spacing: 4) {
                ForEach(["推荐", "我的"], id: \.self) { t in
                    let on = (t == "推荐") == (presetTab == 0)
                    Button { presetTab = (t == "推荐") ? 0 : 1 } label: {
                        Text(t).font(.system(size: 11, weight: on ? .semibold : .regular))
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(on ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10)))
                    }.buttonStyle(.plain)
                }
            }
            // 「应用方式 叠加/替换」已移到上方工具条（用户要求：不要放在预设列里）
            Text(applyMode == 1 ? "当前方式：替换（新方案整块覆盖）" : "当前方式：叠加（只改新方案动过的项）")
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            Text(presetTab == 0
                 ? "内置经验模板（不是官方预设；每条都列出目标数值，可核对）"
                 : "你自己存的预设（存在 Application Support，重开还在）")
                .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if presetTab == 0 {
                        // 收藏库聚类出来的参考组（有实测依据的那几条，放最上面）
                        ForEach(Array(styles.enumerated()), id: \.offset) { i, s in
                            if s.index < 1000 { presetRow(s, at: i) }
                        }
                        ForEach(presetGroups, id: \.name) { g in
                            let open = openPresetGroup == g.name
                            Button { openPresetGroup = open ? nil : g.name } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                    Text(g.name).font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text(String(g.items.count)).font(.system(size: 9)).foregroundColor(.secondary)
                                }.padding(.vertical, 3).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if open {
                                Text(g.note).font(.system(size: 9)).foregroundColor(.secondary)
                                    .lineLimit(3).fixedSize(horizontal: false, vertical: true).padding(.leading, 14)
                                ForEach(g.items, id: \.index) { it in
                                    if let i = styles.firstIndex(where: { $0.index == it.index && $0.name == it.name }) {
                                        presetRow(it, at: i).padding(.leading, 10)
                                    }
                                }
                            }
                        }
                    } else {
                        if myPresets.isEmpty {
                            Text("还没有自己的预设：调好一张后点下面的「保存当前为预设…」")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        ForEach(Array(myPresets.enumerated()), id: \.offset) { _, s in
                            if let i = styles.firstIndex(where: { $0.index == s.index && $0.name == s.name }) {
                                presetRow(s, at: i)
                            }
                        }
                    }
                }
            }
            Divider()
            // ⚠️ 这两个按钮在固定宽 215 的面板底部会被压缩截断（§238 实测截图里只剩半个字）——
            // 给它们 fixedSize，宁可窄栏整体滚动，也不让文字被切
            HStack(spacing: 6) {
                Button("存为预设…") { savePresetFile() }.font(.system(size: 10)).fixedSize()
                Button("载入…") { loadPresetFile() }.font(.system(size: 10)).fixedSize()
            }
        }
        .padding(10).frame(width: 215)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 预设行：名字 + 目标数值（可核对），当前选中的高亮
    func presetRow(_ s: StylePreset, at i: Int) -> some View {
        Button {
            // ⚠️ 这里**必须**走 applyPreset —— 原来它自己 inline 改参数（pushHistory + mergeParams），
            // 于是"再点一次 = 取消应用"那段逻辑永远走不到（用户三次报"预设再点仍未取消"就是这个）。
            // 与"部位变形"那次是同一类错误：修了 A，界面走的是 B。
            applyPreset(s)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(String(format: "q50 %.2f · 饱和 %.0f%% · 暖 %+.0f", s.target.q50, s.target.sat, s.target.warmSh))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(i == styleIdx ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)))
        }.buttonStyle(.plain)
    }

    func colBtn(_ icon: String, _ tip: String, _ idx: Int) -> some View {
        Button { panel = idx } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15))
                // ⚠️ 窄栏中文标签必须**限一行并允许缩字**（§238）：原来没有 lineLimit，
                // 稍长的标签（如「批量导出」）会换行成两行，把下面一个按钮顶掉、文字互相压住。
                // 宽度也从 46 放到 56：46 放不下 4 个汉字，缩字到 0.6 会小得看不清。
                Text(tip).font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(width: 56)
            .foregroundColor(panel == idx ? .accentColor : .primary)
        }.buttonStyle(.plain)
    }

    @ViewBuilder var panelView: some View {
        switch panel {
        case 2: historyPanel
        case 3: facePanel
        // §245：首页那张「去瑕疵/磨皮」快捷卡片指向 panel = 4，而这里**从来没有 case 4** ⇒
        // 点它会落到 default（队列面板）—— 用户看到的就是「点了首页卡片，出来的面板不对」。
        // 4 号就是人像面板（磨皮/祛瑕所在），与卡片文案一致。
        case 4: facePanel
        case 5: pickPanel
        case 6: placeholderPanel
        case 7: editPanel
        case 8: clothesPanel
        case 9: imagePanel
        case 10: petPanel
        case 17: partsPanel
        case 18: trashPanel
        case 12: refPanel
        case 13: searchPanel
        case 14: helpPanel
        case 15: feedbackPanel
        case 16: refLibPanel
        case 11: exportPanel
        case 0: stylePanel
        case 1: paramPanel
        default: queuePanel
        }
    }

    var stylePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预设").font(.headline)
            // 分类词照像素蛋糕（实测：无效果 / 肤质肤色 / 质感肌 / 防油肌 / 原生肌 / 肤质·中性 / 肤色·暖冷 / 胶片 / 婚纱 / 婚礼跟拍）
            // 区别在于：它的预设是官方做的，我们的风格是从「你自己的收藏库」聚类出来的——所以这排词只作对照，不塞进列表冒充预设。
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["无效果", "肤质肤色", "质感肌", "原生肌", "肤色·暖冷", "胶片", "婚纱", "婚礼跟拍"], id: \.self) { c in
                        Text(c).font(.system(size: 10)).foregroundColor(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
            Text("↑ 像素蛋糕的预设分类词，供对照；下面这几组是**从你的收藏库长出来的**")
                .font(.caption2).foregroundColor(.secondary)
            Text("参考组（来自你的收藏库聚类）").font(.system(size: 12, weight: .medium))
            ForEach(Array(styles.enumerated()), id: \.offset) { i, s in
                Button {
                    applyPreset(s)     // 统一入口：这样"再点一次 = 取消应用"对参考组也生效
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i == styleIdx ? s.name + "（已应用）" : s.name).font(.system(size: 12)).lineLimit(1)
                            Text(String(format: "q50 %.2f · 饱和 %.0f%% · 高光色偏 %+.0f", s.target.q50, s.target.sat, s.target.warmHi))
                                .font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if i == styleIdx { Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor) }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == styleIdx ? Color.accentColor.opacity(0.12) : Color.black.opacity(0.04)))
                }.buttonStyle(.plain)
            }
            Divider()
            Divider()
            Text("场景识别 → 推荐参数").font(.system(size: 11, weight: .medium))
            Button("识别场景并套用推荐…") { runSceneSuggest() }.disabled(srcURL == nil)
            if let info = sceneInfo {
                Text("判为「" + info.category + "」｜脸 " + String(info.faces) + " 人 " + String(info.people)
                     + " 动物 " + String(info.animals)).font(.caption2).foregroundColor(.secondary)
                Text(info.reasons.joined(separator: "；")).font(.caption2).foregroundColor(.secondary)
                Text("标签：" + info.labels.prefix(4).map { $0.0 }.joined(separator: "/"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text("用的是系统图像分类 + 人脸/人体/动物检测，映射成我们自己的经验参数，不是官方预设。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("预设管理").font(.system(size: 11, weight: .medium))
            HStack {
                Button("保存当前为预设…") { savePresetFile() }.disabled(styles.isEmpty)
                Button("载入预设…") { loadPresetFile() }
            }.font(.system(size: 11))
            Text("预设 schema v1（contentretouch.preset/v1）：调色参数可存可传，往返一致。")
                .font(.caption2).foregroundColor(.secondary)
            Divider()
            Text("检索：拿当前原片在 13,484 张参考库里找相似组（M4a）").font(.caption).foregroundColor(.secondary).padding(.top, 6)
            Button("查相似参考组…") { findSimilar() }.disabled(srcURL == nil)
        }
    }






}
