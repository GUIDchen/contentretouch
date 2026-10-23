// PanelsLibrary.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {







    // MARK: 参考追色面板
    var refPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参考追色").font(.headline)
            Text("给几张「想要的样子」，折算成目标影调与色彩，再把这张图追过去。目标取参考图的**中位数**——一张异类不会把整组带偏。")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Button("选择参考图…") { pickRefs() }
                Button("清空") { refPaths = []; refTargetStats = nil; refInfo = "" }
            }
            HStack(spacing: 6) {
                TextField("或粘贴图片直链 / 带 og:image 的网页", text: $refURLText).font(.system(size: 11))
                Button("抓取") { grabRefs() }
            }
            if !refPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(refPaths.indices, id: \.self) { i in
                            if let ns = thumb(refPaths[i], 72) {
                                Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: 72, height: 72).clipped().cornerRadius(6)
                            }
                        }
                    }
                }
            }
            Button("① 折算目标") { solveRef() }.disabled(refPaths.isEmpty)
            if let t = refTargetStats {
                Text(String(format: "目标 q5/q50/q95 = %.2f/%.2f/%.2f　饱和 %.0f%%　阴影暖冷 %+.1f　高光暖冷 %+.1f",
                            t.q5, t.q50, t.q95, t.sat, t.warmSh, t.warmHi)).font(.system(size: 11))
            }
            // 分区追色（#4）：全局之外，可以再指定"只把某个区域朝参考的同一区域看齐"
            VStack(alignment: .leading, spacing: 4) {
                Text("分区追色（勾选后，这些区域各自朝参考的**同一区域**看齐）")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach([ColorRegion.skin, .person, .background, .environment], id: \.self) { r in
                        Toggle(r.rawValue, isOn: Binding(
                            get: { refRegionSel.contains(r.rawValue) },
                            set: { v in
                                if v { refRegionSel.insert(r.rawValue) } else { refRegionSel.remove(r.rawValue) }
                            })).toggleStyle(.checkbox).font(.system(size: 10))
                    }
                }
                Text(refRegionHint).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("② 追色修这张图") { applyRef() }.disabled(srcURL == nil || refTargetStats == nil)
                // ⑨ 随时取消追色：还原到追色之前的状态
                Button("取消追色") {
                    guard let prev = preRefSnapshot else { status = "还没有追过色"; return }
                    pushHistory("取消追色")
                    apply(prev)
                    preRefSnapshot = nil
                    regionMatches = []
                    refInfo = "已取消追色，回到追色之前的状态"
                    status = refInfo
                }.disabled(preRefSnapshot == nil)
            }
            if !refInfo.isEmpty { Text(refInfo).font(.caption2).foregroundColor(.secondary) }
            Text("实测（2 张冷调原图 → 3 张暖调参考）：与参考的误差 1.738→0.733、1.865→0.656；\n按索引独立复量：亮度 0.13→0.33（参考 0.37）、暖冷 −3.0→+12.0（参考 +24.9）。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 素材库检索面板
    var searchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("素材库检索").font(.headline)
            Text("先把目录里的图抽成要素表（分类词 / 人脸 / 人数 / 天空 / 色彩 / 构图），之后按关键词秒查。")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                TextField("例：天空 多人 暖色　（空格分隔=与）", text: $searchQuery).font(.system(size: 11))
                Button("检索") { runSearch() }
            }
            HStack(spacing: 6) {
                Button("以图搜图") { runSimilar() }.disabled(srcURL == nil)
                Button("建索引…") { runIndex() }.disabled(indexBusy)
                Text(indexProgress.isEmpty ? indexPathHint : indexProgress)
                    .font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
            Text("中文行业词（朱砂 / 晨袍）不是识别出来的，而是**由可测特征映射**出来的：红色占比 + 人数 + 室内 + 无天空。")
                .font(.caption2).foregroundColor(.secondary)
            if !simInfo.isEmpty {
                Text(simInfo).font(.caption2).foregroundColor(.secondary)
                ForEach(Array(simHits.prefix(12).enumerated()), id: \.offset) { _, h in
                    Button {
                        switchToImage(URL(fileURLWithPath: h.0))
                    } label: {
                        HStack(spacing: 4) {
                            Text(String(format: "%.3f", h.1)).font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text((h.0 as NSString).lastPathComponent).font(.system(size: 10)).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }
                Divider()
            }
            if !searchHits.isEmpty {
                Text("命中 \(searchHits.count) 张（显示前 60，点一条载入）").font(.system(size: 11, weight: .medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(searchHits.prefix(60).indices), id: \.self) { i in
                            let r = searchHits[i]
                            Button {
                                switchToImage(URL(fileURLWithPath: r.path))
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.file).font(.system(size: 11)).lineLimit(1)
                                    Text(String(format: "脸 %d　人 %d　天空 %.0f%%　亮 %.2f　暖 %+.0f",
                                                r.faces, r.persons, r.sky * 100, r.luma, r.warm))
                                        .font(.system(size: 9)).foregroundColor(.secondary)
                                    Text(r.tags.prefix(12).joined(separator: " "))
                                        .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 320)
            }
        }
    }




    // MARK: 参照图库（#1 选图库 / #2 生成可用的参照图 / #3 增量索引）
    var refLibPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("参照图库").font(.headline)
            Text("选一个照片目录当「参照对照图库」：用来找与当前照片风格接近的参照图，并折算成追色目标。")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Button("选择图库目录…") { pickRefLibrary() }
                Button("增量更新索引") { runRefLibIndex() }.disabled(refLibBusy || refLibDir.isEmpty)
            }
            if refLibDir.isEmpty {
                Text("还没选图库。").font(.caption2).foregroundColor(.secondary)
            } else {
                Text((refLibDir as NSString).lastPathComponent + "（已索引 \(refLibIndex) 张）")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Text(refLibDir).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2)
                if !refLibProgress.isEmpty {
                    Text(refLibProgress).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Divider()
            Text("推荐参照图").font(.system(size: 11, weight: .medium))
            Text("按当前照片在参照图库里的相似度排序（用 768 维图像嵌入，不是比色调）。选中的那张会作为画布第三栏显示。")
                .font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Button("找相似参照图") { recommendRefs() }.disabled(srcURL == nil || refLibIndex == 0)
                Button(hasRefEmbeddings ? "重建嵌入表" : "建图像嵌入表") { runRefLibEmbeddings() }
                    .disabled(refLibBusy || refLibIndex == 0)
                    .help("768 维图像嵌入：找相似参照图靠它。一万三千张约 6~10 分钟，只需建一次")
                Button(showRefPane ? "隐藏参照图栏" : "显示参照图栏") { showRefPane.toggle() }
                    .disabled(chosenRef == nil)
            }
            if !recRefs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(recRefs.enumerated()), id: \.offset) { _, r in
                            VStack(spacing: 2) {
                                if let t = ThumbCache.shared.image(URL(fileURLWithPath: r.path), maxPixel: 160) {
                                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 84, height: 84).clipped().cornerRadius(5)
                                        .overlay(RoundedRectangle(cornerRadius: 5)
                                            .stroke(chosenRef == r.path ? Color.accentColor : Color.black.opacity(0.2),
                                                    lineWidth: chosenRef == r.path ? 2.5 : 1))
                                }
                                Text(String(format: "%.3f", r.distance))
                                    .font(.system(size: 8)).foregroundColor(.secondary)
                            }
                            .onTapGesture {
                                chosenRef = r.path
                                showRefPane = true
                                status = "参照图已选中：" + (r.path as NSString).lastPathComponent
                            }
                        }
                    }
                }.frame(height: 104)
                Button("用这些参照图追色") { applyRefsAsTarget() }.font(.system(size: 11))
            }
            Divider()
            Text(hasRefEmbeddings
                 ? "嵌入表已就绪：找相似参照图走的是 768 维图像嵌入。"
                 : "还没有嵌入表：现在点「找相似参照图」只能按亮度/暖冷粗排。点「建图像嵌入表」一次（约 6~10 分钟）之后就准了。")
                .font(.caption2).foregroundColor(hasRefEmbeddings ? .secondary : .orange)
                .font(.caption2).foregroundColor(.secondary)
        }
    }





}
