// AI 挑图（近似）：按「清晰度 + 人脸质量 + 闭眼 + 构图 + 曝光」打分排序
// 用法: pick-cli <目录> [--top N] [--csv out.csv]
//
// 诚实说明：这不是审美打分模型（那需要训练），是可解释的工程指标：
//   清晰度   = 灰度高通能量（越低越糊）
//   人脸质量 = Vision VNDetectFaceCaptureQualityRequest（模糊/光线/表情的综合分）
//   闭眼     = 眼部关键点的「眼高/眼宽」比值（小于 0.22 判疑似闭眼）
//   构图     = 主体离最近三分线交点的距离（越近越高），贴边/被切掉扣分
//   曝光     = 贴黑/贴白像素占比（越高越可能是废片）
// 界面上应当把它当「粗筛」，最终还得人看。
//
// 打分逻辑只有一份：RetouchCore.scoreImage（界面与命令行共用），这个文件只负责跑目录与输出。
import Foundation
import RetouchCore

let args = CommandLine.arguments
func arg(_ n: String, _ d: String) -> String {
    if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }
    return d
}
if args.contains("--help") || args.count < 2 {
    print("用法: pick-cli <目录> [--top N] [--csv out.csv] [--workers N]")
    exit(args.count < 2 ? 2 : 0)
}
let dir = URL(fileURLWithPath: args[1])
let topN = Int(arg("--top", "0")) ?? 0
let csvOut = arg("--csv", "")
let workers = max(1, min(8, Int(arg("--workers", "4")) ?? 4))

// ⚠️ 退出码就是 CLI 的接口：目录读不到 / 一张图都没有，必须是**非零退出**。
// 原来 `try?` 把两种失败都吃掉，打印"挑图：0 张"并返回 0 —— 脚本与 CI 会当成挑完了
//（与 retouch-cli 同一条规矩，见账本第 148 节）。
guard let dirEntries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
    FileHandle.standardError.write(("错误：目录读不到：\(dir.path)\n").data(using: .utf8)!)
    exit(2)
}
let files = dirEntries
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.path < $1.path }
guard !files.isEmpty else {
    FileHandle.standardError.write(("错误：这个目录里没有可挑的图片：\(dir.path)\n").data(using: .utf8)!)
    exit(2)
}

var rows: [ImageScore] = []
var skipped = 0        // 打分失败的张数：**必须报出来**，别让"少挑了几张"静默发生
let lock = NSLock()
let done = { () -> Int in lock.lock(); defer { lock.unlock() }; return rows.count }()
_ = done
let group = DispatchGroup()
let sem = DispatchSemaphore(value: workers)
for f in files {
    sem.wait(); group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        if let s = scoreImage(f.path) {
            lock.lock(); rows.append(s); lock.unlock()
        } else {
            lock.lock(); skipped += 1; lock.unlock()
            FileHandle.standardError.write(("打分失败（跳过）：\(f.lastPathComponent)\n").data(using: .utf8)!)
        }
        sem.signal(); group.leave()
    }
}
group.wait()
rows.sort { $0.total > $1.total }

// 一张都没打上分 = 整批失败（不是"挑到 0 张"）
if rows.isEmpty {
    FileHandle.standardError.write("错误：\(files.count) 张一张都没打上分\n".data(using: .utf8)!)
    exit(2)
}
print("挑图：\(rows.count) 张" + (skipped > 0 ? "（另有 \(skipped) 张打分失败）" : "")
      + "（按总分降序；总分是工程指标，不是审美）")
for (i, r) in (topN > 0 ? Array(rows.prefix(topN)) : rows).enumerated() {
    print(String(format: "%3d. %-28@ 总分 %6.1f ｜ 清晰 %.1f ｜ 人脸 %d 张(质量 %.2f) ｜ 睁眼 %.2f ｜ 构图 %.2f ｜ %@",
                 i + 1, r.file as NSString, r.total, r.sharpness, r.faces, r.faceQuality,
                 r.eyeOpenness, r.composition,
                 r.flags.isEmpty ? "—" : r.flags.joined(separator: "、")))
}
if !csvOut.isEmpty {
    var csv = "file,score,sharpness,faces,face_quality,eye_openness,composition,flags\n"
    for r in rows {
        csv += "\(r.file),\(String(format: "%.2f", r.total)),\(String(format: "%.2f", r.sharpness)),\(r.faces),"
            + "\(String(format: "%.3f", r.faceQuality)),\(String(format: "%.3f", r.eyeOpenness)),"
            + "\(String(format: "%.3f", r.composition)),\(r.flags.joined(separator: "|"))\n"
    }
    try? csv.write(toFile: csvOut, atomically: true, encoding: .utf8)
    print("CSV：\(csvOut)")
}
