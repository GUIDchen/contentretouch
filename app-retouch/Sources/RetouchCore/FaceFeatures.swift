// FaceFeatures：面部关键点基础设施 + 依赖它的全部人像功能
//
// 【关键点口径（实测校准，不要改回老写法）】
//   VNFaceLandmarkRegion2D.normalizedPoints 是**相对人脸框**的，原点左下 —— 与 Core Image 同向，
//   所以图像坐标 = (box.minX + p.x * box.width, box.minY + p.y * box.height)，**不做 y 翻转**。
//   实测证据：脸框归一化 (0.661, 0.788, 0.133, 0.089) 的那张脸，innerLips 质心 (0.439, 0.269)
//   → 图像归一化 (0.719, 0.812)：落在脸框内、眼睛下方 ✅。旧代码用「图像归一化」口径算出 (0.439, 0.731)，
//   掉到脸框外（叠加图 docs/shots/关键点口径校准.png）。当时牙齿/唇色「验证通过」是因为
//   采样点用的也是同一个错蒙版 —— 循环验证，不算验证。
//
// 【位图蒙版 y 方向（实测校准）】
//   CGContext 画的位图包成 CIImage 后**不需要翻 y**：用脸框当多边形画蒙版，脸框处均值 0.986（不翻）、
//   0.000（翻）。旧代码里的 cy = H - y 是错的，会让蒙版落到镜像位置。
//
// 这两条都是「靠印象会猜错」的，所以 coretest 里都有对应断言。
import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - 关键点





// MARK: - 蒙版工具（统一用「不翻 y」的已验证写法）





// MARK: - 区域内颜色调整



// MARK: - 人像参数（一整组，界面直接绑）


// MARK: - 逐条功能实现




// MARK: - 主入口



// MARK: - 频域分离（保毛孔磨皮 / 肤色统一）
//
// 像素蛋糕卖点里的「中性灰磨皮 + 保留皮肤质感」= 频域分离：把图拆成
//   低频（色调/光影，负责斑块不均） + 高频（毛孔/细纹/边缘，负责质感）
// 磨皮要做的是「把低频弄均匀」，而不是「把高频压掉」；只压高频就会糊成塑料。
//
// Core Image 的滤镜没法把两张图相减（CIColorMatrix 只吃一张图），所以这里用
// CIColorKernel 写三行内核（本机实测可用，见 coretest 探针）。公式：
//   out = src + (low2 - low) * k
//   low  = 高斯(r)，low2 = 高斯(4r)
// 效果：把尺度在 r~4r 之间的色调不均抹平，比 r 更细的毛孔纹理原样保留。
private let toneKernelSource = """
kernel vec4 toneEven(__sample s, __sample low, __sample low2, float k) {
    vec3 d = low2.rgb - low.rgb;
    return vec4(s.rgb + d * k, s.a);
}
"""

/// 低频内核只编译一次（编译失败就回落到「线性混模糊图」的老办法）
let toneKernel: CIColorKernel? = CIColorKernel(source: toneKernelSource)



// MARK: - 手部 / 脚部（共用同一套「区域柔化」，不再各写一份）






