import AppKit

/// 气泡内容视图：圆角背景 + 换行文字；点击回调（用于立即关闭气泡）。
private final class BubbleView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// 状态消息气泡：贴宠物窗口上方居中的独立小面板（不占宠物窗、不被其边界裁剪），
/// 文本多行折行（总宽 ≤240、最多 3 行、尾部省略号），按行数 6/8/10 秒自动消失、点击立即消失。
/// 宠物拖动结束/尺寸变化时由 AppDelegate 调 repositionIfVisible 跟随。
final class BubbleController {
    /// 气泡最大总宽（pt）；四边内边距 10 → 内容最大宽 = 240 - 20 = 220。
    private static let maxBubbleWidth: CGFloat = 240
    private static let bubblePadding: CGFloat = 10
    private static let maxLines = 3

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
        // 显式测折行尺寸：label.sizeToFit() 对长文本会量成单行宽（真机实测气泡拉成横条），
        // 所以按内容最大宽用 boundingRect 自己算行数与实际宽高。
        let font = label.font ?? .systemFont(ofSize: 13)
        let maxContentW = Self.maxBubbleWidth - Self.bubblePadding * 2
        let bound = (message as NSString).boundingRect(
            with: NSSize(width: maxContentW, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let rawLines = Int(ceil(bound.height / lineHeight))
        let lines = min(Self.maxLines, max(1, rawLines))
        let contentW = max(ceil(bound.width), 40)          // 短消息仍是小气泡，宽取实际文本宽
        let contentH = ceil(lineHeight * CGFloat(lines))   // 高度随行数增长（封顶 3 行）
        label.frame = NSRect(x: Self.bubblePadding, y: Self.bubblePadding,
                             width: contentW, height: contentH)
        panel.setContentSize(NSSize(width: contentW + Self.bubblePadding * 2,
                                    height: contentH + Self.bubblePadding * 2))
        position(panel: panel, anchor: anchor)
        panel.orderFrontRegardless()
        // 显示时长随行数：1 行 6 秒 / 2 行 8 秒 / 3 行 10 秒
        let duration: TimeInterval = lines <= 1 ? 6.0 : (lines == 2 ? 8.0 : 10.0)
        PetLog.d("气泡显示 lines=\(lines) duration=\(Int(duration))s size=\(Int(contentW + Self.bubblePadding * 2))x\(Int(contentH + Self.bubblePadding * 2)) message=\"\(message)\"")
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            self?.hide(reason: "到时自动（\(Int(duration)) 秒）")
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
        label.maximumNumberOfLines = Self.maxLines   // 超过 3 行尾部省略号截断
        label.preferredMaxLayoutWidth = Self.maxBubbleWidth - Self.bubblePadding * 2
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
