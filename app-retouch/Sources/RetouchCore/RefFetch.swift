// 参考图抓取：用户给一条链接（图片直链 / 网页 / 分享页），把里面的图抓下来当参考图。
//
// 诚实边界：小红书、抖音这类**前端渲染**页面（内容靠 JS 注入）抓不到图——HTML 里根本没有
// 图片地址。这里能可靠处理的是：图片直链、有 og:image 的分享页、以及正文里直接写 <img src>
// 的静态页面。抓不到就返回空并说明原因，不假装成功。
import Foundation
import CoreImage
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 从 HTML 里抽图片地址：先看 og:image / twitter:image（分享页最可靠的那个），再退回全局正则。
public func imageURLsIn(html: String, base: URL? = nil) -> [String] {
    var out: [String] = []
    func abs(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("//") { return "https:" + t }
        if t.hasPrefix("http") { return t }
        guard let b = base else { return nil }
        if t.hasPrefix("/") { return (b.scheme ?? "https") + "://" + (b.host ?? "") + t }
        // 相对路径（如 images/a.jpg）：按页面地址拼
        return b.deletingLastPathComponent().appendingPathComponent(t).absoluteString
    }
    // 1) og:image / twitter:image
    let metaPattern = "<meta[^>]+(?:property|name)=[\"'](?:og:image|twitter:image)[\"'][^>]*>"
    if let re = try? NSRegularExpression(pattern: metaPattern, options: [.caseInsensitive]) {
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            if let cr = try? NSRegularExpression(pattern: "content=[\"']([^\"']+)[\"']", options: [.caseInsensitive]),
               let cm = cr.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)),
               cm.numberOfRanges > 1, let u = abs((tag as NSString).substring(with: cm.range(at: 1))) {
                out.append(u)
            }
        }
    }
    // 2) 正文里的图片地址（<img src> / data-src / 裸链接）
    //
    // 这里**故意不用正则**：早先那版是一个带转义的长正则，写坏的后果是
    // NSRegularExpression 直接抛错、被 try? 吞掉 → 整段静默失效，只有 og:image 能抓到。
    // 表现是「从网页抓参考图」只抓到 1 张、正文里的图一张都不来（服务器日志里根本没有请求）。
    // 按引号/尖括号切词再判后缀，没有转义可写错，出错也是明摆着的。
    let imageExts: Set<String> = ["jpg", "jpeg", "jpe", "png", "webp", "heic", "avif"]
    for raw in html.split(whereSeparator: { "\"'<>() ,;\n\t\\".contains($0) }) {
        let token = String(raw)
        guard token.hasPrefix("http") || token.hasPrefix("//") || token.hasPrefix("/") else { continue }
        let noQuery = token.split(separator: "?").first.map(String.init) ?? token
        guard imageExts.contains((noQuery as NSString).pathExtension.lowercased()) else { continue }
        if let u = abs(token) { out.append(u) }
    }
    // 去重 + 去掉明显的图标/头像/logo（这些当参考图只会污染目标统计）
    var seen = Set<String>()
    let junk = ["icon", "logo", "avatar", "sprite", "blank", "placeholder", "emoji", "qrcode"]
    return out.filter { u in
        let low = u.lowercased()
        guard !junk.contains(where: { low.contains($0) }) else { return false }
        return seen.insert(u).inserted
    }
}

/// 抓一条链接下的参考图，存到 dir，返回本地路径（最多 maxCount 张）。
public func fetchReferences(_ link: String, into dir: String, maxCount: Int = 8) -> [String] {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil else { return [] }

    let isImage = ["jpg", "jpeg", "png", "webp", "heic"].contains(url.pathExtension.lowercased())
    func download(_ u: String, _ name: String) -> String? {
        guard let uu = URL(string: u) else { return nil }
        let dst = (dir as NSString).appendingPathComponent(name)
        if fm.fileExists(atPath: dst) { return dst }
        var done = false
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: uu) { data, _, _ in
            defer { sem.signal() }
            guard let data = data, data.count > 4096,  // 太小的多半是占位图
                  let img = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
            // 只认真的能解码成图的（有些站会把 html 伪装成 .jpg）
            guard sharedCtx.createCGImage(img, from: img.extent) != nil else { return }
            try? data.write(to: URL(fileURLWithPath: dst))
            done = true
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 20)
        return done ? dst : nil
    }

    if isImage {
        return download(trimmed, "ref_0." + url.pathExtension.lowercased()).map { [$0] } ?? []
    }
    // 页面：先拿 HTML
    var html = ""
    let sem = DispatchSemaphore(value: 0)
    var req = URLRequest(url: url)
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let d = data { html = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + 25)
    guard !html.isEmpty else { return [] }
    var picked: [String] = []
    for (i, u) in imageURLsIn(html: html, base: url).enumerated() where i < maxCount {
        if let p = download(u, "ref_\(i)." + (URL(string: u)?.pathExtension.lowercased() ?? "jpg")) { picked.append(p) }
    }
    return picked
}
