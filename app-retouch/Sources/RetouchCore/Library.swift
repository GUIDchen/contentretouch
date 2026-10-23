// Library：交付层的本地实现——虚拟副本（同图多版本）、本地回收站、选片交付
//
// 像素蛋糕这几项要么在服务端（云空间/联机/ERP），要么依赖它的项目库。我们做本机版：
//   · 虚拟副本：一张原片存多个参数版本，随时切换比对（参数存本地 JSON，不动原图）
//   · 回收站：删掉的是「移进本地回收站」，可恢复、可清空（防止手一抖删了原片）
//   · 选片交付：按星级挑出要交付的片子，拷到交付目录 + 出一份选片清单 CSV
import Foundation
import CoreImage

// MARK: - 一份可存可读的编辑状态
//
// 为什么用「具名字典装其余滑杆」：界面上的滑杆还会继续加，挨个列出来每次都要改两处。
// 核心参数（调色 + 人像）保持强类型，其余按名字进 extras。
public struct EditState: Codable {
    public var params = Params()
    public var portrait = PortraitOptions()
    public var skinGrade = "off"
    public var skinStrength = 0.0
    public var skinTone = false
    public var texturePreserve = true
    public var extras: [String: Double] = [:]
    public init() {}
}

// MARK: - 虚拟副本

public struct VersionRecord: Codable, Identifiable {
    public var id: String = UUID().uuidString
    public var name: String
    public var date: Date = Date()
    public var state: EditState
    public init(name: String, state: EditState) {
        self.name = name; self.state = state
    }
}

public enum VersionStore {
    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ContentRetouch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("versions.json")
    }

    public static func all() -> [String: [VersionRecord]] {
        guard let d = try? Data(contentsOf: fileURL),
              let m = try? JSONDecoder().decode([String: [VersionRecord]].self, from: d) else { return [:] }
        return m
    }

    public static func versions(of path: String) -> [VersionRecord] {
        (all()[path] ?? []).sorted { $0.date > $1.date }
    }

    /// 存一个版本（同名覆盖），每张图最多保留 20 个
    @discardableResult
    public static func save(path: String, name: String, state: EditState) -> [VersionRecord] {
        var m = all()
        var list = (m[path] ?? []).filter { $0.name != name }
        list.insert(VersionRecord(name: name, state: state), at: 0)
        if list.count > 20 { list = Array(list.prefix(20)) }
        m[path] = list
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: fileURL) }
        return list.sorted { $0.date > $1.date }
    }

    @discardableResult
    public static func remove(path: String, id: String) -> [VersionRecord] {
        var m = all()
        m[path] = (m[path] ?? []).filter { $0.id != id }
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: fileURL) }
        return (m[path] ?? []).sorted { $0.date > $1.date }
    }
}

// MARK: - 本地回收站

public struct TrashItem: Codable, Identifiable {
    public var id = UUID().uuidString
    public var name: String          // 在回收站里的文件名
    public var originalPath: String
    public var date: Date = Date()
    public var bytes: Int64 = 0
    public init(name: String, originalPath: String, bytes: Int64 = 0) {
        self.name = name; self.originalPath = originalPath; self.bytes = bytes
    }
}

public enum LocalTrash {
    public static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let d = base.appendingPathComponent("ContentRetouch/trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    public static var indexURL: URL { dir.appendingPathComponent("index.json") }

    public static func list() -> [TrashItem] {
        guard let d = try? Data(contentsOf: indexURL),
              let l = try? JSONDecoder().decode([TrashItem].self, from: d) else { return [] }
        return l.sorted { $0.date > $1.date }
    }

    static func writeIndex(_ l: [TrashItem]) {
        if let d = try? JSONEncoder().encode(l) { try? d.write(to: indexURL) }
    }

    /// 把文件移进回收站（同名的加时间戳后缀，不覆盖）
    @discardableResult
    public static func move(_ paths: [String]) -> Int {
        var l = list()
        var moved = 0
        let fm = FileManager.default
        for p in paths {
            guard fm.fileExists(atPath: p) else { continue }
            let base = (p as NSString).lastPathComponent
            var target = dir.appendingPathComponent(base)
            if fm.fileExists(atPath: target.path) {
                let stem = (base as NSString).deletingPathExtension
                let ext = (base as NSString).pathExtension
                let stamp = Int(Date().timeIntervalSince1970)
                target = dir.appendingPathComponent("\(stem)_\(stamp)" + (ext.isEmpty ? "" : ".\(ext)"))
            }
            guard (try? fm.moveItem(atPath: p, toPath: target.path)) != nil else { continue }
            let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
            l.append(TrashItem(name: target.lastPathComponent, originalPath: p, bytes: size))
            moved += 1
        }
        writeIndex(l)
        return moved
    }

    /// 恢复回原路径（原目录不存在就重建）
    @discardableResult
    public static func restore(_ id: String) -> Bool {
        var l = list()
        guard let i = l.firstIndex(where: { $0.id == id }) else { return false }
        let item = l[i]
        let fm = FileManager.default
        let src = dir.appendingPathComponent(item.name)
        let dst = URL(fileURLWithPath: item.originalPath)
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: src, to: dst)) != nil else { return false }
        l.remove(at: i)
        writeIndex(l)
        return true
    }

    /// 清空（真删）
    @discardableResult
    public static func empty() -> Int {
        let l = list()
        let fm = FileManager.default
        var n = 0
        for item in l {
            if (try? fm.removeItem(at: dir.appendingPathComponent(item.name))) != nil { n += 1 }
        }
        writeIndex([])
        return n
    }

    public static func sizeBytes() -> Int64 { list().reduce(0) { $0 + $1.bytes } }
}

// MARK: - 选片交付

public struct SelectionRow {
    public var file: String
    public var stars: Int
    public var flags: [String]
    public init(file: String, stars: Int, flags: [String] = []) {
        self.file = file; self.stars = stars; self.flags = flags
    }
}

/// 按星级从已打分的片子里挑出要交付的，拷到交付目录并写清单。
/// 用拷贝而不是移动：原片永远不动（批量修图的铁律）。
public func deliverSelection(_ rows: [SelectionRow], minStars: Int, to outDir: URL,
                             copyFiles: Bool = true) -> (count: Int, bytes: Int64) {
    let fm = FileManager.default
    try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
    var picked = rows.filter { $0.stars >= minStars }
    picked.sort { $0.file < $1.file }
    var bytes: Int64 = 0
    var csv = "file,stars,flags\n"
    for r in picked {
        csv += "\(r.file),\(r.stars),\(r.flags.joined(separator: "|"))\n"
        if copyFiles, fm.fileExists(atPath: r.file) {
            let dst = outDir.appendingPathComponent((r.file as NSString).lastPathComponent)
            if !fm.fileExists(atPath: dst.path), (try? fm.copyItem(atPath: r.file, toPath: dst.path)) != nil {
                bytes += (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int64) ?? 0
            }
        }
    }
    try? csv.write(to: outDir.appendingPathComponent("选片清单.csv"), atomically: true, encoding: .utf8)
    return (picked.count, bytes)
}
