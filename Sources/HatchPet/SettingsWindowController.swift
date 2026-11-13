import AppKit
import UniformTypeIdentifiers

/// 设置窗口：通道（粘贴通道码连接）/ 当前连接状态行 / 轮询间隔 / 代理 + 测试连接 / 形象 / 检查更新 / 关于。
/// v0.31：① 粘码连接落盘后与引导页共用管理钥领取（MgmtService.claimMgmtKey，
/// 老服务端静默跳过）；② 通道连接节之后新增「已绑定 agent」区——仅本机持有
/// 当前通道管理钥时整区显示（无钥连标题都不渲染、高度不占，靠基线帧快照 +
/// 窗高 delta 实现），区内名单（序号/label/绑定时间/解绑）随打开设置与连接
/// 变化刷新，「添加 agent」领一次性绑定码后导出带 pet-bind.json 的绑定包。
/// v0.30：按用户对 v0.29 设置页截图的逐条标注改——① 通道框已配置时直接显示
/// 当前通道名（仍可粘新码换通道；内容未改就点「连接」时回「已是当前通道」）；
/// ② 删 v0.29 新增的通道码展示行；③ 「复制通道码/重新走引导」同行加「导出
/// SKILL」按钮（仅已配置时可见，导出 pet-claim 包且必带 pet-channel.json，
/// 多对一交接）；④ 检查更新节收紧：状态文字改与按钮同行、无内容时不留空行；
/// ⑤ 关于行版本号与「官网」按钮同行居中对齐；⑥ 删底部整行（左下版本小字 +
/// 右下「关闭」按钮，关窗走标题栏按钮；windowWillClose 兜底保留）。
/// v0.29：导出分流与 pet-claim 双模式（见 SkillExport）；其设置页通道码展示行
/// 已于 v0.30 按用户标注删除。
/// v0.27：通道码框设死单行（maximumNumberOfLines=1、cell usesSingleLineMode、
/// 不换行可横滚，与引导页同口径）；v0.26 的字数提示文案全部去掉，粘贴清洗
/// 保留但无声。连接行本就是一行横排（标签+框+连接），不改。
/// v0.26：通道码框挂 delegate 做粘贴清洗（内容变化即去掉全部空白、多行剪贴板
/// 自动拼成一整串；根因与主菜单修复见 main.swift）。
/// v0.25：删各节独立说明文字（代理/形象/更新三处说明行、状态行初始说明），
/// 反馈文案缩短为一句事实；关于节按钮改「官网」。
/// v0.23：删「导出 skill」整节（引导页免费通道与自建面板已有各自导出入口，此处
/// 是重复入口；SkillExport 本体不动）与「说明」整节；新增「关于」节（一行版本 +
/// 官网链接按钮）。
/// v0.21：连接区再简化——删掉只读展示块，只剩一行「通道：[粘贴框] 连接」+ 状态行；
/// 连接凭证的用户面名称统一叫「通道码」（即 hatchpet1: 串，旧称配对串；wire 格式与
/// PairingString 解析不变）。
/// v0.20：配置只认通道码——服务器/通道名/accesskey 三字段手填已砍，换配置只能粘
/// 通道码应用（PairingString 校验后写入与引导页同一套存储：UserDefaults + 本机钥
/// 文件，见 ChannelSettings/KeyFileStore）。
/// 服务器、通道名、间隔存 UserDefaults；accesskey 只存本机钥文件（权限 600，见 KeyFileStore），不用系统钥匙串。
/// v0.15 起全量即时生效（macOS 系统设置风格，无「保存」按钮）：开关/下拉变更即落盘
/// 应用；代理文本框在编辑结束（回车或失焦）时落盘应用。每次应用后经 onApplied 回调让
/// AppDelegate 重启轮询器（按新配置重建会话）；关窗不回滚。
final class SettingsWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// 任一改动即时应用后回调（AppDelegate 据此重启轮询器使新配置生效）
    var onApplied: (() -> Void)?
    /// 某状态的形象被替换/恢复时回调（AppDelegate 据此让正在播该状态的播放器立即重载）
    var onAssetsChanged: ((PetState) -> Void)?
    /// 「重新走引导」点击回调（AppDelegate 据此打开引导窗）
    var onReopenOnboarding: (() -> Void)?

    private var window: NSWindow?
    /// 当前连接状态行（v0.21：一行显示「当前连接：服务器 / 通道 · 状态」或「尚未配置通道」）
    private var connectionStatusLabel: NSTextField!
    /// 最近一次测连接结果（nil = 本次打开设置后未测）：状态行尾巴用，刷新见 refreshConnectionStatus
    private var lastTestOK: Bool?
    private var pairingField: NSTextField!
    private var copyPairingButton: NSButton!
    private var intervalPopup: NSPopUpButton!
    private var proxyCheckbox: NSButton!
    private var proxyTypePopup: NSPopUpButton!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!
    private var statusLabel: NSTextField!
    /// 「形象」小节每状态一行：来源字 + 恢复默认按钮（key 为状态本身）
    private var assetRows: [PetState: (source: NSTextField, reset: NSButton)] = [:]
    private var updateStatusLabel: NSTextField!
    // MARK: 「已绑定 agent」区（v0.31）动态布局基线
    /// 区容器（通道连接节之后插入；显隐与高度由 layoutAgentsSection 管理）
    private var agentsContainer: NSView!
    /// 最近一次成功拉到的名单（拉取失败时静默保留，见 refreshAgentsSection）
    private var lastAgents: [AgentInfo] = []
    /// 通道连接节各视图的建窗基线帧（minY 不低于连接状态行者）：区展开时整体上移 delta
    private var agentsAboveViews: [(view: NSView, frame: NSRect)] = []
    /// 区下方各视图的最高顶边（基线坐标）：容器底边锚在此处，下方视图永不移动
    private var agentsBelowTop: CGFloat = 0
    /// 建窗时窗口 frame 高（基线）：区展开时窗高 = 基线 + delta
    private var agentsBaseFrameH: CGFloat = 0
    /// 当前已施加的区展开量（0 = 整区不占高）
    private var agentsDelta: CGFloat = 0
    /// 回填字段时置真，抑制 programmatic change 误触发即时应用（见 loadIntoFields）
    private var isLoading = false
    /// 最近一次已应用的控件快照（关窗时若与当前控件不一致，自动提交一次防丢失）
    private var appliedSnapshot: String?

    func show() {
        let window = ensureWindow()
        loadIntoFields()
        MgmtService.ensureMgmtKey() // v0.33：打开设置即触发持续领取（已持有则无操作）
        refreshAgentsSection(fetch: true)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        PetLog.d("设置窗口打开")
    }

    // MARK: - 构建窗口（固定布局，手动 frame）

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        // 窗口高度按光标驱动布局的总 decrement 定；超过屏幕可视高时按屏幕收。
        let visibleH = NSScreen.main?.visibleFrame.height ?? 1060
        // v0.30：删通道码展示行（-36）、检查更新状态行并入按钮行（-34）、底部
        // 整行已删不再预留关闭按钮区——总 decrement 596、上下各留 20，窗高
        // 从 746 收到 636
        let W: CGFloat = 540, H: CGFloat = min(636, visibleH - 16)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "MusePet 设置"
        win.isReleasedWhenClosed = false
        win.delegate = self // 关窗前把未提交的文本编辑自动提交一次（见 windowWillClose）
        // v0.33：管理钥在设置打开期间被持续重试领到时，即时刷出 agent 区
        NotificationCenter.default.addObserver(forName: MgmtService.keyReadyNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshAgentsSection(fetch: true)
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        win.contentView = content

        let labelX: CGFloat = 20, labelW: CGFloat = 104
        let fieldX: CGFloat = 132, fieldW: CGFloat = W - fieldX - 20
        var cursor = H - 20 // 从顶部往下排

        func addLabel(_ text: String, top: CGFloat, height: CGFloat = 24) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.alignment = .right
            l.font = .systemFont(ofSize: 13)
            l.frame = NSRect(x: labelX, y: top - height, width: labelW, height: height)
            content.addSubview(l)
            return l
        }

        // 通道（v0.21：连接区只剩一行——粘贴通道码点「连接」换连接；通道码即
        // hatchpet1: 串，PairingString 校验后写入存储并自动测连接）
        _ = addLabel("通道", top: cursor)
        pairingField = NSTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW - 88, height: 24))
        pairingField.placeholderString = "粘贴通道码"
        pairingField.delegate = self // v0.26：粘贴清洗（见 controlTextDidChange）
        // v0.27：设死单行——不换行、不撑高，长串框内横向滚动/裁剪（同引导页）
        pairingField.maximumNumberOfLines = 1
        pairingField.cell?.usesSingleLineMode = true
        pairingField.cell?.wraps = false
        pairingField.cell?.isScrollable = true
        pairingField.lineBreakMode = .byClipping
        content.addSubview(pairingField)
        let pairConnectBtn = NSButton(title: "连接", target: self, action: #selector(connectFromPairing))
        pairConnectBtn.bezelStyle = .rounded
        pairConnectBtn.frame = NSRect(x: fieldX + fieldW - 80, y: cursor - 26, width: 80, height: 28)
        content.addSubview(pairConnectBtn)
        cursor -= 36
        copyPairingButton = NSButton(title: "复制通道码", target: self, action: #selector(copyPairing))
        copyPairingButton.bezelStyle = .rounded
        copyPairingButton.frame = NSRect(x: fieldX, y: cursor - 28, width: 130, height: 28)
        content.addSubview(copyPairingButton)
        let reopenBtn = NSButton(title: "重新走引导", target: self, action: #selector(reopenOnboarding))
        reopenBtn.bezelStyle = .rounded
        reopenBtn.frame = NSRect(x: fieldX + 140, y: cursor - 28, width: 130, height: 28)
        content.addSubview(reopenBtn)
        cursor -= 34
        // 当前连接状态行（v0.21）：一行说清现状，随载入/应用通道码/测连接结果刷新
        connectionStatusLabel = NSTextField(labelWithString: "")
        connectionStatusLabel.font = .systemFont(ofSize: 12)
        connectionStatusLabel.textColor = .secondaryLabelColor
        connectionStatusLabel.lineBreakMode = .byTruncatingMiddle
        connectionStatusLabel.frame = NSRect(x: fieldX, y: cursor - 20, width: fieldW, height: 20)
        content.addSubview(connectionStatusLabel)
        cursor -= 30

        // 轮询间隔
        _ = addLabel("轮询间隔", top: cursor)
        intervalPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: cursor - 26, width: 140, height: 26), pullsDown: false)
        for sec in ChannelSettings.intervalChoices {
            intervalPopup.addItem(withTitle: "\(sec) 秒")
            intervalPopup.itemArray.last?.representedObject = sec
        }
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalChanged)
        content.addSubview(intervalPopup)
        cursor -= 40

        // 代理小节：开关 + 类型/主机/端口（直连 TLS 失败时经本机代理出海）
        _ = addLabel("代理", top: cursor)
        proxyCheckbox = NSButton(checkboxWithTitle: "使用代理连接服务器", target: self, action: #selector(proxyToggled))
        proxyCheckbox.frame = NSRect(x: fieldX, y: cursor - 24, width: 240, height: 24)
        content.addSubview(proxyCheckbox)
        cursor -= 34
        proxyTypePopup = NSPopUpButton(frame: NSRect(x: fieldX, y: cursor - 26, width: 96, height: 26), pullsDown: false)
        proxyTypePopup.addItems(withTitles: ["HTTP", "SOCKS5"])
        proxyTypePopup.target = self
        proxyTypePopup.action = #selector(proxyTypeChanged)
        content.addSubview(proxyTypePopup)
        proxyHostField = NSTextField(frame: NSRect(x: fieldX + 104, y: cursor - 24, width: 176, height: 24))
        proxyHostField.placeholderString = ProxyConfig.defaultHost
        proxyHostField.delegate = self
        content.addSubview(proxyHostField)
        proxyPortField = NSTextField(frame: NSRect(x: fieldX + 288, y: cursor - 24, width: 84, height: 24))
        proxyPortField.placeholderString = "\(ProxyConfig.defaultPort)"
        proxyPortField.delegate = self
        content.addSubview(proxyPortField)
        cursor -= 32

        // 测试连接 + 状态行（状态行初始置空，只显示操作反馈）
        let testBtn = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: fieldX, y: cursor - 28, width: 110, height: 28)
        content.addSubview(testBtn)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.frame = NSRect(x: fieldX + 120, y: cursor - 44, width: fieldW - 120, height: 44)
        content.addSubview(statusLabel)
        cursor -= 56

        // 形象小节（v0.11）：五个状态各一行——来源字 + 选择文件/恢复默认
        let sep2 = NSBox(frame: NSRect(x: 20, y: cursor - 4, width: W - 40, height: 1))
        sep2.boxType = .separator
        content.addSubview(sep2)
        cursor -= 10
        let assetsTitle = NSTextField(labelWithString: "形象（按状态自定义）")
        assetsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        assetsTitle.frame = NSRect(x: 20, y: cursor - 18, width: 260, height: 18)
        content.addSubview(assetsTitle)
        cursor -= 26
        for (idx, state) in PetState.allCases.enumerated() {
            let nameLabel = NSTextField(labelWithString: state.label)
            nameLabel.alignment = .right
            nameLabel.font = .systemFont(ofSize: 12)
            nameLabel.frame = NSRect(x: labelX, y: cursor - 22, width: labelW, height: 18)
            content.addSubview(nameLabel)
            let source = NSTextField(labelWithString: "内置")
            source.font = .systemFont(ofSize: 11)
            source.textColor = .secondaryLabelColor
            source.lineBreakMode = .byTruncatingMiddle
            source.frame = NSRect(x: fieldX, y: cursor - 22, width: 150, height: 18)
            content.addSubview(source)
            let pickBtn = NSButton(title: "选择文件…", target: self, action: #selector(pickAssetFile(_:)))
            pickBtn.bezelStyle = .rounded
            pickBtn.tag = idx
            pickBtn.frame = NSRect(x: 290, y: cursor - 27, width: 104, height: 26)
            content.addSubview(pickBtn)
            let resetBtn = NSButton(title: "恢复默认", target: self, action: #selector(resetAsset(_:)))
            resetBtn.bezelStyle = .rounded
            resetBtn.tag = idx
            resetBtn.frame = NSRect(x: 402, y: cursor - 27, width: 88, height: 26)
            content.addSubview(resetBtn)
            assetRows[state] = (source: source, reset: resetBtn)
            cursor -= 32
        }

        // 检查更新小节：检查更新按钮 + 更新状态行（初始置空，只显示检查反馈；
        // 版本行 v0.23 起移到「关于」节）
        let sep4 = NSBox(frame: NSRect(x: 20, y: cursor - 4, width: W - 40, height: 1))
        sep4.boxType = .separator
        content.addSubview(sep4)
        cursor -= 10
        let updateTitle = NSTextField(labelWithString: "检查更新")
        updateTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        updateTitle.frame = NSRect(x: 20, y: cursor - 18, width: 200, height: 18)
        content.addSubview(updateTitle)
        cursor -= 26
        // v0.30：按钮与状态文字同行——按钮左界 fieldX 与其他节按钮一线，状态
        // 文字在按钮右侧同行同高显示；状态行不再独占一行，无内容时不留空白
        let checkBtn = NSButton(title: "检查更新", target: self, action: #selector(checkUpdates))
        checkBtn.bezelStyle = .rounded
        checkBtn.frame = NSRect(x: fieldX, y: cursor - 27, width: 110, height: 26)
        content.addSubview(checkBtn)
        updateStatusLabel = NSTextField(labelWithString: "")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byWordWrapping
        updateStatusLabel.maximumNumberOfLines = 2
        updateStatusLabel.frame = NSRect(x: fieldX + 120, y: cursor - 27, width: fieldW - 120, height: 26)
        content.addSubview(updateStatusLabel)
        cursor -= 34

        // 关于小节（v0.23）：只放一行版本 + 官网链接按钮，说明文字已全删
        let sep5 = NSBox(frame: NSRect(x: 20, y: cursor - 4, width: W - 40, height: 1))
        sep5.boxType = .separator
        content.addSubview(sep5)
        cursor -= 10
        let aboutTitle = NSTextField(labelWithString: "关于")
        aboutTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        aboutTitle.frame = NSRect(x: 20, y: cursor - 18, width: 200, height: 18)
        content.addSubview(aboutTitle)
        cursor -= 26
        // v0.30：版本文字与「官网」按钮整行对齐——文字框垂直居中对齐按钮
        // （两者中心同在 cursor-14），左界 fieldX、按钮右界 fieldX+fieldW 与他行一致
        let aboutVer = NSTextField(labelWithString: AppVersion.displayString)
        aboutVer.font = .systemFont(ofSize: 12)
        aboutVer.frame = NSRect(x: fieldX, y: cursor - 24, width: 220, height: 20)
        content.addSubview(aboutVer)
        let landingBtn = NSButton(title: "官网", target: self, action: #selector(openLandingPage))
        landingBtn.bezelStyle = .rounded
        landingBtn.frame = NSRect(x: fieldX + fieldW - 120, y: cursor - 27, width: 120, height: 26)
        content.addSubview(landingBtn)
        cursor -= 32

        // v0.30：底部整行已删——左下角版本小字（与关于节版本重复）与右下角
        // 「关闭」按钮一并移除；关窗走标题栏关闭钮，关窗兜底见 windowWillClose。

        // v0.31：「已绑定 agent」区布局基线——以连接状态行 minY 为界，其上
        // 各视图记基线帧（区展开时整体上移），其下最高顶边记为容器锚点；
        // 容器最后加入，不进基线快照。
        let threshold = connectionStatusLabel.frame.minY
        agentsAboveViews = content.subviews.compactMap { v in
            v.frame.minY >= threshold ? (view: v, frame: v.frame) : nil
        }
        agentsBelowTop = content.subviews.filter { $0.frame.minY < threshold }
            .map { $0.frame.maxY }.max() ?? 0
        agentsBaseFrameH = win.frame.height
        agentsContainer = NSView()
        agentsContainer.isHidden = true
        content.addSubview(agentsContainer)

        self.window = win
        return win
    }

    private func loadIntoFields() {
        isLoading = true
        defer { isLoading = false }
        let cfg = ChannelSettings.load()
        lastTestOK = nil
        refreshConnectionStatus()
        if let idx = ChannelSettings.intervalChoices.firstIndex(of: cfg.intervalSec) {
            intervalPopup.selectItem(at: idx)
        }
        proxyCheckbox.state = cfg.proxy.enabled ? .on : .off
        proxyTypePopup.selectItem(at: cfg.proxy.type == "socks" ? 1 : 0)
        proxyHostField.stringValue = cfg.proxy.host
        proxyPortField.stringValue = "\(cfg.proxy.port)"
        updateProxyControls()
        statusLabel.stringValue = ""
        refreshAssetRows()
        appliedSnapshot = snapshotFromFields()
        let keyPresent = !(ChannelSettings.accessKey(for: cfg.channel) ?? "").isEmpty
        PetLog.d("设置窗口已载入 server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s proxy=\(cfg.proxy.summary) keyPresent=\(keyPresent)")
    }

    /// 当前连接状态行刷新（载入、应用通道码、即时应用、测连接后调用）：未配置时
    /// 「尚未配置通道」；已配置时按来源分称（v0.21 命名补充）——服务器是公共中转
    /// 时「当前连接：免费通道（<通道名>）」，否则「当前连接：自建通道（<通道名> ·
    /// <服务器域名>）」；尾巴状态取最近一次测连接结果（测过才带 · 已连接/连接失败）。
    /// v0.30 附带：通道框回显当前通道名（未配置则清空回待粘贴）。
    /// 通道框正在编辑（用户准备粘新码）时不抢其内容。
    private func refreshConnectionStatus() {
        let cfg = ChannelSettings.load()
        let key = ChannelSettings.accessKey(for: cfg.channel) ?? ""
        guard !cfg.channel.isEmpty, !key.isEmpty else {
            connectionStatusLabel.stringValue = "尚未配置通道"
            if pairingField.currentEditor() == nil { pairingField.stringValue = "" }
            PetLog.d("[pairing] 连接状态行：尚未配置通道 channel空=\(cfg.channel.isEmpty) keyPresent=\(!key.isEmpty)")
            return
        }
        // 通道框直接显示当前通道名：免费通道即 free_…、自建即其通道名
        if pairingField.currentEditor() == nil { pairingField.stringValue = cfg.channel }
        var host = cfg.server
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        let suffix = lastTestOK.map { $0 ? " · 已连接" : " · 连接失败" } ?? ""
        if cfg.baseURL == ChannelSettings.defaultServer {
            connectionStatusLabel.stringValue = "当前连接：免费通道（\(cfg.channel)）\(suffix)"
        } else {
            connectionStatusLabel.stringValue = "当前连接：自建通道（\(cfg.channel) · \(host)）\(suffix)"
        }
        PetLog.d("[pairing] 连接状态行：\(connectionStatusLabel.stringValue)")
    }

    // MARK: - 「已绑定 agent」区（v0.31）

    /// 整区显隐的唯一判据：本机持有当前通道的管理钥。无钥整区不出现
    /// （连标题都不渲染、高度不占）。
    private var agentsSectionVisible: Bool {
        MgmtService.hasMgmtKey(channel: ChannelSettings.load().channel)
    }

    /// 区内容高：分隔+标题 30 + 每 agent 一行 32 + 「添加 agent」按钮行 36
    private func agentsViewHeight() -> CGFloat {
        66 + CGFloat(lastAgents.count) * 32
    }

    /// 按当前显隐与名单排区：展开时通道连接节整体上移 delta、窗高同步加
    /// delta，下方各节原地不动，容器填入腾出的空档；收起时逆操作。
    private func layoutAgentsSection() {
        guard let win = window, agentsContainer != nil else { return }
        guard agentsSectionVisible else {
            if agentsDelta != 0 { applyAgentsDelta(0, win: win) }
            agentsContainer.isHidden = true
            PetLog.d("[mgmt] agents 区隐藏：本机未持有当前通道管理钥（整区不渲染）")
            return
        }
        let viewH = agentsViewHeight()
        let delta = viewH + 10
        if abs(delta - agentsDelta) > 0.5 { applyAgentsDelta(delta, win: win) }
        agentsContainer.frame = NSRect(x: 20, y: agentsBelowTop, width: 500, height: viewH)
        agentsContainer.isHidden = false
        rebuildAgentsContainer(viewH: viewH)
        PetLog.d("[mgmt] agents 区显示：名单 \(lastAgents.count) 个，viewH=\(viewH) delta=\(agentsDelta)")
    }

    private func applyAgentsDelta(_ delta: CGFloat, win: NSWindow) {
        for (view, base) in agentsAboveViews {
            var f = base
            f.origin.y = base.origin.y + delta
            view.frame = f
        }
        var frame = win.frame
        frame.size.height = agentsBaseFrameH + delta
        win.setFrame(frame, display: true, animate: false)
        agentsDelta = delta
    }

    /// 重建区内子视图：标题行 + 每 agent 一行（序号 · label · 绑定时间 +
    /// 「解绑」按钮，tag=agent 序号）+ 底部「添加 agent」按钮。
    private func rebuildAgentsContainer(viewH: CGFloat) {
        agentsContainer.subviews.forEach { $0.removeFromSuperview() }
        let sep = NSBox(frame: NSRect(x: 0, y: viewH - 5, width: 500, height: 1))
        sep.boxType = .separator
        agentsContainer.addSubview(sep)
        let title = NSTextField(labelWithString: "已绑定 agent")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 0, y: viewH - 30, width: 260, height: 18)
        agentsContainer.addSubview(title)
        for (i, agent) in lastAgents.enumerated() {
            let rowY = viewH - 38 - CGFloat(i) * 32 - 28
            let label = NSTextField(labelWithString: agent.rowText)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.frame = NSRect(x: 112, y: rowY + 5, width: 290, height: 18)
            agentsContainer.addSubview(label)
            let btn = NSButton(title: "解绑", target: self, action: #selector(unbindAgent(_:)))
            btn.bezelStyle = .rounded
            btn.tag = agent.index
            btn.frame = NSRect(x: 410, y: rowY, width: 90, height: 28)
            agentsContainer.addSubview(btn)
        }
        let addBtn = NSButton(title: "添加 agent", target: self, action: #selector(addAgentTapped))
        addBtn.bezelStyle = .rounded
        addBtn.frame = NSRect(x: 112, y: 4, width: 130, height: 28)
        agentsContainer.addSubview(addBtn)
    }

    /// 打开设置/连接变化时调用：先按显隐排版，再（持有管理钥时）拉名单刷新；
    /// 拉取失败静默保留上次名单（或空名单），不打扰用户。
    private func refreshAgentsSection(fetch: Bool) {
        layoutAgentsSection()
        guard fetch, agentsSectionVisible else { return }
        let cfg = ChannelSettings.load()
        guard let mgmt = MgmtService.mgmtKey(channel: cfg.channel) else { return }
        MgmtService.fetchAgents(server: cfg.baseURL, channel: cfg.channel, mgmtKey: mgmt, proxy: cfg.proxy) { [weak self] agents in
            guard let self else { return }
            if let agents { self.lastAgents = agents }
            self.layoutAgentsSection()
        }
    }

    @objc private func unbindAgent(_ sender: NSButton) {
        let cfg = ChannelSettings.load()
        guard let mgmt = MgmtService.mgmtKey(channel: cfg.channel) else { return }
        let index = sender.tag
        PetLog.d("[mgmt] 设置页点「解绑」channel=\(cfg.channel) index=\(index)")
        MgmtService.removeAgent(server: cfg.baseURL, channel: cfg.channel, mgmtKey: mgmt, index: index, proxy: cfg.proxy) { [weak self] ok in
            guard let self, ok else { return }
            self.refreshAgentsSection(fetch: true)
        }
    }

    /// 「添加 agent」：领一次性绑定码 → 导出 pet-claim 包，绑定码经
    /// pet-bind.json 写进包根（字段 server_url/channel/binding_code/
    /// exported_at/note）。绑定码与管理钥只进包/钥文件，不进日志与 UI 文案；
    /// 导出反馈沿用 SkillExport 的导出完成提示口径。绑定包不附
    /// pet-channel.json（见 SkillExport 的 includeChannelJSON 说明）。
    @objc private func addAgentTapped() {
        let cfg = ChannelSettings.load()
        guard let mgmt = MgmtService.mgmtKey(channel: cfg.channel) else {
            PetLog.d("[mgmt] 设置页点「添加 agent」拦截：本机未持有当前通道管理钥 channel=\(cfg.channel)")
            return
        }
        PetLog.d("[mgmt] 设置页点「添加 agent」channel=\(cfg.channel)，先领 bind-codes 绑定码（码不记日志）")
        MgmtService.createBindingCode(server: cfg.baseURL, channel: cfg.channel, mgmtKey: mgmt, proxy: cfg.proxy) { [weak self] result in
            guard let self else { return }
            guard let result else {
                self.statusLabel.stringValue = "添加 agent 失败：领绑定码未成，请稍后重试。"
                PetLog.d("[mgmt] 添加 agent 中止：bind-codes 未领到绑定码 channel=\(cfg.channel)")
                return
            }
            let obj: [String: Any] = [
                "server_url": cfg.baseURL,
                "channel": cfg.channel,
                "binding_code": result.code,
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "note": "此包用于追加绑定一个 agent：新 agent 装此 skill 后用包内绑定码完成绑定；绑定码一次性、短时有效，用过即废，只随此包传递、不要外传。",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]),
                  let text = String(data: data, encoding: .utf8) else {
                self.statusLabel.stringValue = "添加 agent 失败：绑定文件组装出错。"
                PetLog.d("[mgmt] 添加 agent 中止：pet-bind.json 组装失败 channel=\(cfg.channel)")
                return
            }
            PetLog.d("[mgmt] pet-bind.json 已组装 channel=\(cfg.channel) codeLen=\(result.code.count)（码只进包、不记日志），开始导出绑定包")
            self.statusLabel.stringValue = SkillExport.export(package: "pet-claim",
                                                              suggestedName: "pet-claim-skill.zip",
                                                              extraFiles: ["pet-bind.json": text + "\n"],
                                                              includeChannelJSON: false)
        }
    }

    // MARK: - 代理小节

    @objc private func proxyToggled() {
        updateProxyControls()
        guard !isLoading else { return }
        let proxy = proxyFromFields()
        applyFromFields(feedback: proxy.enabled ? "已生效：代理已开启（\(proxy.summary)）" : "已生效：代理已关闭")
    }

    @objc private func proxyTypeChanged() {
        guard !isLoading else { return }
        let proxy = proxyFromFields()
        applyFromFields(feedback: "已生效：代理类型 \(proxy.type == "socks" ? "SOCKS5" : "HTTP")（当前\(proxy.summary)）")
    }

    @objc private func intervalChanged() {
        guard !isLoading else { return }
        let sec = (intervalPopup.selectedItem?.representedObject as? Int) ?? ChannelSettings.defaultInterval
        applyFromFields(feedback: "已生效：轮询间隔 \(sec) 秒")
    }

    // MARK: - 即时生效（v0.15）

    /// 文本框编辑结束（回车或失焦）即提交：落盘 + 应用 + 状态行反馈。
    /// v0.20 起只剩代理主机/端口两个文本框走这条路径（连接三件套已不可手填，
    /// 换连接走通道码，见 connectFromPairing）。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isLoading, let field = obj.object as? NSTextField else { return }
        // 通道码框（v0.26 起挂了 delegate）不走即时应用：换连接只认点「连接」。
        if field === pairingField { return }
        switch field {
        case proxyHostField, proxyPortField:
            applyFromFields(feedback: "已生效：代理 \(proxyFromFields().summary)")
        default:
            applyFromFields(feedback: "已生效")
        }
    }

    /// 从当前控件组装配置：连接三件套（服务器/通道）已不可编辑，以已保存值为准；
    /// 间隔/代理以界面当前值为准。写回的仍是同一套 UserDefaults 键，数据不动。
    private func configFromFields() -> ChannelConfig {
        let stored = ChannelSettings.load()
        let interval = (intervalPopup.selectedItem?.representedObject as? Int) ?? ChannelSettings.defaultInterval
        return ChannelConfig(server: stored.server,
                             channel: stored.channel,
                             intervalSec: interval,
                             proxy: proxyFromFields())
    }

    /// 控件快照（只用于判「关窗前是否有未提交改动」：间隔 + 代理四项）
    private func snapshotFromFields() -> String {
        let proxy = proxyFromFields()
        let interval = (intervalPopup.selectedItem?.representedObject as? Int) ?? ChannelSettings.defaultInterval
        return ["\(interval)", "\(proxy.enabled)", proxy.type, proxy.host, "\(proxy.port)"].joined(separator: "|")
    }

    /// 即时应用主入口：落盘配置、刷新从属 UI、回调重启轮询器、状态行反馈。
    private func applyFromFields(feedback: String) {
        let cfg = configFromFields()
        ChannelSettings.save(cfg)
        refreshConnectionStatus()
        appliedSnapshot = snapshotFromFields()
        onApplied?()
        statusLabel.stringValue = feedback
        PetLog.d("设置即时生效：\(feedback)（server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s proxy=\(cfg.proxy.summary)）")
    }

    /// 关窗兜底：若有文本改动没经「编辑结束」提交（例如改完直接点窗口关闭钮），
    /// 先自动提交一次，兑现「关窗不回滚」；无改动则直接放行不重复应用。
    func windowWillClose(_ notification: Notification) {
        guard !isLoading, appliedSnapshot != nil, snapshotFromFields() != appliedSnapshot else { return }
        PetLog.d("关窗前检测到未提交的字段改动，自动即时应用一次")
        applyFromFields(feedback: "已生效：关窗前已自动保存改动")
    }

    /// 未勾选时类型/主机/端口置灰
    private func updateProxyControls() {
        let on = proxyCheckbox.state == .on
        proxyTypePopup.isEnabled = on
        proxyHostField.isEnabled = on
        proxyPortField.isEnabled = on
    }

    /// 从当前字段读代理配置（即时应用与测试连接共用，都以界面当前值为准）
    private func proxyFromFields() -> ProxyConfig {
        let host = proxyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(proxyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { (1...65535).contains($0) ? $0 : nil } ?? ProxyConfig.defaultPort
        return ProxyConfig(enabled: proxyCheckbox.state == .on,
                           type: proxyTypePopup.indexOfSelectedItem == 1 ? "socks" : "http",
                           host: host.isEmpty ? ProxyConfig.defaultHost : host,
                           port: port)
    }

    // MARK: - 形象小节（按状态自定义）

    /// 刷新每个状态行的来源字与「恢复默认」可用性：有自定义且文件在 → 显示源文件
    /// 名、恢复可用；映射在但文件丢了 → 提示已回退内置；无自定义 → 「内置」。
    private func refreshAssetRows() {
        for (state, row) in assetRows {
            row.source.textColor = .secondaryLabelColor
            if CustomAssets.customFileName(for: state) != nil {
                if CustomAssets.customURL(for: state) != nil {
                    let shown = CustomAssets.customSourceName(for: state)
                        ?? CustomAssets.customFileName(for: state) ?? ""
                    row.source.stringValue = "自定义：\(shown)"
                    row.reset.isEnabled = true
                } else {
                    row.source.stringValue = "自定义文件已丢失，已回退内置"
                    row.reset.isEnabled = true
                }
            } else {
                row.source.stringValue = "内置"
                row.reset.isEnabled = false
            }
        }
    }

    @objc private func pickAssetFile(_ sender: NSButton) {
        let state = PetState.allCases[sender.tag]
        let panel = NSOpenPanel()
        panel.title = "为「\(state.label)」选择形象视频"
        panel.allowedContentTypes = [UTType.movie, UTType.video]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            PetLog.d("形象选择取消 state=\(state.rawValue)")
            return
        }
        PetLog.d("形象选择 state=\(state.rawValue) 源文件=\(url.lastPathComponent)")
        if let err = CustomAssets.setCustom(state: state, sourceURL: url) {
            // 回滚语义在 CustomAssets 内（失败不动旧设置）；行尾状态字 + 状态行双提示
            if let row = assetRows[state] {
                row.source.stringValue = "替换失败（已保留原形象）"
                row.source.textColor = .systemRed
            }
            statusLabel.stringValue = "「\(state.label)」形象替换失败：\(err)"
            return
        }
        refreshAssetRows()
        statusLabel.stringValue = "「\(state.label)」形象已替换为：\(url.lastPathComponent)（立即生效）"
        onAssetsChanged?(state)
    }

    @objc private func resetAsset(_ sender: NSButton) {
        let state = PetState.allCases[sender.tag]
        CustomAssets.clearCustom(state: state)
        refreshAssetRows()
        statusLabel.stringValue = "「\(state.label)」形象已恢复为内置动画（立即生效）"
        onAssetsChanged?(state)
    }

    // MARK: - 检查更新 / 关于

    @objc private func checkUpdates() {
        updateStatusLabel.stringValue = "检查中…"
        UpdateChecker.checkManually { [weak self] text in
            self?.updateStatusLabel.stringValue = text
        }
    }

    // MARK: - Actions

    @objc private func testConnection() {
        // 测的是当前已保存并生效的连接；换连接先粘通道码点「连接」应用（v0.21）。
        let cfg = ChannelSettings.load()
        let base = cfg.baseURL
        let channel = cfg.channel
        let key = ChannelSettings.accessKey(for: channel) ?? ""
        guard !channel.isEmpty, !key.isEmpty else {
            statusLabel.stringValue = "测试失败：尚未配置通道（先粘贴通道码点「连接」）。"
            PetLog.d("测试连接未执行：未配置通道 channel空=\(channel.isEmpty) key空=\(key.isEmpty)")
            return
        }
        guard let url = URL(string: "\(base)/c/\(channel)") else {
            statusLabel.stringValue = "测试失败：服务器地址格式不对。"
            return
        }
        statusLabel.stringValue = "测试中…"
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let proxy = proxyFromFields()
        PetLog.d("测试连接 GET \(base)/c/\(channel) proxy=\(proxy.summary)")
        let session = RelaySession.makeSession(proxy: proxy)
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.lastTestOK = false
                    self.refreshConnectionStatus()
                    self.statusLabel.stringValue = "连接失败：\(error.localizedDescription)"
                    PetLog.d("测试连接网络错误：\(error.localizedDescription)")
                    return
                }
                let http = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard http == 200, let data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    var msg = ""
                    if let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       let m = o["message"] as? String { msg = "：\(m)" }
                    self.lastTestOK = false
                    self.refreshConnectionStatus()
                    self.statusLabel.stringValue = "连接失败：HTTP \(http)\(msg)（核对通道码后重试）"
                    PetLog.d("测试连接失败 HTTP \(http)\(msg)")
                    return
                }
                let seq = (obj["seq"] as? NSNumber)?.intValue ?? 0
                var stateText = "（通道暂无数据）"
                var timeText = ""
                if let payload = (obj["payload"] ?? obj["data"]) as? [String: Any] {
                    if let s = payload["state"] as? String { stateText = "状态 \(s)" }
                    if let ts = (payload["ts"] as? NSNumber)?.doubleValue {
                        timeText = "，数据时间 \(Self.timeString(ms: ts))"
                    }
                }
                self.lastTestOK = true
                self.refreshConnectionStatus()
                self.statusLabel.stringValue = "连接成功：seq=\(seq)，\(stateText)\(timeText)"
                PetLog.d("测试连接成功 seq=\(seq) \(stateText)")
            }
        }.resume()
    }

    // MARK: - 通道码框粘贴清洗（v0.26）

    /// 通道框开始编辑时若内容正是当前通道名（v0.30 的回显值），全选——用户
    /// 多半是来粘新码的，全选后粘贴即整串替换，不会和通道名拼在一起解析失败。
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === pairingField else { return }
        let cur = ChannelSettings.load()
        guard !cur.channel.isEmpty, field.stringValue == cur.channel,
              let editor = field.currentEditor() else { return }
        editor.selectAll(nil)
        PetLog.d("[pairing] 通道框开始编辑且内容为当前通道名，已全选待粘贴替换 channel=\(cur.channel)")
    }

    /// 内容变化即清洗：去掉全部空白（换行、回车、空格）——剪贴板里的串被聊天
    /// 客户端折成多行时，粘进来立刻拼成一整串单行，不再被单行字段编辑器在
    /// 首个换行处截断。清洗确实改写了内容时把 caret 拉到串尾并滚动到可见。
    /// 清洗无声：不给任何字数/已输入类反馈文案（v0.27 用户定版）。只对通道
    /// 码框生效，代理字段不走这里。
    func controlTextDidChange(_ obj: Notification) {
        guard !isLoading, let field = obj.object as? NSTextField, field === pairingField else { return }
        let raw = field.stringValue
        let cleaned = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        if cleaned != raw {
            field.stringValue = cleaned
            moveCaretToEnd(field)
            PetLog.d("[pairing] 通道码输入清洗：去掉空白 \(raw.count - cleaned.count) 字、拼成一整串 len=\(cleaned.count)（串本体不记日志）")
        }
    }

    /// 把字段编辑器的 caret 移到串尾并滚动到可见（清洗改写后用；未经清洗的
    /// 正常粘贴 caret 本就落在插入末尾、编辑器会自动滚动，无需干预）。
    private func moveCaretToEnd(_ field: NSTextField) {
        guard let editor = field.currentEditor() else { return }
        let len = (field.stringValue as NSString).length
        editor.selectedRange = NSRange(location: len, length: 0)
        if len > 0 { editor.scrollRangeToVisible(NSRange(location: len - 1, length: 1)) }
    }

    // MARK: - 通道码（v0.18 引入 hatchpet1: 串；v0.21 起用户面统一称「通道码」，唯一的连接配置入口）

    @objc private func reopenOnboarding() {
        PetLog.d("[pairing] 设置页点「重新走引导」")
        onReopenOnboarding?()
    }

    @objc private func openLandingPage() {
        PetLog.d("[about] 打开官网 https://pet.8529527.xyz/")
        NSWorkspace.shared.open(URL(string: "https://pet.8529527.xyz/")!)
    }

    /// 应用通道码：PairingString 按 PROTOCOL 4 步解码校验 → 写入既有存储（服务器/
    /// 通道进 UserDefaults、钥进本机钥文件，与引导页同一套键）→ 即时生效 → 自动测
    /// 连接。校验失败只提示、不动现有配置；成功后输入框回显新通道名（整串码含
    /// 钥、不留在框里）。v0.30：框里是未改动的当前通道名时点「连接」，不报
    /// 「通道码不对」，回「已是当前通道」。
    @objc private func connectFromPairing() {
        let raw = pairingField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cur = ChannelSettings.load()
        if !cur.channel.isEmpty, raw == cur.channel,
           !(ChannelSettings.accessKey(for: cur.channel) ?? "").isEmpty {
            statusLabel.stringValue = "已是当前通道（\(cur.channel)），无需重新连接。"
            PetLog.d("[pairing] 点「连接」但框内容未改（当前通道名 channel=\(cur.channel)），提示已是当前通道")
            return
        }
        guard let parsed = PairingString.parse(pairingField.stringValue) else {
            statusLabel.stringValue = "通道码不对（应以 hatchpet1: 开头）。"
            return
        }
        let cfg = ChannelConfig(server: parsed.server, channel: parsed.channel,
                                intervalSec: cur.intervalSec, proxy: cur.proxy)
        ChannelSettings.save(cfg)
        KeyFileStore.save(key: parsed.key, channel: parsed.channel)
        // v0.31 管理钥领取：与引导页共用同一领取点（落盘之后），异步静默；
        // 领取完成回调刷新「已绑定 agent」区（新通道名单作废重拉）
        lastAgents = []
        MgmtService.claimMgmtKey(server: parsed.server, channel: parsed.channel, readKey: parsed.key, proxy: cur.proxy) { [weak self] in
            self?.refreshAgentsSection(fetch: true)
        }
        window?.makeFirstResponder(nil) // 先收编辑态，下面的回显与状态刷新才稳定
        pairingField.stringValue = parsed.channel // 回显新通道名，与刷新口径一致
        lastTestOK = nil
        refreshConnectionStatus()
        appliedSnapshot = snapshotFromFields()
        onApplied?()
        PetLog.d("[pairing] 通道码已应用 server=\(parsed.server) channel=\(parsed.channel)（钥已存本机钥文件、输入框回显通道名），自动测连接")
        statusLabel.stringValue = "通道码已应用并生效，正在测连接…"
        testConnection()
    }

    /// 把当前配置组装成通道码复制到剪贴板。
    @objc private func copyPairing() {
        let channel = currentChannelName()
        guard !channel.isEmpty, let key = ChannelSettings.accessKey(for: channel), !key.isEmpty else {
            statusLabel.stringValue = "复制通道码失败：当前还没有保存在本机的连接（先粘贴通道码点「连接」）。"
            PetLog.d("[pairing] 复制通道码失败 channel=\(channel)：本机无钥")
            return
        }
        let str = PairingString.encode(server: currentServerBase(), channel: channel, key: key)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        statusLabel.stringValue = "通道码已复制。"
        PetLog.d("[pairing] 通道码已复制 channel=\(channel)（钥不记日志）")
    }

    // MARK: - 当前连接取值（复制通道码用）

    /// 当前通道名与服务器基地址：以已保存并生效的配置为准。
    private func currentChannelName() -> String {
        ChannelSettings.load().channel
    }

    private func currentServerBase() -> String {
        ChannelSettings.load().baseURL
    }

    private static func timeString(ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
