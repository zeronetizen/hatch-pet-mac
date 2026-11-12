import AppKit

/// 气泡内容视图：「思想云」轮廓（v0.10 起，用户在三方案示意图里选了 C）——
/// 云团主体（核心椭圆 + 一圈固定图案的凸起圆叠成的并集）+ 下方两个递减圆点引线。
/// AppKit 路径没有并集运算，做法：
/// - 填充：把核心椭圆与每个凸起圆作为同向子路径叠进一条 NSBezierPath，
///   用默认的非零缠绕（non-zero）填充，叠加区域自然成并集，不留内部线；
/// - 描边：不能直接 stroke（会把每个圆的整圈都画出来）。改为先画一份同形、
///   处处向外扩 1.0pt 的垫底（椭圆半轴 +1、每个圆半径 +1，近似等距偏移），
///   垫底露出的 1.0pt 圈即视觉描边；圆点引线同理（先画 r+1 垫底再画本体）。
///   v0.11：垫底由 1.5 降到 1.0，凹口处描边显粗的问题随之减轻（等距偏移在凹口
///   必然略粗，属此法的固有近似，1.0pt 下已不明显）。
/// 云团与圆点的几何（核心椭圆、各圆圆心/半径，均在本视图坐标系内）由
/// BubbleController 按「正常朝向」（云在上、圆点在下）算好后下发；面板被迫贴到
/// 宠物下方时控制器把全部 y 坐标镜像后再下发，本视图不感知朝向。
/// 点击回调（用于立即关闭气泡）。
private final class BubbleView: NSView {
    /// 描边垫底向外扩的距离（pt），即视觉描边粗细。v0.11 由 1.5 收窄到 1.0。
    static let outlinePad: CGFloat = 1.0

    var coreEllipse: NSRect = .zero
    var bumps: [(center: NSPoint, radius: CGFloat)] = []
    var dots: [(center: NSPoint, radius: CGFloat)] = []
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // 轮廓按几何现画，尺寸变了必须重画
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 垫底描边层（同形外扩）→ 本体填充层
        cloudPath(expand: Self.outlinePad).fill(with: NSColor.separatorColor)
        cloudPath(expand: 0).fill(with: NSColor.controlBackgroundColor)
        for dot in dots {
            dotPath(dot, expand: Self.outlinePad).fill(with: NSColor.separatorColor)
        }
        for dot in dots {
            dotPath(dot, expand: 0).fill(with: NSColor.controlBackgroundColor)
        }
    }

    /// 云团并集路径：核心椭圆 + 每个凸起圆各作一条子路径叠入同一路径，
    /// 非零缠绕填充即并集。expand>0 时椭圆半轴与各圆半径同步外扩（垫底描边用）。
    private func cloudPath(expand: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.append(NSBezierPath(ovalIn: coreEllipse.insetBy(dx: -expand, dy: -expand)))
        for bump in bumps {
            let r = bump.radius + expand
            path.append(NSBezierPath(ovalIn: NSRect(x: bump.center.x - r, y: bump.center.y - r,
                                                    width: r * 2, height: r * 2)))
        }
        return path
    }

    private func dotPath(_ dot: (center: NSPoint, radius: CGFloat), expand: CGFloat) -> NSBezierPath {
        let r = dot.radius + expand
        return NSBezierPath(ovalIn: NSRect(x: dot.center.x - r, y: dot.center.y - r,
                                           width: r * 2, height: r * 2))
    }
}

/// NSBezierPath 填充便捷方法（指定颜色填充一次）。
private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

/// 状态消息气泡：贴宠物窗口上方居中的独立小面板（不占宠物窗、不被其边界裁剪），
/// 形态为思想云（v0.10 起：云团轮廓 + 圆点引线，圆点串下端指向宠物头顶）；
/// 文本多行折行（内容最大宽 200、最多 3 行、尾部省略号），按行数 6/8/10 秒自动消失、点击立即消失。
/// 宠物拖动结束/尺寸变化时由 AppDelegate 调 repositionIfVisible 跟随。
final class BubbleController {
    /// 文字安全区最大宽（pt）：云团内圈不规则，文字只放中心安全区，故从旧版 220 收到 200。
    private static let maxContentWidth: CGFloat = 200
    private static let maxLines = 3
    /// 核心椭圆相对文字的留白：半轴 = 文字半宽 + 30 / 文字半高 + 24，
    /// 保证文字矩形（含四角）始终落在核心椭圆内、不压凸起的凹口。
    private static let corePadX: CGFloat = 30
    private static let corePadY: CGFloat = 24
    /// 凸起图案（角度°, 半径系数）：固定数组保证云形稳定、不随机；角度按数学
    /// 方向（90° 为正上方），每 30° 一个、底部三个（240/270/300）正对下方。
    /// v0.11 修匀：旧版半径 19–27 落差过大，且底部凸起圆心都在椭圆周上、
    /// 下沿参差（左下曾出现单个凸起明显下垂像要滴下来）。新版半径改用相对
    /// bumpBaseRadius 的系数（0.95–1.13，方差收窄），底部一排再做下沿对齐
    /// （见 makeLayout），左右两端（0°/180°）系数取中值避免过尖。
    private static let bumpAngles: [CGFloat] = [0, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330]
    private static let bumpBaseRadius: CGFloat = 24
    private static let bumpFactors: [CGFloat] = [1.00, 1.08, 1.13, 1.05, 1.12, 0.97,
                                                 1.08, 1.00, 1.12, 1.05, 1.10, 0.95]
    /// 圆点串占高：云下间隙 6 + 大圆直径 10 + 间隙 5 + 小圆直径 7 + 底部余量 2 = 30。
    private static let dotsZoneHeight: CGFloat = 30

    /// 一次 show 的布局（全部按正常朝向：云在上、圆点在下；坐标为视图坐标系）。
    private struct Layout {
        var panelSize: NSSize
        var coreEllipse: NSRect
        var bumps: [(center: NSPoint, radius: CGFloat)]
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
        PetLog.d("气泡显示 shape=cloud lines=\(lines) duration=\(Int(duration))s size=\(Int(layout.panelSize.width))x\(Int(layout.panelSize.height)) message=\"\(message)\"")
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

    /// 按文字尺寸算云团布局（正常朝向）。云团尺寸由核心椭圆 + 最大凸起决定：
    /// 半宽 = 核心半轴 a + 缩放后最大凸起半径，两侧各留 3pt 给垫底描边与抗锯齿。
    private static func makeLayout(contentW: CGFloat, contentH: CGFloat) -> Layout {
        let a = contentW / 2 + corePadX          // 核心椭圆半轴
        let b = contentH / 2 + corePadY
        // 凸起缩放：以核心尺寸为参照，云越小凸起越收敛（下限 0.6），保证形状比例稳定
        let scale = min(1, max(0.6, min(2 * a, 2 * b * 2.2) / 300))
        let rBase = bumpBaseRadius * scale
        let radii = bumpFactors.map { $0 * rBase }
        let rMax = radii.max() ?? 0
        let cloudW = 2 * (a + rMax) + 6
        let cloudH = 2 * (b + rMax) + 6
        let panelSize = NSSize(width: cloudW, height: cloudH + dotsZoneHeight)
        // 正常朝向：云团占面板上部，圆点串占底部 dotsZoneHeight
        let center = NSPoint(x: cloudW / 2, y: dotsZoneHeight + cloudH / 2)
        let core = NSRect(x: center.x - a, y: center.y - b, width: 2 * a, height: 2 * b)
        var bumps: [(center: NSPoint, radius: CGFloat)] = []
        for (i, deg) in bumpAngles.enumerated() {
            let t = deg * .pi / 180
            var cy = center.y + b * sin(t)
            // 底部一排（sin ≤ -0.8，即 240°/270°/300°）下沿对齐：把圆心 y 改到
            // 「圆心 - 半径 = -(b + rBase)」，三者的底边落在同一条线上，谁也不
            // 单独下垂。对齐量仅由半径差决定（≤ ±0.13·rBase ≈ ±3pt），凸起与
            // 核心椭圆仍大幅重叠、并集不断裂。两侧下角（210°/330°）不参与对齐，
            // 保持云团下角自然上收的弧度。
            if sin(t) <= -0.8 {
                cy = center.y - (b + rBase) + radii[i]
            }
            bumps.append((center: NSPoint(x: center.x + a * cos(t), y: cy),
                          radius: radii[i]))
        }
        // 圆点串：自云团下沿向下，半径 5 → 3.5 递减，略向左（宠物头顶方向）漂移
        let dots: [(center: NSPoint, radius: CGFloat)] = [
            (center: NSPoint(x: center.x - 5, y: dotsZoneHeight - 11), radius: 5),
            (center: NSPoint(x: center.x - 10, y: dotsZoneHeight - 24.5), radius: 3.5),
        ]
        let labelFrame = NSRect(x: center.x - contentW / 2, y: center.y - contentH / 2,
                                width: contentW, height: contentH)
        return Layout(panelSize: panelSize, coreEllipse: core, bumps: bumps,
                      dots: dots, labelFrame: labelFrame)
    }

    /// 把布局下发到视图与标签；flipped 时全部 y 坐标关于面板高度镜像
    /// （云落到面板下部、圆点串在云上方，思想泡上下关系仍成立）。
    private func applyLayout(_ layout: Layout, flipped: Bool,
                             to view: BubbleView, label: NSTextField) {
        let h = layout.panelSize.height
        func flipRect(_ r: NSRect) -> NSRect {
            flipped ? NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height) : r
        }
        func flipPoint(_ p: NSPoint) -> NSPoint {
            flipped ? NSPoint(x: p.x, y: h - p.y) : p
        }
        view.coreEllipse = flipRect(layout.coreEllipse)
        view.bumps = layout.bumps.map { (center: flipPoint($0.center), radius: $0.radius) }
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
