import Foundation

/// 宠物状态。oneShot=true 的状态（waking/milestone）播完一遍后回落到进入前的状态；
/// 其余状态循环播放。与 Android 版 PetState 保持同一套语义。
enum PetState: String, CaseIterable {
    case idle
    case working
    case making
    case waking
    case milestone

    var label: String {
        switch self {
        case .idle: return "待机/连接中"
        case .working: return "办公中"
        case .making: return "动手做东西"
        case .waking: return "刚醒来"
        case .milestone: return "里程碑庆祝"
        }
    }

    /// Resources 内的视频文件名（与 ~/assets/avatar/reference/ 原文件同名，原样不重编码）
    var resourceName: String {
        switch self {
        case .idle: return "hatch"
        case .working: return "hatch_working"
        case .making: return "hatch_making_something"
        case .waking: return "hatch_waking"
        case .milestone: return "hatch_milestone_level_up"
        }
    }

    var oneShot: Bool {
        self == .waking || self == .milestone
    }

    /// 忙碌状态：本地事件（睡醒/解锁）触发的 waking 不打断它们
    var isBusy: Bool {
        self == .working || self == .making
    }
}
