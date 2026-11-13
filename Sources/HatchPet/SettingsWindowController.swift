import AppKit
import UniformTypeIdentifiers

/// 设置窗口：通道（粘贴通道码连接）/ 当前连接状态行 / 轮询间隔 / 代理 + 测试连接 / 形象 / 检查更新 / 关于。
/// v0.29：状态行下方加一行当前通道码展示（只读单行框 + 「复制」按钮，由已存
/// 配置当场拼整串；未配置时整行隐藏），供主人取用分发（多对一）。
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
    /// 当前通道码展示行（v0.29）：标签 + 只读单行框 + 复制按钮；未配置时三件全隐藏
    private var currentCodeLabel: NSTextField!
    private var currentCodeField: NSTextField!
    private var copyCodeButton: NSButton!
    private var intervalPopup: NSPopUpButton!
    private var proxyCheckbox: NSButton!
    private var proxyTypePopup: NSPopUpButton!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!
    private var statusLabel: NSTextField!
    /// 「形象」小节每状态一行：来源字 + 恢复默认按钮（key 为状态本身）
    private var assetRows: [PetState: (source: NSTextField, reset: NSButton)] = [:]
    private var updateStatusLabel: NSTextField!
    /// 回填字段时置真，抑制 programmatic change 误触发即时应用（见 loadIntoFields）
    private var isLoading = false
    /// 最近一次已应用的控件快照（关窗时若与当前控件不一致，自动提交一次防丢失）
    private var appliedSnapshot: String?

    func show() {
        let window = ensureWindow()
        loadIntoFields()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        PetLog.d("设置窗口打开")
    }

    // MARK: - 构建窗口（固定布局，手动 frame）

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        // 窗口高度按光标驱动布局的总 decrement 定：内容排满后底部留约 60 给
        // 关闭按钮区；超过屏幕可视高时按屏幕收。
        let visibleH = NSScreen.main?.visibleFrame.height ?? 1060
        // v0.29：加通道码展示行（-36），窗高从 710 涨到 746（总 decrement 666，
        // 内容底边仍停在 60）；v0.25 时曾删代理/形象说明行各 -36
        let W: CGFloat = 540, H: CGFloat = min(746, visibleH - 16)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "MusePet 设置"
        win.isReleasedWhenClosed = false
        win.delegate = self // 关窗前把未提交的文本编辑自动提交一次（见 windowWillClose）
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

        // 当前通道码展示行（v0.29）：已配置时把已存 server+channel+钥当场拼成
        // 整串、只读单行展示，供主人取用分发（多对一）；未配置时整行隐藏
        // （布局位置恒定预留，显隐在 refreshConnectionStatus 里切换）。
        currentCodeLabel = addLabel("通道码", top: cursor)
        currentCodeField = NSTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW - 88, height: 24))
        currentCodeField.isEditable = false
        currentCodeField.isSelectable = true
        currentCodeField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        // 单行属性同其他码框：不换行、不撑高，长串框内横向滚动/裁剪
        currentCodeField.maximumNumberOfLines = 1
        currentCodeField.cell?.usesSingleLineMode = true
        currentCodeField.cell?.wraps = false
        currentCodeField.cell?.isScrollable = true
        currentCodeField.lineBreakMode = .byClipping
        content.addSubview(currentCodeField)
        copyCodeButton = NSButton(title: "复制", target: self, action: #selector(copyPairing))
        copyCodeButton.bezelStyle = .rounded
        copyCodeButton.frame = NSRect(x: fieldX + fieldW - 80, y: cursor - 26, width: 80, height: 28)
        content.addSubview(copyCodeButton)
        cursor -= 36

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
        let checkBtn = NSButton(title: "检查更新", target: self, action: #selector(checkUpdates))
        checkBtn.bezelStyle = .rounded
        checkBtn.frame = NSRect(x: fieldX, y: cursor - 27, width: 110, height: 26)
        content.addSubview(checkBtn)
        cursor -= 32
        updateStatusLabel = NSTextField(labelWithString: "")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byWordWrapping
        updateStatusLabel.maximumNumberOfLines = 2
        updateStatusLabel.frame = NSRect(x: fieldX, y: cursor - 26, width: fieldW, height: 26)
        content.addSubview(updateStatusLabel)
        cursor -= 36

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
        let aboutVer = NSTextField(labelWithString: AppVersion.displayString)
        aboutVer.font = .systemFont(ofSize: 12)
        aboutVer.frame = NSRect(x: fieldX, y: cursor - 22, width: 220, height: 20)
        content.addSubview(aboutVer)
        let landingBtn = NSButton(title: "官网", target: self, action: #selector(openLandingPage))
        landingBtn.bezelStyle = .rounded
        landingBtn.frame = NSRect(x: fieldX + fieldW - 120, y: cursor - 27, width: 120, height: 26)
        content.addSubview(landingBtn)
        cursor -= 32

        // 底部按钮（v0.15 即时生效后只剩「关闭」：关窗不回滚，已生效的改动保留；
        // 不给回车等价键——回车留给文本框提交编辑）
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        closeBtn.bezelStyle = .rounded
        closeBtn.frame = NSRect(x: W - 120, y: 16, width: 100, height: 32)
        content.addSubview(closeBtn)

        // 底部左下角版本小字（运行时从 Info.plist 读，打包版本变了自动跟上）
        let versionLabel = NSTextField(labelWithString: AppVersion.displayString)
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.frame = NSRect(x: 20, y: 24, width: 240, height: 16)
        content.addSubview(versionLabel)
        PetLog.d("设置窗口版本行：\(AppVersion.displayString)")

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
    /// 同时刷新 v0.29 的通道码展示行显隐与内容（未配置隐藏、已配置拼整串）。
    private func refreshConnectionStatus() {
        let cfg = ChannelSettings.load()
        let key = ChannelSettings.accessKey(for: cfg.channel) ?? ""
        guard !cfg.channel.isEmpty, !key.isEmpty else {
            connectionStatusLabel.stringValue = "尚未配置通道"
            // v0.29：未配置时通道码展示行整行隐藏、内容清空（不留钥残串）
            currentCodeLabel.isHidden = true
            currentCodeField.isHidden = true
            copyCodeButton.isHidden = true
            currentCodeField.stringValue = ""
            PetLog.d("[pairing] 连接状态行：尚未配置通道 channel空=\(cfg.channel.isEmpty) keyPresent=\(!key.isEmpty)")
            return
        }
        // v0.29：已配置时当场拼出当前通道码整串展示（复制走既有 copyPairing）
        currentCodeLabel.isHidden = false
        currentCodeField.isHidden = false
        copyCodeButton.isHidden = false
        currentCodeField.stringValue = PairingString.encode(server: cfg.baseURL, channel: cfg.channel, key: key)
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

    @objc private func closeWindow() {
        PetLog.d("设置窗口关闭（即时生效，无未保存改动）")
        window?.close()
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
    /// 连接。校验失败只提示、不动现有配置；成功后清空输入框（码含钥，不留明文）。
    @objc private func connectFromPairing() {
        guard let parsed = PairingString.parse(pairingField.stringValue) else {
            statusLabel.stringValue = "通道码不对（应以 hatchpet1: 开头）。"
            return
        }
        let cur = ChannelSettings.load()
        let cfg = ChannelConfig(server: parsed.server, channel: parsed.channel,
                                intervalSec: cur.intervalSec, proxy: cur.proxy)
        ChannelSettings.save(cfg)
        KeyFileStore.save(key: parsed.key, channel: parsed.channel)
        pairingField.stringValue = ""
        lastTestOK = nil
        refreshConnectionStatus()
        appliedSnapshot = snapshotFromFields()
        onApplied?()
        PetLog.d("[pairing] 通道码已应用 server=\(parsed.server) channel=\(parsed.channel)（钥已存本机钥文件、输入框已清空），自动测连接")
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
