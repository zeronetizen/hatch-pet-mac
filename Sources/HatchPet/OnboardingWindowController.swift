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
/// v0.24：① 修品牌标题被窗口顶边裁切——relayout 旧实现把 win.frame 高（含
/// 标题栏约 28pt）直接当 content 高用，内容整体上移一个标题栏、标题上半截被
/// 吃掉；改用 frameRect(forContentRect:) 换算，并把顶距放宽到 22pt。② 代理
/// 链路核对与可见化：存储键/设置页保存/读取/fetchStatus 传参/makeSession 的
/// CFNetwork 字典五段在代码上全对得上，断点在字典被 CFNetwork 真正执行这一
/// 步 App 侧不可观测（且本机 TUN 会兜底掩盖其他流量）——引导页状态行下新增
/// 代理配置行，与 ChannelSettings 同一份存储、预填现值、改完即存即重查，
/// 每次查询尝试都把 via=proxy(host:port)/direct 与结果记进日志，走没走代理
/// 从此有据可查。③ /status 与 /redeem 韧性兜底：先走已保存代理（主路），没
/// 拿到服务器有效应答且首试确实走了代理时，自动直连重试一次；两次都失败才
/// 进失败态，失败文案主句后以小字附最终错误诊断（HTTP 码或错误域+码）。
final class OnboardingWindowController: NSObject, NSTextFieldDelegate {
    var onConnected: (() -> Void)?

    private var window: NSWindow?
    private var brandIcon: NSImageView!
    private var brandTitle: NSTextField!
    private var brandSub: NSTextField!
    private var statusLine: NSTextField!
    private var retryButton: NSButton!
    private var proxyCheckbox: NSButton!
    private var proxyTypePopup: NSPopUpButton!
    private var proxyHostField: NSTextField!
    private var proxyPortField: NSTextField!
    private var proxyHint: NSTextField!
    /// 预填代理行时为真，屏蔽「改动即存即重查」（只认用户真实编辑）
    private var isPrefillingProxy = false
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
    /// /status 失败态时状态行多出一行小字诊断，状态段额外高度（0 = 单行）
    private var statusDetailH: CGFloat = 0

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
        statusLine.lineBreakMode = .byWordWrapping
        statusLine.maximumNumberOfLines = 2 // 失败态第二行是小字诊断（见 showStatusFailure）
        content.addSubview(statusLine)
        retryButton = NSButton(title: "重试", target: self, action: #selector(fetchStatusTapped))
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        content.addSubview(retryButton)

        // 代理配置行（v0.24）：与 ChannelSettings 同一份存储——首启未配置用户
        // 唯一的代理入口，也是核对「查询到底走没走已保存代理」的可见入口。
        // 字段与归一化口径同设置页（proxyFromFields 一套），改动即存即重查。
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
        proxyHint = NSTextField(labelWithString: "查不到名额？挂代理的用户先在这里填代理——与设置页同一份配置，改完自动重新查询。")
        proxyHint.font = .systemFont(ofSize: 11)
        proxyHint.textColor = .secondaryLabelColor
        content.addSubview(proxyHint)
        prefillProxyRow()

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
    /// v0.24 修裁切：这里算出的 H 是 **content 高**，窗口 frame 高还要加上标题
    /// 栏（约 28pt），必须用 frameRect(forContentRect:) 换算——旧实现直接拿
    /// frame 高当 content 高、又把 content.frame 强设为该高度，内容被整体上移
    /// 一个标题栏，品牌标题的上半截被窗口顶边吃掉。content 的实际尺寸由窗口
    /// 按 contentRect 自动给定，本函数也不再手动赋 content.frame。
    /// 各段高度与卡内子视图已逐项核对：品牌区 56（图标 44 + 上下留白 6/6，
    /// 标题行 22 + 副文案 32 + 间隔 2）；状态段 26（+失败诊断行时 +15）；
    /// 代理行 46（控件行 26 + 间隔 4 + 提示行 16）；免费卡 148
    /// （14+36+6+28+6+44+14）、bot 卡 120（14+36+4+28+8+16+14）、
    /// 通道码卡 80（14+18+8+26+14）、自建卡 126（14+18+6+26+8+40+14），
    /// 均与 ensureWindow 里的子视图 frame 一一对应，不重叠不裁切。
    private func relayout() {
        guard let win = window else { return }
        let mainH: CGFloat = !claimCard.isHidden ? Self.claimCardH : (!botCard.isHidden ? Self.botCardH : 0)
        let statusH: CGFloat = 26 + statusDetailH
        var contentH: CGFloat = 22 + 56 + 10 + statusH + 12 + 46 + 12 + Self.pairingCardH + 12 + Self.selfhostCardH + 10 + 30 + 16
        if mainH > 0 { contentH += mainH + 12 }
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
        top -= 56 + 10
        // 状态行（高 26，失败诊断行再 +15）
        statusLine.frame = NSRect(x: Self.X, y: top - (22 + statusDetailH), width: Self.FW - 92, height: 18 + statusDetailH)
        retryButton.frame = NSRect(x: Self.X + Self.FW - 80, y: top - 26, width: 80, height: 26)
        top -= statusH + 12
        // 代理行（高 46：控件行 26 + 间隔 4 + 提示行 16）
        proxyCheckbox.frame = NSRect(x: Self.X, y: top - 25, width: 88, height: 24)
        proxyTypePopup.frame = NSRect(x: Self.X + 92, y: top - 26, width: 92, height: 26)
        proxyHostField.frame = NSRect(x: Self.X + 192, y: top - 25, width: 224, height: 24)
        proxyPortField.frame = NSRect(x: Self.X + 424, y: top - 25, width: 96, height: 24)
        proxyHint.frame = NSRect(x: Self.X, y: top - 46, width: Self.FW, height: 16)
        top -= 46 + 12
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
        statusDetailH = 0
        relayout()
        guard let url = URL(string: "\(base)/status") else {
            showStatusFailure(http: -1, error: nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        statusAttempt(request: request, proxy: cfg.proxy, isRetry: false)
    }

    /// /status 单次尝试。v0.24 韧性：首试按配置 proxy；没解析出有效应答且首试
    /// 确实走了代理时，自动直连（ProxyConfig.disabled）重试一次；两次都失败
    /// 才进失败态。两次尝试的 url/代理与否/http/err 都记日志。
    private func statusAttempt(request: URLRequest, proxy: ProxyConfig, isRetry: Bool) {
        let n = isRetry ? 2 : 1
        let via = isRetry ? "direct（直连重试）" : (proxy.isActive ? "proxy(\(proxy.summary))" : "direct")
        PetLog.d("[onboarding] GET \(request.url?.absoluteString ?? "-") 查公共中取名额 attempt=\(n) via=\(via)")
        sendOnce(request, proxy: isRetry ? .disabled : proxy) { [weak self] data, http, error in
            guard let self else { return }
            let parsed = Self.parseStatus(data, http, error)
            PetLog.d("[onboarding] /status attempt=\(n) 结果 http=\(http) err=\(Self.errDesc(error)) parsed=\(parsed != nil)")
            if parsed == nil, !isRetry, proxy.isActive {
                PetLog.d("[onboarding] /status 经代理未拿到有效应答，自动直连重试一次")
                self.statusAttempt(request: request, proxy: proxy, isRetry: true)
                return
            }
            DispatchQueue.main.async {
                guard let parsed else {
                    self.showStatusFailure(http: http, error: error)
                    return
                }
                self.statusDetailH = 0
                if parsed.state == "open" {
                    self.statusLine.stringValue = "免费通道：有名额"
                    self.claimText.stringValue = "免费通道还有名额（剩余 \(parsed.left) 个），用领取 skill 让智能体帮你领一条免费通道："
                    self.claimCard.isHidden = false
                    PetLog.d("[onboarding] 分流=open free_left=\(parsed.left)，显示免费通道领取面板")
                } else {
                    self.statusLine.stringValue = "免费通道：直领名额已满"
                    self.botCard.isHidden = false
                    PetLog.d("[onboarding] 分流=full，显示 bot 面板")
                }
                self.relayout()
            }
        }
    }

    /// /status 失败态：主句保持简短，其后第二行小字附最终一次尝试的错误诊断。
    private func showStatusFailure(http: Int, error: Error?) {
        let main = "查不到名额（网络或服务异常），点重试；已有通道码可直接在下面连接。"
        let attr = NSMutableAttributedString(string: main, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        attr.append(NSAttributedString(string: "\n\(Self.failureDetail(http: http, error: error))", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        statusLine.attributedStringValue = attr
        statusDetailH = 15
        retryButton.isHidden = false
        relayout()
        PetLog.d("[onboarding] 公共中转 /status 失败（最终）http=\(http) err=\(Self.errDesc(error))（降级：通道码/自建仍可用）")
    }

    // MARK: - 公共中转请求小工具

    /// 发一次请求并回报 (data, http, error)；会话用完即弃。
    private func sendOnce(_ request: URLRequest, proxy: ProxyConfig,
                          completion: @escaping (Data?, Int, Error?) -> Void) {
        let session = RelaySession.makeSession(proxy: proxy)
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            completion(data, (response as? HTTPURLResponse)?.statusCode ?? -1, error)
        }.resume()
    }

    /// /status 有效应答解析：200 + JSON 含 state 才算拿到服务器应答。
    private static func parseStatus(_ data: Data?, _ http: Int, _ error: Error?) -> (state: String, left: Int)? {
        guard error == nil, http == 200, let data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = obj["state"] as? String else { return nil }
        return (state, (obj["free_left"] as? NSNumber)?.intValue ?? 0)
    }

    /// 日志用错误描述：域/码 + 本地化说明。
    private static func errDesc(_ error: Error?) -> String {
        guard let error else { return "-" }
        let ns = error as NSError
        return "\(ns.domain)/\(ns.code) \(error.localizedDescription)"
    }

    /// 失败文案的小字诊断：（HTTP 503）或（错误域 码）；两者皆无则（无响应）。
    private static func failureDetail(http: Int, error: Error?) -> String {
        if let error {
            let ns = error as NSError
            return "（\(ns.domain) \(ns.code)）"
        }
        return http > 0 ? "（HTTP \(http)）" : "（无响应）"
    }

    /// feedback 用文案：主句 + 其后小字诊断（同行拼接）。
    private static func feedbackText(main: String, detail: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: main, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
        ])
        attr.append(NSAttributedString(string: " \(detail)", attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return attr
    }

    // MARK: - 代理行（引导页内嵌，与 ChannelSettings 同一份存储）

    /// 预填已保存的代理值（建窗时调一次；预填不触发保存/重查）
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

    /// 代理主机/端口编辑结束（回车或失焦）即保存 + 重查
    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isPrefillingProxy, let field = obj.object as? NSTextField,
              field === proxyHostField || field === proxyPortField else { return }
        applyProxyFromRow()
    }

    /// 存回同一份 ChannelSettings 存储（只换 proxy，服务器/通道/间隔以已保存
    /// 值为准，不碰其他字段），随即用新代理重新查名额。
    private func applyProxyFromRow() {
        var cfg = ChannelSettings.load()
        cfg.proxy = proxyFromRow()
        ChannelSettings.save(cfg)
        PetLog.d("[onboarding] 代理行改动已保存 proxy=\(cfg.proxy.summary)，自动重新查名额")
        fetchStatus()
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
        redeemAttempt(request: request, proxy: cfg.proxy, base: base, isRetry: false)
    }

    /// /redeem 单次尝试。v0.24 韧性与 /status 同口径：首试走已保存代理（主
    /// 路）；拿到服务器应答（201 成功或带业务 error 的 JSON）即为定论、不重
    /// 试——避免一次性领取码被无谓重复提交；只有传输层失败/无应答（如代理异
    /// 常、CF 边缘错误页）且首试确实走了代理时，才自动直连重试一次。两次都
    /// 没拿到应答才报网络失败，主句后以小字附最终错误诊断。
    private func redeemAttempt(request: URLRequest, proxy: ProxyConfig, base: String, isRetry: Bool) {
        let n = isRetry ? 2 : 1
        let via = isRetry ? "direct（直连重试）" : (proxy.isActive ? "proxy(\(proxy.summary))" : "direct")
        PetLog.d("[redeem] attempt=\(n) via=\(via) url=\(request.url?.absoluteString ?? "-")")
        sendOnce(request, proxy: isRetry ? .disabled : proxy) { [weak self] data, http, error in
            guard let self else { return }
            let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let channel = obj?["channel"] as? String
            let key = obj?["key"] as? String
            let succeeded = http == 201 && channel.map { !$0.isEmpty } == true && key.map { !$0.isEmpty } == true
            // 「服务器应答」= 无传输错误且回了可解析 JSON（成功或业务错误都算）
            let answered = error == nil && obj != nil
            PetLog.d("[redeem] attempt=\(n) 结果 http=\(http) err=\(Self.errDesc(error)) answered=\(answered) ok=\(succeeded) error=\((obj?["error"] as? String) ?? "-")")
            if !answered, !isRetry, proxy.isActive {
                PetLog.d("[redeem] 经代理未拿到服务器应答，自动直连重试一次")
                self.redeemAttempt(request: request, proxy: proxy, base: base, isRetry: true)
                return
            }
            DispatchQueue.main.async {
                self.setActionsEnabled(true)
                if succeeded, let channel, let key {
                    PetLog.d("[redeem] 兑换成功 channel=\(channel) keyLen=\(key.count)，自动走连接流程")
                    self.applyConnection(server: base, channel: channel, key: key, source: "redeem")
                    return
                }
                if answered {
                    let errCode = obj?["error"] as? String ?? ""
                    self.feedback.stringValue = Self.redeemErrorText(errCode, http: http, channel: channel)
                    PetLog.d("[redeem] 兑换失败 http=\(http) error=\(errCode)")
                    return
                }
                self.feedback.attributedStringValue = Self.feedbackText(
                    main: "兑换失败：网络异常，请稍后重试。",
                    detail: Self.failureDetail(http: http, error: error))
                PetLog.d("[redeem] 兑换网络失败（未拿到服务器应答）最终 http=\(http) err=\(Self.errDesc(error))")
            }
        }
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
