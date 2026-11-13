import AppKit
import UniformTypeIdentifiers

/// 设置窗口：通道服务器 / 通道名 / accesskey（本机钥文件）/ 轮询间隔 / 代理 + 测试连接 + 配对串 + 导出 skill 包。
/// v0.18：撤「注册新通道」（领取走引导/skill），配对块升级为 hatchpet1: 配对串；说明只留一行短提示 + 落地页链接。
/// 服务器、通道名、间隔存 UserDefaults；accesskey 只存本机钥文件（权限 600，见 KeyFileStore），不用系统钥匙串。
/// v0.15 起全量即时生效（macOS 系统设置风格，无「保存」按钮）：开关/下拉变更即落盘
/// 应用；文本框在编辑结束（回车或失焦）时落盘应用。每次应用后经 onApplied 回调让
/// AppDelegate 重启轮询器（按新配置重建会话）；关窗不回滚。
final class SettingsWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// 任一改动即时应用后回调（AppDelegate 据此重启轮询器使新配置生效）
    var onApplied: (() -> Void)?
    /// 某状态的形象被替换/恢复时回调（AppDelegate 据此让正在播该状态的播放器立即重载）
    var onAssetsChanged: ((PetState) -> Void)?
    /// 「重新走引导」点击回调（AppDelegate 据此打开引导窗）
    var onReopenOnboarding: (() -> Void)?

    private var window: NSWindow?
    private var serverField: NSTextField!
    private var channelField: NSTextField!
    private var keyField: NSSecureTextField!
    private var keyHint: NSTextField!
    private var pairingField: NSTextField!
    private var copyPairingButton: NSButton!
    private var intervalPopup: NSPopUpButton!
    private var proxyCheckbox: NSButton!
    private var proxyTypePopup: NSPopUpButton!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!
    private var statusLabel: NSTextField!
    private var exportButton: NSButton!
    private var exportHint: NSTextField!
    /// 「形象」小节每状态一行：来源字 + 恢复默认按钮（key 为状态本身）
    private var assetRows: [PetState: (source: NSTextField, reset: NSButton)] = [:]
    private var updateStatusLabel: NSTextField!
    /// 回填字段时置真，抑制 programmatic change 误触发即时应用（见 loadIntoFields）
    private var isLoading = false
    /// 最近一次已应用的字段快照（关窗时若与当前字段不一致，自动提交一次防丢失）
    private var appliedSnapshot: String?

    /// v0.18 起说明只留一行短提示，全部说明导向落地页（唯一出处）
    private static let helpHint = "改动即时生效、无保存按钮；钥只存本机文件。完整说明看落地页："

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
        // v0.11 起多了「形象」「关于/更新」两节，窗口加高到 1060；超过屏幕
        // 可视高时按屏幕收（下方说明区滚动高度随之变小，布局是光标驱动的、
        // 整体等比下移，不会错位）。
        let visibleH = NSScreen.main?.visibleFrame.height ?? 1060
        let W: CGFloat = 540, H: CGFloat = min(1000, visibleH - 16)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "HatchPet 设置"
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

        // 服务器地址
        _ = addLabel("服务器地址", top: cursor)
        serverField = NSTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW, height: 24))
        serverField.placeholderString = ChannelSettings.defaultServer
        serverField.delegate = self
        content.addSubview(serverField)
        cursor -= 36

        // 通道名
        _ = addLabel("通道名", top: cursor)
        channelField = NSTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW, height: 24))
        channelField.placeholderString = ChannelSettings.defaultChannel
        channelField.delegate = self
        content.addSubview(channelField)
        cursor -= 36

        // accesskey
        _ = addLabel("accesskey", top: cursor)
        keyField = NSSecureTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW, height: 24))
        keyField.placeholderString = "粘贴通道的 accesskey（只存本机文件）"
        keyField.delegate = self
        content.addSubview(keyField)
        cursor -= 26
        keyHint = NSTextField(labelWithString: "")
        keyHint.font = .systemFont(ofSize: 11)
        keyHint.textColor = .secondaryLabelColor
        keyHint.frame = NSRect(x: fieldX, y: cursor - 14, width: fieldW, height: 14)
        content.addSubview(keyHint)
        cursor -= 24

        // 配对串（v0.18，取代 v0.17「注册新通道」）：粘贴 hatchpet1: 串解码填入连接；
        // 同行区另有复制配对串与「重新走引导」入口
        _ = addLabel("配对串", top: cursor)
        pairingField = NSTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW - 120, height: 24))
        pairingField.placeholderString = "hatchpet1:…（粘贴整串后点连接）"
        content.addSubview(pairingField)
        let pairConnectBtn = NSButton(title: "连接", target: self, action: #selector(connectFromPairing))
        pairConnectBtn.bezelStyle = .rounded
        pairConnectBtn.frame = NSRect(x: fieldX + fieldW - 110, y: cursor - 26, width: 110, height: 28)
        content.addSubview(pairConnectBtn)
        cursor -= 36
        copyPairingButton = NSButton(title: "复制配对串", target: self, action: #selector(copyPairing))
        copyPairingButton.bezelStyle = .rounded
        copyPairingButton.frame = NSRect(x: fieldX, y: cursor - 28, width: 130, height: 28)
        content.addSubview(copyPairingButton)
        let reopenBtn = NSButton(title: "重新走引导", target: self, action: #selector(reopenOnboarding))
        reopenBtn.bezelStyle = .rounded
        reopenBtn.frame = NSRect(x: fieldX + 140, y: cursor - 28, width: 130, height: 28)
        content.addSubview(reopenBtn)
        cursor -= 34
        let pairHint = NSTextField(labelWithString: "领取、兑换、自建拿到的都是同一串配对串，粘到这里连接即可；上方三字段手填仍可作兜底。配对串含钥，只发信任对象。")
        pairHint.font = .systemFont(ofSize: 11)
        pairHint.textColor = .secondaryLabelColor
        pairHint.lineBreakMode = .byWordWrapping
        pairHint.maximumNumberOfLines = 2
        pairHint.frame = NSRect(x: fieldX, y: cursor - 26, width: fieldW, height: 26)
        content.addSubview(pairHint)
        cursor -= 34

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

        // 代理小节：开关 + 类型/主机/端口 + 说明（直连 TLS 失败时经本机代理出海）
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
        let proxyHint = NSTextField(labelWithString: "直连服务器失败（如 TLS 错误）时，可填本机代理客户端的监听地址，例如 mihomo/Clash 的 127.0.0.1:7890（混合端口选 HTTP 即可）。")
        proxyHint.font = .systemFont(ofSize: 11)
        proxyHint.textColor = .secondaryLabelColor
        proxyHint.lineBreakMode = .byWordWrapping
        proxyHint.maximumNumberOfLines = 2
        proxyHint.frame = NSRect(x: fieldX, y: cursor - 26, width: fieldW, height: 26)
        content.addSubview(proxyHint)
        cursor -= 36

        // 测试连接 + 状态行
        let testBtn = NSButton(title: "测试连接", target: self, action: #selector(testConnection))
        testBtn.bezelStyle = .rounded
        testBtn.frame = NSRect(x: fieldX, y: cursor - 28, width: 110, height: 28)
        content.addSubview(testBtn)
        statusLabel = NSTextField(labelWithString: "所有改动即时生效：填好可直接点测试连接。")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.frame = NSRect(x: fieldX + 120, y: cursor - 44, width: fieldW - 120, height: 44)
        content.addSubview(statusLabel)
        cursor -= 56

        // 导出 skill 小节
        let sep = NSBox(frame: NSRect(x: 20, y: cursor - 4, width: W - 40, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)
        cursor -= 10
        let exportTitle = NSTextField(labelWithString: "导出 skill")
        exportTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        exportTitle.frame = NSRect(x: 20, y: cursor - 18, width: 200, height: 18)
        content.addSubview(exportTitle)
        cursor -= 24
        exportButton = NSButton(title: "导出 skill 包…", target: self, action: #selector(exportSkill))
        exportButton.bezelStyle = .rounded
        exportButton.frame = NSRect(x: fieldX, y: cursor - 28, width: 150, height: 28)
        content.addSubview(exportButton)
        exportHint = NSTextField(labelWithString: "")
        exportHint.font = .systemFont(ofSize: 11)
        exportHint.textColor = .secondaryLabelColor
        exportHint.frame = NSRect(x: fieldX + 160, y: cursor - 26, width: fieldW - 160, height: 22)
        content.addSubview(exportHint)
        cursor -= 34
        let exportWarn = NSTextField(labelWithString: "导出包内含当前服务器、通道名与 accesskey，拿到的人可读写这个通道，只发给信任的人。")
        exportWarn.font = .systemFont(ofSize: 11)
        exportWarn.textColor = .secondaryLabelColor
        exportWarn.lineBreakMode = .byWordWrapping
        exportWarn.maximumNumberOfLines = 2
        exportWarn.frame = NSRect(x: fieldX, y: cursor - 26, width: fieldW, height: 26)
        content.addSubview(exportWarn)
        cursor -= 34

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
        let assetsHint = NSTextField(labelWithString: "为状态选自己的视频（mp4/mov）替换内置动画，立即生效。建议正方形、白底、480×480——素材走同一套抠像，白底效果最好。")
        assetsHint.font = .systemFont(ofSize: 11)
        assetsHint.textColor = .secondaryLabelColor
        assetsHint.lineBreakMode = .byWordWrapping
        assetsHint.maximumNumberOfLines = 2
        assetsHint.frame = NSRect(x: fieldX, y: cursor - 26, width: fieldW, height: 26)
        content.addSubview(assetsHint)
        cursor -= 36

        // 关于 / 更新小节（v0.11）：当前版本 + 检查更新按钮 + 更新状态行
        let updateTitle = NSTextField(labelWithString: "关于 / 更新")
        updateTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        updateTitle.frame = NSRect(x: 20, y: cursor - 18, width: 200, height: 18)
        content.addSubview(updateTitle)
        cursor -= 26
        _ = addLabel("当前版本", top: cursor)
        let curVer = NSTextField(labelWithString: AppVersion.displayString)
        curVer.font = .systemFont(ofSize: 12)
        curVer.frame = NSRect(x: fieldX, y: cursor - 22, width: 190, height: 20)
        content.addSubview(curVer)
        let checkBtn = NSButton(title: "检查更新", target: self, action: #selector(checkUpdates))
        checkBtn.bezelStyle = .rounded
        checkBtn.frame = NSRect(x: 330, y: cursor - 27, width: 110, height: 26)
        content.addSubview(checkBtn)
        cursor -= 32
        updateStatusLabel = NSTextField(labelWithString: "更新源：GitHub 仓 zeronetizen/hatch-pet-mac 的 Releases（经本页代理）；启动时每天自动静默检查一次。")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.lineBreakMode = .byWordWrapping
        updateStatusLabel.maximumNumberOfLines = 2
        updateStatusLabel.frame = NSRect(x: fieldX, y: cursor - 26, width: fieldW, height: 26)
        content.addSubview(updateStatusLabel)
        cursor -= 36

        // 说明（v0.18：一行短提示 + 落地页链接按钮，删去原大段说明滚动区）
        let sep3 = NSBox(frame: NSRect(x: 20, y: cursor - 4, width: W - 40, height: 1))
        sep3.boxType = .separator
        content.addSubview(sep3)
        cursor -= 10
        let helpLabel = NSTextField(labelWithString: "说明")
        helpLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        helpLabel.frame = NSRect(x: 20, y: cursor - 18, width: 200, height: 18)
        content.addSubview(helpLabel)
        cursor -= 26
        let helpHintLabel = NSTextField(labelWithString: Self.helpHint)
        helpHintLabel.font = .systemFont(ofSize: 12)
        helpHintLabel.lineBreakMode = .byWordWrapping
        helpHintLabel.maximumNumberOfLines = 2
        helpHintLabel.frame = NSRect(x: fieldX, y: cursor - 28, width: fieldW - 130, height: 28)
        content.addSubview(helpHintLabel)
        let helpLinkBtn = NSButton(title: "查看说明", target: self, action: #selector(openHelpPage))
        helpLinkBtn.bezelStyle = .rounded
        helpLinkBtn.frame = NSRect(x: fieldX + fieldW - 120, y: cursor - 27, width: 120, height: 26)
        content.addSubview(helpLinkBtn)
        cursor -= 34

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
        serverField.stringValue = cfg.server
        channelField.stringValue = cfg.channel
        if let idx = ChannelSettings.intervalChoices.firstIndex(of: cfg.intervalSec) {
            intervalPopup.selectItem(at: idx)
        }
        if let key = ChannelSettings.accessKey(for: cfg.channel), !key.isEmpty {
            keyField.stringValue = key
        } else {
            keyField.stringValue = ""
        }
        refreshKeyHint(channel: cfg.channel)
        proxyCheckbox.state = cfg.proxy.enabled ? .on : .off
        proxyTypePopup.selectItem(at: cfg.proxy.type == "socks" ? 1 : 0)
        proxyHostField.stringValue = cfg.proxy.host
        proxyPortField.stringValue = "\(cfg.proxy.port)"
        updateProxyControls()
        statusLabel.stringValue = "所有改动即时生效：填好可直接点测试连接。"
        refreshExportState()
        refreshAssetRows()
        appliedSnapshot = snapshotFromFields()
        PetLog.d("设置窗口已载入 server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s proxy=\(cfg.proxy.summary) keyPresent=\(keyField.stringValue.isEmpty ? false : true)")
    }

    /// 钥提示行：按本机钥文件里当前通道的实际状态显示（载入与每次应用后调用）
    private func refreshKeyHint(channel: String) {
        if let key = ChannelSettings.accessKey(for: channel), !key.isEmpty {
            keyHint.stringValue = "本机已保存通道「\(channel)」的钥（len=\(key.count)）；清空输入并回车/点开别处即删除它。"
        } else {
            keyHint.stringValue = "通道「\(channel)」的钥尚未保存；粘贴后回车或点开别处即存入本机。"
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
    /// keyField 走同一路径（applyFromFields 内统一处理钥的存/删）。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isLoading, let field = obj.object as? NSTextField else { return }
        switch field {
        case keyField:
            let key = keyField.stringValue
            applyFromFields(feedback: key.isEmpty
                ? "已生效：accesskey 已删除（通道功能关闭）"
                : "已生效：accesskey 已存入本机（len=\(key.count)）")
        case serverField:
            applyFromFields(feedback: "已生效：服务器 \(currentServerBase())")
        case channelField:
            applyFromFields(feedback: "已生效：通道 \(currentChannelName())")
        case proxyHostField, proxyPortField:
            applyFromFields(feedback: "已生效：代理 \(proxyFromFields().summary)")
        default:
            applyFromFields(feedback: "已生效")
        }
    }

    /// 从当前字段组装归一化配置（与旧「保存」同一套口径：空值回默认）
    private func configFromFields() -> ChannelConfig {
        let server = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = (intervalPopup.selectedItem?.representedObject as? Int) ?? ChannelSettings.defaultInterval
        return ChannelConfig(server: server.isEmpty ? ChannelSettings.defaultServer : server,
                             channel: channel.isEmpty ? ChannelSettings.defaultChannel : channel,
                             intervalSec: interval,
                             proxy: proxyFromFields())
    }

    /// 字段快照（只用于判「关窗前是否有未提交改动」，含钥原文仅在内存比对、绝不记日志）
    private func snapshotFromFields() -> String {
        let proxy = proxyFromFields()
        let interval = (intervalPopup.selectedItem?.representedObject as? Int) ?? ChannelSettings.defaultInterval
        return [serverField.stringValue, channelField.stringValue, "\(interval)",
                "\(proxy.enabled)", proxy.type, proxy.host, "\(proxy.port)",
                keyField.stringValue].joined(separator: "|")
    }

    /// 即时应用主入口：落盘配置、按需存/删钥、刷新从属 UI、回调重启轮询器、状态行反馈。
    private func applyFromFields(feedback: String) {
        let cfg = configFromFields()
        ChannelSettings.save(cfg)
        persistKey(for: cfg.channel)
        refreshKeyHint(channel: cfg.channel)
        refreshExportState()
        appliedSnapshot = snapshotFromFields()
        onApplied?()
        statusLabel.stringValue = feedback
        PetLog.d("设置即时生效：\(feedback)（server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s proxy=\(cfg.proxy.summary)）")
    }

    /// 钥落盘：与本机已存值相同则跳过（免得每次提交都重写文件刷日志）；
    /// 字段非空且不同 → 存入当前通道；字段为空且本机有 → 删除（通道功能关闭）。
    private func persistKey(for channel: String) {
        let key = keyField.stringValue
        let stored = ChannelSettings.accessKey(for: channel)
        if key.isEmpty {
            if stored != nil {
                KeyFileStore.delete(channel: channel)
                PetLog.d("即时生效：accesskey 已清空，删除通道 \(channel) 的本机钥文件")
            }
        } else if stored != key {
            KeyFileStore.save(key: key, channel: channel)
        }
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
        panel.message = "建议正方形、白底视频（480×480 最佳）：素材会经与内置动画相同的抠像显示。"
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

    // MARK: - 关于 / 更新

    @objc private func checkUpdates() {
        updateStatusLabel.stringValue = "检查中…（经当前代理设置访问 GitHub）"
        UpdateChecker.checkManually { [weak self] text in
            self?.updateStatusLabel.stringValue = text
        }
    }

    // MARK: - Actions

    @objc private func testConnection() {
        let server = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        let channel = channelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keyField.stringValue
        guard !base.isEmpty, !channel.isEmpty, !key.isEmpty else {
            statusLabel.stringValue = "测试失败：服务器、通道名、accesskey 都要先填好。"
            PetLog.d("测试连接未执行：有字段为空 server空=\(base.isEmpty) channel空=\(channel.isEmpty) key空=\(key.isEmpty)")
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
                    self.statusLabel.stringValue = "连接失败：HTTP \(http)\(msg)（检查服务器地址、通道名与钥是否匹配）"
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
                self.statusLabel.stringValue = "连接成功：seq=\(seq)，\(stateText)\(timeText)"
                PetLog.d("测试连接成功 seq=\(seq) \(stateText)")
            }
        }.resume()
    }

    // MARK: - 配对串（v0.18，取代 v0.17 注册新通道 / 三行配对块）

    @objc private func reopenOnboarding() {
        PetLog.d("[pairing] 设置页点「重新走引导」")
        onReopenOnboarding?()
    }

    @objc private func openHelpPage() {
        PetLog.d("[pairing] 打开落地页（全部说明唯一出处）https://pet.8529527.xyz/")
        NSWorkspace.shared.open(URL(string: "https://pet.8529527.xyz/")!)
    }

    /// 粘贴配对串连接：PairingString 按 PROTOCOL 4 步解码校验 → 填三字段 →
    /// 即时应用落盘 → 复用测连接给反馈。失败只提示、不动现有配置。
    @objc private func connectFromPairing() {
        guard let parsed = PairingString.parse(pairingField.stringValue) else {
            statusLabel.stringValue = "配对串不对：应是 hatchpet1: 开头的一整串，原样粘贴、不要改动。"
            return
        }
        isLoading = true
        serverField.stringValue = parsed.server
        channelField.stringValue = parsed.channel
        keyField.stringValue = parsed.key
        isLoading = false
        PetLog.d("[pairing] 配对串已填入三字段 server=\(parsed.server) channel=\(parsed.channel)，即时应用并测连接")
        applyFromFields(feedback: "配对串已填入并生效，正在测连接…")
        testConnection()
    }

    /// 把当前配置组装成新配对串复制到剪贴板（取代 v1 三行配对块）。
    @objc private func copyPairing() {
        let channel = currentChannelName()
        guard !channel.isEmpty, let key = ChannelSettings.accessKey(for: channel), !key.isEmpty else {
            statusLabel.stringValue = "复制配对串失败：当前通道还没有保存在本机的 accesskey（先粘贴配对串连接，或在上方填入钥、回车存入本机）。"
            PetLog.d("[pairing] 复制配对串失败 channel=\(channel)：本机无钥")
            return
        }
        let str = PairingString.encode(server: currentServerBase(), channel: channel, key: key)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        statusLabel.stringValue = "配对串已复制：整串发给你的智能体，它就能往这条通道写状态。配对串含钥，只发给信任的对象。"
        PetLog.d("[pairing] 配对串已复制 channel=\(channel)（钥不记日志）")
    }

    // MARK: - 导出 skill 包

    /// 当前通道名（字段为空时用默认值）与服务器基地址（字段为空时用默认、去尾斜杠）。
    private func currentChannelName() -> String {
        let ch = channelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ch.isEmpty ? ChannelSettings.defaultChannel : ch
    }

    private func currentServerBase() -> String {
        let s = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var base = s.isEmpty ? ChannelSettings.defaultServer : s
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// .app 内置 skill 模板目录（v0.18 起为 relay-channel-setup 包）；缺失返回 nil。
    private func skillTemplateDir() -> URL? {
        SkillExport.templateDir("relay-channel-setup")
    }

    /// 刷新导出按钮可用状态：模板缺失或本机无当前通道的钥文件时禁用。窗口打开与每次即时应用后调用。
    private func refreshExportState() {
        guard let exportButton, let exportHint else { return }
        if skillTemplateDir() == nil {
            exportButton.isEnabled = false
            exportHint.stringValue = "应用内未找到 skill 模板，无法导出。"
            PetLog.d("导出 skill 不可用：Bundle 内未找到 skill/relay-channel-setup 模板")
            return
        }
        let channel = currentChannelName()
        if let key = ChannelSettings.accessKey(for: channel), !key.isEmpty {
            exportButton.isEnabled = true
            exportHint.stringValue = "可导出，将含通道「\(channel)」的 accesskey。"
            PetLog.d("导出 skill 可用 channel=\(channel)（钥在本机钥文件中）")
        } else {
            exportButton.isEnabled = false
            exportHint.stringValue = "先填入 accesskey 后可导出（填入即存入本机）。"
            PetLog.d("导出 skill 不可用：本机无通道 \(channel) 的钥文件")
        }
    }

    @objc private func exportSkill() {
        let channel = currentChannelName()
        let server = currentServerBase()
        guard let template = skillTemplateDir() else {
            statusLabel.stringValue = "导出失败：应用内未找到 skill 模板。"
            PetLog.d("skill 导出失败 channel=\(channel)：模板缺失")
            return
        }
        guard let key = ChannelSettings.accessKey(for: channel), !key.isEmpty else {
            statusLabel.stringValue = "导出失败：本机没有保存通道「\(channel)」的 accesskey，请先填写（回车或点开别处即存入本机）。"
            PetLog.d("skill 导出失败 channel=\(channel)：本机无钥文件")
            refreshExportState()
            return
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("hatchpet-skill-export-\(UUID().uuidString)", isDirectory: true)
        let pkgDir = staging.appendingPathComponent("relay-channel-setup", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: pkgDir, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(atPath: template.path) {
                try fm.copyItem(at: template.appendingPathComponent(item),
                                to: pkgDir.appendingPathComponent(item))
            }
            let cfg: [String: Any] = [
                "server_url": server,
                "channel": channel,
                "accesskey": key,
                "exported_at": ISO8601DateFormatter().string(from: Date()),
                "note": "含通道钥，只发给信任的人",
            ]
            let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: pkgDir.appendingPathComponent("pet-channel.json"), options: .atomic)
            PetLog.d("skill 导出组包完成 channel=\(channel) server=\(server) 含钥=true（钥原文不记日志）")
        } catch {
            statusLabel.stringValue = "导出失败：组包出错（\(error.localizedDescription)）"
            PetLog.d("skill 导出组包失败 channel=\(channel)：\(error.localizedDescription)")
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 skill 包"
        panel.message = "包内含当前通道的 accesskey，只发给信任的人。"
        panel.nameFieldStringValue = "relay-channel-setup-skill.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else {
            statusLabel.stringValue = "已取消导出。"
            PetLog.d("skill 导出被用户取消 channel=\(channel)")
            return
        }
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            let ok: Bool
            if fm.fileExists(atPath: "/usr/bin/ditto") {
                ok = runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", pkgDir.path, dest.path])
            } else {
                ok = runTool("/usr/bin/zip", ["-r", dest.path, "relay-channel-setup"], currentDir: staging.path)
            }
            guard ok else {
                throw NSError(domain: "HatchPetExport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "打包命令执行失败"])
            }
        } catch {
            statusLabel.stringValue = "导出失败：\(error.localizedDescription)"
            PetLog.d("skill 导出打包失败 channel=\(channel)：\(error.localizedDescription)")
            return
        }
        statusLabel.stringValue = "已导出 skill 包到：\(dest.path)"
        PetLog.d("skill 导出成功 路径=\(dest.path) 通道=\(channel) 含钥=true")
    }

    private func runTool(_ path: String, _ args: [String], currentDir: String? = nil) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let currentDir { p.currentDirectoryURL = URL(fileURLWithPath: currentDir) }
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            PetLog.d("导出工具启动失败 \(path)：\(error.localizedDescription)")
            return false
        }
        p.waitUntilExit()
        PetLog.d("导出工具 \(path) 退出码 \(p.terminationStatus)")
        return p.terminationStatus == 0
    }

    private static func timeString(ms: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
