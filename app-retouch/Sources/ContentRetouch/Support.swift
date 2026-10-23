// 从 ContentRetouchApp.swift 搬出来的**画布/数据支撑件**。
//
// 为什么要搬：主文件一度到 7000+ 行，而这一批类型是"被多个面板共用"的基础设施——
// 它们散在巨文件里时最容易出现"改对了 A、界面走的是 B"（这个项目里已经踩过三次：
// 预设取消、部位变形、双击复位）。集中到一处后，至少这些支撑件只有一份。
//
// 内容：MaskStroke/RegionAdjust/HistoryEntry/BatchRow（数据）、ThumbCache（缩略图缓存）、
// CanvasGlobalKey/PaneFramesKey（画布坐标上报）、CanvasInput（事件监视器）、
// CursorArea/CursorNSView（光标）、CanvasEventCatcher（AppKit 画布事件捕获）、DblClickReset（双击复位）。

import SwiftUI
import AppKit
import CoreImage
import RetouchCore

struct MaskStroke: Codable, Equatable {
    var x: Double
    var y: Double
    var r: Double
}

struct RegionAdjust: Identifiable {
    let id = UUID()
    var shape = 0                     // 0 矩形 1 椭圆 2 圆形；3 = 只用画笔涂（不要形状）
    var rect = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)   // 归一化
    var feather = 30.0
    var enabled = true
    /// 蒙版画笔（照 PS 的图层蒙版：白 = 生效、黑 = 不生效）
    var paintAdd: [MaskStroke] = []
    var paintSub: [MaskStroke] = []
    var inverted = false
    // 增量（只列最常用的几项，够"局部加减一点"用）
    var dBrightness = 0.0
    var dContrast = 0.0
    var dSat = 0.0
    var dWarm = 0.0
    var dGamma = 0.0
    var isEmpty: Bool {
        abs(dBrightness) < 0.01 && abs(dContrast) < 0.01 && abs(dSat) < 0.01
            && abs(dWarm) < 0.01 && abs(dGamma) < 0.005
    }
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    var label: String
    var date = Date()
    var params: Params
    var portrait: PortraitOptions
    var skinGrade: String
    var skinStrength: Double
    var skinTone: Bool
    var texturePreserve: Bool
    var slimWaist: Double
    var wideShoulders: Double
    var bgPurify: Double
    var clothes: Double
    var pet: Double
    var liquifyAmount: Double
    var crop: CGRect?
    var cropApplied = false
    var rotateDeg: Double
    var flipH: Bool
    var quarterTurns: Int
    // 手绘/工具类的状态也要进历史：否则"回到某一步"只回到滑杆值，涂过的点/笔触不会跟着回退
    var spotPoints: [CGPoint] = []
    var clonePoints: [CGPoint] = []
    var patchPoints: [CGPoint] = []
    /// 仿制的取样段（撤销/重做后"来源跟着笔走"的偏移要能复原）
    var cloneEpochs: [(at: Int, source: CGPoint)] = []
    var cloneSource: CGPoint? = nil
    var warp: [WarpStroke] = []
    var freeze: [WarpStroke] = []
    var sky: SkyOptions = SkyOptions()
    var regions: [RegionAdjust] = []
    var skinMaskShow = false
}

struct BatchRow: Identifiable {
    let id = UUID()
    var file: String
    var errBefore: Double
    var errAfter: Double
    var params: Params
    var alreadyClose: Bool
}

/// 缩略图缓存：**只解码到显示需要的像素数**，并用 NSCache 限总量。
///
/// 为什么必须有它：底栏缩略图条原来直接 `NSImage(contentsOf:)`——那是**整张原图**（24MP 的片子
/// 一解码就是几十 MB）。导入一整个素材库（实测 13485 张）时，内存直接从 0.2 GB 冲到 **3.17 GB**，
/// 而且还在涨；用户报的「一加载文件内存就飙到 50 多 G」就是这条路径。
/// 现在改成 ImageIO 的缩略图解码（只出 128px），再配一个 300 张上限的缓存：
/// 13,485 张的缩略图全在缓存里也只有约 17 MB。
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 300 }

    func image(_ url: URL, maxPixel: Int = 128) -> NSImage? {
        let key = "\(url.path)|\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: key)
        return img
    }
}

/// 画布的滚轮输入。
///
/// 为什么用「本地事件监听」而不是自定义 NSView：鼠标滚轮事件是按命中测试派发的，
/// 一个 hitTest 返回 nil 的透明视图**收不到 scrollWheel**；而那些能收到滚轮的视图会顺手把
/// 鼠标按下也吃掉，画布的笔刷/抓手就全废了。本地监听器只旁观、不参与命中测试，
/// 而且只在指针确实位于画布内时才消费事件（其余位置照常滚给别的控件）。
/// 各图框在画布坐标里的矩形（键是栏标题）
/// Canvas rect in screen coordinates (the mouse monitor uses it to test the press point).
struct CanvasGlobalKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

struct PaneFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}


/// 双击滑杆 = 还原初始值（**统一入口**）。
///
/// 为什么要有这个修饰器：项目里其实有**四套滑杆**（slider / miniSlider / pSlider / 裸 Slider），
/// 我上一轮只给 `slider` 加了双击复位，于是用户在人像面板（pSlider）和工具属性（miniSlider）里
/// 试双击仍然毫无反应——"滑杆双击还原仍未实现"就是这么来的。
/// 现在统一走这里，加新滑杆时也只需挂一个修饰器。
/// 注意：必须用 `simultaneousGesture` —— `onTapGesture` 会被 Slider 自己消费掉，双击传不上来。
struct DblClickReset: ViewModifier {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let onChange: () -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(TapGesture(count: 2).onEnded {
            value = range.lowerBound
            onChange()
        })
        .help("双击还原为初始值（" + String(format: "%.2f", range.lowerBound) + "）")
    }
}

extension View {
    func dblClickReset(_ value: Binding<Double>, in range: ClosedRange<Double>,
                       label: String = "", onChange: @escaping () -> Void) -> some View {
        modifier(DblClickReset(value: value, range: range, label: label, onChange: onChange))
    }
}

final class CanvasInput: ObservableObject {
    var mouseMonitor: Any?; var dragMonitor: Any?; var upMonitor: Any?
    static let shared = CanvasInput()
    /// ② 液化工作区是否打开（打开时方向键 = 推一笔）
    @Published var liquifyArmed = false
    /// 方向键推一笔：每次自增，视图观察后消费掉
    @Published var pushTick = 0
    var pendingPush: (Double, Double) = (0, 0)
    @Published var zoomTick: Double = 0
    /// 撤销/重做：⌘Z / ⇧⌘Z 被 macOS 标准的「编辑」菜单（走响应链的 undo:）先接走了，
    /// 视图上挂的 keyboardShortcut 根本轮不到。所以用本地事件监听在**菜单之前**截下这两个键。
    @Published var undoTick = 0
    @Published var redoTick = 0
    var pointerInCanvas = false
    private var monitor: Any?
    private var keyMonitor: Any?

    // ── 拖动走 AppKit 事件监视器，而不是 SwiftUI 手势 ──
    // 原因：用户反复报"抓手大图拖不动、液化向前推/左推没反应"，而点按类工具（收缩/膨胀）正常。
    // 我用合成鼠标事件（win.postEvent）测过：事件确实到了窗口、工具状态也对，但面板上的
    // DragGesture 回调一次都没触发——也就是说这条通路在用户机器上不可靠。
    // 本项目已经用同样的手段（NSEvent 本地监视器）稳定解决了滚轮缩放、⌘Z 被菜单吃掉两件事，
    // 所以拖动也照这条路走：不依赖 SwiftUI 的手势识别， directement 收鼠标事件。
    @Published var dragging = false          // 正在画布内按住左键
    @Published var dragTick = 0              // 每次移动自增（视图观察后消费）
    @Published var dragPhase = 0             // 0=按下 1=移动 2=松开
    var dragStart = CGPoint.zero             // 按下点（窗口坐标）
    var dragPoint = CGPoint.zero             // 当前点（窗口坐标）
    var canvasFrame = CGRect.zero            // hua bu zai chuang kou zuo biao li de ju xing (legacy)
    var canvasFrameGlobal = CGRect.zero      // hua bu zai ping mu zuo biao li de ju xing (monitor yong)
    var dragModifiers: NSEvent.ModifierFlags = []

    func installMouse() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
            let c = CanvasInput.shared
            let screenPt = e.window?.convertPoint(toScreen: e.locationInWindow) ?? e.locationInWindow
            if ProcessInfo.processInfo.environment["CR_DIAG"] != nil {
                FileHandle.standardError.write(("DIAG 鼠标按下 屏幕 " + String(Int(screenPt.x)) + "," + String(Int(screenPt.y))
                    + " 画布 " + String(Int(c.canvasFrameGlobal.minX)) + "," + String(Int(c.canvasFrameGlobal.minY))
                    + "," + String(Int(c.canvasFrameGlobal.width)) + "," + String(Int(c.canvasFrameGlobal.height))
                    + "\n").data(using: .utf8)!)
            }
            // SwiftUI 的 .global 是**屏幕坐标、原点左上**；AppKit 的 convertPoint(toScreen:) 是**原点左下**。
            // 两者相差一次 y 翻转——上一版没翻，命中判定永远为假（DIAG 打印出来是 y=37 / y=-8，一眼可见）。
            let screenH = NSScreen.main?.frame.height ?? 0
            let ptTopLeft = CGPoint(x: screenPt.x, y: screenH - screenPt.y)
            // 命中判定：优先用画布矩形；矩形没拿到或算不准时，退化成「排除右侧参数区与顶部工具条」。
            // 宁可多认一点，也不要出现「点了没反应」。
            let winW = e.window?.frame.width ?? 1200
            let winH = e.window?.frame.height ?? 800
            let inRightPanel = e.locationInWindow.x > winW - 360
            let inTopBar = e.locationInWindow.y > winH - 60
            let rectKnown = c.canvasFrameGlobal.width > 10
            let inCanvas = rectKnown ? c.canvasFrameGlobal.contains(ptTopLeft) : true
            guard !inRightPanel, !inTopBar, inCanvas else { return e }
            c.dragging = true; c.dragPhase = 0
            c.dragStart = e.locationInWindow; c.dragPoint = e.locationInWindow
            c.dragModifiers = e.modifierFlags
            c.dragTick += 1
            return e        // 不吞：按钮、滑杆等正常控件还要用
        }
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { e in
            let c = CanvasInput.shared
            guard c.dragging else { return e }
            c.dragPhase = 1; c.dragPoint = e.locationInWindow
            if ProcessInfo.processInfo.environment["CR_DIAG"] != nil {
                print("DIAG 拖动事件到达 x=" + String(Int(e.locationInWindow.x)))
                fflush(stdout)
            }
            c.dragModifiers = e.modifierFlags
            c.dragTick += 1
            // 注意：不要吞 mouseDragged / mouseUp。吞掉抬起事件，按钮永远收不到 mouseUp，
            // 表现就是所有按钮点了都没反应（上一版吞过，用户立刻报了这个问题）。
            return e
        }
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { e in
            let c = CanvasInput.shared
            guard c.dragging else { return e }
            c.dragPhase = 2; c.dragPoint = e.locationInWindow
            c.dragTick += 1
            c.dragging = false
            return e     // 同样不能吞：按钮要靠这个 mouseUp 才算点完
        }
    }

    func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let cmd = e.modifierFlags.contains(.command)
            let shift = e.modifierFlags.contains(.shift)
            // ② 方向键 = 在液化工作区里"推一笔"（不依赖鼠标拖动这条通路）。
            // 只在液化工作区打开时生效，否则会抢走列表导航等正常用途。
            if !cmd, CanvasInput.shared.liquifyArmed,
               [123: (0.0, -1.0), 124: (1.0, 0.0), 125: (0.0, 1.0), 126: (0.0, -1.0)][Int(e.keyCode)] != nil {
                let dir: (Double, Double)
                switch Int(e.keyCode) {
                case 123: dir = (-1, 0)      // ←
                case 124: dir = (1, 0)       // →
                case 125: dir = (0, 1)       // ↓（图像坐标 y 向上，所以"往下推"是 +y）
                default:  dir = (0, -1)      // ↑
                }
                CanvasInput.shared.pushTick += 1
                CanvasInput.shared.pendingPush = dir
                return nil                   // 吃掉，免得方向键去滚列表
            }
            guard cmd, e.charactersIgnoringModifiers?.lowercased() == "z" else { return e }
            DispatchQueue.main.async {
                if shift { CanvasInput.shared.redoTick += 1 } else { CanvasInput.shared.undoTick += 1 }
            }
            return nil    // 吃掉：不要让系统菜单再去处理
        }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            guard CanvasInput.shared.pointerInCanvas else { return e }
            CanvasInput.shared.zoomTick += Double(e.scrollingDeltaY)
            return nil    // 消费掉：否则上下滚动会去滚右侧面板
        }
    }
}

/// 光标区域：让画布在「笔刷工具 / 抓手 / 普通」之间切换鼠标指针。
/// SwiftUI 没有直接设置光标的能力，所以放一个透明的 NSView 进去，
/// 用 AppKit 的 cursor rect 机制——这是系统推荐的做法，比自己 push/pop NSCursor 稳
///（后者一旦漏掉一次 pop，光标就永久卡在十字线上）。
final class CursorNSView: CursorTrackingView {
    /// 不参与命中测试：事件照样走到下面的 SwiftUI 手势里
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 圆形笔刷光标：直径 = 画布上那个范围圈的真实大小。
/// 用户原话：“应该改为圆圈，可改变大小” —— 十字只能指位置，圈才看得出**这一下会作用到多大范围**。
/// 按直径缓存：避免每次重绘都造一个新 NSCursor（那样 didSet 的相等判断永远为假，白白刷光标）。
enum BrushCursor {
    private static var cache: [Int: NSCursor] = [:]
    static func circle(_ dia: CGFloat) -> NSCursor {
        let d = max(8, min(240, dia.rounded()))
        if let c = cache[Int(d)] { return c }
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            // 双色描边（外深内白）：浅色/深色照片上都能看清
            let outer = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            outer.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.6).setStroke(); outer.stroke()
            let inner = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            inner.lineWidth = 1.5
            NSColor.white.withAlphaComponent(0.95).setStroke(); inner.stroke()
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: d / 2, y: d / 2))
        cache[Int(d)] = c
        return c
    }
}

/// 光标跟踪基类：**全仓只此一份实现**（这个项目两次栽在“两处各写一份、只改了一处”）。
///
/// ⚠️ 为什么原来“设了光标却还是箭头”（用户报了三次）：
/// AppKit 只在**窗口接受 mouseMoved 事件**、且视图有 tracking area 时才会去跑光标逻辑。
/// 全仓从没设过这两样，cursorRect 等于挂在那里没人查 —— 不是值传错，是机制没启动。
class CursorTrackingView: NSView {
    var cursor: NSCursor = .arrow {
        didSet { if cursor != oldValue { applyCursor() } }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    private var tracking: NSTrackingArea?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                         .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func cursorUpdate(with event: NSEvent) { applyCursor() }
    override func mouseEntered(with event: NSEvent) { applyCursor() }
    override func mouseMoved(with event: NSEvent) { applyCursor() }
    func applyCursor() { cursor.set() }
}


/// 画布事件捕获视图（AppKit 直接收鼠标事件）。
///
/// 为什么需要它：SwiftUI 面板上的 `DragGesture` 在用户机器上一直不生效（点按类却正常）。
/// 与其继续猜手势竞争，不如**让 AppKit 直接把事件送到我们自己的 NSView** —— 这条路上没有
/// SwiftUI 的手势识别参与，事件派发是 AppKit 的基本能力（滚轮/按键监视器早已证明可用）。
///
/// 只在"拖动类工具"激活时挂上去：其余情况仍然走 SwiftUI（点按类工具不受影响）。
final class CanvasEventCatcherNSView: CursorTrackingView {
    // phase: 0=按下 1=拖动 2=抬起 3=点按；坐标为左上原点的视图坐标。
    // 第三个参数是**这一次事件的修饰键**（⌥/⇧…）。为什么不读全局 NSEvent.modifierFlags：
    // 全局那份是"键盘此刻的状态"，跟这一个事件未必一致，而且自检没法用合成事件验证（合成事件带 flags）。
    var onEvent: ((Int, CGPoint, NSEvent.ModifierFlags) -> Void)?
    /// 光标（随工具变化）由基类 CursorTrackingView 统一实现
    private func fire(_ phase: Int, _ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        // AppKit 视图坐标原点在左下 → 转成左上原点（与 SwiftUI 一致）
        onEvent?(phase, CGPoint(x: p.x, y: bounds.height - p.y), e.modifierFlags)
    }
    private var downPoint: CGPoint = .zero
    override func mouseDown(with e: NSEvent) { downPoint = convert(e.locationInWindow, from: nil); fire(0, e) }
    override func mouseDragged(with e: NSEvent) { fire(1, e) }
    override func mouseUp(with e: NSEvent) {
        fire(2, e)
        // 这一层是 AppKit 视图、hitTest 返回 self，会吞掉点击，于是 SwiftUI 的
        // SpatialTapGesture 收不到 —— 膨胀/收缩/褶皱/平滑这些点按类工具会全失效。
        // 所以这里自己判定「几乎没有位移的按下+抬起 = 一次点按」，另报一个 phase=3。
        let p = convert(e.locationInWindow, from: nil)
        // 6px 而不是 4px：真实点击（尤其触控板）常带 3~8px 抖动，阈值太严会把点按误判成拖动
        if hypot(p.x - downPoint.x, p.y - downPoint.y) < 6 { fire(3, e) }
    }
}

struct CanvasEventCatcher: NSViewRepresentable {
    let onEvent: (Int, CGPoint, NSEvent.ModifierFlags) -> Void
    var cursor: NSCursor = .arrow          // 由调用方按当前工具给（十字/手/箭头）
    func makeNSView(context: Context) -> CanvasEventCatcherNSView {
        let v = CanvasEventCatcherNSView(); v.onEvent = onEvent; v.cursor = cursor; return v
    }
    func updateNSView(_ v: CanvasEventCatcherNSView, context: Context) {
        v.onEvent = onEvent
        v.cursor = cursor                  // 切工具时跟着变（didSet 会 invalidate 光标区）
    }
}
struct CursorArea: NSViewRepresentable {
    var cursor: NSCursor
    func makeNSView(context: Context) -> CursorNSView {
        let v = CursorNSView(); v.cursor = cursor; return v
    }
    func updateNSView(_ nsView: CursorNSView, context: Context) { nsView.cursor = cursor }
}

// SPM 出来的可执行文件默认不算「带 UI 的前台程序」：进程活着但看不到窗口。

/// 滑杆双击复位用的**注册表**：每个滑杆把自己在屏幕上的矩形与"复位动作"登记进来，
/// 由应用级的双击监视器统一查找并调用。
///
/// 为什么需要这么绕：macOS 上 SwiftUI 的 `Slider` 是**原生 AppKit 控件**，
/// 鼠标按下/拖动/松开全被它吃掉，`simultaneousGesture(TapGesture(count: 2))` 收不到事件
///（用户报了四次"双击没反应"）。挂在标签行上能收到，但用户很自然会去双击滑杆本身。
/// 所以：**事件层用 NSEvent 监视器**（本项目用它稳定解决了滚轮缩放、⌘Z、画布拖动），
/// 视图层只负责把"我是谁、我在哪、复位做什么"登记上来。
final class SliderResetStore: ObservableObject {
    static let shared = SliderResetStore()
    struct Item { var rect: CGRect; var reset: () -> Void }
    private var items: [UUID: Item] = [:]
    /// 诊断用：命中次数（自检确认'双击真的走到了复位'）
    private(set) var hitCount = 0
    private let lock = NSLock()
    func register(_ id: UUID, rect: CGRect, reset: @escaping () -> Void) {
        lock.lock(); items[id] = Item(rect: rect, reset: reset); lock.unlock()
    }
    func unregister(_ id: UUID) { lock.lock(); items[id] = nil; lock.unlock() }
    /// 返回是否命中（命中就执行复位）
    @discardableResult
    func reset(at screenPoint: CGPoint) -> Bool { reset(atAny: [screenPoint]) != nil }

    /// **唯一的命中入口**：按顺序试若干坐标空间候选，返回命中的候选下标（nil = 没命中）。
    /// 为什么不认一个死坐标空间：SwiftUI 的 .global 在窗口里到底是"窗口内容左上"还是"屏幕左上"
    /// 官方没有稳定承诺，登记侧和事件侧一旦各按各的理解换算就会像上一版那样"偶发命中"。
    /// 这里把两种理解都当候选，谁中谁算——并把下标打出来，让自检能直接告诉我们真相。
    @discardableResult
    func reset(atAny points: [CGPoint]) -> Int? {
        lock.lock()
        var hit: Item?
        var idx: Int?
        for (i, p) in points.enumerated() {
            if let h = items.values.first(where: { $0.rect.contains(p) }) { hit = h; idx = i; break }
        }
        lock.unlock()
        if let hit { hitCount += 1; hit.reset(); return idx }
        return nil
    }
    /// 诊断用：把已登记的滑杆矩形列出来（自检要拿一个坐标去点）
    func debugItems() -> [(id: UUID, rect: CGRect)] {
        lock.lock(); defer { lock.unlock() }
        return items.map { (id: $0.key, rect: $0.value.rect) }
    }

    /// 诊断（CR_MOUSELOG=1）：把进到应用层的每一次按下/抬起都打出来（含 clickCount 与位置）。
    /// 为什么要它：合成双击"能命中"、真人双击"没用"已经反复出现 —— 必须看清**真实输入到底送了哪些事件**，
    /// 而不是继续在"我以为的事件序列"上改代码。
    private func installMouseLog() {
        for (name, mask) in [("down", NSEvent.EventTypeMask.leftMouseDown), ("up", .leftMouseUp)] {
            NSEvent.addLocalMonitorForEvents(matching: mask) { e in
                FileHandle.standardError.write(("MOUSELOG " + name + " click=" + String(e.clickCount)
                    + String(format: " 窗口坐标=(%.0f,%.0f)", e.locationInWindow.x, e.locationInWindow.y)
                    + " 时间=" + String(format: "%.3f", e.timestamp) + "\n").data(using: .utf8)!)
                return e
            }
        }
    }

    /// 安装双击监视器（只装一次）
    private var monitor: Any?
    private var monitorDown: Any?
    /// 自己记「上一次按下」：**不再依赖系统的 clickCount**（第 107 节的根因）。
    /// 为什么：clickCount 由系统按「双击间隔」判定；手速稍慢、或系统把间隔调短，
    /// 第二下就只是 clickCount=1 —— 而我们一直 guard 在 clickCount == 2 上，
    /// 于是出现最要命的那种局面：我合成的事件带 clickState=2、永远能命中，真人双击永远不中。
    private var lastDown: (t: TimeInterval, p: CGPoint)?
    private var armed = false
    /// 窗口基础坐标（左下原点）→ 窗口内容坐标（左上原点），登记侧用的就是这一套
    static func topLeft(_ p: CGPoint, in win: NSWindow) -> CGPoint {
        CGPoint(x: p.x, y: (win.contentView?.frame.maxY ?? win.frame.height) - p.y)
    }
    func installMonitor() {
        guard monitor == nil else { return }
        if ProcessInfo.processInfo.environment["CR_MOUSELOG"] != nil { installMouseLog() }
        // 第一路：自己判定双击（0.5s 内、同一处 8px 内再按一次）
        monitorDown = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { e in
            guard let win = e.window else { return e }
            let p = Self.topLeft(e.locationInWindow, in: win)
            if let last = self.lastDown, e.timestamp - last.t < 0.5,
               hypot(p.x - last.p.x, p.y - last.p.y) < 8 {
                self.armed = true
                self.lastDown = nil
            } else {
                self.armed = false
                self.lastDown = (e.timestamp, p)
            }
            return e
        }
        // ⚠️ 复位必须发生在 **mouseUp**（第 106 节实测）：
        // 原生 NSSlider 在按下时会把滑块跳到点击位置，挂在 down 上复位会被它立刻覆盖。
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { e in
            guard let win = e.window else { return e }
            // 第二路：系统判定的双击也认（两条路都通，才算真的通）
            guard self.armed || e.clickCount == 2 else { return e }
            self.armed = false
            let lw = e.locationInWindow
            let contentTop = win.contentView?.frame.maxY ?? win.frame.height
            let winFlipFrame = CGPoint(x: lw.x, y: win.frame.height - lw.y)
            let winFlipContent = Self.topLeft(lw, in: win)
            let sp = win.convertPoint(toScreen: lw)
            let scr = win.screen ?? NSScreen.main
            let screenFlip = CGPoint(x: sp.x, y: (scr?.frame.maxY ?? 0) - sp.y)
            let idx = SliderResetStore.shared.reset(atAny: [winFlipContent, winFlipFrame, screenFlip])
            if ProcessInfo.processInfo.environment["CR_SLIDERCLICK"] != nil || ProcessInfo.processInfo.environment["CR_SLIDERDIAG"] != nil {
                FileHandle.standardError.write(("SLIDERDIAG 命中=" + String(describing: idx)
                    + " 候选[窗口内容" + fmt(winFlipContent) + " 窗口" + fmt(winFlipFrame) + " 屏幕" + fmt(screenFlip) + "]"
                    + " 已登记=" + String(SliderResetStore.shared.debugItems().map { fmt($0.rect) }.joined(separator: " "))
                    + " 窗口origin=" + fmt(win.frame.origin) + " 尺寸=" + String(format: "%.0fx%.0f", win.frame.width, win.frame.height) + " 内容顶=" + String(format: "%.0f", contentTop) + "\n").data(using: .utf8)!)
            }
            return e    // 绝不吞事件（吞了按钮会点不动）
        }
    }
}

/// 诊断格式化（文件级：监视器闭包是逃逸的，用 self 方法会报 captured self）
private func fmt(_ p: CGPoint) -> String { String(format: "(%.0f,%.0f)", p.x, p.y) }
private func fmt(_ r: CGRect) -> String { String(format: "%.0fx%.0f@%.0f,%.0f", r.width, r.height, r.minX, r.minY) }

/// 给滑杆挂上"双击复位"：登记自己的屏幕矩形与复位动作。
struct SliderDblClickReset: ViewModifier {
    let reset: () -> Void
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.background(GeometryReader { gg in
            Color.clear
                .onAppear {
                    SliderResetStore.shared.installMonitor()
                    SliderResetStore.shared.register(id, rect: gg.frame(in: .global), reset: reset)
                }
                // **按帧变化重登记，而不是只按尺寸**：窗口移动、面板滚动、布局换位都会让
                // 之前登记的矩形失效（实测登记 y 范围 222…1380 而窗口只占 284…1116，全是陈旧的）。
                .onChange(of: gg.frame(in: .global)) { _, f in
                    SliderResetStore.shared.register(id, rect: f, reset: reset)
                }
                .onChange(of: gg.size) { _, _ in
                    SliderResetStore.shared.register(id, rect: gg.frame(in: .global), reset: reset)
                }
                .onDisappear { SliderResetStore.shared.unregister(id) }
        })
    }
}

extension View {
    /// 双击滑杆任意位置 = 复位（事件由应用级监视器处理，见 SliderResetStore）
    func sliderDblClickReset(_ reset: @escaping () -> Void) -> some View {
        modifier(SliderDblClickReset(reset: reset))
    }

    func denorm(_ r: CGRect, _ e: CGRect) -> CGRect {
        CGRect(x: e.minX + r.minX * e.width, y: e.minY + r.minY * e.height,
               width: r.width * e.width, height: r.height * e.height)
    }
}
