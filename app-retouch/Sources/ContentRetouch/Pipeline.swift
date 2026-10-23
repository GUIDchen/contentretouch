// Pipeline.swift：从 ContentRetouchApp.swift 按功能拆出（只搬家，不改逻辑）。
// 存储属性（@State 等）必定留在主文件——Swift 不允许 extension 里有存储属性。
import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import RetouchCore

extension MainView {
    /// 范围 → 蒙版：**形状 ∪ 画笔加 − 画笔减**（照 PS：蒙版上涂白=生效、涂黑=不生效）。
    func regionMaskImage(_ r: RegionAdjust, _ e: CGRect) -> CIImage {
        var mask: CIImage
        if r.shape == 3 {
            mask = blackMask(e)                    // 纯画笔蒙版：从全黑开始涂
        } else {
            let rect = CGRect(x: e.minX + r.rect.minX * e.width, y: e.minY + r.rect.minY * e.height,
                              width: r.rect.width * e.width, height: r.rect.height * e.height)
            let fe = max(1, min(rect.width, rect.height) * (r.feather / 100))
            mask = shapeMask(r, rect: rect, feather: fe, extent: e)
        }
        for st in r.paintAdd { mask = maskUnion(mask, maskCircle(st, e)) }
        for st in r.paintSub {
            mask = mask.applyingFilter("CIMultiplyBlendMode", parameters: [
                kCIInputBackgroundImageKey: invertedMask(maskCircle(st, e), extent: e)])
        }
        return r.inverted ? invertedMask(mask, extent: e) : mask
    }

    /// 一笔蒙版笔画 → 一张柔边圆蒙版
    func maskCircle(_ s: MaskStroke, _ e: CGRect) -> CIImage {
        let r = max(1, s.r / 100 * Double(max(e.width, e.height)))
        let c = CGPoint(x: e.minX + s.x * e.width, y: e.minY + s.y * e.height)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        return rectMask(extent: e, rect: rect, feather: max(1, r * 0.5), ellipse: true)
    }

    func shapeMask(_ r: RegionAdjust, rect: CGRect, feather fe: Double, extent e: CGRect) -> CIImage {
        if r.shape == 0 {   // 矩形（硬边靠 feather 控制）
            return rectMask(extent: e, rect: rect, feather: fe)
        }
        // 椭圆 / 圆形：圆形 = 取短边做正方形（形状 2 与 1 的差别就是是否强制等宽高）
        var rr = rect
        if r.shape == 2 {
            let side = min(rect.width, rect.height)
            rr = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        }
        return rectMask(extent: e, rect: rr, feather: fe, ellipse: true)
    }

    func applyGeometry(_ img: CIImage, _ m: ManualEditSet) -> CIImage {
        var out = img
        let autoCropOn = m.autoCrop, rotateDeg = m.rotateDeg, flipH = m.flipH, quarterTurns = m.quarterTurns
        if autoCropOn {
            let rect = detectBorderCropConverged(out)
            if rect.width < out.extent.width - 2 || rect.height < out.extent.height - 2 {
                out = out.cropped(to: rect)
            }
        }
        if abs(rotateDeg) > 0.01 || flipH || quarterTurns != 0 {
            let e = out.extent
            // 先挪到原点再变换，否则变换会绕着图像外原点转，内容跑出画布

            var t = out.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            if flipH { t = t.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
            let totalDeg = rotateDeg + Double(quarterTurns) * 90
            if abs(totalDeg) > 0.01 {
                t = t.transformed(by: CGAffineTransform(rotationAngle: totalDeg * .pi / 180))
            }
            // 变换后裁回原来尺寸的中心区域，避免出现透明边
            let size = e.size
            let c = CGPoint(x: t.extent.midX, y: t.extent.midY)
            let rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2,
                              width: size.width, height: size.height)
            out = t.cropped(to: rect).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        }
        return out
    }

    func manualEditsNow() -> ManualEditSet {
        var m = ManualEditSet()
        m.spotPoints = spotPoints; m.spotRadius = spotRadius
        m.spotFeather = spotFeather; m.spotStrength = spotStrength
        m.cloneFeather = cloneFeather; m.cloneOpacity = cloneOpacity
        m.spotFeather = spotFeather; m.spotStrength = spotStrength
        m.cloneFeather = cloneFeather; m.cloneOpacity = cloneOpacity
        m.patchActive = patchActive; m.cloneActive = cloneActive
        m.clonePoints = clonePoints; m.patchPoints = patchPoints; m.cloneSource = cloneSource; m.cloneRadius = cloneRadius
        m.cloneOffsets = cloneOffsets(clonePoints, epochs: cloneEpochs)
        m.warp = warpStrokes; m.freeze = freezeStrokes
        m.sky = sky
        m.autoCrop = autoCropOn; m.rotateDeg = rotateDeg
        m.flipH = flipH; m.quarterTurns = quarterTurns
        m.cropRect = cropRect
        m.cropApplied = cropApplied
        m.liquifyAmount = liquifyAmount
        m.faceRect = faces.max(by: { $0.rect.width < $1.rect.width })?.rect
        return m
    }

    /// 阶段一：修复（污点/修补/仿制）。放在调色之前——先修再调。
    func repairStage(_ input: CIImage, _ m: ManualEditSet) -> CIImage {
        let e = input.extent
        var out = input
        if !m.spotPoints.isEmpty {
            out = healSpots(out, points: m.spotPoints.map { denorm($0, e) },
                            radius: radiusPx(m.spotRadius, e),
                            strength: m.spotStrength / 100, feather: m.spotFeather / 100)
        }
        // **不再看"工具是否开着"**：效果是编辑结果，不是临时预览；关掉工具 = 退出编辑。
        if !m.patchPoints.isEmpty {
            out = patch(out, points: m.patchPoints.map { denorm($0, e) },
                        radius: radiusPx(m.cloneRadius, e), feather: m.cloneFeather / 100)
        }
        if m.cloneSource != nil, !m.clonePoints.isEmpty {
            let offs = m.cloneOffsets.map { denorm($0, e) }
            out = cloneAligned(out, points: m.clonePoints.map { denorm($0, e) }, offsets: offs,
                               radius: radiusPx(m.cloneRadius, e),
                               feather: m.cloneFeather / 100, opacity: m.cloneOpacity / 100)
        }
        return out
    }

    /// 阶段二：换天空 → 液化笔触 → 祛边/旋转/翻转 → 裁剪 → 整体液化。
    /// 顺序在预览里已经验证过（几何类必须放最后，否则按关键点算的蒙版会对不上）。
    func finishStage(_ input: CIImage, _ m: ManualEditSet) -> CIImage {
        let e = input.extent
        var out = input
        if m.sky.anyEnabled { let r = replaceSky(out, m.sky); out = r.image }
        if !m.warp.isEmpty || !m.freeze.isEmpty {
            func conv(_ list: [WarpStroke]) -> [WarpStroke] {
                list.map { st in
                    WarpStroke(mode: st.mode, center: denorm(st.center, e), radius: radiusPx(st.radius, e),
                               delta: CGPoint(x: st.delta.x * e.width, y: st.delta.y * e.height),
                               strength: st.strength, density: st.density)
                }
            }
            out = applyLiquify(out, strokes: conv(m.warp), freeze: conv(m.freeze))
        }
        out = applyGeometry(out, m)
        if let r = m.cropRect, m.cropApplied { out = out.cropped(to: denorm(r, e)) }
        if abs(m.liquifyAmount) > 0.5, let fr = m.faceRect {
            let cx = fr.midX * e.width, cy = fr.midY * e.height
            let r = Double(fr.width) * Double(e.width) * 1.6
            out = liquify(out, strokes: [LiquifyStroke(center: CGPoint(x: cx, y: cy), radius: r,
                                                       strength: m.liquifyAmount / 100)])
        }
        return out
    }

    /// 修复类工具的参数指纹（**单一来源**：既进缓存键，也用于判断能不能增量复用）
    var paramKey: String {
        String(format: "%.2f,%.2f,%.2f,%.2f,%.2f,%.2f",
               spotRadius, spotFeather, spotStrength, cloneRadius, cloneFeather, cloneOpacity)
    }

    /// 修复一遍：污点修复 / 修补 / 仿制图章，按（原片尺寸 + 落点 + 半径 + 工具属性）记忆化
    func repairPass(_ input: CIImage) -> CIImage {
        let t0 = Date()
        let e = input.extent
        let hasRepair = !spotPoints.isEmpty || !patchPoints.isEmpty || !clonePoints.isEmpty
        if !hasRepair { return input }      // 没有任何修复
        var key = "\(Int(e.width))x\(Int(e.height))"
        key += "|s\(spotPoints.count)|p\(patchPoints.count)|c\(clonePoints.count)|eo\(cloneEpochs.count)"
        // ⚠️ **工具属性必须进键**（第 111 节修的 bug）：原来只记了落点数与半径，
        // 于是改「羽化 / 程度 / 不透明度」时键没变 → 命中旧缓存 → 预览纹丝不动，滑杆看着像坏的。
        key += "|P" + paramKey
        key += "|src\(cloneSource.map { "\($0.x),\($0.y)" } ?? "-")"
        if key == repairCacheKey, let c = repairCacheImage { return c }
        var out = input
        // 增量：落点是只增的（同半径下），就只把**新增的那些**作用在上一次的结果上
        let canIncremental = bakedSpotRadius == spotRadius
            && bakedParamKey == paramKey
            && spotPoints.count > bakedSpotCount
            && Array(spotPoints.prefix(bakedSpotCount)) == bakedSpotPoints
            && repairCacheImage != nil
        let pm = manualEditsNow()      // 工具属性（羽化/程度/不透明度）与导出走同一份值
        if canIncremental, let prev = repairCacheImage {
            let fresh = Array(spotPoints.dropFirst(bakedSpotCount))
            out = healSpots(prev, points: fresh.map { denorm($0, e) }, radius: radiusPx(spotRadius, e),
                            strength: pm.spotStrength / 100, feather: pm.spotFeather / 100)
        } else if !spotPoints.isEmpty {
            out = healSpots(out, points: spotPoints.map { denorm($0, e) }, radius: radiusPx(spotRadius, e),
                            strength: pm.spotStrength / 100, feather: pm.spotFeather / 100)
        }
        bakedSpotCount = spotPoints.count
        bakedSpotRadius = spotRadius
        bakedSpotPoints = spotPoints
        bakedParamKey = paramKey
        if !patchPoints.isEmpty {
            out = patch(out, points: patchPoints.map { denorm($0, e) }, radius: radiusPx(cloneRadius, e),
                        feather: pm.cloneFeather / 100)
        }
        if cloneSource != nil, !clonePoints.isEmpty {
            // **来源跟着笔走**：逐点偏移（原来每个点都盖取样点那块，一笔下来全是同一个图案）
            let offs = cloneOffsets(clonePoints, epochs: cloneEpochs).map { denorm($0, e) }
            out = cloneAligned(out, points: clonePoints.map { denorm($0, e) }, offsets: offs,
                               radius: radiusPx(cloneRadius, e),
                               feather: pm.cloneFeather / 100, opacity: pm.cloneOpacity / 100)
        }
        if selfCheckEcho {
            let dt = Date().timeIntervalSince(t0)
            FileHandle.standardError.write(String(format: "修复耗时 %.0f ms（原片 %dx%d，只处理洞的包围盒）\n",
                                                   dt * 1000, Int(e.width), Int(e.height)).data(using: .utf8)!)
        }
        repairCacheKey = key
        repairCacheImage = out
        return out
    }

    /// 仿制图章**逐点偏移**：同一取样段内恒定 = 该段第一个落点 − 取样点；换取样点后换新值。
    /// 归一化空间里算，之后由 denorm 换算到像素（两者都是线性，减法与换算可交换）。
    func cloneOffsets(_ pts: [CGPoint], epochs: [(at: Int, source: CGPoint)]) -> [CGPoint] {
        guard !pts.isEmpty else { return [] }
        // 没有段信息（历史恢复/老数据）时用"首个落点 − 取样点"恒定偏移：
        // 至少是一整条连续纹理；**绝不能退回偏移 0** —— 那等于把每个点原样复盖一遍，什么都不会变。
        guard let firstSrc = epochs.first?.source else {
            guard let s = cloneSource else { return Array(repeating: .zero, count: pts.count) }
            let off = CGPoint(x: pts[0].x - s.x, y: pts[0].y - s.y)
            return Array(repeating: off, count: pts.count)
        }
        _ = firstSrc
        var out: [CGPoint] = []
        var cur = 0
        for (i, _) in pts.enumerated() {
            while cur + 1 < epochs.count && epochs[cur + 1].at <= i { cur += 1 }
            let e = epochs[cur]
            let anchor = pts[min(max(0, e.at), pts.count - 1)]
            out.append(CGPoint(x: anchor.x - e.source.x, y: anchor.y - e.source.y))
        }
        return out
    }

    // MARK: 效果链（预览与导出共用，保证所见即所得）
    /// geos：与 input 同尺度的关键点；传 nil 时内部自己检测（导出全分辨率时用 nil）
    func renderPipeline(_ input: CIImage, geos: [FaceGeo]? = nil, cfg: PipelineConfig? = nil) -> CIImage {
        // ⚠️ 这一段是**同名的局部变量遮蔽 @State**，不是重复声明。
        // 好处：下面 120 行的管线代码一个字都不用改，就能在「界面状态」与「导出快照」之间切换；
        // 代价是这一段必须**跟着管线正文一起维护**——正文里新读一个 @State，这里也要补一行，
        // 否则导出会静默沿用旧值（不再有第二条实现，但漏一行同样是坑）。已在文档里记下这条约定。
        let params = cfg?.params ?? self.params
        let target = cfg?.target ?? self.target
        let faces = cfg?.faces ?? self.faces
        let cachedGeos = cfg?.cachedGeos ?? self.cachedGeos
        let personSkin = cfg?.personSkin ?? self.personSkin
        let portrait = cfg?.portrait ?? self.portrait
        let autoSkinAmount = cfg?.autoSkinAmount ?? self.autoSkinAmount
        let slimWaist = cfg?.slimWaist ?? self.slimWaist
        let wideShoulders = cfg?.wideShoulders ?? self.wideShoulders
        let bodyDeformFactor = cfg?.bodyK ?? self.bodyDeformFactor
        let localWarm = cfg?.localWarm ?? self.localWarm
        let localBright = cfg?.localBright ?? self.localBright
        let petStrength = cfg?.pet ?? self.petStrength
        let petOptions = cfg?.petOptions ?? self.petOptions
        let bgPurify = cfg?.bgPurify ?? self.bgPurify
        let clothesStrength = cfg?.clothes ?? self.clothesStrength
        let autoWB = cfg?.autoWB ?? self.autoWB
        let autoExposeAmount = cfg?.autoExpose ?? self.autoExposeAmount
        let highlightRecover = cfg?.highlightRecover ?? self.highlightRecover
        let denoiseAmount = cfg?.denoise ?? self.denoiseAmount
        let sharpenAmount = cfg?.sharpen ?? self.sharpenAmount
        let smartSharpen = cfg?.smartSharpen ?? self.smartSharpen
        let autoFill = cfg?.autoFill ?? self.autoFill
        let bgBlur = cfg?.bgBlur ?? self.bgBlur
        let edgeRefine = cfg?.edgeRefine ?? self.edgeRefine
        let vignetteAmount = cfg?.vignette ?? self.vignetteAmount
        let grainAmount = cfg?.grain ?? self.grainAmount
        let lightAmount = cfg?.light ?? self.lightAmount
        let lightWarm = cfg?.lightWarm ?? self.lightWarm
        let lensDistortion = cfg?.lensDistortion ?? self.lensDistortion
        let lensVignette = cfg?.lensVignette ?? self.lensVignette
        let lensCA = cfg?.lensCA ?? self.lensCA
        let perspH = cfg?.perspH ?? self.perspH
        let perspV = cfg?.perspV ?? self.perspV
        let manualAll = cfg?.manual ?? manualEditsNow()
        let regions = cfg?.regions ?? self.regions
        let regionMatches = cfg?.regionMatches ?? self.regionMatches
        let parts = cfg?.parts ?? self.partAdjusts
        let e = input.extent
        // —— 修复类操作放在最前面（#4 的算法升级顺带带来的结构调整）——
        // 一、语义对：祛痘/去污/修补/仿制是「修」，调色与美颜是「调」，先修再调；
        // 二、性能对：换成基于样例的修补之后一个洞要 200ms 级，而这些操作只依赖**原片**与落点，
        //     与调色参数无关——放在最前面才能缓存下来，否则拖一下滑杆就重跑一次（实测拖一下就卡）。
        // 预览路径继续用带缓存的 repairPass（拖滑杆不重跑）；导出路径用快照里的值
        let repaired = cfg == nil ? repairPass(input) : repairStage(input, manualAll)
        var out = renderWithFaces(repaired, global: params, faces: faces,
                                  perFace: cfg?.perFace ?? perFaceParams())
        // 分区追色（#4）：先按区域把「该区域朝参考看齐」的那一版贴上去，再做范围选择的局部增量。
        if !regionMatches.isEmpty {
            for rm in regionMatches {
                guard let m = rm.region.mask(repaired) else { continue }
                let local = render(repaired, rm.params)
                out = local.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
            }
        }
        // ⑩ 按部位：脸/眼/唇/鼻/耳/手臂/腿，每块各自贴各自的增量
        if !parts.isEmpty { out = applyPartAdjustments(out, parts, geos: geos ?? [], base: params) }
        // 范围选择：对每个启用的范围，用「全局 + 该范围的增量」再渲一遍颜色，按形状蒙版贴回去。
        // 放在调色之后、皮肤/人像之前：局部加减的是**颜色与影调**，后面的美颜仍按整幅走。
        for r in regions where r.enabled && !r.isEmpty {
            var lp = params
            lp.brightness += r.dBrightness
            lp.contrast = max(0, lp.contrast + r.dContrast)
            lp.desat = max(0, lp.desat + r.dSat)
            lp.gamma = max(0.2, lp.gamma + r.dGamma)
            lp.cbSh[0] += r.dWarm / 1.923     // 与全局面板的刻度一致（Δ(R−B) 折算）
            lp.cbHi[0] += r.dWarm / 1.923
            let local = render(repaired, lp)
            let m = regionMaskImage(r, e)
            out = local.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: m])
        }
        var sk = cfg?.skin ?? SkinOptions()
        if cfg == nil {
            sk.grade = skinGrade
            sk.strength = skinStrength
            sk.unifyTone = skinTone
            sk.texturePreserve = texturePreserve
            sk.deltaWarm = target.warmHi * 0.25
        }
        out = applySkin(out, sk, geos: geos)
        // 按人分别处理（实例分割）：只有用户真的给了强度才跑分割，避免每拖一下滑杆都分割
        if personSkin.contains(where: { $0 > 0.01 }) {
            var po = sk
            po.grade = "off"                      // 强度由逐人值给
            po.strength = 0
            let persons = ensurePersons()
            out = applySkinPerPerson(out, po, persons: persons, strengths: personSkin,
                                     faceBoxes: cachedGeos.map { $0.box },
                                     faces: cachedGeos)   // 关键点：用来扣掉眼睛
        }
        if portrait.anyEnabled { out = applyPortrait(out, portrait, geos: geos) }
        if autoSkinAmount > 0.5 {
            // 自动肤色：用皮肤掩膜量出肤色色相，朝目标带微调（只在皮肤区）
            var faces: [FaceGeo] = geos ?? []
            if faces.isEmpty, let cg = sharedCtx.createCGImage(out, from: e) {
                faces = detectFaceGeos(cg, size: e.size)
            }
            if !faces.isEmpty {
                let mask = faces.count == 1 ? skinMaskForFace(out, face: faces[0])
                                            : skinMaskForFaces(out, geos: faces)
                let (fixed, _, shift) = autoSkinTone(out, mask: mask, amount: autoSkinAmount)
                out = fixed
                if abs(shift) > 0.2 { _ = shift }
            }
        }
        if slimWaist > 0.5 || wideShoulders > 0.5 {
            // 侧身折扣：3D 姿态判出朝向，侧身时收腰/宽肩按 |cos| 打折（见 bodyDeformFactor）
            out = reshapeBody(out, slimWaist: slimWaist * bodyDeformFactor,
                              wideShoulders: wideShoulders * bodyDeformFactor)
        }
        if let r = cropRect, abs(localWarm) > 0.01 || abs(localBright) > 0.01 {
            out = localColorMatch(out, rect: denorm(r, e), deltaWarm: localWarm, deltaBright: localBright,
                                  strength: 0.9, feather: 24)
        }
        if petOptions.anyEnabled { out = applyPetDetailed(out, petOptions) }
        else if petStrength > 0.5 { out = smoothAnimals(out, strength: petStrength) }
        if bgPurify > 0.5 { out = purifyBackgroundEx(out, flattenRadius: 24, strength: bgPurify) }
        if clothesStrength > 0.5 { out = smoothClothes(out, strength: clothesStrength) }
        // 换天空 + 液化笔触：与批量导出共用同一份实现（见 finishStage）
        if manualAll.sky.anyEnabled || !manualAll.warp.isEmpty || !manualAll.freeze.isEmpty {
            out = finishStage(out, manualAll)
        }
        // 自动白平衡放在最前面（它是「把拍摄时的色偏校回来」，后面的调色都应以它为前提）
        if autoWB > 0.5 { out = applyWhiteBalance(out, amount: autoWB) }
        if autoExposeAmount > 0.5 { out = autoExpose(out, amount: autoExposeAmount) }
        if highlightRecover > 0.5 { out = recoverHighlights(out, amount: highlightRecover) }
        // 后调色补充：先降噪再锐化（顺序反了等于把噪点也锐出来）
        if denoiseAmount > 0.5 { out = denoise(out, amount: denoiseAmount) }
        if sharpenAmount > 0.5 { out = sharpen(out, amount: sharpenAmount) }
        if smartSharpen > 0.5 { out = sharpenEdgeAware(out, amount: smartSharpen) }
        if autoFill > 0.5 {
            let face = cachedGeos.max(by: { $0.box.width < $1.box.width })?.box
            out = autoFillLight(out, amount: autoFill, face: face)
        }
        // 虚化前先留一份：边缘优化要把**清晰的主体边缘**贴回虚化后的图里
        //（refineEdges 以前是空操作，见它的注释；coretest 第 27 段量出 0.00 才被发现）
        let beforeBlur = out
        if bgBlur > 0.5 { out = backgroundBlur(out, radius: 24, strength: bgBlur) }
        if edgeRefine > 0.5 { out = refineEdges(out, amount: edgeRefine, original: beforeBlur) }
        if abs(vignetteAmount) > 0.5 { out = vignette(out, amount: vignetteAmount) }
        if grainAmount > 0.5 { out = grain(out, amount: grainAmount) }
        if lightAmount > 0.5 {
            out = addLight(out, strength: lightAmount,
                           at: CGPoint(x: e.midX, y: e.minY + e.height * 0.68),
                           radiusRatio: 0.75, warm: lightWarm)
        }
        // 镜头校正 + 透视校正：放在最后（它改的是几何，应该移动「已经修好的整幅图」，
        // 放在前面会让后面所有按关键点算的蒙版对不上）
        if abs(lensDistortion) > 0.01 { out = correctLensDistortion(out, amount: lensDistortion) }
        if lensVignette > 0.01 { out = correctVignetting(out, amount: lensVignette) }
        if abs(lensCA) > 0.01 { out = correctChromaticAberration(out, amount: lensCA) }
        if abs(perspH) > 0.01 || abs(perspV) > 0.01 {
            out = perspectiveCorrect(out, horizontal: perspH, vertical: perspV)
        }
        // 几何（祛边/旋转/翻转）→ 裁剪 → 整体液化：用同一份实现，导出走的是同一条链
        var geo = manualAll
        geo.sky = SkyOptions()        // 天空与液化笔触上面已经做过，这里只补几何与裁剪
        geo.warp = []; geo.freeze = []
        let sigBefore = ProcessInfo.processInfo.environment["CR_AUDIT"] == "1" ? diagSig(out) : 0
        out = finishStage(out, geo)
        if ProcessInfo.processInfo.environment["CR_AUDIT"] == "1" {
            FileHandle.standardError.write("PIPESIG 收腰前 \(sigBefore) → 返回前 \(diagSig(out))（宽肩=\(wideShoulders) 收腰=\(slimWaist)）\n".data(using: .utf8)!)
        }
        return out
    }
}
