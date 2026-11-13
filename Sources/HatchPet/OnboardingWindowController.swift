import AppKit

/// 首启引导窗（v0.18）：未配置通道+钥时由 AppDelegate 弹出，设置里也可经
/// 「重新走引导」再开。打开即 GET /status 分流：
/// - open → 领取面板（导出领取 skill 包 + 通道码粘贴连接）
/// - full → bot 面板（跳 @hatchPetBot + 领取串单输入兑换）
/// - 查失败 → 提示重试，通道码粘贴与自建面板仍可用，不堵死
/// 两态常显自建面板（邮箱 → 生成带 pet-owner.json 的自建 skill 包）。
/// 连接成功 = 落盘配置 + 存钥 + 回调 AppDelegate 重启轮询，随后关窗。
final class OnboardingWindowController: NSObject {
    var onConnected: (() -> Void)?

    private var window: NSWindow?
    private var statusLine: NSTextField!
    private var retryButton: NSButton!
    private var claimGroup: NSView!
    private var claimText: NSTextField!
    private var botGroup: NSView!
    private var claimStringField: NSTextField!
    private var pairingField: NSTextField!
    private var emailField: NSTextField!
    private var feedback: NSTextField!
    private var actionButtons: [NSButton] = []

    func show() {
        let win = ensureWindow()
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        PetLog.d("[onboarding] 引导窗打开，开始查 /status 分流")
        fetchStatus()
    }

    // MARK: - 构建（固定布局，手动 frame，与设置窗同一套路）

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let W: CGFloat = 560, H: CGFloat = 580
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "MusePet 引导"
        win.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        win.contentView = content
        let X: CGFloat = 20, FW: CGFloat = W - 40
        var cursor = H - 20

        let title = NSTextField(labelWithString: "欢迎使用 MusePet")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.frame = NSRect(x: X, y: cursor - 24, width: FW, height: 24)
        content.addSubview(title)
        cursor -= 32
        let intro = NSTextField(labelWithString: "这只宠物会显示你的智能体正在干什么。它需要一条中转通道才能收到状态，下面选一条路拿到通道即可。")
        intro.font = .systemFont(ofSize: 12)
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 2
        intro.frame = NSRect(x: X, y: cursor - 30, width: FW, height: 30)
        content.addSubview(intro)
        cursor -= 38

        statusLine = NSTextField(labelWithString: "正在查询公共中转名额…")
        statusLine.font = .systemFont(ofSize: 12, weight: .medium)
        statusLine.frame = NSRect(x: X, y: cursor - 18, width: FW - 90, height: 18)
        content.addSubview(statusLine)
        retryButton = NSButton(title: "重试", target: self, action: #selector(fetchStatusTapped))
        retryButton.bezelStyle = .rounded
        retryButton.frame = NSRect(x: X + FW - 80, y: cursor - 24, width: 80, height: 26)
        retryButton.isHidden = true
        content.addSubview(retryButton)
        cursor -= 28

        // 主面板区（领取 / bot 两组同框，按分流结果切换可见性）
        let groupFrame = NSRect(x: X, y: cursor - 148, width: FW, height: 148)
        claimGroup = NSView(frame: groupFrame)
        botGroup = NSView(frame: groupFrame)
        content.addSubview(claimGroup)
        content.addSubview(botGroup)
        // 领取组
        claimText = NSTextField(labelWithString: "")
        claimText.font = .systemFont(ofSize: 13, weight: .medium)
        claimText.lineBreakMode = .byWordWrapping
        claimText.maximumNumberOfLines = 2
        claimText.frame = NSRect(x: 0, y: 106, width: FW, height: 36)
        claimGroup.addSubview(claimText)
        let claimBtn = NSButton(title: "导出领取 skill 包", target: self, action: #selector(exportClaim))
        claimBtn.bezelStyle = .rounded
        claimBtn.frame = NSRect(x: 0, y: 66, width: 170, height: 28)
        claimGroup.addSubview(claimBtn)
        actionButtons.append(claimBtn)
        let claimHint = NSTextField(labelWithString: "把导出的包交给你的智能体，它领到免费通道后会给你一个通道码，粘到下方通道码框点「连接」即可。")
        claimHint.font = .systemFont(ofSize: 11)
        claimHint.textColor = .secondaryLabelColor
        claimHint.lineBreakMode = .byWordWrapping
        claimHint.maximumNumberOfLines = 3
        claimHint.frame = NSRect(x: 0, y: 6, width: FW, height: 44)
        claimGroup.addSubview(claimHint)
        // bot 组：兑换区只有领取串单输入（v0.19 定版，不再手填兑换码/数字 ID）
        let botText = NSTextField(labelWithString: "免费通道的直领名额已领完，还可以从 bot 领：去宠物 bot 做几个小任务，会领到一串「领取串」，整串粘到下面兑换成免费通道：")
        botText.font = .systemFont(ofSize: 13, weight: .medium)
        botText.lineBreakMode = .byWordWrapping
        botText.maximumNumberOfLines = 2
        botText.frame = NSRect(x: 0, y: 106, width: FW, height: 36)
        botGroup.addSubview(botText)
        let botBtn = NSButton(title: "去 Telegram 领取", target: self, action: #selector(openBot))
        botBtn.bezelStyle = .rounded
        botBtn.frame = NSRect(x: 0, y: 68, width: 160, height: 28)
        botGroup.addSubview(botBtn)
        actionButtons.append(botBtn)
        claimStringField = NSTextField(frame: NSRect(x: 0, y: 30, width: FW - 100, height: 24))
        claimStringField.placeholderString = "领取串 hatchpet-code1:…（从 bot 消息整串粘贴）"
        botGroup.addSubview(claimStringField)
        let claimRedeemBtn = NSButton(title: "兑换", target: self, action: #selector(redeemFromClaimString))
        claimRedeemBtn.bezelStyle = .rounded
        claimRedeemBtn.frame = NSRect(x: FW - 90, y: 28, width: 90, height: 28)
        botGroup.addSubview(claimRedeemBtn)
        actionButtons.append(claimRedeemBtn)
        let botHint = NSTextField(labelWithString: "领取串在 bot 发码的消息里，整串复制粘贴即可，不用再手填兑换码和数字 ID；兑换成功会自动连接。")
        botHint.font = .systemFont(ofSize: 11)
        botHint.textColor = .secondaryLabelColor
        botHint.frame = NSRect(x: 0, y: 6, width: FW, height: 16)
        botGroup.addSubview(botHint)
        claimGroup.isHidden = true
        botGroup.isHidden = true
        cursor -= 156

        // 通道码（两态常显，三路共同收尾）
        let pairLabel = NSTextField(labelWithString: "通道码")
        pairLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pairLabel.frame = NSRect(x: X, y: cursor - 18, width: 120, height: 18)
        content.addSubview(pairLabel)
        cursor -= 24
        pairingField = NSTextField(frame: NSRect(x: X, y: cursor - 24, width: FW - 120, height: 24))
        pairingField.placeholderString = "hatchpet1:…（粘贴整串）"
        content.addSubview(pairingField)
        let connectBtn = NSButton(title: "连接", target: self, action: #selector(connectFromPairing))
        connectBtn.bezelStyle = .rounded
        connectBtn.frame = NSRect(x: X + FW - 110, y: cursor - 26, width: 110, height: 28)
        content.addSubview(connectBtn)
        actionButtons.append(connectBtn)
        cursor -= 36

        let sep = NSBox(frame: NSRect(x: X, y: cursor - 2, width: FW, height: 1))
        sep.boxType = .separator
        content.addSubview(sep)
        cursor -= 12

        // 自建面板（两态常显，弱化）
        let selfTitle = NSTextField(labelWithString: "自建通道（可选）")
        selfTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        selfTitle.frame = NSRect(x: X, y: cursor - 18, width: 200, height: 18)
        content.addSubview(selfTitle)
        cursor -= 26
        emailField = NSTextField(frame: NSRect(x: X, y: cursor - 24, width: FW - 190, height: 24))
        emailField.placeholderString = "你的邮箱（用于注册/登录 Cloudflare）"
        content.addSubview(emailField)
        let genBtn = NSButton(title: "生成自建 skill 包", target: self, action: #selector(exportSelfhost))
        genBtn.bezelStyle = .rounded
        genBtn.frame = NSRect(x: X + FW - 180, y: cursor - 26, width: 180, height: 28)
        content.addSubview(genBtn)
        actionButtons.append(genBtn)
        cursor -= 34
        let selfNote = NSTextField(labelWithString: "自建通道的数据存在你自己的 Cloudflare、不占免费通道名额。把生成的包交给你的智能体，它会凭邮箱引导你完成部署；部署完把通道码粘回上面即可。")
        selfNote.font = .systemFont(ofSize: 11)
        selfNote.textColor = .secondaryLabelColor
        selfNote.lineBreakMode = .byWordWrapping
        selfNote.maximumNumberOfLines = 3
        selfNote.frame = NSRect(x: X, y: cursor - 40, width: FW, height: 40)
        content.addSubview(selfNote)
        cursor -= 48

        feedback = NSTextField(labelWithString: "")
        feedback.font = .systemFont(ofSize: 12)
        feedback.lineBreakMode = .byWordWrapping
        feedback.maximumNumberOfLines = 2
        feedback.frame = NSRect(x: X, y: cursor - 32, width: FW - 110, height: 32)
        content.addSubview(feedback)
        let closeBtn = NSButton(title: "关闭", target: self, action: #selector(closeTapped))
        closeBtn.bezelStyle = .rounded
        closeBtn.frame = NSRect(x: X + FW - 100, y: cursor - 34, width: 100, height: 30)
        content.addSubview(closeBtn)

        self.window = win
        return win
    }

    @objc private func closeTapped() { window?.close() }
    @objc private func fetchStatusTapped() { fetchStatus() }

    private func setActionsEnabled(_ on: Bool) {
        actionButtons.forEach { $0.isEnabled = on }
    }

    // MARK: - /status 分流

    private func fetchStatus() {
        let cfg = ChannelSettings.load()
        let base = cfg.baseURL
        statusLine.stringValue = "正在查询公共中转名额…"
        retryButton.isHidden = true
        claimGroup.isHidden = true
        botGroup.isHidden = true
        PetLog.d("[onboarding] GET \(base)/status 查名额分流")
        guard let url = URL(string: "\(base)/status") else {
            statusLine.stringValue = "服务器地址格式不对，无法查询名额。"
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
                    self.statusLine.stringValue = "查不到名额状态（\(error?.localizedDescription ?? "HTTP \(http)")）。网络恢复后点重试；已有通道码可以直接粘到下面连接。"
                    self.retryButton.isHidden = false
                    PetLog.d("[onboarding] /status 失败 http=\(http) err=\(error?.localizedDescription ?? "-")（降级：通道码/自建仍可用）")
                    return
                }
                let left = (obj["free_left"] as? NSNumber)?.intValue ?? 0
                if state == "open" {
                    self.statusLine.stringValue = "免费通道：有名额"
                    self.claimText.stringValue = "免费通道还有名额（剩余 \(left) 个），用领取 skill 让智能体帮你领一条免费通道："
                    self.claimGroup.isHidden = false
                    PetLog.d("[onboarding] 分流=open free_left=\(left)，显示免费通道领取面板")
                } else {
                    self.statusLine.stringValue = "免费通道：直领名额已满"
                    self.botGroup.isHidden = false
                    PetLog.d("[onboarding] 分流=full，显示 bot 面板")
                }
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
        PetLog.d("[onboarding] 打开 https://t.me/hatchPetBot")
        NSWorkspace.shared.open(URL(string: "https://t.me/hatchPetBot")!)
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
        let base = cfg.baseURL
        guard let url = URL(string: "\(base)/redeem") else { return }
        PetLog.d("[redeem] POST \(base)/redeem codeLen=\(code.count)（码与 ID 不记日志）")
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
