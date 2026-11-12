import AppKit

// SwiftPM 可执行入口：accessory 应用（不占 Dock、不抢焦点），
// 打包时 Info.plist 里的 LSUIElement 与这里保持一致。
private let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
