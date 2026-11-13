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
    private let onboarding = OnboardingWindowController()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var staleTimer: Timer?
    /// 失联变暗相位（v0.12 起改为渐进变暗，见下方实现）：是否已进入变暗 +
    /// 当前已应用的窗口 alpha；目标 alpha 由数据年龄的连续函数算出。
    private var dimPhase = false
    private var currentAlpha: CGFloat = 1.0

    private enum DefaultsKey {
        static let size = "pet.size"
        static let originX = "pet.originX"
        static let originY = "pet.originY"
        static let hasOrigin = "pet.hasOrigin"
        static let clickThrough = "pet.clickThrough"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetLog.setup()
        PetLog.d("HatchPet 启动（\(AppVersion.displayString)） bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier)")
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

        settingsController.onApplied = { [weak self] in
            PetLog.d("设置即时应用回调：重启轮询器使新配置生效（按新配置重建会话）")
            self?.poller.restart()
        }
        settingsController.onAssetsChanged = { [weak self] state in
            guard let self else { return }
            if self.stateMachine.current == state {
                PetLog.d("形象变更且正播该状态 state=\(state.rawValue)，立即重载播放器")
                self.renderer.play(state: state)
            } else {
                PetLog.d("形象变更 state=\(state.rawValue)（当前状态 \(self.stateMachine.current.rawValue)，下次切到时生效）")
            }
        }

        settingsController.onReopenOnboarding = { [weak self] in
            self?.onboarding.show()
        }
        onboarding.onConnected = { [weak self] in
            PetLog.d("[onboarding] 引导连接成功回调：重启轮询器使新配置生效")
            self?.poller.restart()
        }

        setupPoller()
        registerSystemObservers()
        stateMachine.start()
        poller.restart()
        // 首启引导（v0.18）：未配置通道+钥时弹出引导窗；已配置直接进宠物、不打扰
        let launchCfg = ChannelSettings.load()
        let launchHasKey = ChannelSettings.accessKey(for: launchCfg.channel).map { !$0.isEmpty } ?? false
        if launchCfg.channel.isEmpty || !launchHasKey {
            PetLog.d("[onboarding] 未配置通道+钥（channel空=\(launchCfg.channel.isEmpty) hasKey=\(launchHasKey)），启动弹出引导窗")
            onboarding.show()
        } else {
            PetLog.d("[onboarding] 已配置通道 \(launchCfg.channel)，不弹引导")
        }
        startStaleTimer()
        // 启动静默检查更新（每天最多一次，失败只记日志；见 UpdateChecker）
        UpdateChecker.checkOnLaunchIfNeeded()
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
            // 新数据到达即复查失联变暗：正在变暗/已变暗时不等下个 tick，立即平滑恢复
            self.checkStaleness()
        }
    }

    // MARK: - 失联渐进变暗（v0.12）

    // v0.11 及以前：数据超 5 分钟一步跳到 alpha 0.55。回合制写入节奏下 5 分钟
    // 太短、频繁触发，且一步跳变在真机上就是「突然透明」（用户原话）。
    // v0.12 改为：阈值放宽到 20 分钟；越过阈值后用 60 秒线性渐变到 0.75 封底；
    // 收到新数据立即平滑恢复到 1（约 0.3 秒）。目标 alpha 是数据年龄的连续函数，
    // 定时 tick 只负责把当前 alpha 朝目标推进，其中下行速率另行封顶保证匀速。
    private static let staleThreshold: TimeInterval = 20 * 60      // 1200s
    private static let staleTick: TimeInterval = 2                 // tick 间隔（s）
    private static let dimFloor: CGFloat = 0.75
    private static let dimFadeSeconds: TimeInterval = 60

    private func startStaleTimer() {
        staleTimer = Timer.scheduledTimer(withTimeInterval: Self.staleTick, repeats: true) { [weak self] _ in
            self?.checkStaleness()
        }
        PetLog.d("失联变暗检查定时器已启动（每 \(Int(Self.staleTick))s，阈值 \(Int(Self.staleThreshold))s，\(Int(Self.dimFadeSeconds))s 渐变至 \(Self.dimFloor)）")
    }

    /// 目标 alpha（连续函数）：年龄 ≤ 阈值 → 1；其后 60 秒内线性降到 0.75 封底。
    /// 轮询未启用（本地手动模式）或还没拿到过任何数据 → 恒为 1（不变暗）。
    private func targetAlpha(age: TimeInterval?) -> CGFloat {
        guard poller.enabled, let age else { return 1 }
        if age <= Self.staleThreshold { return 1 }
        let t = min(1, (age - Self.staleThreshold) / Self.dimFadeSeconds)
        return 1 - (1 - Self.dimFloor) * CGFloat(t)
    }

    private func checkStaleness() {
        let age: TimeInterval?
        if poller.enabled, let tsMs = poller.latestDataTsMs {
            age = Date().timeIntervalSince1970 - tsMs / 1000
        } else {
            age = nil
        }
        let target = targetAlpha(age: age)
        // 进入 / 退出变暗各记一条（带数据年龄秒数）
        if let age, age > Self.staleThreshold, !dimPhase {
            dimPhase = true
            PetLog.d("进入失联变暗 数据年龄=\(Int(age))s（阈值 \(Int(Self.staleThreshold))s，将在 \(Int(Self.dimFadeSeconds))s 内渐变至 \(Self.dimFloor)）")
        } else if dimPhase, target >= 1 {
            dimPhase = false
            let ageText = age.map { "\(Int($0))s" } ?? "无（轮询未启用/尚无数据）"
            PetLog.d("退出失联变暗 数据年龄=\(ageText)，平滑还原 alpha=1")
        }
        applyAlpha(target: target)
    }

    private func applyAlpha(target: CGFloat) {
        if target > currentAlpha {
            // 恢复方向：立即平滑还原到 1（约 0.3 秒动画），不等 tick 慢慢爬
            currentAlpha = target
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = target
            }
        } else if target < currentAlpha {
            // 变暗方向：下行速率按 tick 封顶（每 tick 最多走完 (tick/60) 的全程），
            // 保证 60 秒匀速渐变，不因年龄跳变而一步到位
            let maxStep = (1 - Self.dimFloor) * CGFloat(Self.staleTick / Self.dimFadeSeconds)
            let next = max(target, currentAlpha - maxStep)
            currentAlpha = next
            panel.alphaValue = next
        }
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
