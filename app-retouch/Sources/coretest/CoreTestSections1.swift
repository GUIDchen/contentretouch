// CoreTestSections1.swift：coretest 的第 1~8 节，从 main.swift 拆出（逻辑一字未改）。
import Foundation
import RetouchCore
import CoreImage
import ImageIO
import Vision

func runSections1() {
// coretest：ContentRetouch 的可运行校验
//
// 规矩落成代码：
//   1) 不许循环验证：目标位置来自 Vision 关键点/人脸框（它们自己先被几何校验过），
//      判定用「变化质心离目标近、离镜像位置远」这种能证伪的口径。
//   2) 「该变的」和「不该变的」必须同时报数。
//   3) 差异必须按**全分辨率**比较——早先用缩放图比较，Core Image 重采样会造出满图假差异
//      （实测把 5e-6 的真实平均差放大成 0.03），差一点又误判一次。
// 失败会让退出码非 0。




// MARK: - 全分辨率差异图



/// 参数有效性体检要用的人像字段表（与 App 里的 portraitKeys 同源，这里只放核心层能直接写的那些）




/// 人像效果统一判定：
///   有效果 = 峰值变化足够大；落点 = 变化质心离目标近、离镜像远；不越界 = 脸区变化密度远高于远处


// MARK: - 素材



// MARK: - 1. 关键点口径

}
