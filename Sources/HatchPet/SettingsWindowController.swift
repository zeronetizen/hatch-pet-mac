import AppKit
import UniformTypeIdentifiers

/// 设置窗口：通道服务器 / 通道名 / accesskey（本机钥文件）/ 轮询间隔 / 代理 + 测试连接 + 导出 skill 包 + 详细说明。
/// 服务器、通道名、间隔存 UserDefaults；accesskey 只存本机钥文件（权限 600，见 KeyFileStore），不用系统钥匙串。
/// 保存后经 onSave 回调让 AppDelegate 立即重启轮询器生效。
final class SettingsWindowController: NSObject {
    var onSave: (() -> Void)?
    /// 某状态的形象被替换/恢复时回调（AppDelegate 据此让正在播该状态的播放器立即重载）
    var onAssetsChanged: ((PetState) -> Void)?

    private var window: NSWindow?
    private var serverField: NSTextField!
    private var channelField: NSTextField!
    private var keyField: NSSecureTextField!
    private var keyHint: NSTextField!
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

    private static let helpText = """
    【每个字段是什么】
    · 服务器地址：通道服务的地址。宠物定时到这个地址读取最新状态。本应用不直连任何其他服务器。
    · 通道名：服务器上的一条通道，相当于一个专属信箱。写入方（例如你的 Muse）和这只宠物用同一个通道名对上头。
    · accesskey：这条通道的钥匙，读写共用同一把。保存在本机应用数据目录的文件中（~/Library/Application Support/HatchPet/keys/<通道名>.key，目录权限 700、文件权限 600），不进系统钥匙串（避免权限弹窗），不写进应用、不打包分发、不上传到任何地方（只在向上面填写的服务器请求时作为身份凭证发送）。注：v0.5 及以前版本把钥存在系统钥匙串里，v0.6 起改存上述文件，旧钥不会自动迁移，升级后在设置里重填一次即可。
    · 轮询间隔：多久去服务器看一次新状态。越短越实时、流量越大；15 秒对桌面宠物足够，流量和耗电都可以忽略。

    【默认服务器是谁的】
    默认地址 https://relay.nonzero-e3c.workers.dev 是本应用作者运营的一台通道服务器（跑在 Cloudflare 上）。你的宠物状态数据（就是一小段 JSON：状态、可选的一句消息、时间戳）会经过它中转。介意的话，完全可以换成你自己的服务器，见下一段。

    【想用自己的服务器】
    本仓库附带一个给 Muse 用的部署 skill：skill/relay-channel（SKILL.md + assets/ 里是服务端全部代码）。把它装进你自己的 Muse，然后对它说一句「用 skill/relay-channel 部署我自己的通道」，它会引导你在你自己的 Cloudflare 账号上一键部署一套同样的通道服务、建好第一条通道，并把新服务器的地址和 accesskey 交给你。把那两个值填回本设置页即可，之后数据只走你自己的服务器。为安全起见，部署时 Cloudflare 的 API token 走安全凭证流程，不要把任何密钥明文粘贴到聊天或文件里。

    【测试连接报 TLS 错误怎么办】
    默认服务器域名（*.workers.dev）在某些网络下直连会被干扰，TLS 握手直接失败。这不是钥或通道填错。办法一：在你的代理客户端（如 mihomo）里把 workers.dev 设为走代理。办法二：用本页的「代理」小节——勾选「使用代理连接服务器」，填本机代理客户端的监听地址（混合端口如 127.0.0.1:7890 选 HTTP；纯 SOCKS5 端口选 SOCKS5），保存后轮询与测试连接都会经它出海，与系统 TUN 规则互不影响。

    【没配置会怎样】
    accesskey 留空（保存后即删除本机钥文件）时，通道功能关闭，宠物退回纯本地手动模式：用菜单切换状态，不联网、不轮询。

    【长时间没新状态会变淡】
    通道数据超过 20 分钟没有更新时，宠物会在随后一分钟里缓慢变淡（到 75% 不透明），表示对端暂时失联；这不是故障，也不会一步突然透明。一旦收到新数据，会立即平滑恢复全亮。

    【把这条通道分享给信任的人】
    设置页下方有「导出 skill 包」：填好 accesskey 并保存后可用。导出的 zip 里装着部署 skill（对方的 Muse 装上它就能部署或对接通道）和一份 pet-channel.json（当前服务器地址、通道名与 accesskey）。拿到这个包的人可以读写你的这条通道——只发给信任的人，不要发到公开场合。

    【自定义形象】
    「形象」小节可为五个状态各选一个自己的视频（mp4/mov）替换内置动画，例如把官方待机的大头特写换成全身素材。选中的文件会被拷贝到 ~/Library/Application Support/HatchPet/assets/ 下长期保存（原文件之后移动/删除不影响），设置后立即生效；「恢复默认」删掉拷贝、回到内置动画。素材与内置动画走同一套实时抠像：建议正方形、白底视频，与内置素材同规格 480×480 最佳；非白底素材抠像边缘会不干净。内置的待机动画本身是特写构图，这是素材如此，不是显示被裁。

    【检查更新】
    「关于 / 更新」小节可手动检查更新；应用启动时也会每天静默自动检查一次。更新只从 GitHub 公开仓 zeronetizen/hatch-pet-mac 的 Releases 拉取（检查与下载都走本页配置的代理），下载后先校验新包版本确实更高，确认更新后应用会退出、由一个一次性助手把新版换上并自动重启——钥文件、自定义形象与设置都存在应用之外，不受影响。任何一步失败都会停在旧版并弹窗说明。
    """

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
        let W: CGFloat = 540, H: CGFloat = min(1060, visibleH - 16)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "HatchPet 设置"
        win.isReleasedWhenClosed = false
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
        content.addSubview(serverField)
        cursor -= 36

        // 通道名
        _ = addLabel("通道名", top: cursor)
        channelField = NSTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW, height: 24))
        channelField.placeholderString = ChannelSettings.defaultChannel
        content.addSubview(channelField)
        cursor -= 36

        // accesskey
        _ = addLabel("accesskey", top: cursor)
        keyField = NSSecureTextField(frame: NSRect(x: fieldX, y: cursor - 24, width: fieldW, height: 24))
        keyField.placeholderString = "粘贴通道的 accesskey（只存本机文件）"
        content.addSubview(keyField)
        cursor -= 26
        keyHint = NSTextField(labelWithString: "")
        keyHint.font = .systemFont(ofSize: 11)
        keyHint.textColor = .secondaryLabelColor
        keyHint.frame = NSRect(x: fieldX, y: cursor - 14, width: fieldW, height: 14)
        content.addSubview(keyHint)
        cursor -= 24

        // 轮询间隔
        _ = addLabel("轮询间隔", top: cursor)
        intervalPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: cursor - 26, width: 140, height: 26), pullsDown: false)
        for sec in ChannelSettings.intervalChoices {
            intervalPopup.addItem(withTitle: "\(sec) 秒")
            intervalPopup.itemArray.last?.representedObject = sec
        }
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
        content.addSubview(proxyTypePopup)
        proxyHostField = NSTextField(frame: NSRect(x: fieldX + 104, y: cursor - 24, width: 176, height: 24))
        proxyHostField.placeholderString = ProxyConfig.defaultHost
        content.addSubview(proxyHostField)
        proxyPortField = NSTextField(frame: NSRect(x: fieldX + 288, y: cursor - 24, width: 84, height: 24))
        proxyPortField.placeholderString = "\(ProxyConfig.defaultPort)"
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
        statusLabel = NSTextField(labelWithString: "填好后可先测试连接，再保存。")
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

        // 详细说明
        let helpLabel = NSTextField(labelWithString: "说明")
        helpLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        helpLabel.frame = NSRect(x: 20, y: cursor - 18, width: 200, height: 18)
        content.addSubview(helpLabel)
        cursor -= 24
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 64, width: W - 40, height: cursor - 64))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: W - 40, height: cursor - 64))
        textView.string = Self.helpText
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = textView
        content.addSubview(scroll)

        // 底部按钮
        let saveBtn = NSButton(title: "保存", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: W - 120, y: 16, width: 100, height: 32)
        content.addSubview(saveBtn)
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.frame = NSRect(x: W - 232, y: 16, width: 100, height: 32)
        content.addSubview(cancelBtn)

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
        let cfg = ChannelSettings.load()
        serverField.stringValue = cfg.server
        channelField.stringValue = cfg.channel
        if let idx = ChannelSettings.intervalChoices.firstIndex(of: cfg.intervalSec) {
            intervalPopup.selectItem(at: idx)
        }
        if let key = ChannelSettings.accessKey(for: cfg.channel), !key.isEmpty {
            keyField.stringValue = key
            keyHint.stringValue = "本机已保存通道「\(cfg.channel)」的钥（len=\(key.count)）；清空并保存将删除它。"
        } else {
            keyField.stringValue = ""
            keyHint.stringValue = "通道「\(cfg.channel)」的钥尚未保存；留空保存则保持未配置。"
        }
        proxyCheckbox.state = cfg.proxy.enabled ? .on : .off
        proxyTypePopup.selectItem(at: cfg.proxy.type == "socks" ? 1 : 0)
        proxyHostField.stringValue = cfg.proxy.host
        proxyPortField.stringValue = "\(cfg.proxy.port)"
        updateProxyControls()
        statusLabel.stringValue = "填好后可先测试连接，再保存。"
        refreshExportState()
        refreshAssetRows()
        PetLog.d("设置窗口已载入 server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s proxy=\(cfg.proxy.summary) keyPresent=\(keyField.stringValue.isEmpty ? false : true)")
    }

    // MARK: - 代理小节

    @objc private func proxyToggled() {
        updateProxyControls()
        PetLog.d("代理开关切换为 \(proxyCheckbox.state == .on ? "开" : "关")（保存后生效，测试连接立即按当前勾选走）")
    }

    /// 未勾选时类型/主机/端口置灰
    private func updateProxyControls() {
        let on = proxyCheckbox.state == .on
        proxyTypePopup.isEnabled = on
        proxyHostField.isEnabled = on
        proxyPortField.isEnabled = on
    }

    /// 从当前字段读代理配置（保存与测试连接共用，测试不必先保存）
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
                if let payload = obj["data"] as? [String: Any] {
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

    @objc private func save() {
        let server = serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let channel = channelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let interval = (intervalPopup.selectedItem?.representedObject as? Int) ?? ChannelSettings.defaultInterval
        let cfg = ChannelConfig(server: server.isEmpty ? ChannelSettings.defaultServer : server,
                                channel: channel.isEmpty ? ChannelSettings.defaultChannel : channel,
                                intervalSec: interval,
                                proxy: proxyFromFields())
        ChannelSettings.save(cfg)
        let key = keyField.stringValue
        if key.isEmpty {
            KeyFileStore.delete(channel: cfg.channel)
            PetLog.d("设置保存：accesskey 为空，已删除通道 \(cfg.channel) 的本机钥文件（通道功能关闭）")
        } else {
            KeyFileStore.save(key: key, channel: cfg.channel)
        }
        refreshExportState()
        onSave?()
        window?.close()
        PetLog.d("设置已保存并生效（轮询器将按新配置重启）")
    }

    @objc private func cancel() {
        PetLog.d("设置窗口取消（不保存）")
        window?.close()
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

    /// .app 内置 skill 模板目录（assemble 时拷到 Contents/Resources/skill/relay-channel）；缺失返回 nil。
    private func skillTemplateDir() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("skill/relay-channel", isDirectory: true)
        let md = dir.appendingPathComponent("SKILL.md")
        return FileManager.default.fileExists(atPath: md.path) ? dir : nil
    }

    /// 刷新导出按钮可用状态：模板缺失或本机无当前通道的钥文件时禁用。窗口打开与保存后调用。
    private func refreshExportState() {
        guard let exportButton, let exportHint else { return }
        if skillTemplateDir() == nil {
            exportButton.isEnabled = false
            exportHint.stringValue = "应用内未找到 skill 模板，无法导出。"
            PetLog.d("导出 skill 不可用：Bundle 内未找到 skill/relay-channel 模板")
            return
        }
        let channel = currentChannelName()
        if let key = ChannelSettings.accessKey(for: channel), !key.isEmpty {
            exportButton.isEnabled = true
            exportHint.stringValue = "可导出，将含通道「\(channel)」的 accesskey。"
            PetLog.d("导出 skill 可用 channel=\(channel)（钥在本机钥文件中）")
        } else {
            exportButton.isEnabled = false
            exportHint.stringValue = "先填入 accesskey 并保存后可导出。"
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
            statusLabel.stringValue = "导出失败：本机没有保存通道「\(channel)」的 accesskey，请先填写并保存。"
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
