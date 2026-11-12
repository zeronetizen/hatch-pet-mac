import AppKit

/// 应用装配：日志 → 资源体检 → 渲染器 → 悬浮窗 → 状态机 → 菜单栏 → 系统事件。
/// 持久化（UserDefaults）：窗口位置（原点）、尺寸、触摸穿透开关。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PetPanel!
    private var renderer: PetVideoRenderer!
    private var menuController: StatusMenuController!
    private let stateMachine = StateMachine()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    private enum DefaultsKey {
        static let size = "pet.size"
        static let originX = "pet.originX"
        static let originY = "pet.originY"
        static let hasOrigin = "pet.hasOrigin"
        static let clickThrough = "pet.clickThrough"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PetLog.setup()
        PetLog.d("HatchPet 启动 bundle=\(Bundle.main.bundlePath) pid=\(ProcessInfo.processInfo.processIdentifier)")
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
            self?.savePosition()
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
        menuController.onQuit = {
            NSApp.terminate(nil)
        }

        registerSystemObservers()
        stateMachine.start()
        PetLog.d("启动完成 state=\(stateMachine.current.rawValue) size=\(Int(size)) clickThrough=\(clickThrough) renderMode=\(renderer.mode)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        PetLog.d("HatchPet 退出 state=\(stateMachine.current.rawValue)")
        savePosition()
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
            menuController.petVisible = false
            PetLog.d("宠物已隐藏（菜单栏仍可调出）")
        } else {
            panel.orderFrontRegardless()
            menuController.petVisible = true
            PetLog.d("宠物已显示")
        }
    }

    // MARK: - 本地系统事件（点缀，不抢真实状态）

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 didWake（系统唤醒）")
            self?.renderer.resumeFromSleep()
            self?.stateMachine.request(.waking, source: "系统唤醒", interruptBusy: false)
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 willSleep（系统将睡眠）")
            self?.renderer.pauseForSleep()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screensDidSleep（屏幕睡眠）")
            self?.renderer.pauseForSleep()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screensDidWake（屏幕唤醒）")
            self?.renderer.resumeFromSleep()
            self?.stateMachine.request(.waking, source: "屏幕唤醒", interruptBusy: false)
        })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screenIsUnlocked（屏幕解锁）")
            self?.renderer.resumeFromSleep()
            self?.stateMachine.request(.waking, source: "屏幕解锁", interruptBusy: false)
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            PetLog.d("系统事件 screenIsLocked（屏幕锁定）")
            self?.renderer.pauseForSleep()
        })
        PetLog.d("系统事件观察者已注册：didWake/willSleep/screensDidSleep/screensDidWake/screenIsUnlocked/screenIsLocked")
    }
}
