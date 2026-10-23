// CanvasOverlay.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 参考线：三分线 + 中心线（像素蛋糕的参考线是同一用途）
    var guidesOverlay: some View {
        GeometryReader { g in
            Path { p in
                for f in [1.0/3, 2.0/3] {
                    p.move(to: CGPoint(x: g.size.width * f, y: 0))
                    p.addLine(to: CGPoint(x: g.size.width * f, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: g.size.height * f))
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height * f))
                }
                p.move(to: CGPoint(x: g.size.width / 2, y: 0)); p.addLine(to: CGPoint(x: g.size.width / 2, y: g.size.height))
                p.move(to: CGPoint(x: 0, y: g.size.height / 2)); p.addLine(to: CGPoint(x: g.size.width, y: g.size.height / 2))
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)
        }.allowsHitTesting(false)
    }

    /// 「有范围的笔刷类工具」——只有这些才显示范围圈、才允许在圈上拖改大小。
    /// **裁剪不算**：裁剪拖的是矩形框，给它画一个笔刷圈既误导、又会把拖动抢去改半径。
    var realBrushActive: Bool {
        brushActive || spotActive || patchActive || cloneActive
    }

    /// 需要十字光标、需要抢画布拖动的工具（裁剪也在内）
    var brushToolActive: Bool { realBrushActive || cropMode }

    /// 落点叠加：把用户涂过的点/笔触画出来。
    ///
    /// 为什么必须有它：污点修复、修补、仿制图章、液化刷**只改像素、不留痕迹**——
    /// 在小面积或低对比的地方涂一下，画面几乎看不出变化，用户的第一反应就是「这功能没实现」。
    /// （这是这一轮里最值得补的一环：功能一直在跑，缺的是「我涂到哪儿了」的反馈。）
    var strokesOverlay: some View {
        GeometryReader { g in
            let box = srcImage.map { displayedRect(viewSize: g.size, imageSize: $0.size) } ?? .zero
            ZStack {
                // 每个点画一个小圈（ViewBuilder 里不能写局部函数，所以直接内联）
                // 注意判据用的是「有没有落点」，不是「工具是否开着」：污点/液化的落点
                // 即使切走工具也仍然生效（渲染链里没有把它们绑在开关上），标记就必须跟着一起显示，
                // 否则「效果还在、标记没了」，反而更让人困惑。
                // 默认**不画**落点标记：用户反馈"停留的圈挡着看效果"。
                // 拖动过程中仍然画（那是正在做的事），停下来就干净；需要常显时用工具属性里的开关。
                // ① **只画最新一次操作**的标记：原来把历史所有落点都画出来，
                // 于是"按下去就满屏旧圈"（用户报的正是这个）。
                // 拖动中画当前这一笔的全部落点（那是正在做的事）；松手后只留最后一个点。
                // 可见性判据从「开关或拖动中」改成「有落点就显示最新一次」：
                // 用户要的正是"只看最新一次的操作圈"，而原来停下后**一个都不画**（我自检里那句
                // "画出的圈数=1"是我自己算的，不是真实渲染条件——这轮把它改对了）。
                // ④ **两套画布分开画**（用户报：主画布的圈在液化工作区里还在；液化工作区的圈
                // 关掉工作区后还留在主画布上）。原因是主画布和液化工作区**共用同一个 pane()**，
                // 于是共用这一个叠加层。按当前在哪套画布决定画哪些。
                // ③ 每个工具只画**自己**的圈（用户报：用仿制图章时污点/修补的圈也冒出来）。
                // 效果本身与开关无关（关工具效果还在，见第 107 节）——这里只管"画不画提示圈"。
                if !liquifyWorkspace, spotActive, !spotPoints.isEmpty {
                    markers(spotPoints, from: strokeStartSpot, box: box, color: .orange, dia: 14)
                }
                // 诊断（CR_UITRACE）：叠加层自报几何 —— 用来确认"圈到底画在屏幕哪儿"
                if ProcessInfo.processInfo.environment["CR_UITRACE"] != nil, !spotPoints.isEmpty || !clonePoints.isEmpty || !patchPoints.isEmpty {
                    let last = spotPoints.last ?? patchPoints.last ?? clonePoints.last!
                    let _ = FileHandle.standardError.write(("UITRACE 叠加层 size=" + String(format: "%.0fx%.0f", g.size.width, g.size.height)
                        + " box=" + String(format: "%.0f,%.0f %.0fx%.0f", box.minX, box.minY, box.width, box.height)
                        + " 最后一个点=" + String(format: "%.3f,%.3f", last.x, last.y)
                        + " 圈心=" + String(format: "%.0f,%.0f", box.minX + last.x * box.width, box.minY + (1 - last.y) * box.height)
                        + " 画标记=是（只画最新一个）"
                        + "｜主画布[污点=" + ((!liquifyWorkspace && !spotPoints.isEmpty) ? "画" : "不画")
                        + " 修补=" + ((!liquifyWorkspace && patchActive && !patchPoints.isEmpty) ? "画" : "不画")
                        + " 仿制=" + ((!liquifyWorkspace && cloneActive && !clonePoints.isEmpty) ? "画" : "不画")
                        + " 范围=" + ((!liquifyWorkspace && !regions.isEmpty) ? "画" : "不画") + "]"
                        + "｜液化工作区[液化=" + ((liquifyWorkspace && !warpStrokes.isEmpty) ? "画" + String(strokeMarkLive ? min(warpStrokes.count - strokeStartWarp, 6) : 1) + "个" : "不画") + "]\n").data(using: .utf8)!)
                }
                if !liquifyWorkspace, patchActive, !patchPoints.isEmpty {
                    markers(patchPoints, from: strokeStartPatch, box: box, color: .yellow, dia: 14)
                }
                if !liquifyWorkspace, cloneActive {
                    // 取样点（绿）随时可见：用户要能在中途看清"现在从哪取样"
                    if let s = cloneSource { strokeDot(s, box: box, color: .green, dia: 24) }
                    if !clonePoints.isEmpty { markers(clonePoints, from: strokeStartClone, box: box, color: .cyan, dia: 14) }
                }
                // ③ 范围的轮廓**始终画出来**（选中那个用高亮色）：
                // 之前画完范围在画布上什么都看不见（只多了一堆滑杆），用户自然认为"没反应"。
                ForEach(regions) { r in
                    let rb = CGRect(x: box.minX + r.rect.minX * box.width,
                                    y: box.minY + (1 - r.rect.minY - r.rect.height) * box.height,
                                    width: r.rect.width * box.width, height: r.rect.height * box.height)
                    // 轮廓按**形状**画：0 矩形 / 1 椭圆 / 2 圆形（圆形取短边，与渲染一致）
                    Group {
                        if r.shape == 1 {
                            Ellipse().stroke(r.id == selectedRegion ? Color.accentColor : Color.white.opacity(0.55),
                                             lineWidth: r.id == selectedRegion ? 2 : 1)
                        } else if r.shape == 2 {
                            Circle().stroke(r.id == selectedRegion ? Color.accentColor : Color.white.opacity(0.55),
                                            lineWidth: r.id == selectedRegion ? 2 : 1)
                        } else {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(r.id == selectedRegion ? Color.accentColor : Color.white.opacity(0.55),
                                        style: StrokeStyle(lineWidth: r.id == selectedRegion ? 2 : 1,
                                                           dash: r.enabled ? [] : [4, 3]))
                        }
                    }
                    .frame(width: r.shape == 2 ? max(2, min(rb.width, rb.height)) : max(2, rb.width),
                           height: r.shape == 2 ? max(2, min(rb.width, rb.height)) : max(2, rb.height))
                    .position(x: rb.midX, y: rb.midY)
                    // 蒙版涂过的点画出来（原来涂完什么都看不见，等于没有反馈）
                    .overlay(maskPaintOverlay(r, box: box).allowsHitTesting(false))
                }
                // 液化落点：**只在液化工作区里画**（关掉工作区后主画布不该留着这些圈），
                // 并且拖动中只画当前这一笔。
                if liquifyWorkspace, !warpStrokes.isEmpty {
                    let d = brushRadiusPx(viewSize: g.size, imageSize: srcImage?.size ?? .zero) * 2
                    let shown = strokeMarkLive ? Array(warpStrokes.dropFirst(min(strokeStartWarp, warpStrokes.count)))
                                               : Array(warpStrokes.suffix(1))
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, st in
                        strokeDot(st.center, box: box, color: .purple, dia: max(6, Double(d) * 0.45))
                    }
                }
            }
        }.allowsHitTesting(false)
    }

    /// 一个落点小圈（归一化坐标 y 向上，屏幕 y 向下，所以要翻一下）
    func strokeDot(_ p: CGPoint, box: CGRect, color: Color, dia: Double) -> some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.2)
            .background(Circle().fill(color.opacity(0.25)))
            .frame(width: dia, height: dia)
            .position(x: box.minX + p.x * box.width, y: box.minY + (1 - p.y) * box.height)
    }

    /// 冻结区叠加：画成蓝圈，让「哪些地方锁住了」看得见（像素蛋糕的「显示蒙版」）
    var freezeOverlay: some View {
        GeometryReader { g in
            ZStack {
                ForEach(Array(freezeStrokes.enumerated()), id: \.offset) { _, f in
                    Circle()
                        .stroke(Color.blue.opacity(0.7), lineWidth: 1.5)
                        .background(Circle().fill(Color.blue.opacity(0.15)))
                        .frame(width: CGFloat(f.radius * 2) / 100 * max(g.size.width, g.size.height),
                               height: CGFloat(f.radius * 2) / 100 * max(g.size.width, g.size.height))
                        .position(x: f.center.x * g.size.width, y: (1 - f.center.y) * g.size.height)
                }
            }
        }.allowsHitTesting(false)
    }
}
