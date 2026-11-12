import Foundation

/// 通道轮询器：按设置间隔 GET /c/{通道}?since=<本地seq>（Bearer 钥，读不需 HMAC）。
/// - 200：解析 {seq, data:{state,event,message,ts}} 回调 onData；204：无变化。
/// - 错误：菜单状态项经 onStatus 更新；重试间隔指数退避（间隔×2^n，上限 120s），恢复后回正常间隔。
/// - 睡眠暂停（pause），唤醒立即拉一次（resumeAndPoll）。
/// - 未配置钥：轮询关闭，宠物保持本地手动模式。
/// 全程在主队列回调；日志记每轮 HTTP 码与 seq，不记钥。
final class ChannelPoller {
    struct RemoteData {
        let seq: Int
        let state: String?
        let event: String?
        let message: String?
        /// 数据自带时间戳（毫秒，来自 data.ts；缺失时用服务端信封 ts）
        let dataTsMs: Double?
    }

    var onData: ((RemoteData) -> Void)?
    var onStatus: ((String) -> Void)?

    private(set) var enabled = false
    private(set) var localSeq = 0
    /// 最近一条数据的时间戳（毫秒），供失联变暗判定
    private(set) var latestDataTsMs: Double?

    private var config: ChannelConfig?
    private var key: String?
    private var session: URLSession?
    private var timer: Timer?
    private var failCount = 0
    private var paused = false
    private var inFlight = false
    private var generation = 0

    func restart() {
        generation += 1
        stopTimer()
        failCount = 0
        inFlight = false
        let cfg = ChannelSettings.load()
        config = cfg
        // 每次重启按当前设置重建会话（v0.15 起设置即时生效，改动即经此落地）
        session?.invalidateAndCancel()
        session = RelaySession.makeSession(proxy: cfg.proxy)
        key = ChannelSettings.accessKey(for: cfg.channel)
        guard let key, !key.isEmpty else {
            enabled = false
            self.key = nil
            PetLog.d("轮询关闭：通道 \(cfg.channel) 未配置 accesskey（宠物保持本地手动模式）")
            onStatus?("通道：未配置（在「设置…」里填 accesskey）")
            return
        }
        enabled = true
        PetLog.d("轮询启动 server=\(cfg.baseURL) channel=\(cfg.channel) interval=\(cfg.intervalSec)s proxy=\(cfg.proxy.summary) localSeq=\(localSeq)（钥 len=\(key.count)，内容不记日志）")
        onStatus?("通道：连接中…")
        schedule(after: 0.3)
    }

    func pause() {
        guard enabled else { return }
        paused = true
        stopTimer()
        PetLog.d("轮询暂停（系统睡眠/锁屏）")
    }

    func resumeAndPoll() {
        guard enabled else { return }
        paused = false
        PetLog.d("轮询恢复（唤醒/解锁），立即拉一次")
        schedule(after: 0.3)
    }

    // MARK: - 内部

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(after delay: TimeInterval) {
        stopTimer()
        guard enabled, !paused else { return }
        let gen = generation
        timer = Timer.scheduledTimer(withTimeInterval: max(delay, 0.1), repeats: false) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            self.poll()
        }
    }

    private func poll() {
        guard enabled, !paused, !inFlight,
              let cfg = config, let key, let session else { return }
        inFlight = true
        let gen = generation
        let urlString = "\(cfg.baseURL)/c/\(cfg.channel)?since=\(localSeq)"
        guard let url = URL(string: urlString) else {
            PetLog.d("轮询失败：服务器地址无效 \(urlString)")
            finishPoll(gen: gen, success: false, statusText: "通道：服务器地址无效")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        PetLog.d("轮询 GET /c/\(cfg.channel)?since=\(localSeq)")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.inFlight = false
                if let error {
                    PetLog.d("轮询网络错误：\(error.localizedDescription)")
                    self.finishPoll(gen: gen, success: false, statusText: "通道：网络错误（\(error.localizedDescription)）")
                    return
                }
                let http = (response as? HTTPURLResponse)?.statusCode ?? -1
                switch http {
                case 204:
                    PetLog.d("轮询 204 无变化 seq=\(self.localSeq)")
                    self.finishPoll(gen: gen, success: true, statusText: "通道：已连接 seq=\(self.localSeq)")
                case 200:
                    self.handleOK(data: data)
                default:
                    var reason = ""
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let msg = obj["message"] as? String {
                        reason = " \(msg)"
                    }
                    PetLog.d("轮询 HTTP \(http)\(reason)")
                    self.finishPoll(gen: gen, success: false, statusText: "通道：HTTP \(http)\(reason)")
                }
            }
        }.resume()
    }

    private func handleOK(data: Data?) {
        guard let data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let seq = (obj["seq"] as? NSNumber)?.intValue else {
            PetLog.d("轮询 200 但响应解析失败（非预期 JSON）")
            finishPoll(gen: generation, success: false, statusText: "通道：响应格式错误")
            return
        }
        let envelopeTs = (obj["ts"] as? NSNumber)?.doubleValue
        var state: String?
        var event: String?
        var message: String?
        var dataTs = envelopeTs
        if let payload = obj["data"] as? [String: Any] {
            state = payload["state"] as? String
            event = payload["event"] as? String
            message = payload["message"] as? String
            if let ts = (payload["ts"] as? NSNumber)?.doubleValue { dataTs = ts }
        }
        let isNew = seq > localSeq
        localSeq = max(localSeq, seq)
        if let dataTs { latestDataTsMs = dataTs }
        PetLog.d("轮询 200 seq=\(seq) isNew=\(isNew) state=\(state ?? "nil") event=\(event ?? "nil") message=\(message == nil ? "nil" : "有") dataTs=\(dataTs.map { String(Int($0)) } ?? "nil")")
        finishPoll(gen: generation, success: true, statusText: "通道：已连接 seq=\(seq)")
        if isNew {
            onData?(RemoteData(seq: seq, state: state, event: event, message: message, dataTsMs: dataTs))
        }
    }

    private func finishPoll(gen: Int, success: Bool, statusText: String) {
        guard gen == generation else { return }
        onStatus?(statusText)
        guard let cfg = config else { return }
        if success {
            failCount = 0
            schedule(after: TimeInterval(cfg.intervalSec))
        } else {
            failCount += 1
            let backoff = min(TimeInterval(cfg.intervalSec) * pow(2.0, Double(failCount)), 120)
            PetLog.d("轮询退避 failCount=\(failCount) 下次 \(Int(backoff))s 后重试")
            schedule(after: backoff)
        }
    }
}
