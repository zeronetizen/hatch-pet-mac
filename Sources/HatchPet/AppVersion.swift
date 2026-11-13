import Foundation

/// 应用版本文案：运行时从 Bundle 的 Info.plist 读 CFBundleShortVersionString
/// 与 CFBundleVersion 拼接，永不硬编码——发版只改 Packaging/Info.plist 一处，
/// 设置窗口与状态菜单显示的版本便自动跟上。文案形如「HatchPet v0.7 (build 7)」。
enum AppVersion {
    static var displayString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "MusePet v\(short) (build \(build))"
    }
}
