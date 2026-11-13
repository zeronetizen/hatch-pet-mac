import AppKit

/// 首启引导窗（v0.18）：未配置通道+钥时由 AppDelegate 弹出，设置里也可经
/// 「重新走引导」再开。打开即 GET /status 分流：
/// - open → 领取面板（导出领取 skill 包 + 通道码粘贴连接）
/// - full → bot 面板（跳 @MusePetBot + 领取串单输入兑换）
/// - 查失败 → 提示重试，通道码粘贴与自建面板仍可用，不堵死
/// 两态常显自建面板（邮箱 → 生成带 pet-owner.json 的自建 skill 包）。
/// 连接成功 = 落盘配置 + 存钥 + 回调 AppDelegate 重启轮询，随后关窗。
/// v0.23：① /status 固定查公共中转（名额是公共中转的属性；旧逻辑跟随当前配置
/// 的服务器，已配置自建/私有中转的用户重走引导必 404）；/redeem 同理固定公共
/// 中转。② 版式收紧：品牌区 + 分组卡片（浅色圆角），窗口高度按可见分组动态
/// 计算（隐藏分组不占位），删底部「关闭」按钮（标题栏关闭钮已足够）。
final class OnboardingWindowController: NSObject {
    var onConnected: (() -> Void)?

    private var window: NSWindow?
    private var brandIcon: NSImageView!
    private var brandTitle: NSTextField!
    private var brandSub: NSTextField!
    private var statusLine: NSTextField!
    private var retryButton: NSButton!
    private var claimCard: NSBox!
    private var claimText: NSTextField!
    private var botCard: NSBox!
    private var claimStringField: NSTextField!
    private var pairingCard: NSBox!
    private var pairingField: NSTextField!
    private var selfhostCard: NSBox!
    private var emailField: NSTextField!
    private var feedback: NSTextField!
    private var actionButtons: [NSButton] = []

    // 布局常量（手动 frame；relayout 按可见分组从顶往下排并定窗高）
    private static let W: CGFloat = 560
    private static let X: CGFloat = 20
    private static var FW: CGFloat { W - 40 }
    private static let claimCardH: CGFloat = 148
    private static let botCardH: CGFloat = 120
    private static let pairingCardH: CGFloat = 80
    private static let selfhostCardH: CGFloat = 126

    func show() {
        let win = ensureWindow()
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        PetLog.d("[onboarding] 引导窗打开，开始查 /status 分流")
        fetchStatus()
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

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.W, height: 398),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "MusePet 引导"
        win.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.W, height: 398))
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

        // 名额状态行 + 重试
        statusLine = NSTextField(labelWithString: "正在查询公共中转名额…")
        statusLine.font = .systemFont(ofSize: 12, weight: .medium)
        content.addSubview(statusLine)
        retryButton = NSButton(title: "重试", target: self, action: #selector(fetchStatusTapped))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        content.addSubview(retryButton)

        // 免费通道卡片（分流 open 时显示）
        claimCard = makeCard(height: Self.claimCardH)
        claimText = NSTextField(labelWithString: "")
        claimText.font = .systemFont(ofSize: 13, weight: .medium)
        claimText.lineBreakMode = .byWordWrapping
        claimText.maximumNumberOfLines = 2
        claimText.frame = NSRect(x: 14, y: 98, width: innerW, height: 36)
        claimCard.addSubview(claimText)
        let claimBtn = NSButton(title: "导出领取 skill 包", target: self, action: #selector(exportClaim))
        claimBtn.bezelStyle = .rounded
        claimBtn.frame = NSRect(x: 14, y: 64, width: 170, height: 28)
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

        // bot 卡片（分流 full 时显示）：兑换区只有领取串单输入（v0.19 定版）
        botCard = makeCard(height: Self.botCardH)
        let botText = NSTextField(labelWithString: "免费通道的直领名额已领完，还可以从 bot 领：去宠物 bot 做几个小任务，会领到一串「领取串」，整串粘到下面兑换成免费通道：")
        botText.font = .systemFont(ofSize: 13, weight: .medium)
        botText.lineBreakMode = .byWordWrapping
        botText.maximumNumberOfLines = 2
        botText.frame = NSRect(x: 14, y: 70, width: innerW, height: 36)
        botCard.addSubview(botText)
        let botBtn = NSButton(title: "去 Telegram 领取", target: self, action: #selector(openBot))
        botBtn.bezelStyle = .rounded
        botBtn.frame = NSRect(x: 14, y: 38, width: 150, height: 28)
        botCard.addSubview(botBtn)
        actionButtons.append(botBtn)
        claimStringField = NSTextField(frame: NSRect(x: 172, y: 40, width: innerW - 172 + 14 - 98, height: 24))
        claimStringField.placeholderString = "领取串 hatchpet-code1:…（从 bot 消息整串粘贴）"
        botCard.addSubview(claimStringField)
        let claimRedeemBtn = NSButton(title: "兑换", target: self, action: #selector(redeemFromClaimString))
        claimRedeemBtn.bezelStyle = .rounded
        claimRedeemBtn.frame = NSRect(x: 14 + innerW - 90, y: 38, width: 90, height: 28)
        botCard.addSubview(claimRedeemBtn)
        actionButtons.append(claimRedeemBtn)
        let botHint = NSTextField(labelWithString: "领取串在 bot 发码的消息里，整串复制粘贴即可，不用再手填兑换码和数字 ID；兑换成功会自动连接。")
        botHint.font = .systemFont(ofSize: 11)
        botHint.textColor = .secondaryLabelColor
        botHint.frame = NSRect(x: 14, y: 14, width: innerW, height: 16)
        botCard.addSubview(botHint)
        content.addSubview(botCard)
        claimCard.isHidden = true
        botCard.isHidden = true

        // 通道码卡片（两态常显，三路共同收尾）
        pairingCard = makeCard(height: Self.pairingCardH)
        let pairLabel = NSTextField(labelWithString: "通道码")
        pairLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pairLabel.frame = NSRect(x: 14, y: 48, width: 200, height: 18)
        pairingCard.addSubview(pairLabel)
        pairingField = NSTextField(frame: NSRect(x: 14, y: 16, width: innerW - 120, height: 24))
        pairingField.placeholderString = "hatchpet1:…（粘贴整串）"
        pairingCard.addSubview(pairingField)
        let connectBtn = NSButton(title: "连接", target: self, action: #selector(connectFromPairing))
        connectBtn.bezelStyle = .rounded
        connectBtn.bezelColor = .controlAccentColor // 主按钮：强调色突出
        connectBtn.frame = NSRect(x: 14 + innerW - 110, y: 14, width: 110, height: 28)
        pairingCard.addSubview(connectBtn)
        actionButtons.append(connectBtn)
        content.addSubview(pairingCard)

        // 自建通道卡片（两态常显）
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

    /// 按当前可见分组从顶往下排版并定窗高：隐藏的主卡片不占位，
    /// 失败/未分流态窗口自动收矮，不留大片空白。调整窗高时锚定顶边。
    private func relayout() {
        guard let win = window, let content = win.contentView else { return }
        let mainH: CGFloat = !claimCard.isHidden ? Self.claimCardH : (!botCard.isHidden ? Self.botCardH : 0)
        var H: CGFloat = 18 + 56 + 10 + 26 + 12 + Self.pairingCardH + 12 + Self.selfhostCardH + 10 + 30 + 16
        if mainH > 0 { H += mainH + 12 }
        var frame = win.frame
        if abs(frame.height - H) > 0.5 || abs(frame.width - Self.W) > 0.5 {
            let topEdge = frame.maxY
            frame.size = NSSize(width: Self.W, height: H)
            frame.origin.y = topEdge - H
            win.setFrame(frame, display: true, animate: false)
        }
        content.frame = NSRect(x: 0, y: 0, width: Self.W, height: H)
        var top = H - 18 // 距顶游标：每放一段减去其高度
        // 品牌区（高 56）
        brandIcon.frame = NSRect(x: Self.X, y: top - 50, width: 44, height: 44)
        brandTitle.frame = NSRect(x: Self.X + 56, y: top - 24, width: Self.FW - 56, height: 24)
        brandSub.frame = NSRect(x: Self.X + 56, y: top - 56, width: Self.FW - 56, height: 32)
        top -= 56 + 10
        // 状态行（高 26）
        statusLine.frame = NSRect(x: Self.X, y: top - 22, width: Self.FW - 92, height: 18)
        retryButton.frame = NSRect(x: Self.X + Self.FW - 80, y: top - 26, width: 80, height: 26)
        top -= 26 + 12
        // 主卡片（可见才占位）
        if !claimCard.isHidden {
            claimCard.frame = NSRect(x: Self.X, y: top - Self.claimCardH, width: Self.FW, height: Self.claimCardH)
            top -= Self.claimCardH + 12
        }
        if !botCard.isHidden {
            botCard.frame = NSRect(x: Self.X, y: top - Self.botCardH, width: Self.FW, height: Self.botCardH)
            top -= Self.botCardH + 12
        }
        pairingCard.frame = NSRect(x: Self.X, y: top - Self.pairingCardH, width: Self.FW, height: Self.pairingCardH)
        top -= Self.pairingCardH + 12
        selfhostCard.frame = NSRect(x: Self.X, y: top - Self.selfhostCardH, width: Self.FW, height: Self.selfhostCardH)
        top -= Self.selfhostCardH + 10
        feedback.frame = NSRect(x: Self.X, y: top - 30, width: Self.FW, height: 30)
    }

    @objc private func fetchStatusTapped() { fetchStatus() }

    private func setActionsEnabled(_ on: Bool) {
        actionButtons.forEach { $0.isEnabled = on }
    }

    // MARK: - /status 分流

    private func fetchStatus() {
        let cfg = ChannelSettings.load()
        // v0.23：名额是公共中转的属性，固定查公共中转的 /status，与当前配置的
        // 服务器无关（旧逻辑查已配置服务器，自建/私有中转没有此接口必 404）；
        // 代理仍可用当前配置的 proxy。
        let base = ChannelSettings.defaultServer
        statusLine.stringValue = "正在查询公共中转名额…"
        retryButton.isHidden = true
        claimCard.isHidden = true
        botCard.isHidden = true
        relayout()
        PetLog.d("[onboarding] GET \(base)/status 查公共中取名额分流（固定公共中转，与当前配置服务器无关）")
        guard let url = URL(string: "\(base)/status") else {
            statusLine.stringValue = "查不到名额（网络或服务异常），点重试；已有通道码可直接在下面连接。"
            retryButton.isHidden = false
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let session = RelaySession.makeSession(proxy: cfg.proxy)
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                let http = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard error == nil, http == 200, let data,
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let state = obj["state"] as? String else {
                    self.statusLine.stringValue = "查不到名额（网络或服务异常），点重试；已有通道码可直接在下面连接。"
                    self.retryButton.isHidden = false
                    PetLog.d("[onboarding] 公共中转 /status 失败 http=\(http) err=\(error?.localizedDescription ?? "-")（降级：通道码/自建仍可用）")
                    return
                }
                let left = (obj["free_left"] as? NSNumber)?.intValue ?? 0
                if state == "open" {
                    self.statusLine.stringValue = "免费通道：有名额"
                    self.claimText.stringValue = "免费通道还有名额（剩余 \(left) 个），用领取 skill 让智能体帮你领一条免费通道："
                    self.claimCard.isHidden = false
                    PetLog.d("[onboarding] 分流=open free_left=\(left)，显示免费通道领取面板")
                } else {
                    self.statusLine.stringValue = "免费通道：直领名额已满"
                    self.botCard.isHidden = false
                    PetLog.d("[onboarding] 分流=full，显示 bot 面板")
                }
                self.relayout()
            }
        }.resume()
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

    @objc private func openBot() {
        PetLog.d("[onboarding] 打开 https://t.me/MusePetBot")
        NSWorkspace.shared.open(URL(string: "https://t.me/MusePetBot")!)
    }

    // MARK: - 兑换

    /// 唯一入口：领取串单输入。解码校验全过才发请求；串不对只提示、不发网络。
    /// 校验过后 POST /redeem {code, tgId}，201 后沿用连接流程自动落盘。
    @objc private func redeemFromClaimString() {
        let raw = claimStringField.stringValue
        guard let parsed = ClaimString.parse(raw) else {
            feedback.stringValue = "这串不完整或不是领取串：应是 hatchpet-code1: 开头的一整串，从 bot 消息里整串复制、不要改动。"
            return
        }
        performRedeem(code: parsed.code, tgIdJSON: parsed.tgId)
    }

    private func performRedeem(code: String, tgIdJSON: Any) {
        let cfg = ChannelSettings.load()
        // v0.23：领取串是公共中转发码、公共中转兑换，与 /status 同理固定公共
        // 中转，不跟随当前配置的服务器（自建中转没有 /redeem 接口）。
        let base = ChannelSettings.defaultServer
        guard let url = URL(string: "\(base)/redeem") else { return }
        PetLog.d("[redeem] POST \(base)/redeem codeLen=\(code.count)（固定公共中转；码与 ID 不记日志）")
        setActionsEnabled(false)
        feedback.stringValue = "兑换中…"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["code": code, "tgId": tgIdJSON]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let session = RelaySession.makeSession(proxy: cfg.proxy)
        session.dataTask(with: request) { [weak self] data, response, error in
            session.finishTasksAndInvalidate()
            DispatchQueue.main.async {
                guard let self else { return }
                self.setActionsEnabled(true)
                let http = (response as? HTTPURLResponse)?.statusCode ?? -1
                if let error {
                    self.feedback.stringValue = "兑换失败：\(error.localizedDescription)"
                    PetLog.d("[redeem] 兑换网络错误：\(error.localizedDescription)")
                    return
                }
                let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                if http == 201, let channel = obj?["channel"] as? String,
                   let key = obj?["key"] as? String, !channel.isEmpty, !key.isEmpty {
                    PetLog.d("[redeem] 兑换成功 channel=\(channel) keyLen=\(key.count)，自动走连接流程")
                    self.applyConnection(server: base, channel: channel, key: key, source: "redeem")
                    return
                }
                let errCode = obj?["error"] as? String ?? ""
                self.feedback.stringValue = Self.redeemErrorText(errCode, http: http,
                                                                 channel: obj?["channel"] as? String)
                PetLog.d("[redeem] 兑换失败 http=\(http) error=\(errCode)")
            }
        }.resume()
    }

    /// PROTOCOL /redeem 错误码 → 人话
    static func redeemErrorText(_ code: String, http: Int, channel: String?) -> String {
        switch code {
        case "code_not_found": return "兑换失败：这个码不存在或已经被用掉了，回 bot 核对或重新领一个。"
        case "code_expired": return "兑换失败：兑换码已过期（有效期 24 小时），回 bot 重新领一个新码。"
        case "code_revoked": return "兑换失败：这个码已被作废，回 bot 重新领一个。"
        case "tg_mismatch": return "兑换失败：这串领取串不是发给你的账号的（码与账号不匹配），回 bot 用你自己的账号重新领一串。"
        case "already_claimed": return "这个 Telegram 账号已经领过通道了（一号一领）\(channel.map { "：\($0)" } ?? "")。请用当初的通道码连接。"
        case "rate_limited": return "兑换失败：太频繁了，过一会儿再试。"
        case "busy": return "兑换失败：服务器繁忙，过一会儿再试。"
        case "bad_request", "bad_json": return "兑换失败：领取串内容格式不对，整串重新复制后重试。"
        case "too_large": return "兑换失败：请求异常（too_large），请重试。"
        default: return "兑换失败：服务器返回 HTTP \(http)\(code.isEmpty ? "" : "（\(code)）")。"
        }
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
                self.feedback.stringValue = "已连接通道「\(channel)」，宠物开始接收状态。"
                self.onConnected?()
                self.window?.close()
            }
        }.resume()
    }
}
