import AppKit

/// 首启引导窗：未配置通道+钥时由 AppDelegate 弹出，设置里也可经「重新走
/// 引导」再开。v0.31 起为单一静态布局，不再查名额、不再按状态切换面板：
/// - 免费通道卡片（静态）：一行左文案右按钮（导出领取 skill 包），按钮下
///   保留原有说明段；
/// - 代理行：与设置页同一份配置，改完即存（控件与同步逻辑沿用 v0.24）；
/// - 通道码卡片（常显）：粘贴通道码点「连接」；
/// - 自建通道卡片（常显）：邮箱 → 生成带 pet-owner.json 的自建 skill 包。
/// 连接成功 = 落盘配置 + 存钥 + 回调 AppDelegate 重启轮询，随后关窗；
/// 落盘后异步向中转领取管理钥存本机（见 MgmtService，失败静默待下次）。
/// 粘贴框设死单行（v0.27 定版）：maximumNumberOfLines=1、cell
/// usesSingleLineMode、不换行可横滚；粘贴清洗保留但无声（v0.26 起，根因
/// 是应用无主菜单、Cmd+V 无人派发，修在 main.swift；内容变化即去掉全部
/// 空白、多行剪贴板自动拼成一整串）。
/// 版式为品牌区 + 分组卡片（浅色圆角），高度按 contentRect 换算窗口
/// frame（v0.24 修标题裁切），无底部「关闭」按钮（标题栏关闭钮已足够）。
final class OnboardingWindowController: NSObject, NSTextFieldDelegate {
    var onConnected: (() -> Void)?

    private var window: NSWindow?
    private var brandIcon: NSImageView!
    private var brandTitle: NSTextField!
    private var brandSub: NSTextField!
    private var proxyCheckbox: NSButton!
    private var proxyTypePopup: NSPopUpButton!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!
    /// 预填代理行时为真，屏蔽「改动即存」（只认用户真实编辑）
    private var isPrefillingProxy = false
    private var claimCard: NSBox!
    private var pairingCard: NSBox!
    private var pairingField: NSTextField!
    private var selfhostCard: NSBox!
    private var emailField: NSTextField!
    private var feedback: NSTextField!
    private var actionButtons: [NSButton] = []

    // 布局常量（手动 frame；relayout 按静态分组从顶往下排并定窗高）
    private static let W: CGFloat = 560
    private static let X: CGFloat = 20
    private static var FW: CGFloat { W - 40 }
    private static let claimCardH: CGFloat = 114
    private static let pairingCardH: CGFloat = 80
    private static let selfhostCardH: CGFloat = 126
    /// 静态内容高：顶距 22 + 品牌 56 + 代理行 26 + 免费卡 114 + 通道码卡 80
    /// + 自建卡 126 + 反馈 30，段间隔 12/12/12/12/10、底距 16，合计 528。
    private static let contentH: CGFloat = 528

    func show() {
        let win = ensureWindow()
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        PetLog.d("[onboarding] 引导窗打开（v0.31 静态布局，无名额查询）")
    }

    // MARK: - 构建（卡片容器 + 相对内布局；绝对位置由 relayout 统一排）

    /// 浅色圆角卡片：原生 AppKit 观感（控制背景色 + 分隔线描边），不引图片资源。
    private func makeCard(height: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.frame = NSRect(x: Self.X, y: 0, width: Self.FW, height: height)
        return box
    }

    /// 粘贴框设死单行（v0.27，用户定版）：等价 SwiftUI 的 lineLimit=1——不换行、
    /// 不撑高，长串在框内横向滚动/裁剪，只占一行。布局与卡片高度一律不动。
    private static func makeSingleLine(_ field: NSTextField) {
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.W, height: Self.contentH),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "MusePet 引导"
        win.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.W, height: Self.contentH))
        win.contentView = content
        let innerW = Self.FW - 28 // 卡片内宽（左右各 14 内边距）

        // 品牌区：应用图标 + 标题 + 一句副文案
        brandIcon = NSImageView()
        brandIcon.image = NSApp.applicationIconImage
        brandIcon.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(brandIcon)
        brandTitle = NSTextField(labelWithString: "欢迎使用 MusePet")
        brandTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        content.addSubview(brandTitle)
        brandSub = NSTextField(labelWithString: "这只宠物会显示你的智能体正在干什么。它需要一条中转通道才能收到状态，下面选一条路拿到通道即可。")
        brandSub.font = .systemFont(ofSize: 12)
        brandSub.textColor = .secondaryLabelColor
        brandSub.lineBreakMode = .byWordWrapping
        brandSub.maximumNumberOfLines = 3
        content.addSubview(brandSub)

        // 代理配置行（v0.24）：与 ChannelSettings 同一份存储——首启未配置用户
        // 唯一的代理入口。字段与归一化口径同设置页（proxyFromFields 一套），
        // 改动即存。v0.31：行下原有一句提示文案已按定稿整句删除。
        proxyCheckbox = NSButton(checkboxWithTitle: "使用代理", target: self, action: #selector(proxyRowChanged))
        content.addSubview(proxyCheckbox)
        proxyTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        proxyTypePopup.addItems(withTitles: ["HTTP", "SOCKS5"])
        proxyTypePopup.target = self
        proxyTypePopup.action = #selector(proxyRowChanged)
        content.addSubview(proxyTypePopup)
        proxyHostField = NSTextField()
        proxyHostField.placeholderString = ProxyConfig.defaultHost
        proxyHostField.delegate = self
        content.addSubview(proxyHostField)
        proxyPortField = NSTextField()
        proxyPortField.placeholderString = "\(ProxyConfig.defaultPort)"
        proxyPortField.delegate = self
        content.addSubview(proxyPortField)
        prefillProxyRow()

        // 免费通道卡片（v0.31 静态）：首行左文案右按钮同行，按钮下保留说明段
        claimCard = makeCard(height: Self.claimCardH)
        let claimText = NSTextField(labelWithString: "用领取 skill 让智能体帮你领一条免费通道（名额有限）")
        claimText.font = .systemFont(ofSize: 13, weight: .medium)
        claimText.lineBreakMode = .byWordWrapping
        claimText.maximumNumberOfLines = 2
        claimText.frame = NSRect(x: 14, y: 66, width: innerW - 182, height: 36)
        claimCard.addSubview(claimText)
        let claimBtn = NSButton(title: "导出领取 skill 包", target: self, action: #selector(exportClaim))
        claimBtn.bezelStyle = .rounded
        claimBtn.frame = NSRect(x: 14 + innerW - 170, y: 70, width: 170, height: 28)
        claimCard.addSubview(claimBtn)
        actionButtons.append(claimBtn)
        let claimHint = NSTextField(labelWithString: "把导出的包交给你的智能体，它领到免费通道后会给你一个通道码，粘到下方通道码框点「连接」即可。")
        claimHint.font = .systemFont(ofSize: 11)
        claimHint.textColor = .secondaryLabelColor
        claimHint.lineBreakMode = .byWordWrapping
        claimHint.maximumNumberOfLines = 3
        claimHint.frame = NSRect(x: 14, y: 14, width: innerW, height: 44)
        claimCard.addSubview(claimHint)
        content.addSubview(claimCard)

        // 通道码卡片（常显，三路共同收尾）
        pairingCard = makeCard(height: Self.pairingCardH)
        let pairLabel = NSTextField(labelWithString: "通道码")
        pairLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pairLabel.frame = NSRect(x: 14, y: 48, width: 200, height: 18)
        pairingCard.addSubview(pairLabel)
        pairingField = NSTextField(frame: NSRect(x: 14, y: 16, width: innerW - 120, height: 24))
        pairingField.placeholderString = "hatchpet1:…（粘贴整串）"
        pairingField.delegate = self // v0.26：粘贴清洗（见 controlTextDidChange）
        Self.makeSingleLine(pairingField)
        pairingCard.addSubview(pairingField)
        let connectBtn = NSButton(title: "连接", target: self, action: #selector(connectFromPairing))
        connectBtn.bezelStyle = .rounded
        connectBtn.bezelColor = .controlAccentColor // 主按钮：强调色突出
        connectBtn.frame = NSRect(x: 14 + innerW - 110, y: 14, width: 110, height: 28)
        pairingCard.addSubview(connectBtn)
        actionButtons.append(connectBtn)
        content.addSubview(pairingCard)

        // 自建通道卡片（常显）
        selfhostCard = makeCard(height: Self.selfhostCardH)
        let selfTitle = NSTextField(labelWithString: "自建通道（可选）")
        selfTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        selfTitle.frame = NSRect(x: 14, y: 94, width: 240, height: 18)
        selfhostCard.addSubview(selfTitle)
        emailField = NSTextField(frame: NSRect(x: 14, y: 62, width: innerW - 190, height: 24))
        emailField.placeholderString = "你的邮箱（用于注册/登录 Cloudflare）"
        selfhostCard.addSubview(emailField)
        let genBtn = NSButton(title: "生成自建 skill 包", target: self, action: #selector(exportSelfhost))
        genBtn.bezelStyle = .rounded
        genBtn.frame = NSRect(x: 14 + innerW - 180, y: 60, width: 180, height: 28)
        selfhostCard.addSubview(genBtn)
        actionButtons.append(genBtn)
        let selfNote = NSTextField(labelWithString: "自建通道的数据存在你自己的 Cloudflare、不占免费通道名额。把生成的包交给你的智能体，它会凭邮箱引导你完成部署；部署完把通道码粘回上面即可。")
        selfNote.font = .systemFont(ofSize: 11)
        selfNote.textColor = .secondaryLabelColor
        selfNote.lineBreakMode = .byWordWrapping
        selfNote.maximumNumberOfLines = 3
        selfNote.frame = NSRect(x: 14, y: 14, width: innerW, height: 40)
        selfhostCard.addSubview(selfNote)
        content.addSubview(selfhostCard)

        feedback = NSTextField(labelWithString: "")
        feedback.font = .systemFont(ofSize: 12)
        feedback.lineBreakMode = .byWordWrapping
        feedback.maximumNumberOfLines = 2
        content.addSubview(feedback)

        self.window = win
        relayout()
        return win
    }

    /// 静态布局：各分组恒定可见，按固定高度从顶往下排并定窗高。H 是
    /// content 高，窗口 frame 高用 frameRect(forContentRect:) 换算（含标题
    /// 栏约 28pt，v0.24 修裁切）；content 实际尺寸由窗口按 contentRect
    /// 自动给定，本函数不手动赋 content.frame。
    /// 各段高度与卡内子视图逐项对应：品牌区 56（图标 44 + 上下留白 6/6，
    /// 标题行 22 + 副文案 32 + 间隔 2）；代理行 26；免费卡 114（14+44+8+
    /// 36+12，首行文案与按钮同行）、通道码卡 80（14+18+8+26+14）、自建卡
    /// 126（14+18+6+26+8+40+14）。
    private func relayout() {
        guard let win = window else { return }
        let contentH = Self.contentH
        let target = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.W, height: contentH))
        var frame = win.frame
        if abs(frame.height - target.height) > 0.5 || abs(frame.width - target.width) > 0.5 {
            let topEdge = frame.maxY
            frame.size = target.size
            frame.origin.y = topEdge - target.height
            win.setFrame(frame, display: true, animate: false)
        }
        var top = contentH - 22 // 距顶游标（content 坐标）：每放一段减去其高度
        // 品牌区（高 56）
        brandIcon.frame = NSRect(x: Self.X, y: top - 50, width: 44, height: 44)
        brandTitle.frame = NSRect(x: Self.X + 56, y: top - 22, width: Self.FW - 56, height: 22)
        brandSub.frame = NSRect(x: Self.X + 56, y: top - 56, width: Self.FW - 56, height: 32)
        top -= 56 + 12
        // 代理行（高 26，仅控件行）
        proxyCheckbox.frame = NSRect(x: Self.X, y: top - 25, width: 88, height: 24)
        proxyTypePopup.frame = NSRect(x: Self.X + 92, y: top - 26, width: 92, height: 26)
        proxyHostField.frame = NSRect(x: Self.X + 192, y: top - 25, width: 224, height: 24)
        proxyPortField.frame = NSRect(x: Self.X + 424, y: top - 25, width: 96, height: 24)
        top -= 26 + 12
        // 免费通道卡片
        claimCard.frame = NSRect(x: Self.X, y: top - Self.claimCardH, width: Self.FW, height: Self.claimCardH)
        top -= Self.claimCardH + 12
        pairingCard.frame = NSRect(x: Self.X, y: top - Self.pairingCardH, width: Self.FW, height: Self.pairingCardH)
        top -= Self.pairingCardH + 12
        selfhostCard.frame = NSRect(x: Self.X, y: top - Self.selfhostCardH, width: Self.FW, height: Self.selfhostCardH)
        top -= Self.selfhostCardH + 10
        feedback.frame = NSRect(x: Self.X, y: top - 30, width: Self.FW, height: 30)
    }

    private func setActionsEnabled(_ on: Bool) {
        actionButtons.forEach { $0.isEnabled = on }
    }

    // MARK: - 粘贴框清洗（通道码，v0.26）

    /// 内容变化即清洗：去掉全部空白（换行、回车、空格）——剪贴板里的串被聊天
    /// 客户端折成多行时，粘进来立刻拼成一整串单行，不再被单行字段编辑器在
    /// 首个换行处截断（parse 只 trim 首尾、内部空白对 base64 是致命的）。
    /// 清洗确实改写了内容时把 caret 拉到串尾并滚动到可见。清洗无声：不给任何
    /// 字数/已输入类反馈文案（v0.27 用户定版）。只对通道码框生效，代理/邮箱
    /// 等字段不走这里。
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === pairingField else { return }
        let raw = field.stringValue
        let cleaned = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        if cleaned != raw {
            field.stringValue = cleaned
            moveCaretToEnd(field)
            PetLog.d("[onboarding] 通道码输入清洗：去掉空白 \(raw.count - cleaned.count) 字、拼成一整串 len=\(cleaned.count)（串本体不记日志）")
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

    // MARK: - 代理行（引导页内嵌，与 ChannelSettings 同一份存储）

    /// 预填已保存的代理值（建窗时调一次；预填不触发保存）
    private func prefillProxyRow() {
        let proxy = ChannelSettings.load().proxy
        isPrefillingProxy = true
        proxyCheckbox.state = proxy.enabled ? .on : .off
        proxyTypePopup.selectItem(at: proxy.type == "socks" ? 1 : 0)
        proxyHostField.stringValue = proxy.host
        proxyPortField.stringValue = "\(proxy.port)"
        isPrefillingProxy = false
        updateProxyRowControls()
        PetLog.d("[onboarding] 代理行预填 proxy=\(proxy.summary)（引导页与设置页同一份存储）")
    }

    /// 未勾选时类型/主机/端口置灰（口径同设置页）
    private func updateProxyRowControls() {
        let on = proxyCheckbox.state == .on
        proxyTypePopup.isEnabled = on
        proxyHostField.isEnabled = on
        proxyPortField.isEnabled = on
    }

    /// 从代理行控件读配置：归一化口径同设置页 proxyFromFields（空主机→默认、
    /// 端口非法→默认），保证从零填写也能拼出可用配置。
    private func proxyFromRow() -> ProxyConfig {
        let host = proxyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = Int(proxyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { (1...65535).contains($0) ? $0 : nil } ?? ProxyConfig.defaultPort
        return ProxyConfig(enabled: proxyCheckbox.state == .on,
                           type: proxyTypePopup.indexOfSelectedItem == 1 ? "socks" : "http",
                           host: host.isEmpty ? ProxyConfig.defaultHost : host,
                           port: port)
    }

    @objc private func proxyRowChanged() {
        guard !isPrefillingProxy else { return }
        updateProxyRowControls()
        applyProxyFromRow()
    }

    /// 代理主机/端口编辑结束（回车或失焦）即保存
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isPrefillingProxy, let field = obj.object as? NSTextField,
              field === proxyHostField || field === proxyPortField else { return }
        applyProxyFromRow()
    }

    /// 存回同一份 ChannelSettings 存储（只换 proxy，服务器/通道/间隔以已保存
    /// 值为准，不碰其他字段）。
    private func applyProxyFromRow() {
        var cfg = ChannelSettings.load()
        cfg.proxy = proxyFromRow()
        ChannelSettings.save(cfg)
        PetLog.d("[onboarding] 代理行改动已保存 proxy=\(cfg.proxy.summary)")
    }

    // MARK: - 领取 / 自建导出

    @objc private func exportClaim() {
        PetLog.d("[onboarding] 导出领取 skill 包")
        feedback.stringValue = SkillExport.export(package: "pet-claim",
                                                  suggestedName: "pet-claim-skill.zip")
    }

    @objc private func exportSelfhost() {
        let email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), email.contains("."), !email.contains(" ") else {
            feedback.stringValue = "先填一个有效的邮箱，再生成自建 skill 包。"
            PetLog.d("[onboarding] 自建导出拦截：邮箱格式不对")
            return
        }
        let ownerObj: [String: Any] = ["email": email]
        let ownerData = try! JSONSerialization.data(withJSONObject: ownerObj, options: [.sortedKeys])
        let ownerText = String(data: ownerData, encoding: .utf8)! + "\n"
        PetLog.d("[onboarding] 生成自建 skill 包（pet-owner.json 写邮箱，邮箱原文不记日志）")
        feedback.stringValue = SkillExport.export(package: "relay-channel-setup",
                                                  suggestedName: "relay-channel-setup-skill.zip",
                                                  extraFiles: ["pet-owner.json": ownerText])
    }

    // MARK: - 通道码连接（共同收尾）

    @objc private func connectFromPairing() {
        let raw = pairingField.stringValue
        guard let parsed = PairingString.parse(raw) else {
            feedback.stringValue = "通道码不对：应是 hatchpet1: 开头的一整串，原样粘贴、不要改动。"
            PetLog.d("[onboarding] 通道码连接拦截：解码/校验未过")
            return
        }
        applyConnection(server: parsed.server, channel: parsed.channel, key: parsed.key, source: "pairing")
    }

    /// 落盘 + 存钥 + 测连接：GET /c/<channel> 回 200/204 即连接成功，
    /// 保存配置、回调重启轮询、关窗；401 等失败只提示不落盘。
    /// v0.31：落盘成功后异步领取管理钥（MgmtService.claimMgmtKey，老服务端
    /// 无此端点时静默跳过、待下次连接重试），UI 不加任何提示文案。
    private func applyConnection(server: String, channel: String, key: String, source: String) {
        PetLog.d("[onboarding] 连接流程 source=\(source) server=\(server) channel=\(channel) keyLen=\(key.count)")
        setActionsEnabled(false)
        feedback.stringValue = "连接测试中…"
        guard let url = URL(string: "\(server)/c/\(channel)") else {
            setActionsEnabled(true)
            feedback.stringValue = "连接失败：服务器地址格式不对。"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let cfg = ChannelSettings.load()
        let session = RelaySession.makeSession(proxy: cfg.proxy)
        session.dataTask(with: request) { [weak self] _, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                self.setActionsEnabled(true)
                let http = (response as? HTTPURLResponse)?.statusCode ?? -1
                if let error {
                    self.feedback.stringValue = "连接失败：\(error.localizedDescription)"
                    PetLog.d("[onboarding] 连接测试网络错误：\(error.localizedDescription)")
                    return
                }
                guard http == 200 || http == 204 else {
                    self.feedback.stringValue = http == 401
                        ? "连接失败：钥不对或通道不存在（HTTP 401），核对通道码后重试。"
                        : "连接失败：服务器返回 HTTP \(http)。"
                    PetLog.d("[onboarding] 连接测试失败 http=\(http)（未落盘）")
                    return
                }
                var newCfg = cfg
                newCfg.server = server
                newCfg.channel = channel
                ChannelSettings.save(newCfg)
                KeyFileStore.save(key: key, channel: channel)
                PetLog.d("[onboarding] 连接成功并已落盘 server=\(server) channel=\(channel)，回调重启轮询")
                // v0.31 管理钥领取：与设置页粘码连接共用同一领取点（落盘之后）
                MgmtService.claimMgmtKey(server: server, channel: channel, readKey: key, proxy: cfg.proxy)
                self.feedback.stringValue = "已连接通道「\(channel)」，宠物开始接收状态。"
                self.onConnected?()
                self.window?.close()
            }
        }.resume()
    }
}
