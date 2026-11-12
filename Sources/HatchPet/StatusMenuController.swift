import AppKit

/// 菜单栏图标与菜单：当前状态标题、通道连接状态、最新消息（只读）、
/// 状态子菜单（当前状态打勾）、尺寸子菜单（立即生效）、触摸穿透开关、
/// 隐藏/显示、设置…、退出。动态值由 AppDelegate 写入本类属性，
/// 菜单每次打开前（menuWillOpen）刷新显示。
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let sizeChoices = [100, 120, 160, 200, 240]

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var headerItem: NSMenuItem!
    private var channelItem: NSMenuItem!
    private var messageItem: NSMenuItem!
    private var stateItems: [PetState: NSMenuItem] = [:]
    private var sizeItems: [Int: NSMenuItem] = [:]
    private var clickThroughItem: NSMenuItem!
    private var visibilityItem: NSMenuItem!

    var currentState: PetState = .idle
    var currentSize: Int = 160
    var clickThrough: Bool = false
    var petVisible: Bool = true
    /// 通道状态一行字（如「通道：已连接 seq=3」或未配置提示）
    var channelStatus: String = "通道：未配置（在「设置…」里填 accesskey）"
    /// 最新状态消息（内容 + 时间），无则 nil
    var latestMessage: (text: String, at: Date)?

    var onSelectState: ((PetState) -> Void)?
    var onSelectSize: ((Int) -> Void)?
    var onToggleClickThrough: ((Bool) -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pawprint.fill",
                                   accessibilityDescription: "HatchPet")
            button.image?.isTemplate = true
            button.toolTip = "Hatch 悬浮宠物"
        }
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        PetLog.d("菜单栏图标与菜单已创建（含通道状态/最新消息/设置入口）")
    }

    private func buildMenu() {
        headerItem = NSMenuItem(title: "状态：—", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        channelItem = NSMenuItem(title: channelStatus, action: nil, keyEquivalent: "")
        channelItem.isEnabled = false
        menu.addItem(channelItem)

        messageItem = NSMenuItem(title: "最新消息：—", action: nil, keyEquivalent: "")
        messageItem.isEnabled = false
        menu.addItem(messageItem)

        menu.addItem(.separator())

        let stateMenuItem = NSMenuItem(title: "状态", action: nil, keyEquivalent: "")
        let stateMenu = NSMenu()
        for state in PetState.allCases {
            let item = NSMenuItem(title: state.label,
                                  action: #selector(selectState(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = state.rawValue
            stateMenu.addItem(item)
            stateItems[state] = item
        }
        stateMenuItem.submenu = stateMenu
        menu.addItem(stateMenuItem)

        let sizeMenuItem = NSMenuItem(title: "尺寸", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for size in Self.sizeChoices {
            let item = NSMenuItem(title: "\(size) pt",
                                  action: #selector(selectSize(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = size
            sizeMenu.addItem(item)
            sizeItems[size] = item
        }
        sizeMenuItem.submenu = sizeMenu
        menu.addItem(sizeMenuItem)

        menu.addItem(.separator())

        clickThroughItem = NSMenuItem(title: "触摸穿透（点不动宠物）",
                                      action: #selector(toggleClickThrough(_:)),
                                      keyEquivalent: "")
        clickThroughItem.target = self
        menu.addItem(clickThroughItem)

        visibilityItem = NSMenuItem(title: "隐藏宠物",
                                    action: #selector(toggleVisibility(_:)),
                                    keyEquivalent: "")
        visibilityItem.target = self
        menu.addItem(visibilityItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(openSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出 HatchPet",
                                  action: #selector(quit(_:)),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        headerItem.title = "状态：\(currentState.label)"
        channelItem.title = channelStatus
        if let latestMessage {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            f.locale = Locale(identifier: "en_US_POSIX")
            messageItem.title = "最新消息：\(latestMessage.text)（\(f.string(from: latestMessage.at))）"
        } else {
            messageItem.title = "最新消息：—"
        }
        for (state, item) in stateItems {
            item.state = (state == currentState) ? .on : .off
        }
        for (size, item) in sizeItems {
            item.state = (size == currentSize) ? .on : .off
        }
        clickThroughItem.state = clickThrough ? .on : .off
        visibilityItem.title = petVisible ? "隐藏宠物" : "显示宠物"
        PetLog.d("菜单打开 刷新 state=\(currentState.rawValue) size=\(currentSize) clickThrough=\(clickThrough) visible=\(petVisible) channel=\(channelStatus)")
    }

    // MARK: - Actions

    @objc private func selectState(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let state = PetState(rawValue: raw) else { return }
        PetLog.d("菜单选择状态 \(state.rawValue)")
        onSelectState?(state)
    }

    @objc private func selectSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Int else { return }
        PetLog.d("菜单选择尺寸 \(size)pt")
        onSelectSize?(size)
    }

    @objc private func toggleClickThrough(_ sender: NSMenuItem) {
        let newValue = !clickThrough
        PetLog.d("菜单切换触摸穿透 -> \(newValue)")
        onToggleClickThrough?(newValue)
    }

    @objc private func toggleVisibility(_ sender: NSMenuItem) {
        PetLog.d("菜单切换显示/隐藏 当前visible=\(petVisible)")
        onToggleVisibility?()
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        PetLog.d("菜单打开设置")
        onOpenSettings?()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        PetLog.d("菜单选择退出")
        onQuit?()
    }
}
