import Foundation

/// 状态机，规则与 Android 版对齐：
/// - idle/working/making 循环播放；
/// - waking/milestone 为一次性状态，可立即打断任何状态，播完回落到进入前的状态；
/// - 一次性状态播放中收到的普通状态请求只改回落目标，不打断；
/// - 普通切换有 2 秒最小停留防抖，被拒必须记日志并写明原因；
/// - 本地事件（睡醒/解锁）触发的 waking（interruptBusy=false）不打断 working/making。
final class StateMachine {
    private(set) var current: PetState = .idle
    private var fallback: PetState = .idle
    private var lastChangeAt = Date.distantPast
    private let minStay: TimeInterval = 2.0

    /// 状态真正生效时回调（切换播放器、刷新菜单勾选）
    var onApply: ((PetState, String) -> Void)?

    /// 启动时直接把初始状态（idle）推给播放器，绕过防抖与“同状态”判定。
    func start() {
        PetLog.d("状态机启动 initial=\(current.rawValue)")
        apply(current, source: "启动")
    }

    func request(_ target: PetState, source: String, interruptBusy: Bool = true) {
        PetLog.d("状态请求 target=\(target.rawValue) source=\(source) current=\(current.rawValue) fallback=\(fallback.rawValue) interruptBusy=\(interruptBusy)")

        if target.oneShot {
            if target == current {
                PetLog.d("拒绝切换：一次性状态 \(target.rawValue) 正在播放，忽略重复请求 source=\(source)")
                return
            }
            if !interruptBusy && current.isBusy {
                PetLog.d("拒绝切换：本地事件的一次性状态 \(target.rawValue) 不打断忙碌状态 \(current.rawValue) source=\(source)")
                return
            }
            if current.oneShot {
                PetLog.d("一次性状态 \(current.rawValue) 被 \(target.rawValue) 替换，回落目标保持 \(fallback.rawValue)")
            } else {
                fallback = current
            }
            apply(target, source: source)
            return
        }

        if current.oneShot {
            fallback = target
            PetLog.d("一次性状态 \(current.rawValue) 播放中，普通请求 \(target.rawValue) 已记为回落目标（不打断）")
            return
        }

        if target == current {
            PetLog.d("拒绝切换：目标与当前状态相同 \(target.rawValue) source=\(source)")
            return
        }

        let stayed = Date().timeIntervalSince(lastChangeAt)
        if stayed < minStay {
            PetLog.d("拒绝切换：最小停留 \(minStay)s 未满（已停留 \(String(format: "%.2f", stayed))s），忽略 \(target.rawValue) source=\(source)")
            return
        }
        apply(target, source: source)
    }

    /// 播放器报告当前视频播完时调用（渲染器只对一次性状态转发此回调）。
    func handlePlaybackFinished() {
        guard current.oneShot else {
            PetLog.d("播放结束回调但当前不是一次性状态 current=\(current.rawValue)，忽略")
            return
        }
        let finished = current
        PetLog.d("一次性状态 \(finished.rawValue) 播完，回落到 \(fallback.rawValue)")
        apply(fallback, source: "oneShot回落")
    }

    private func apply(_ state: PetState, source: String) {
        current = state
        lastChangeAt = Date()
        PetLog.d("状态生效 -> \(state.rawValue)（\(state.label)）source=\(source) oneShot=\(state.oneShot)")
        onApply?(state, source)
    }
}
