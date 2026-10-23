// CoreTestSections7.swift：coretest 的第 49~56 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections7() {

/// 与应用里 renderPipeline 同构的一遍（调色 + 皮肤 + 人像 + 背景纯化 + 影调）

if let src = loadFixture(wedding, maxDim: 0) {
    let tLoad = Date()
    _ = loadImage(root + "/" + wedding, maxDim: 1400)
    let loadMs = Date().timeIntervalSince(tLoad) * 1000
    let preview = loadFixture(wedding, maxDim: 1400)!
    var times: [Double] = []
    for _ in 0..<3 {
        let t = Date(); _ = renderable(fullPipeline(preview)); times.append(Date().timeIntervalSince(t) * 1000)
    }
    times.sort()
    print("  预览链路 " + String(Int(preview.extent.width)) + "x" + String(Int(preview.extent.height))
          + "：中位 " + fmt(times[1], 0) + " ms（读图 " + fmt(loadMs, 0) + " ms，只做一次并缓存）")
    var times2: [Double] = []
    for _ in 0..<2 {
        let t = Date(); _ = renderable(fullPipeline(src)); times2.append(Date().timeIntervalSince(t) * 1000)
    }
    print("  全分辨率链路 " + String(Int(src.extent.width)) + "x" + String(Int(src.extent.height))
          + "：中位 " + fmt(times2.min() ?? 0, 0) + " ms")

    // 批量吞吐（全分辨率、完整链路、含出图），串行 vs 4 并行，并看内存峰值
    let pool = (0..<8).compactMap { i -> String? in
        for d in libDirs {
            let cand = root + "/" + d + "/" + bigFace
            if FileManager.default.fileExists(atPath: cand) { return cand }
        }
        _ = i
        return nil
    }
    let files = pool + [root + "/" + wedding]
    for workers in [1, 4] {
        let tmp = "/tmp/probe/perf_w" + String(workers)
        try? FileManager.default.removeItem(atPath: tmp)
        var es = ExportSettings(); es.maxLongEdge = 0
        let before = rssMB()
        let t0 = Date()
        let res = exportBatch(files: files, outDir: tmp, es, makeImage: { p in
            guard let ci = loadImage(p, maxDim: 0) else { return nil }
            return fullPipeline(ci)
        }, workers: workers)
        let dt = Date().timeIntervalSince(t0)
        let peak = rssMB()
        print("  批量 " + String(files.count) + " 张（全分辨率全链路）并行 " + String(workers) + "："
              + fmt(dt, 2) + " s = " + fmt(Double(res.written) / max(0.001, dt), 2) + " 张/秒"
              + "，RSS " + fmt(before, 0) + " → " + fmt(peak, 0) + " MB，产出 "
              + fmt(Double(res.bytes) / 1_048_576, 1) + " MB")
    }
}

// MARK: - 7b. 交付层：虚拟副本 / 回收站 / 选片


head("7b. 虚拟副本 / 本地回收站 / 选片交付")
do {
    // 虚拟副本：存 → 读 → 内容一致；同名覆盖不重复；删除生效
    let imgPath = "/tmp/probe/version_target.jpg"
    var st = EditState()
    st.params.gamma = 1.23
    st.portrait.teeth = 66
    st.skinGrade = "strong"
    st.extras["sharpen"] = 42
    _ = VersionStore.save(path: imgPath, name: "冷调版", state: st)
    var st2 = EditState()
    st2.params.gamma = 0.88
    st2.portrait.faceSlim = 55
    _ = VersionStore.save(path: imgPath, name: "暖调版", state: st2)
    let list = VersionStore.versions(of: imgPath)
    let cold = list.first { $0.name == "冷调版" }
    check("虚拟副本：存读往返", list.count == 2 && cold?.state.params.gamma == 1.23
          && cold?.state.portrait.teeth == 66 && cold?.state.extras["sharpen"] == 42,
          "存了 " + String(list.count) + " 个版本；冷调版 gamma " + fmt(cold?.state.params.gamma ?? 0, 2)
          + "、牙齿 " + String(Int(cold?.state.portrait.teeth ?? 0)) + "、sharpen " + String(Int(cold?.state.extras["sharpen"] ?? 0)))
    _ = VersionStore.save(path: imgPath, name: "冷调版", state: st)      // 同名覆盖
    check("虚拟副本：同名覆盖不重复", VersionStore.versions(of: imgPath).count == 2,
          "再存一次同名后仍是 " + String(VersionStore.versions(of: imgPath).count) + " 个")
    // 删掉当前列表里的冷调版（覆盖后 id 会变，必须重新取）
    if let target = VersionStore.versions(of: imgPath).first(where: { $0.name == "冷调版" }) {
        _ = VersionStore.remove(path: imgPath, id: target.id)
    }
    let afterDel = VersionStore.versions(of: imgPath)
    check("虚拟副本：删除生效", afterDel.count == 1 && afterDel.first?.name == "暖调版",
          "删一个后剩 " + String(afterDel.count) + " 个（" + (afterDel.first?.name ?? "-") + "）")

    // 回收站：同名文件不覆盖；恢复回原路径；清空
    _ = LocalTrash.empty()
    let da = "/tmp/probe/trashA", db = "/tmp/probe/trashB"
    try? FileManager.default.createDirectory(atPath: da, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: db, withIntermediateDirectories: true)
    for d in [da, db] { try? "x".write(toFile: d + "/same.txt", atomically: true, encoding: .utf8) }
    let moved = LocalTrash.move([da + "/same.txt", db + "/same.txt"])
    let goneAll = !FileManager.default.fileExists(atPath: da + "/same.txt")
        && !FileManager.default.fileExists(atPath: db + "/same.txt")
    let items = LocalTrash.list()
    let distinctNames = Set(items.map { $0.name }).count
    check("回收站：同名不覆盖", moved == 2 && goneAll && items.count == 2 && distinctNames == 2,
          "移入 " + String(moved) + " 个同名文件，原文件都不在了：" + String(goneAll)
          + "，回收站里 " + String(items.count) + " 条 / " + String(distinctNames) + " 个不同文件名")
    if let one = items.first(where: { $0.originalPath == da + "/same.txt" }) {
        let ok = LocalTrash.restore(one.id)
        check("回收站：恢复回原路径", ok && FileManager.default.fileExists(atPath: da + "/same.txt"),
              "恢复 A 目录那份：" + String(ok))
    }
    let left = LocalTrash.list()
    let emptied = LocalTrash.empty()
    check("回收站：清空", emptied == left.count && LocalTrash.list().isEmpty,
          "清掉 " + String(emptied) + " 个，剩余 " + String(LocalTrash.list().count) + " 条")

    // 选片交付：按星级挑、拷文件、写清单
    let deliverDir = URL(fileURLWithPath: "/tmp/probe/deliver")
    try? FileManager.default.removeItem(at: deliverDir)
    let src = root + "/" + wedding
    let rows = [SelectionRow(file: src, stars: 5, flags: []),
                SelectionRow(file: src, stars: 3, flags: ["疑似闭眼"]),
                SelectionRow(file: "/tmp/probe/不存在.jpg", stars: 4, flags: [])]
    let res = deliverSelection(rows, minStars: 4, to: deliverDir)
    let csv = (try? String(contentsOf: deliverDir.appendingPathComponent("选片清单.csv"), encoding: .utf8)) ?? ""
    let copied = (try? FileManager.default.contentsOfDirectory(atPath: deliverDir.path))?.filter { $0.hasSuffix(".jpg") } ?? []
    check("选片交付：按星级挑 + 拷贝 + 清单", res.count == 2 && copied.count == 1 && csv.contains("wedding_01.jpg"),
          "选中 " + String(res.count) + " 条（≥4 星），实拷 " + String(copied.count) + " 个，清单 " + String(csv.split(separator: "\n").count) + " 行")
}

// MARK: - 8. 项目层持久化


head("8. 项目层持久化往返")

_ = ProjectStore.upsert(ProjectRecord(path: "/tmp/perf2/out", done: 50, total: 50))

_ = ProjectStore.upsert(ProjectRecord(path: "/tmp/perf2/out", done: 50, total: 50))

check("项目持久化", again.count == after.count && again.first?.path == "/tmp/perf2/out",
      "文件 " + f.lastPathComponent + "｜登记前 " + String(before.count) + " 条、登记后 " + String(after.count) + " 条、再登记 " + String(again.count) + " 条")

// MARK: - 9. 参考追色


head("9. 参考追色：暖冷偏色是否真的作用到像素")

// 合成图给的是**已知答案**：左半暗、右半亮、整体偏蓝。
// 用真照片测会被内容和噪声掩盖，只有合成图能一句话说清「该变多少」。
}
