import AppKit

/// 气泡内容视图：「思想云」轮廓（v0.10 起，用户在三方案示意图里选了 C）+ 下方
/// 两个递减圆点引线。云形画法在 v0.12 换代（wave=v3）：
/// - v0.10/v0.11：核心椭圆 + 12 个离散圆凸起的并集——真机小尺寸下每个凸起都
///   是一颗独立疙瘩，用户原话「全身起肿物」，且并集不能直接描边、只能垫底近似。
/// - v0.12：一条闭合平滑样条（Catmull-Rom→贝塞尔）一次成形——在核心椭圆上取
///   12 个控制点，半径只做低频调制（sin(2θ)/sin(3θ)，总振幅 ≤6%），整朵云只有
///   2–3 处大而缓的起伏；单路径可直接 stroke 描边（0.75pt），不再需要垫底法。
/// - v0.16（wave=v4）：真机反馈 v3「起伏太弱、看着就是个椭圆」。复盘数学：
///   宽扁核心（长宽比约 2.3）上半径调制在冠部被 sinθ 压平，多大振幅都变不出
///   顶部起伏（且相位凑巧时会在左右尖端冲出尖角）。改法：① 核心纵向留白
///   28→46，长宽比收到约 1.7；② 半径调制换 sin(3θ) 主导（尖端处各正弦项
///   不叠冲高）；③ 上沿再叠一层 cos² 窗瓣的垂直位移（左右两瓣 + 中央矮瓣），
///   顶部呈「两瓣一鞍」。公式与离线渲染预览逐项对齐后才合入（预览图存
///   cloud-v0.16-preview.png，三档文字尺寸均验过：起伏可辨、处处光滑、
///   无单瓣下垂、文字安全区在云内）。
/// - v0.17（wave=v5）：用户仍评 v4 抽象（「像颗豆」），拍板换回并集路线，
///   但凸起要少而大：核心椭圆 + 沿顶部一排 5 个大圆，轮廓取并集的径向
///   包络（自云心发 720 条射线、各形状出口取最大），再做一圈小窗平滑
///   抹掉并集交点的小尖，72 点样条成形。并集天然 ≥ 核心椭圆，文字安全
///   区不变；底部仍是核心椭圆并轻压平（×0.88）。常量与离线渲染
///   （cloud-v5-preview.png，用户已认可的示意轮廓）对齐后合入。
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
    /// 文字安全区最大宽（pt）：v0.17 为 200；v0.18 思想云整体 ×0.85 缩小，
    /// 安全区同步缩到 170（其余几何常量同比例，见 corePadX/corePadY/dots）。
    private static let maxContentWidth: CGFloat = 170
    private static let maxLines = 3
    /// 核心椭圆相对文字的留白：半轴 = 文字半宽 + 34 / 文字半高 + 46。
    /// 纵向留白 v0.16 由 28 提到 46（缘由见文件头 wave=v4 注）：云团长宽比
    /// 收到约 1.7，上沿瓣形起伏才有纵向空间被读成「云」；瓣与鞍都在核心
    /// 椭圆轮廓之外或之上，文字四角始终在云内。
    private static let corePadX: CGFloat = 28.9   // v0.17 的 34 × 0.85
    private static let corePadY: CGFloat = 39.1   // v0.17 的 46 × 0.85
    /// 圆点串占高：v0.17 为 30，v0.18 ×0.85 = 25.5。
    private static let dotsZoneHeight: CGFloat = 25.5

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
        PetLog.d("气泡显示 shape=cloud wave=v5 scale=0.85 lines=\(lines) duration=\(Int(duration))s size=\(Int(layout.panelSize.width))x\(Int(layout.panelSize.height)) message=\"\(message)\"")
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

    /// 云轮廓点（原点为云中心），wave=v5（v0.17）：核心椭圆 + 5 个大圆的
    /// 并集径向包络。圆的排布（x、y、r 均以 b 为单位，沿顶部一排、中间最高）：
    /// (-1.30, 0.38, 0.84)、(-0.55, 0.38, 1.03)、(0.30, 0.38, 1.13)、
    /// (1.10, 0.38, 0.92)、(1.70, 0.32, 0.63)。自原点 (0, 0.05b) 发 720 条
    /// 射线，每条取与全部形状交点出口的最大值即并集外轮廓；半径序列做
    /// 9 点圆环滑动平均抹掉交点小尖；每 10 步取一点共 72 点交给闭合样条；
    /// 原点以下纵坐标 ×0.88 把底部压平。包络恒 ≥ 核心椭圆（并集定义），
    /// 文字安全区与旧版一致。常量与离线渲染逐项对齐，勿凭手感改。
    private static func cloudOutlinePoints(a: CGFloat, b: CGFloat) -> [NSPoint] {
        let bumps: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
            (-1.30, 0.38, 0.84), (-0.55, 0.38, 1.03), (0.30, 0.38, 1.13),
            (1.10, 0.38, 0.92), (1.70, 0.32, 0.63),
        ]
        let ox: CGFloat = 0, oy: CGFloat = 0.05 * b
        let steps = 720
        var radii: [CGFloat] = []
        radii.reserveCapacity(steps)
        for i in 0..<steps {
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let dx = cos(t), dy = sin(t)
            var best: CGFloat = 0
            // 核心椭圆（圆心在云中心、半轴 a/b）的射线出口
            do {
                let ex = ox, ey = oy
                let A = (dx / a) * (dx / a) + (dy / b) * (dy / b)
                let B = 2 * (ex * dx / (a * a) + ey * dy / (b * b))
                let C = (ex / a) * (ex / a) + (ey / b) * (ey / b) - 1
                let disc = B * B - 4 * A * C
                if disc >= 0 {
                    let sq = sqrt(disc)
                    best = max(best, (-B + sq) / (2 * A), (-B - sq) / (2 * A))
                }
            }
            // 5 个大圆的射线出口
            for bump in bumps {
                let cx = bump.x * b, cy = bump.y * b, r = bump.r * b
                let ex = ox - cx, ey = oy - cy
                let A = dx * dx + dy * dy
                let B = 2 * (ex * dx + ey * dy)
                let C = ex * ex + ey * ey - r * r
                let disc = B * B - 4 * A * C
                if disc < 0 { continue }
                let sq = sqrt(disc)
                best = max(best, (-B + sq) / (2 * A), (-B - sq) / (2 * A))
            }
            radii.append(best)
        }
        // 9 点圆环滑动平均：抹掉并集交点的小尖，保留大凸起的起伏
        let half = 4
        var smooth: [CGFloat] = []
        smooth.reserveCapacity(steps)
        for i in 0..<steps {
            var sum: CGFloat = 0
            for k in -half...half { sum += radii[(i + k + steps) % steps] }
            smooth.append(sum / CGFloat(2 * half + 1))
        }
        var pts: [NSPoint] = []
        for i in stride(from: 0, to: steps, by: 10) {
            let t = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
            let x = ox + smooth[i] * cos(t)
            var y = oy + smooth[i] * sin(t)
            if y < oy { y = oy + (y - oy) * 0.88 }   // 底部压平
            pts.append(NSPoint(x: x, y: y))
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
        let path = closedSplinePath(through: cloudOutlinePoints(a: a, b: b))
        let bounds = path.bounds
        let margin: CGFloat = 6.8   // v0.17 的 8 × 0.85
        let cloudW = bounds.width + margin
        let cloudH = bounds.height + margin
        let panelSize = NSSize(width: cloudW, height: cloudH + dotsZoneHeight)
        // 把云形从「原点在云中心」的坐标系平移到视图坐标系
        let dx = -bounds.minX + margin / 2
        let dy = dotsZoneHeight - bounds.minY + margin / 2
        path.transform(using: AffineTransform(translationByX: dx, byY: dy))
        let center = NSPoint(x: bounds.midX + dx, y: bounds.midY + dy)
        // 圆点串：自云团下沿向下，半径 5 → 3.5 递减，略向左（宠物头顶方向）漂移
        // 圆点位置与半径均为 v0.17 数值 ×0.85（5→4.25、3.5→2.975 等）
        let dots: [(center: NSPoint, radius: CGFloat)] = [
            (center: NSPoint(x: center.x - 4.25, y: dotsZoneHeight - 9.35), radius: 4.25),
            (center: NSPoint(x: center.x - 8.5, y: dotsZoneHeight - 20.825), radius: 2.975),
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
            let flip = AffineTransform(m11: 1, m12: 0, m21: 0, m22: -1, tX: 0, tY: h)
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
        label.font = .systemFont(ofSize: 11)   // v0.18 随云整体 ×0.85（原 13）
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
