import AppKit

/// 应用装配：日志 → 资源体检 → 渲染器 → 悬浮窗 → 状态机 → 菜单栏 → 通道轮询
/// → 气泡 → 设置窗口 → 系统事件。
/// 持久化（UserDefaults）：窗口位置（原点）、尺寸、触摸穿透开关、通道配置
/// （服务器/通道名/间隔，见 ChannelSettings）；accesskey 存本机钥文件
/// （~/Library/Application Support/HatchPet/keys/，600，见 KeyFileStore）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PetPanel!
    private var renderer: PetVideoRenderer!
    private var menuController: StatusMenuController!
    private let stateMachine = StateMachine()
    private let poller = ChannelPoller()
    private let bubble = BubbleController()
    private let settingsController = SettingsWindowController()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var staleTimer: Timer?
    private var dimmed = false

    private enum DefaultsKey {
        static let size = "pet.size"
        static let originX = "pet.originX"
        static let originY = "pet.originY"
        static let hasOrigin = "pet.hasOrigin"
        static let clickThrough = "pet.clickThrough"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetLog.setup()
        PetLog.d("HatchPet 启动（v0.2 通道版） bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier)")
        NSApp.setActivationPolicy(.accessory)

        // 资源体检：5 个视频逐个定位并记日志，缺失一眼可见
        for state in PetState.allCases {
            _ = ResourceLocator.videoURL(for: state)
        }

        let defaults = UserDefaults.standard
        let savedSize = defaults.object(forKey: DefaultsKey.size) as? Int
        let size = CGFloat(savedSize ?? 160)

        renderer = PetVideoRenderer()
        renderer.onPlayToEnd = { [weak self] in
            self?.stateMachine.handlePlaybackFinished()
        }

        panel = PetPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size))
        panel.contentView = renderer.contentView
        restorePosition(size: size)
        let clickThrough = defaults.bool(forKey: DefaultsKey.clickThrough)
        panel.ignoresMouseEvents = clickThrough
        panel.orderFrontRegardless()
        (renderer.contentView as? PetContentView)?.dragger.onDragEnd = { [weak self] in
            guard let self else { return }
            self.savePosition()
            self.bubble.repositionIfVisible()
        }

        stateMachine.onApply = { [weak self] state, _ in
            guard let self else { return }
            self.renderer.play(state: state)
            self.menuController.currentState = state
        }

        menuController = StatusMenuController()
        menuController.currentState = stateMachine.current
        menuController.currentSize = Int(size)
        menuController.clickThrough = clickThrough
        menuController.petVisible = true
        menuController.onSelectState = { [weak self] s in
            self?.stateMachine.request(s, source: "菜单")
        }
        menuController.onSelectSize = { [weak self] n in
            self?.applySize(n)
        }
        menuController.onToggleClickThrough = { [weak self] on in
            self?.applyClickThrough(on)
        }
        menuController.onToggleVisibility = { [weak self] in
            self?.toggleVisibility()
        }
        menuController.onOpenSettings = { [weak self] in
            self?.settingsController.show()
        }
        menuController.onQuit = {
            NSApp.terminate(nil)
        }

        settingsController.onSave = { [weak self] in
            PetLog.d("设置保存回调：重启轮询器使新配置生效")
            self?.poller.restart()
        }

        setupPoller()
        registerSystemObservers()
        stateMachine.start()
        poller.restart()
        startStaleTimer()
        PetLog.d("启动完成 state=\(stateMachine.current.rawValue) size=\(Int(size)) clickThrough=\(clickThrough) renderMode=\(renderer.mode) pollerEnabled=\(poller.enabled)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        PetLog.d("HatchPet 退出 state=\(stateMachine.current.rawValue)")
        savePosition()
    }

    // MARK: - 通道轮询接线

    private func setupPoller() {
        poller.onStatus = { [weak self] text in
            self?.menuController.channelStatus = text
        }
        poller.onData = { [weak self] data in
            guard let self else { return }
            PetLog.d("通道数据应用 seq=\(data.seq) state=\(data.state ?? "nil") event=\(data.event ?? "nil")")
            if let raw = data.state {
                if let state = PetState(rawValue: raw) {
                    self.stateMachine.request(state, source: "remote")
                } else {
                    PetLog.d("通道数据 state 值未知：\(raw)（忽略状态部分）")
                }
            }
            if data.event == "milestone" {
                PetLog.d("通道事件 milestone -> 触发里程碑庆祝")
                self.stateMachine.request(.milestone, source: "remote-event")
            } else if let ev = data.event, !ev.isEmpty {
                PetLog.d("通道事件 \(ev)（本版只处理 milestone，其余仅记录）")
            }
            if let message = data.message, !message.isEmpty {
                let at = data.dataTsMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                self.menuController.latestMessage = (text: message, at: at)
                self.bubble.show(message: message, anchor: self.panel)
            }
        }
    }

    // MARK: - 失联变暗（通道数据时间戳超 5 分钟 -> alpha 0.55，恢复新鲜还原）

    private func startStaleTimer() {
        staleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.checkStaleness()
        }
        PetLog.d("失联变暗检查定时器已启动（每 20s，阈值 300s）")
    }

    private func checkStaleness() {
        // 本地手动模式（轮询未启用）不应用此规则
        guard poller.enabled else {
            if dimmed { setDimmed(false, reason: "轮询未启用") }
            return
        }
        guard let tsMs = poller.latestDataTsMs else {
            // 还没拿到过任何数据：不变暗
            return
        }
        let age = Date().timeIntervalSince1970 - tsMs / 1000
        let stale = age > 300
        if stale != dimmed {
            setDimmed(stale, reason: stale ? "数据已 \(Int(age))s 未更新（ts=\(Int(tsMs))）" : "数据已恢复新鲜（age=\(Int(age))s）")
        }
    }

    private func setDimmed(_ on: Bool, reason: String) {
        dimmed = on
        panel.alphaValue = on ? 0.55 : 1.0
        PetLog.d("失联变暗 \(on ? "开启" : "关闭") alpha=\(on ? 0.55 : 1.0) 原因：\(reason)")
    }

    // MARK: - 窗口位置/尺寸/穿透/显隐

    private func restorePosition(size: CGFloat) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: DefaultsKey.hasOrigin) {
            let origin = NSPoint(x: defaults.double(forKey: DefaultsKey.originX),
                                 y: defaults.double(forKey: DefaultsKey.originY))
            let frame = NSRect(origin: origin, size: NSSize(width: size, height: size))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrame(frame, display: false)
                PetLog.d("窗口位置恢复 origin=\(origin) size=\(Int(size))")
                return
            }
            PetLog.d("保存的窗口位置不在任何屏幕可视区内，改用默认位置 saved=\(origin)")
        }
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            // 默认位置：主屏右下偏上（避开 Dock 与右下角通知区）
            let origin = NSPoint(x: vf.maxX - size - 24, y: vf.minY + 140)
            panel.setFrameOrigin(origin)
            PetLog.d("窗口默认位置 origin=\(origin) size=\(Int(size))")
        }
    }

    private func savePosition() {
        guard let panel else { return }
        let frame = panel.frame
        let defaults = UserDefaults.standard
        defaults.set(frame.origin.x, forKey: DefaultsKey.originX)
        defaults.set(frame.origin.y, forKey: DefaultsKey.originY)
        defaults.set(true, forKey: DefaultsKey.hasOrigin)
        PetLog.d("窗口位置已保存 origin=\(frame.origin) size=\(Int(frame.width))")
    }

    private func applySize(_ points: Int) {
        var frame = panel.frame
        frame.size = NSSize(width: points, height: points)
        panel.setFrame(frame, display: true)
        UserDefaults.standard.set(points, forKey: DefaultsKey.size)
        menuController.currentSize = points
        savePosition()
        bubble.repositionIfVisible()
        PetLog.d("尺寸切换 -> \(points)pt origin保持=\(frame.origin)")
    }

    private func applyClickThrough(_ on: Bool) {
        panel.ignoresMouseEvents = on
        UserDefaults.standard.set(on, forKey: DefaultsKey.clickThrough)
        menuController.clickThrough = on
        PetLog.d("触摸穿透 \(on ? "开启" : "关闭")（panel.ignoresMouseEvents=\(on)；开启后只能用菜单栏菜单关闭）")
    }

    private func toggleVisibility() {
        if panel.isVisible {
            panel.orderOut(nil)
            bubble.hide(reason: "宠物隐藏")
            menuController.petVisible = false
            PetLog.d("宠物已隐藏（菜单栏仍可调出）")
        } else {
            panel.orderFrontRegardless()
            menuController.petVisible = true
            PetLog.d("宠物已显示")
        }
    }

    // MARK: - 本地系统事件（点缀，不抢真实状态；同时联动轮询暂停/恢复）

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 didWake（系统唤醒）")
            self?.renderer.resumeFromSleep()
            self?.poller.resumeAndPoll()
            self?.stateMachine.request(.waking, source: "系统唤醒", interruptBusy: false)
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 willSleep（系统将睡眠）")
            self?.renderer.pauseForSleep()
            self?.poller.pause()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screensDidSleep（屏幕睡眠）")
            self?.renderer.pauseForSleep()
            self?.poller.pause()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screensDidWake（屏幕唤醒）")
            self?.renderer.resumeFromSleep()
            self?.poller.resumeAndPoll()
            self?.stateMachine.request(.waking, source: "屏幕唤醒", interruptBusy: false)
        })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screenIsUnlocked（屏幕解锁）")
            self?.renderer.resumeFromSleep()
            self?.poller.resumeAndPoll()
            self?.stateMachine.request(.waking, source: "屏幕解锁", interruptBusy: false)
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screenIsLocked（屏幕锁定）")
            self?.renderer.pauseForSleep()
            self?.poller.pause()
        })
        PetLog.d("系统事件观察者已注册：didWake/willSleep/screensDidSleep/screensDidWake/screenIsUnlocked/screenIsLocked（均联动轮询暂停/恢复）")
    }
}
