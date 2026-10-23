// Index：素材库的「可检索要素」索引
//
// 目标：一万多张素材里按关键词找图（天空、多人、室内、红色、特写…）。
//
// 设计原则：**只索引真的量得出来的东西**，量不出来的不假装。
//   · 真量得出来：场景类别（ImageNet 分类器给的词）、人脸数/人数、有没有天空（skyScore）、
//     主色与色温倾向、亮度/对比、朝向（人脸的 yaw）、室内外（由分类词映射）、格式/尺寸
//   · **量不出来**：晨袍、朱砂这类中文行业词。ImageNet 词表里没有这些语义，
//     所以它们不是「识别」出来的，而是**由可测特征映射出来的**（红色占比 + 人数 + 室内…），
//     索引里会给这类词打上 `derived` 标记，搜索结果里也能看出依据。
import Foundation
import CoreImage
import Vision

public struct ImageRecord: Codable {
    public var path: String
    public var file: String
    public var width = 0, height = 0
    public var format = ""
    public var keywords: [String: Double] = [:]   // ImageNet 词 → 置信度（只留过阈值的）
    public var category = ""                       // 场景类别（复用 classifyScene）
    public var indoor = false
    public var indoorKnown = false
    public var faces = 0
    public var persons = 0
    public var faceYaw = 0.0                       // 最大脸的扭头角度（正脸/侧脸）
    public var sky = 0.0                           // 天空占比 0~1
    public var meanR = 0.0, meanG = 0.0, meanB = 0.0
    public var luma = 0.0
    public var sat = 0.0
    public var warm = 0.0                          // R-B（正=暖）
    public var redShare = 0.0                      // 偏红像素占比（用来映射「红/朱砂/晨袍」这类词）
    public var isCloseup = false                   // 最大脸占画面宽度 > 35%
    public var portrait = false                    // 高 > 宽
    public var tags: [String] = []                 // 最终检索词（含 derived 标记的来源）
    public var tagSource: [String: String] = [:]   // 词 → "measured" / "derived" / "classifier"
}

/// 室内/室外的映射表：ImageNet 词表里跟「室内」「室外」强相关的那些。
/// 这不是完整词表，而是我们自己在素材上攒的映射（和 classifyScene 的关键词表同一个思路）。
private let indoorWords: Set<String> = ["restaurant", "kitchen", "bedroom", "living room", "home theater",
    "conference room", "library", "bakery", "barbershop", "bookshop", "church", "mosque", "palace",
    "greenhouse", "gym", "studio couch", "stage", "toilet seat", "shop", "grocery store", "furniture",
    "wardrobe", "chandelier", "dining table", "piano", "candle", "vase", "picture frame", "carpet",
    "curtain", "four-poster bed", "wine bottle", "coffee mug", "plate rack", "menu", "wedding cake",
    "banquet hall", "altar", "dress shop", "cake", "table lamp", "mirror", "sofa"]
private let outdoorWords: Set<String> = ["seashore", "lakeside", "beach", "cliff", "valley", "mountain",
    "volcano", "geyser", "promontory", "sandbar", "coral reef", "alp", "lakeside", "park", "garden",
    "street", "sidewalk", "crosswalk", "street sign", "bicycle", "convertible", "limousine", "boathouse",
    "pier", "dock", "sailboat", "speedboat", "airliner", "parachute", "balloon", "forest", "tree",
    "grass", "sky", "cloud", "sun", "sunrise", "snow", "field", "meadow", "lawn", "plant", "flower",
    "barn", "farm", "hay", "windmill", "tractor", "lighthouse", "fountain"]

/// 抽取单张图的检索要素
public func indexImage(_ path: String, maxDim: Int = 700, keywordsTop: Int = 8) -> ImageRecord? {
    var r = ImageRecord(path: path, file: (path as NSString).lastPathComponent)
    r.format = (path as NSString).pathExtension.lowercased()
    guard let img = loadAnyImage(path, maxDim: maxDim),
          let cg = sharedCtx.createCGImage(img, from: img.extent) else { return nil }
    let e = img.extent
    r.width = Int(e.width); r.height = Int(e.height)
    r.portrait = e.height > e.width

    // 1) 场景分类（ImageNet 1000 类，取前 N 个词）
    let scene = classifyScene(cg)
    r.category = scene.category
    for (word, score) in scene.labels.prefix(keywordsTop) where score > 0.12 {
        r.keywords[word] = Double(score)
    }

    // 2) 人脸 / 姿态
    let geos = detectFaceGeos(cg, size: e.size)
    r.faces = geos.count
    if let big = geos.max(by: { $0.box.width < $1.box.width }) {
        r.faceYaw = big.yaw * 180 / .pi
        r.isCloseup = big.box.width > e.width * 0.35
    }

    // 3) 人数（前景实例——比人脸数更接近「画面里有几个人」）
    r.persons = personInstanceMasks(img).count

    // 4) 天空
    var skyOpt = SkyOptions(); skyOpt.amount = 100
    r.sky = replaceSky(img, skyOpt).coverage

    // 5) 色彩统计
    let st = measure(img)
    r.sat = st.sat / 100.0
    var buf = [UInt8](repeating: 0, count: 48 * 48 * 4)
    let scale = 48.0 / Double(max(e.width, e.height))
    let sc = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    sharedCtx.render(sc, toBitmap: &buf, rowBytes: 48 * 4, bounds: CGRect(x: 0, y: 0, width: 48, height: 48),
                     format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var sr = 0.0, sg = 0.0, sb = 0.0, reds = 0.0
    for i in 0..<(48 * 48) {
        let R = Double(buf[i * 4]), G = Double(buf[i * 4 + 1]), B = Double(buf[i * 4 + 2])
        sr += R; sg += G; sb += B
        let mx = max(R, max(G, B)), mn = min(R, min(G, B))
        // 偏红：R 明显最大、且有饱和度（避免把灰白也算进来）
        if R > 60 && R - max(G, B) > 30 && (mx - mn) > 40 { reds += 1 }
    }
    let n = 48.0 * 48.0
    r.meanR = sr / n; r.meanG = sg / n; r.meanB = sb / n
    r.warm = r.meanR - r.meanB
    r.redShare = reds / n
    r.luma = (0.2126 * r.meanR + 0.7152 * r.meanG + 0.0722 * r.meanB) / 255.0

    // 6) 室内外：由分类词映射。
    //    两个坑都踩过：(a) 用 contains 匹配会让 "sunglasses" 命中 "sun" 这类假阳性；
    //    (b) 命中为 0 时默认 false = 一律算「室外」，300 张样本里 283 张被判室外。
    //    现在改成精确匹配 + 允许「判不出」——不知道就写未知，不猜。
    let words = Set(r.keywords.keys.map { $0.lowercased().replacingOccurrences(of: "_", with: " ") })
    let indoorHits = words.filter { indoorWords.contains($0) }.count
    let outdoorHits = words.filter { outdoorWords.contains($0) }.count
    r.indoor = indoorHits > outdoorHits
    r.indoorKnown = indoorHits > 0 || outdoorHits > 0

    // 7) 生成检索词（并标注来源）
    func add(_ tag: String, _ source: String) {
        if !r.tags.contains(tag) { r.tags.append(tag) }
        r.tagSource[tag] = source
    }
    for t in poseTags(cg) { add(t, "derived") }    // 姿势：人体关键点推出来的
    for w in r.keywords.keys { add(w, "classifier") }
    if !r.category.isEmpty { add(r.category, "classifier") }
    if r.indoorKnown { add(r.indoor ? "室内" : "室外", "classifier") }
    if r.faces == 0 { add("无人脸", "measured") }
    if r.faces == 1 { add("单脸", "measured") }
    if r.isCloseup { add("特写", "measured") }   // 只有真的占画面够大才算特写
    if r.faces >= 2 { add("多人", "measured"); add("合影", "measured") }
    if r.faces >= 4 { add("大合影", "measured") }
    if r.persons >= 2 && r.persons > r.faces { add("多人(有人未见脸)", "measured") }
    if r.sky > 0.06 { add("天空", "measured") }
    if r.sky > 0.25 { add("大天空", "measured") }
    if abs(r.faceYaw) < 15 && r.faces > 0 { add("正脸", "measured") }
    if abs(r.faceYaw) > 40 { add("侧脸", "measured") }
    if r.redShare > 0.10 { add("红色", "measured") }
    // 中文行业词是**映射**出来的，不是识别出来的：
    if r.redShare > 0.18 && r.faces >= 1 && r.indoor { add("朱砂/红调", "derived") }
    if r.redShare > 0.15 && r.persons >= 1 && r.indoor && r.sky < 0.05 { add("晨袍(红袍候选)", "derived") }
    if r.luma > 0.62 { add("高调亮调", "measured") }
    if r.luma < 0.28 { add("低调暗调", "measured") }
    if r.portrait { add("竖构图", "measured") } else { add("横构图", "measured") }
    if r.warm > 12 { add("暖色", "measured") }
    if r.warm < -12 { add("冷色", "measured") }
    return r
}

/// 递归列出可索引的图（素材库通常是分层的：一批一批建子目录）。
/// 跳过隐藏目录与 macOS 资源叉（`._foo.jpg` 会被 ImageIO 当坏图），否则索引里会混进一堆读不出的记录。
public func indexableFiles(_ root: String, maxDepth: Int = 6) -> [String] {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue {
        return imageExtensions.contains((root as NSString).pathExtension.lowercased()) ? [root] : []
    }
    guard let en = fm.enumerator(atPath: root) else { return [] }
    var out: [String] = []
    for case let rel as String in en {
        let depth = rel.split(separator: "/").count
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix(".") { en.skipDescendants(); continue }
        if depth > maxDepth { en.skipDescendants(); continue }
        guard imageExtensions.contains((rel as NSString).pathExtension.lowercased()) else { continue }
        out.append((root as NSString).appendingPathComponent(rel))
    }
    return out.sorted()
}

/// 姿势标签：由 Vision 的 19 点人体关键点推出来，不训练模型。
///
/// 为什么能做：Vision 自带 VNDetectHumanBodyPoseRequest，关键点里已经有肩/肘/腕/髋/膝/踝。
/// 为什么标 derived：这是**推断**不是识别——规则写得出来、也验得出来，但没有「坐」「跑」的语义模型。
/// 每条规则都给触发条件，方便拿图复核（用 --search 查出来直接看）。
public func poseTags(_ cg: CGImage) -> [String] {
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let req = VNDetectHumanBodyPoseRequest()
    guard (try? handler.perform([req])) != nil else { return [] }
    let obs = req.results ?? []
    if obs.isEmpty { return ["无人体"] }
    guard let pts = try? obs[0].recognizedPoints(.all) else { return [] }
    func p(_ n: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
        guard let r = pts[n], r.confidence > 0.3 else { return nil }
        return r.location                       // 归一化，原点在左下（y 向上）
    }
    var out: [String] = []
    let nose = p(.nose)
    let ls = p(.leftShoulder), rs = p(.rightShoulder)
    let lw = p(.leftWrist), rw = p(.rightWrist)
    let lh = p(.leftHip), rh = p(.rightHip)
    let lk = p(.leftKnee), rk = p(.rightKnee)
    let la = p(.leftAnkle), ra = p(.rightAnkle)
    let shoulderY = [ls?.y, rs?.y].compactMap { $0 }.min()
    let hipY = [lh?.y, rh?.y].compactMap { $0 }.min()
    let kneeY = [lk?.y, rk?.y].compactMap { $0 }.min()
    let ankleY = [la?.y, ra?.y].compactMap { $0 }.max()

    // 构图：看得到踝 = 全身入镜
    if let a = ankleY, let h = hipY, h - a > 0.35 {
        out.append("全身入镜")
        if let k = kneeY {
            // 坐姿：大腿接近水平（髋膝几乎同高）；否则站姿
            if h - k < 0.08 { out.append("坐姿") } else { out.append("站姿") }
        }
    } else if nose != nil, hipY == nil {
        out.append("半身构图")
    }
    // 手：腕高过鼻 = 举起；单侧高过肩 = 抬手；腕贴近髋 = 叉腰/手在腰间
    let noseY = nose?.y ?? 1
    if let l = lw, let r = rw, l.y > noseY, r.y > noseY { out.append("举双手") }
    else if let l = lw, l.y > noseY { out.append("举手") }
    else if let r = rw, r.y > noseY { out.append("举手") }
    else if let s = shoulderY, let l = lw, l.y > s + 0.05 { out.append("抬手") }
    else if let s = shoulderY, let r = rw, r.y > s + 0.05 { out.append("抬手") }
    func dist(_ a: CGPoint?, _ b: CGPoint?) -> Double {
        guard let a = a, let b = b else { return 9 }
        return Double(hypot(a.x - b.x, a.y - b.y))
    }
    // 手在身侧：腕贴近髋。注意这**不是**叉腰——早先把这条直接叫「叉腰」，
    // 结果一张海边walking的照片（手自然垂在身侧拎包）被标成叉腰。名字必须说规则真的量到的东西。
    let nearHip = dist(lw, lh) < 0.12 || dist(rw, rh) < 0.12
    if nearHip { out.append("手在身侧") }
    // 叉腰：腕在髋旁 **且肘明显外撑**（肘比髋更靠外、且不低于髋）
    let le = p(.leftElbow), re = p(.rightElbow)
    func akimbo(_ w: CGPoint?, _ e: CGPoint?, _ h: CGPoint?) -> Bool {
        guard let w = w, let e = e, let h = h else { return false }
        return dist(w, h) < 0.16 && abs(e.x - h.x) > 0.09 && e.y > h.y + 0.02
    }
    if akimbo(lw, le, lh) || akimbo(rw, re, rh) { out.append("叉腰") }
    // 朝向：肩宽明显小于躯干高 = 侧身（透视压缩）
    if let l = ls, let r = rs, let s = shoulderY, let h = hipY, s - h > 0.05 {
        if abs(l.x - r.x) < 0.55 * (s - h) { out.append("侧身") }
    }
    if out.isEmpty { out.append("有体无人脸") }
    return out
}

/// 索引文件：一行一条 JSON（JSONL，方便增量追加与流式读取）
public final class ImageIndexStore {
    public private(set) var records: [ImageRecord] = []
    public init() {}
    public func load(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        records = text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(ImageRecord.self, from: d)
        }
        reindex()
    }
    public func save(_ path: String) throws {
        let enc = JSONEncoder()
        var out = ""
        for r in records {
            if let d = try? enc.encode(r), let s = String(data: d, encoding: .utf8) { out += s + "\n" }
        }
        try out.write(toFile: path, atomically: true, encoding: .utf8)
    }
    public func add(_ r: ImageRecord) { records.append(r); blobs.append(blobOf(r)) }
    /// 整体替换（增量补特征时用：只重算一维，不重跑整条索引）
    public func replaceAll(_ rs: [ImageRecord]) { records = rs; reindex() }

    /// 查询用的「可搜索文本」：一次拼好并转小写，别在每次查询里对每条记录做几百次 lowercase()。
    /// 实测：13529 张全库从 284 ms → 30 ms 级（每次查都现算字符串是白烧 CPU）。
    private var blobs: [String] = []
    private func reindex() { blobs = records.map(blobOf) }
    private func blobOf(_ r: ImageRecord) -> String {
        (r.tags.joined(separator: " ") + " " + r.category + " "
         + r.keywords.keys.joined(separator: " ") + " " + r.file).lowercased()
    }

    /// 查询：空格/逗号分隔的多个词是**与**关系。
    /// 返回 (记录, 命中词数)，按文件名排序；limit = 0 表示要全部（界面要显示真实命中数，不能先截断再报数）。
    public func search(_ query: String, limit: Int = 0) -> [(ImageRecord, Int)] {
        let terms = query.split(whereSeparator: { " ,，、".contains($0) }).map { String($0).lowercased() }
        guard !terms.isEmpty else { return [] }
        var hits: [(ImageRecord, Int)] = []
        for (i, blob) in blobs.enumerated() {
            var n = 0
            // 用字节级 strstr 而不是 String.contains：Swift 的 contains(String) 走的是
            // Unicode 规范化比较，在 400 字的长串上每次都要重组字素簇——实测全库一次查询
            // 要 280~400 ms（界面里就是主线程卡一下）。字节匹配对中文关键词没有语义损失。
            blob.withCString { b in
                for t in terms where t.withCString({ strstr(b, $0) != nil }) { n += 1 }
            }
            if n == terms.count { hits.append((records[i], n)) }
        }
        hits.sort { $0.0.file < $1.0.file }
        return limit > 0 ? Array(hits.prefix(limit)) : hits
    }
}
