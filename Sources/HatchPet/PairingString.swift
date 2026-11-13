import Foundation

/// 配对串（PROTOCOL v2）：`hatchpet1:` + base64url(JSON {v,server,channel,key})。
/// 解码校验严格按协议 4 步：① 去空白、必须有大小写敏感的前缀；② base64url
/// 解码 + JSON 解析，失败整体拒绝、绝不部分应用；③ v==1、server 非空 https、
/// channel 匹配 [A-Za-z0-9_-]{1,64}、key 非空，未知字段忽略；④ 成功后钥按
/// 凭证对待（存本机钥文件），原始配对串不落盘、不记日志。
enum PairingString {
    static let prefix = "hatchpet1:"

    struct Parsed {
        let server: String
        let channel: String
        let key: String
    }

    static func encode(server: String, channel: String, key: String) -> String {
        let obj: [String: Any] = ["v": 1, "server": server, "channel": channel, "key": key]
        // 字典只有固定类型，序列化不会失败
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        PetLog.d("[pairing] 已组装配对串 server=\(server) channel=\(channel) keyLen=\(key.count)（钥不记日志）")
        return prefix + b64
    }

    /// 解析失败返回 nil 并记原因（不记串本体，串含钥）。
    static func parse(_ raw: String) -> Parsed? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else {
            PetLog.d("[pairing] 解码拒绝：缺少 hatchpet1: 前缀（len=\(s.count)）")
            return nil
        }
        var b64 = String(s.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            PetLog.d("[pairing] 解码拒绝：base64url/JSON 解析失败")
            return nil
        }
        guard (obj["v"] as? NSNumber)?.intValue == 1,
              let server = obj["server"] as? String, !server.isEmpty, server.hasPrefix("https://"),
              let channel = obj["channel"] as? String,
              channel.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              let key = obj["key"] as? String, !key.isEmpty else {
            PetLog.d("[pairing] 解码拒绝：字段校验未过（v/server/channel/key）")
            return nil
        }
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        PetLog.d("[pairing] 解码成功 server=\(base) channel=\(channel) keyLen=\(key.count)（钥不记日志）")
        return Parsed(server: base, channel: channel, key: key)
    }
}
