import AppKit

/// 气泡内容视图：说话泡泡轮廓（圆角矩形主体 + 底部中央向下的小尾巴）+ 换行文字；
/// 点击回调（用于立即关闭气泡）。轮廓在 draw 里用一条 NSBezierPath 一次画完
/// （主体与尾巴同一条路径，避免接缝处出现描边横线）。
private final class BubbleView: NSView {
    /// 泡泡几何（与 BubbleController 的布局共用）：主体圆角半径、尾巴宽/高。
    static let cornerRadius: CGFloat = 12
    static let tailWidth: CGFloat = 14
    static let tailHeight: CGFloat = 8

    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // 轮廓按 bounds 现画，尺寸变了必须重画
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 整体内缩 0.75，给 0.5pt 描边留位置，避免边缘被裁
        let b = bounds.insetBy(dx: 0.75, dy: 0.75)
        let body = NSRect(x: b.minX, y: b.minY + Self.tailHeight,
                          width: b.width, height: b.height - Self.tailHeight)
        let r = Self.cornerRadius
        let cx = b.midX
        let halfTail = Self.tailWidth / 2
        let tip = NSPoint(x: cx, y: b.minY + 0.5)   // 尾巴尖，朝向宠物头顶

        let path = NSBezierPath()
        // 沿主体底边从左向右：底边 → 尾巴（下探再回来）→ 底边 → 右下圆角 → 右边 →
        // 右上圆角 → 顶边 → 左上圆角 → 左边 → 左下圆角，闭合。四角用双控制点同置于
        // 角点的三次曲线近似圆角。
        path.move(to: NSPoint(x: body.minX + r, y: body.minY))
        path.line(to: NSPoint(x: cx - halfTail, y: body.minY))
        path.line(to: tip)
        path.line(to: NSPoint(x: cx + halfTail, y: body.minY))
        path.line(to: NSPoint(x: body.maxX - r, y: body.minY))
        path.curve(to: NSPoint(x: body.maxX, y: body.minY + r),
                   controlPoint1: NSPoint(x: body.maxX, y: body.minY),
                   controlPoint2: NSPoint(x: body.maxX, y: body.minY))
        path.line(to: NSPoint(x: body.maxX, y: body.maxY - r))
        path.curve(to: NSPoint(x: body.maxX - r, y: body.maxY),
                   controlPoint1: NSPoint(x: body.maxX, y: body.maxY),
                   controlPoint2: NSPoint(x: body.maxX, y: body.maxY))
        path.line(to: NSPoint(x: body.minX + r, y: body.maxY))
        path.curve(to: NSPoint(x: body.minX, y: body.maxY - r),
                   controlPoint1: NSPoint(x: body.minX, y: body.maxY),
                   controlPoint2: NSPoint(x: body.minX, y: body.maxY))
        path.line(to: NSPoint(x: body.minX, y: body.minY + r))
        path.curve(to: NSPoint(x: body.minX + r, y: body.minY),
                   controlPoint1: NSPoint(x: body.minX, y: body.minY),
                   controlPoint2: NSPoint(x: body.minX, y: body.minY))
        path.close()
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// 状态消息气泡：贴宠物窗口上方居中的独立小面板（不占宠物窗、不被其边界裁剪），
/// 形态为带尾巴的说话泡泡（v0.9 起，尾巴尖朝向宠物头顶）；
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
        // 文字区只在主体内：底部在尾巴之上，底部内边距不含尾巴高
        label.frame = NSRect(x: Self.bubblePadding, y: BubbleView.tailHeight + Self.bubblePadding,
                             width: contentW, height: contentH)
        let panelW = contentW + Self.bubblePadding * 2
        let panelH = contentH + Self.bubblePadding * 2 + BubbleView.tailHeight
        panel.setContentSize(NSSize(width: panelW, height: panelH))
        position(panel: panel, anchor: anchor)
        panel.invalidateShadow()   // 轮廓变了，让窗口阴影按新形状重算
        // 淡入（0.15 秒）。原计划的 0.96→1 缩放没做：内容视图的 layer 由窗口托管，
        // 改 anchorPoint 会让视图渲染位置偏移且本机无 Mac 无法验证，风险与点缀价值不匹配，
        // 只保留零布局风险的 alpha 淡入。
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // 显示时长随行数：1 行 6 秒 / 2 行 8 秒 / 3 行 10 秒
        let duration: TimeInterval = lines <= 1 ? 6.0 : (lines == 2 ? 8.0 : 10.0)
        PetLog.d("气泡显示 shape=speech lines=\(lines) duration=\(Int(duration))s size=\(Int(panelW))x\(Int(panelH)) message=\"\(message)\"")
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
            panel?.alphaValue = 1   // 复位淡入状态，下次 show 会先置 0 再淡入
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

        // 背景与边框全部由 BubbleView.draw 按说话泡泡轮廓画，不再用 layer 的
        // backgroundColor/cornerRadius（layer 圆角会按矩形裁剪、与尾巴轮廓冲突）。
        let view = BubbleView()
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
        var y = pet.maxY + 4   // 面板底边即尾巴尖，离宠物头顶 4pt
        if let screen = anchor.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
            if y + size.height > vf.maxY {
                // 上方放不下就贴宠物下方（此回退下尾巴仍朝下，与主体同向，不翻转）
                y = pet.minY - size.height - 4
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
