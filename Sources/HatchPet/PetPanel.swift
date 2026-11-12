import AppKit

/// 悬浮宠物窗口：无边框、不抢焦点的 NSPanel，透明背景、始终置顶、
/// 出现在所有桌面空间（含全屏应用上方）。位置/尺寸由 AppDelegate 管理与持久化。
final class PetPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false // 拖动由内容视图手动实现（见 PetViews.swift）
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        PetLog.d("PetPanel 初始化 frame=\(contentRect) level=floating spaces=all")
    }

    // 宠物不需要成为 key/main 窗口，避免抢占其他应用的键盘焦点
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
