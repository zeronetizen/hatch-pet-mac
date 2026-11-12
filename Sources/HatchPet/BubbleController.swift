import AppKit

/// 气泡内容视图：圆角背景 + 换行文字；点击回调（用于立即关闭气泡）。
private final class BubbleView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 状态消息气泡：贴宠物窗口上方居中的小面板，6 秒自动消失、点击立即消失。
/// 宠物拖动结束/尺寸变化时由 AppDelegate 调 repositionIfVisible 跟随。
final class BubbleController {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideTimer: Timer?
    private weak var anchor: NSWindow?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(message: String, anchor: NSWindow) {
        self.anchor = anchor
        let panel = ensurePanel()
        guard let label = self.label else { return }
        label.stringValue = message
        // 宽度：最大内容宽 236（气泡总宽 ≤260，左右各 12 内边距）
        label.frame = NSRect(x: 12, y: 10, width: 236, height: 10)
        label.sizeToFit()
        let contentW = max(label.frame.width, 40)
        let contentH = label.frame.height
        label.frame = NSRect(x: 12, y: 10, width: contentW, height: contentH)
        panel.setContentSize(NSSize(width: contentW + 24, height: contentH + 20))
        position(panel: panel, anchor: anchor)
        panel.orderFrontRegardless()
        PetLog.d("气泡显示 message=\"\(message)\" size=\(Int(contentW + 24))x\(Int(contentH + 20))")
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            self?.hide(reason: "6 秒到时自动")
        }
    }

    func hide(reason: String = "手动") {
        hideTimer?.invalidate()
        hideTimer = nil
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            PetLog.d("气泡消失（\(reason)）")
        }
    }

    func repositionIfVisible() {
        guard isVisible, let panel, let anchor else { return }
        position(panel: panel, anchor: anchor)
        PetLog.d("气泡跟随宠物重定位 petOrigin=\(anchor.frame.origin)")
    }

    // MARK: - 内部

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let view = BubbleView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layer?.cornerRadius = 14
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.onClick = { [weak self] in self?.hide(reason: "点击") }

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 236
        view.addSubview(label)
        p.contentView = view

        self.panel = p
        self.label = label
        PetLog.d("气泡面板已创建")
        return p
    }

    private func position(panel: NSPanel, anchor: NSWindow) {
        let pet = anchor.frame
        let size = panel.frame.size
        var x = pet.midX - size.width / 2
        var y = pet.maxY + 8
        if let screen = anchor.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
            if y + size.height > vf.maxY {
                // 上方放不下就贴宠物下方
                y = pet.minY - size.height - 8
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
