import AppKit

/// 气泡内容视图：「思想云」轮廓（v0.10 起，用户在三方案示意图里选了 C）+ 下方
/// 两个递减圆点引线。云形画法在 v0.12 换代（wave=v3）：
/// - v0.10/v0.11：核心椭圆 + 12 个离散圆凸起的并集——真机小尺寸下每个凸起都
///   是一颗独立疙瘩，用户原话「全身起肿物」，且并集不能直接描边、只能垫底近似。
/// - v0.12：一条闭合平滑样条（Catmull-Rom→贝塞尔）一次成形——在核心椭圆上取
///   12 个控制点，半径只做低频调制（sin(2θ)/sin(3θ)，总振幅 ≤6%），整朵云只有
///   2–3 处大而缓的起伏；单路径可直接 stroke 描边（0.75pt），不再需要垫底法。
/// 云形路径（视图坐标）与圆点几何由 BubbleController 按「正常朝向」（云在上、
/// 圆点在下）算好下发；面板被迫贴到宠物下方时控制器把路径整体 y 镜像后下发，
/// 本视图不感知朝向。
/// 点击回调（用于立即关闭气泡）。
private final class BubbleView: NSView {
    var cloudPath: NSBezierPath?
    var dots: [(center: NSPoint, radius: CGFloat)] = []
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // 轮廓按几何现画，尺寸变了必须重画
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let cloudPath {
            NSColor.controlBackgroundColor.setFill()
            cloudPath.fill()
            NSColor.separatorColor.setStroke()
            cloudPath.lineWidth = 0.75
            cloudPath.stroke()
        }
        for dot in dots {
            let r = dot.radius
            let p = NSBezierPath(ovalIn: NSRect(x: dot.center.x - r, y: dot.center.y - r,
                                                width: r * 2, height: r * 2))
            NSColor.controlBackgroundColor.setFill()
            p.fill()
            NSColor.separatorColor.setStroke()
            p.lineWidth = 0.75
            p.stroke()
        }
    }
}

/// 状态消息气泡：贴宠物窗口上方居中的独立小面板（不占宠物窗、不被其边界裁剪），
/// 形态为思想云（云团轮廓 + 圆点引线，圆点串下端指向宠物头顶）；
/// 文本多行折行（内容最大宽 200、最多 3 行、尾部省略号），按行数 6/8/10 秒自动消失、点击立即消失。
/// 宠物拖动结束/尺寸变化时由 AppDelegate 调 repositionIfVisible 跟随。
final class BubbleController {
    /// 文字安全区最大宽（pt）：云团内圈不规则，文字只放中心安全区，故从旧版 220 收到 200。
    private static let maxContentWidth: CGFloat = 200
    private static let maxLines = 3
    /// 核心椭圆相对文字的留白：半轴 = 文字半宽 + 34 / 文字半高 + 28。
    /// v0.12 样条相对核心椭圆有 ≤6% 的低频起伏（最凹处向内约 6%），
    /// 留白比 v0.10/v0.11 的 30/24 略放大，保证文字四角始终在云内。
    private static let corePadX: CGFloat = 34
    private static let corePadY: CGFloat = 28
    /// 圆点串占高：云下间隙 6 + 大圆直径 10 + 间隙 5 + 小圆直径 7 + 底部余量 2 = 30。
    private static let dotsZoneHeight: CGFloat = 30

    /// 一次 show 的布局（全部按正常朝向：云在上、圆点在下；坐标为视图坐标系）。
    private struct Layout {
        var panelSize: NSSize
        var cloudPath: NSBezierPath
        var dots: [(center: NSPoint, radius: CGFloat)]
        var labelFrame: NSRect
    }

    private var panel: NSPanel?
    private var bubbleView: BubbleView?
    private var label: NSTextField?
    private var hideTimer: Timer?
    private weak var anchor: NSWindow?
    private var layout: Layout?
    private var flipped = false   // 面板被迫贴宠物下方时为真（圆点在上、云在下）

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(message: String, anchor: NSWindow) {
        self.anchor = anchor
        let panel = ensurePanel()
        guard let label = self.label, let view = self.bubbleView else { return }
        label.stringValue = message
        // 显式测折行尺寸：label.sizeToFit() 对长文本会量成单行宽（真机实测气泡拉成横条），
        // 所以按内容最大宽用 boundingRect 自己算行数与实际宽高。
        let font = label.font ?? .systemFont(ofSize: 13)
        let bound = (message as NSString).boundingRect(
            with: NSSize(width: Self.maxContentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let rawLines = Int(ceil(bound.height / lineHeight))
        let lines = min(Self.maxLines, max(1, rawLines))
        let contentW = max(ceil(bound.width), 40)          // 短消息仍是小气泡，宽取实际文本宽
        let contentH = ceil(lineHeight * CGFloat(lines))   // 高度随行数增长（封顶 3 行）

        let layout = Self.makeLayout(contentW: contentW, contentH: contentH)
        self.layout = layout
        self.flipped = false
        panel.setContentSize(layout.panelSize)
        applyLayout(layout, flipped: false, to: view, label: label)
        position(panel: panel, anchor: anchor)
        panel.invalidateShadow()   // 轮廓变了，让窗口阴影按新形状重算
        // 淡入（0.15 秒）。缩放点缀未做的原因见 v0.9 记录（layer anchorPoint 偏移、无 Mac 可验）。
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        // 显示时长随行数：1 行 6 秒 / 2 行 8 秒 / 3 行 10 秒
        let duration: TimeInterval = lines <= 1 ? 6.0 : (lines == 2 ? 8.0 : 10.0)
        PetLog.d("气泡显示 shape=cloud wave=v3 lines=\(lines) duration=\(Int(duration))s size=\(Int(layout.panelSize.width))x\(Int(layout.panelSize.height)) message=\"\(message)\"")
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

    // MARK: - 布局

    /// 云轮廓控制点（原点为云中心）：核心椭圆每 30° 一个、共 12 个；半径做
    /// 低频调制 m = 1 + 0.035·sin(2θ+0.9) + 0.025·sin(3θ+2.2)，总振幅 ≤ 6%，
    /// 相位写死保证形状稳定。整圈只有 2–3 处大而缓的起伏，不出现离散疙瘩。
    /// 底部点（sinθ ≤ -0.7）的调制减半，下沿保持相对平齐。
    private static func cloudControlPoints(a: CGFloat, b: CGFloat) -> [NSPoint] {
        var pts: [NSPoint] = []
        for i in 0..<12 {
            let t = CGFloat(i) * .pi / 6
            var m: CGFloat = 1 + 0.035 * sin(2 * t + 0.9) + 0.025 * sin(3 * t + 2.2)
            if sin(t) <= -0.7 { m = 1 + (m - 1) * 0.5 }
            pts.append(NSPoint(x: a * cos(t) * m, y: b * sin(t) * m))
        }
        return pts
    }

    /// Catmull-Rom 闭合样条 → 三次贝塞尔：曲线过全部控制点、无尖角，一次成形。
    private static func closedSplinePath(through pts: [NSPoint]) -> NSBezierPath {
        let n = pts.count
        let path = NSBezierPath()
        guard n >= 3 else { return path }
        path.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i + n - 1) % n]
            let p1 = pts[i]
            let p2 = pts[(i + 1) % n]
            let p3 = pts[(i + 2) % n]
            let c1 = NSPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = NSPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        path.close()
        return path
    }

    /// 按文字尺寸算云团布局（正常朝向）。面板尺寸由样条路径的外包围盒 + 四周
    /// 4pt 余量（描边与抗锯齿）决定；云占面板上部，圆点串占底部 dotsZoneHeight。
    private static func makeLayout(contentW: CGFloat, contentH: CGFloat) -> Layout {
        let a = contentW / 2 + corePadX          // 核心椭圆半轴
        let b = contentH / 2 + corePadY
        let path = closedSplinePath(through: cloudControlPoints(a: a, b: b))
        let bounds = path.bounds
        let margin: CGFloat = 8
        let cloudW = bounds.width + margin
        let cloudH = bounds.height + margin
        let panelSize = NSSize(width: cloudW, height: cloudH + dotsZoneHeight)
        // 把云形从「原点在云中心」的坐标系平移到视图坐标系
        let dx = -bounds.minX + margin / 2
        let dy = dotsZoneHeight - bounds.minY + margin / 2
        let shift = NSAffineTransform()
        shift.translateX(by: dx, yBy: dy)
        path.transform(using: shift)
        let center = NSPoint(x: bounds.midX + dx, y: bounds.midY + dy)
        // 圆点串：自云团下沿向下，半径 5 → 3.5 递减，略向左（宠物头顶方向）漂移
        let dots: [(center: NSPoint, radius: CGFloat)] = [
            (center: NSPoint(x: center.x - 5, y: dotsZoneHeight - 11), radius: 5),
            (center: NSPoint(x: center.x - 10, y: dotsZoneHeight - 24.5), radius: 3.5),
        ]
        let labelFrame = NSRect(x: center.x - contentW / 2, y: center.y - contentH / 2,
                                width: contentW, height: contentH)
        return Layout(panelSize: panelSize, cloudPath: path,
                      dots: dots, labelFrame: labelFrame)
    }

    /// 把布局下发到视图与标签；flipped 时云路径整体关于面板高度镜像、圆点与
    /// 标签同样镜像（云落到面板下部、圆点串在云上方，思想泡上下关系仍成立）。
    private func applyLayout(_ layout: Layout, flipped: Bool,
                             to view: BubbleView, label: NSTextField) {
        let h = layout.panelSize.height
        func flipRect(_ r: NSRect) -> NSRect {
            flipped ? NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) : r
        }
        func flipPoint(_ p: NSPoint) -> NSPoint {
            flipped ? NSPoint(x: p.x, y: h - p.y) : p
        }
        if flipped {
            // (x, y) -> (x, h - y)，用显式矩阵避免拼接顺序歧义；
            // 作用在布局路径的副本上，不污染原始布局。
            let flip = NSAffineTransform(transform: NSAffineTransformStruct(
                m11: 1, m12: 0, m21: 0, m22: -1, tX: 0, tY: h))
            let p = layout.cloudPath.copy() as! NSBezierPath
            p.transform(using: flip)
            view.cloudPath = p
        } else {
            view.cloudPath = layout.cloudPath
        }
        view.dots = layout.dots.map { (center: flipPoint($0.center), radius: $0.radius) }
        view.needsDisplay = true
        label.frame = flipRect(layout.labelFrame)
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

        // 背景与轮廓全部由 BubbleView.draw 按思想云轮廓画，不用 layer 的
        // backgroundColor/cornerRadius（layer 圆角会按矩形裁剪、与云形轮廓冲突）。
        let view = BubbleView()
        view.onClick = { [weak self] in self?.hide(reason: "点击") }

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = Self.maxLines   // 超过 3 行尾部省略号截断
        label.preferredMaxLayoutWidth = Self.maxContentWidth
        view.addSubview(label)
        p.contentView = view

        self.panel = p
        self.bubbleView = view
        self.label = label
        PetLog.d("气泡面板已创建")
        return p
    }

    private func position(panel: NSPanel, anchor: NSWindow) {
        let pet = anchor.frame
        let size = panel.frame.size
        var x = pet.midX - size.width / 2
        var y = pet.maxY + 4   // 面板底边（圆点串下端）离宠物头顶 4pt
        var wantFlipped = false
        if let screen = anchor.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
            if y + size.height > vf.maxY {
                // 上方放不下就贴宠物下方，并把布局镜像（圆点在上、云在下）
                y = pet.minY - size.height - 4
                wantFlipped = true
            }
        }
        if wantFlipped != flipped, let layout, let view = bubbleView, let label {
            flipped = wantFlipped
            applyLayout(layout, flipped: wantFlipped, to: view, label: label)
            panel.invalidateShadow()
            PetLog.d("气泡朝向切换 flipped=\(wantFlipped)")
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
