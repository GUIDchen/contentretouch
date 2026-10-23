// CoreProject.swift：从原文件按功能拆出（只搬家，不改逻辑）。
import SwiftUI
import AppKit
import CoreImage
import Foundation
import Vision
import UniformTypeIdentifiers

/// 预设 → 运行参数
public func params(from s: PresetFile.StyleParams) -> Params {
    var p = Params()
    p.levelsIn = s.levelsIn; p.levelsOut = s.levelsOut
    p.gamma = s.gamma; p.brightness = s.brightness; p.contrast = s.contrast
    p.desat = s.desat
    p.cbSh = s.cbShadow; p.cbMid = s.cbMid; p.cbHi = s.cbHigh
    return p
}

/// 风格组（聚类）→ 预设文件
public func preset(from style: StylePreset, name: String? = nil, refImages: [String] = []) -> PresetFile {
    PresetFile(
        name: name ?? style.name,
        source: .init(kind: "cluster", clusterIndex: style.index, refImages: refImages,
                      note: "由 style_from_library.py 从参考库聚类得到"),
        style: .init(levelsIn: style.params.levelsIn, levelsOut: style.params.levelsOut,
                     gamma: style.params.gamma, brightness: style.params.brightness,
                     contrast: style.params.contrast, desat: style.params.desat,
                     cbShadow: style.params.cbSh, cbMid: style.params.cbMid, cbHigh: style.params.cbHi),
        face: .init(perFaceAdaptive: true, attributes: [:], scope: "single"),
        notes: "",
        target: style.target
    )
}

// MARK: - 项目层（持久化）：对应像素蛋糕主页的「项目」卡片
//
// 每次批量完成后登记一条：目录、已修张数、总数、更新时间。存在
// ~/Library/Application Support/ContentRetouch/projects.json，启动时读回——这样项目列表不随会话消失。
public struct ProjectRecord: Codable {
    public var path: String
    public var done: Int
    public var total: Int
    public var updated: Date
    /// §251：项目名（用户「新建项目」时设的）。可选 ⇒ 旧的项目列表 json 照样能解。
    public var name: String?
    public init(path: String, done: Int, total: Int, updated: Date = Date(), name: String? = nil) {
        self.path = path; self.done = done; self.total = total; self.updated = updated; self.name = name
    }
}

public enum ProjectStore {
    public static var fileURL: URL {
        // 体检用：CR_PROJECTS_PATH 可以把它指到临时文件，别污染用户真实的项目列表（tools/dist/audit_resume.sh）
        if let p = ProcessInfo.processInfo.environment["CR_PROJECTS_PATH"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ContentRetouch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }

    public static func load() -> [ProjectRecord] {
        guard let d = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([ProjectRecord].self, from: d) else { return [] }
        return list.sorted { $0.updated > $1.updated }
    }

    /// §251：新建项目 —— 先只登记「名字 + 目录」，张数等这个目录跑过批量再更新。
    @discardableResult
    public static func create(path: String, name: String) -> [ProjectRecord] {
        upsert(ProjectRecord(path: path, done: 0, total: 0, name: name))
    }

    /// §251：改名（项目卡片上直接改，不改目录）
    @discardableResult
    public static func rename(path: String, name: String) -> [ProjectRecord] {
        var list = load()
        if let i = list.firstIndex(where: { $0.path == path }) {
            list[i].name = name
            list[i].updated = Date()
            if let d = try? JSONEncoder().encode(list) { try? d.write(to: fileURL) }
        }
        return list
    }

    /// 登记/更新一条项目（同路径覆盖），最多保留 50 条
    @discardableResult
    public static func upsert(_ rec: ProjectRecord) -> [ProjectRecord] {
        // §251：批量跑完会 upsert 同一个目录 —— 但不能把「新建项目」设的名字抹掉（名字只由用户改）。
        var r = rec
        if r.name == nil, let old = load().first(where: { $0.path == r.path }), let n = old.name { r.name = n }
        var list = load().filter { $0.path != r.path }
        list.insert(r, at: 0)
        if list.count > 50 { list = Array(list.prefix(50)) }
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: fileURL) }
        return list
    }
}

public func write(_ img: CIImage, to url: URL, format: String = "jpeg", quality: Double = 95) -> Bool {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let opaque = format == "tiff" ? img : img.composited(over: CIImage(color: .white).cropped(to: img.extent))
    guard let cg = sharedCtx.createCGImage(opaque, from: img.extent, format: .RGBA8, colorSpace: space) else { return false }
    let uti = format == "tiff" ? UTType.tiff.identifier : UTType.jpeg.identifier
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else { return false }
    let props: [CFString: Any] = format == "tiff" ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}
