import Foundation

/// 已绑定 agent 名单项（服务端 GET /c/<channel>/agents 的元素）：
/// index 是解绑用的序号，label 可空（空时显示口径为「agent-<序号>」，见
/// displayLabel），boundAt 是绑定时间（字符串原样；数字按时间戳格式化）。
struct AgentInfo {
    let index: Int
    let label: String
    let boundAt: String

    var displayLabel: String { label.isEmpty ? "agent-\(index)" : label }
    var rowText: String {
        boundAt.isEmpty ? "\(index) · \(displayLabel)" : "\(index) · \(displayLabel) · \(boundAt)"
    }
}

/// 管理接口客户端（v0.31，凭证模型 v4 的 App 侧关节）：
/// - 领取管理钥：POST {server}/c/{channel}/mgmt-key，Bearer=通道读钥 →
///   201 {mgmtKey}（仅发一次，存本机 <channel>.mgmt.key，600）；409 = 服务端
///   已领过（视为已有，不报错）；404/网络失败 = 老服务端没有此端点，静默
///   跳过、待下次连接成功时重试。管理钥只进钥文件，日志只记长度。
/// - 管理操作一律 Bearer 管理钥：GET .../agents 名单、POST .../agents/remove
///   {index} 解绑、POST .../bind-codes 领一次性绑定码 {bindingCode, expiresAt}。
///   绑定码只随返回值交给调用方写进导出包，绝不进日志、不进 UI 文案。
/// 全部回调都切回主队列，方便 UI 调用方直接刷新界面。
enum MgmtService {

    // MARK: - 管理钥领取（连接成功后共用）

    /// 连接落盘成功后异步领取管理钥。completion 在主队列回调（无论成败），
    /// 供设置页据此刷新「已绑定 agent」区显隐；引导页可不传。
    static func claimMgmtKey(server: String, channel: String, readKey: String,
                             proxy: ProxyConfig, completion: (() -> Void)? = nil) {
        let base = normalizedBase(server)
        PetLog.d("[mgmt] mgmt-key 领取开始 channel=\(channel) server=\(base)（Bearer=读钥，钥不记日志）")
        guard let url = URL(string: "\(base)/c/\(channel)/mgmt-key") else {
            PetLog.d("[mgmt] mgmt-key 领取跳过：服务器地址拼不出 URL server=\(base)")
            completion?()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(readKey)", forHTTPHeaderField: "Authorization")
        send(request, proxy: proxy) { data, http, error in
            defer { DispatchQueue.main.async { completion?() } }
            if http == 201,
               let obj = jsonObject(data),
               let mgmtKey = obj["mgmtKey"] as? String, !mgmtKey.isEmpty {
                KeyFileStore.saveMgmtKey(key: mgmtKey, channel: channel)
                PetLog.d("[mgmt] mgmt-key 领取成功 channel=\(channel) mgmtKeyLen=\(mgmtKey.count)，已存本机 mgmt 钥文件")
                return
            }
            if http == 409 {
                if KeyFileStore.loadMgmtKey(channel: channel) != nil {
                    PetLog.d("[mgmt] mgmt-key 已领过（409）channel=\(channel)，本机已存 mgmt 钥，视为已有")
                } else {
                    PetLog.d("[mgmt] mgmt-key 已领过（409）channel=\(channel)，但本机未存 mgmt 钥——记一条 dbg 待找回（走 bot 或已绑 agent 的 secret），不向用户报错")
                }
                return
            }
            if http == 404 {
                PetLog.d("[mgmt] mgmt-key 端点不存在（404）channel=\(channel)：老服务端，静默跳过待下次连接重试")
                return
            }
            PetLog.d("[mgmt] mgmt-key 领取未成 channel=\(channel) http=\(http) err=\(errDesc(error))：静默待下次连接重试（老服务端或网络失败均如此）")
        }
    }

    /// 本机是否持有某通道的管理钥（设置页「已绑定 agent」区显隐的唯一判据）
    static func hasMgmtKey(channel: String) -> Bool {
        guard !channel.isEmpty else { return false }
        return KeyFileStore.loadMgmtKey(channel: channel) != nil
    }

    static func mgmtKey(channel: String) -> String? {
        KeyFileStore.loadMgmtKey(channel: channel)
    }

    // MARK: - 名单 / 解绑 / 绑定码（Bearer 管理钥）

    /// 拉取已绑定 agent 名单；失败（非 200/网络/老服务端）回调 nil，调用方
    /// 静默保留上次名单或空名单。
    static func fetchAgents(server: String, channel: String, mgmtKey: String,
                            proxy: ProxyConfig,
                            completion: @escaping ([AgentInfo]?) -> Void) {
        let base = normalizedBase(server)
        guard let url = URL(string: "\(base)/c/\(channel)/agents") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(mgmtKey)", forHTTPHeaderField: "Authorization")
        PetLog.d("[mgmt] agents 名单拉取开始 channel=\(channel)（Bearer=管理钥，不记日志）")
        send(request, proxy: proxy) { data, http, error in
            let parsed: [AgentInfo]?
            if http == 200, let obj = jsonObject(data),
               let arr = obj["agents"] as? [[String: Any]] {
                parsed = arr.compactMap { item in
                    guard let idx = (item["index"] as? NSNumber)?.intValue else { return nil }
                    return AgentInfo(index: idx,
                                     label: (item["label"] as? String) ?? "",
                                     boundAt: boundAtText(item["boundAt"]))
                }
            } else {
                parsed = nil
            }
            PetLog.d("[mgmt] agents 名单拉取结果 channel=\(channel) http=\(http) err=\(errDesc(error)) count=\(parsed?.count ?? -1)")
            DispatchQueue.main.async { completion(parsed) }
        }
    }

    /// 解绑一个 agent（按 index）；成功（200/204）回调 true，调用方刷新名单。
    static func removeAgent(server: String, channel: String, mgmtKey: String, index: Int,
                            proxy: ProxyConfig,
                            completion: @escaping (Bool) -> Void) {
        let base = normalizedBase(server)
        guard let url = URL(string: "\(base)/c/\(channel)/agents/remove") else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(mgmtKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["index": index])
        PetLog.d("[mgmt] agents/remove 解绑开始 channel=\(channel) index=\(index)")
        send(request, proxy: proxy) { _, http, error in
            let ok = http == 200 || http == 204
            PetLog.d("[mgmt] agents/remove 解绑结果 channel=\(channel) index=\(index) http=\(http) err=\(errDesc(error)) ok=\(ok)")
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// 领一次性绑定码（追加 agent 用）；成功回调 (bindingCode, expiresAt)，
    /// 失败回调 nil。绑定码只随返回值交给调用方写 pet-bind.json，绝不记日志。
    static func createBindingCode(server: String, channel: String, mgmtKey: String,
                                  proxy: ProxyConfig,
                                  completion: @escaping ((code: String, expiresAt: String)?) -> Void) {
        let base = normalizedBase(server)
        guard let url = URL(string: "\(base)/c/\(channel)/bind-codes") else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(mgmtKey)", forHTTPHeaderField: "Authorization")
        PetLog.d("[mgmt] bind-codes 绑定码领取开始 channel=\(channel)（Bearer=管理钥，不记日志）")
        send(request, proxy: proxy) { data, http, error in
            var result: (code: String, expiresAt: String)?
            if http == 201, let obj = jsonObject(data),
               let code = obj["bindingCode"] as? String, !code.isEmpty {
                result = (code, boundAtText(obj["expiresAt"]))
            }
            PetLog.d("[mgmt] bind-codes 绑定码领取结果 channel=\(channel) http=\(http) err=\(errDesc(error)) ok=\(result != nil) codeLen=\(result?.code.count ?? 0)（码本体不记日志）")
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - 小工具

    private static func normalizedBase(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func send(_ request: URLRequest, proxy: ProxyConfig,
                             completion: @escaping (Data?, Int, Error?) -> Void) {
        let session = RelaySession.makeSession(proxy: proxy)
        session.dataTask(with: request) { data, response, error in
            session.finishTasksAndInvalidate()
            completion(data, (response as? HTTPURLResponse)?.statusCode ?? -1, error)
        }.resume()
    }

    private static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// boundAt/expiresAt 归一化：字符串原样；数字按时间戳（>1e11 视为毫秒）
    /// 格式化为 yyyy-MM-dd HH:mm；其余类型返回空串。
    private static func boundAtText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            let raw = n.doubleValue
            let seconds = raw > 100_000_000_000 ? raw / 1000 : raw
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date(timeIntervalSince1970: seconds))
        }
        return ""
    }

    private static func errDesc(_ error: Error?) -> String {
        guard let error else { return "-" }
        let ns = error as NSError
        return "\(ns.domain)/\(ns.code) \(error.localizedDescription)"
    }
}
