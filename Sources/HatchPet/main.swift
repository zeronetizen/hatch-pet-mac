import AppKit

// SwiftPM 可执行入口：accessory 应用（不占 Dock、不抢焦点），
// 打包时 Info.plist 里的 LSUIElement 与这里保持一致。
private let appDelegate = AppDelegate()
let app = NSApplication.shared
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
installMainMenu()
app.run()

/// 最小主菜单（v0.26）：本 App 纯代码构建、无 nib/storyboard，Info.plist 也没
/// 有 NSMainNibFile——不手动装主菜单时 NSApp.mainMenu 恒为 nil，而 AppKit 里
/// Cmd+V/X/C/A 的键等价由主菜单的 Edit 项承载，无人派发时所有文本框按 Cmd+V
/// 粘贴全无反应（v0.25 及以前通道码框「粘上去像没有一样」的根因；打字与右键
/// 菜单 Paste 不经主菜单，所以一直没暴露）。这里只装一个 Edit 子菜单：动作以
/// nil target 走响应链、发给当前字段编辑器，不改变 accessory 形态与状态栏菜单。
private func installMainMenu() {
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    let redoItem = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = editMenu
    let mainMenu = NSMenu()
    mainMenu.addItem(editItem)
    app.mainMenu = mainMenu
}
