import AppKit
import UniformTypeIdentifiers

/// 设置窗口：通道服务器 / 通道名 / accesskey（钥匙串）/ 轮询间隔 + 测试连接 + 导出 skill 包 + 详细说明。
/// 服务器、通道名、间隔存 UserDefaults；accesskey 只进 macOS 钥匙串（见 KeychainStore）。
/// 保存后经 onSave 回调让 AppDelegate 立即重启轮询器生效。
final class SettingsWindowController: NSObject {
    var onSave: (() -> Void)?

    private var window: NSWindow?
    private var serverField: NSTextField!
    private var channelField: NSTextField!
    private var keyField: NSSecureTextField!
    private var keyHint: NSTextField!
    private var intervalPopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var exportButton: NSButton!
    private var exportHint: NSTextField!

    private static let helpText = """
    【每个字段是什么】
    · 服务器地址：通道服务的地址。宠物定时到这个地址读取最新状态。本应用不直连任何其他服务器。
    · 通道名：服务器上的一条通道，相当于一个专属信箱。写入方（例如你的 Muse）和这只宠物用同一个通道名对上头。
    · accesskey：这条通道的钥匙，读写共用同一把。只保存在这台 Mac 的系统钥匙串里，不写进应用、不打包分发、不上传到任何地方（只在向上面填写的服务器请求时作为身份凭证发送）。
    · 轮询间隔：多久去服务器看一次新状态。越短越实时、流量越大；15 秒对桌面宠物足够，流量和耗电都可以忽略。

    【默认服务器是谁的】
    默认地址 https://relay.nonzero-e3c.workers.dev 是本应用作者运营的一台通道服务器（跑在 Cloudflare 上）。你的宠物状态数据（就是一小段 JSON：状态、可选的一句消息、时间戳）会经过它中转。介意的话，完全可以换成你自己的服务器，见下一段。

    【想用自己的服务器】
    本仓库附带一个给 Muse 用的部署 skill：skill/relay-channel（SKILL.md + assets/ 里是服务端全部代码）。把它装进你自己的 Muse，然后对它说一句「用 skill/relay-channel 部署我自己的通道」，它会引导你在你自己的 Cloudflare 账号上一键部署一套同样的通道服务、建好第一条通道，并把新服务器的地址和 accesskey 交给你。把那两个值填回本设置页即可，之后数据只走你自己的服务器。为安全起见，部署时 Cloudflare 的 API token 走安全凭证流程，不要把任何密钥明文粘贴到聊天或文件里。

    【没配置会怎样】
    accesskey 留空（保存后即清除钥匙串记录）时，通道功能关闭，宠物退回纯本地手动模式：用菜单切换状态，不联网、不轮询。

    【把这条通道分享给信任的人】
    设置页下方有「导出 skill 包」：填好 accesskey 并保存后可用。导出的 zip 里装着部署 skill（对方的 Muse 装上它就能部署或对接通道）和一份 pet-channel.json（当前服务器地址、通道名与 accesskey）。拿到这个包的人可以读写你的这条通道——只发给信任的人，不要发到公开场合。
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
        let W: CGFloat = 540, H: CGFloat = 762
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
        keyField.placeholderString = "粘贴通道的 accesskey（只存本机钥匙串）"
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
            keyHint.stringValue = "钥匙串里已存有通道「\(cfg.channel)」的钥（len=\(key.count)）；清空并保存将删除它。"
        } else {
            keyField.stringValue = ""
            keyHint.stringValue = "钥匙串里暂无通道「\(cfg.channel)」的钥；留空保存则保持未配置。"
        }
        statusLabel.stringValue = "填好后可先测试连接，再保存。"
        refreshExportState()
        PetLog.d("设置窗口已载入 server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s keyPresent=\(keyField.stringValue.isEmpty ? false : true)")
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
        PetLog.d("测试连接 GET \(base)/c/\(channel)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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
                                intervalSec: interval)
        ChannelSettings.save(cfg)
        let key = keyField.stringValue
        if key.isEmpty {
            KeychainStore.delete(account: cfg.channel)
            PetLog.d("设置保存：accesskey 为空，已清除通道 \(cfg.channel) 的钥匙串记录（通道功能关闭）")
        } else {
            KeychainStore.save(key: key, account: cfg.channel)
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

    /// 刷新导出按钮可用状态：模板缺失或钥匙串无当前通道的钥时禁用。窗口打开与保存后调用。
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
            PetLog.d("导出 skill 可用 channel=\(channel)（钥在钥匙串中）")
        } else {
            exportButton.isEnabled = false
            exportHint.stringValue = "先填入 accesskey 并保存后可导出。"
            PetLog.d("导出 skill 不可用：钥匙串无通道 \(channel) 的 accesskey")
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
            statusLabel.stringValue = "导出失败：钥匙串里没有通道「\(channel)」的 accesskey，请先填写并保存。"
            PetLog.d("skill 导出失败 channel=\(channel)：钥匙串无钥")
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
                ok = runTool("/usr/bin/ditto", ["-c", "-k", "--keepParent", pkgDir.path, dest.path])
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
