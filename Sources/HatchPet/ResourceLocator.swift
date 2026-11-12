import Foundation

/// 资源定位：先查 .app 的 Bundle.main（assemble_app.sh 会把 5 个 mp4 平铺进
/// Contents/Resources，打包后的正式形态），再回退 SwiftPM 的 Bundle.module
/// （swift run / 直接跑构建产物时的形态，资源包由 assemble_app.sh 一并拷入
/// Contents/Resources，保证回退查找不会落空）。每次查找都打日志。
enum ResourceLocator {
    static func videoURL(for state: PetState) -> URL? {
        let name = state.resourceName
        if let url = Bundle.main.url(forResource: name, withExtension: "mp4") {
            PetLog.d("资源定位 state=\(state.rawValue) -> Bundle.main \(url.path)")
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: "mp4") {
            PetLog.d("资源定位 state=\(state.rawValue) -> Bundle.module \(url.path)")
            return url
        }
        PetLog.d("资源定位失败 state=\(state.rawValue) file=\(name).mp4（Bundle.main 与 Bundle.module 均未找到）")
        return nil
    }
}
