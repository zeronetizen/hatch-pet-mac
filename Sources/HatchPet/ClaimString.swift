import Foundation

/// 领取串（PROTOCOL v2）：`hatchpet-code1:` + base64url(JSON {v,code,tg})。
/// bot 发码时把兑换码 + 领取人的 Telegram 数字 ID 一起打成一串，用户整串
/// 粘进引导页兑换区即可兑换——这是兑换区的唯一入口，不再手填两项。
/// 校验：前缀大小写敏感、base64url 解码 + JSON 解析失败整体拒绝、v==1、
/// code 非空字符串、tg 为正整数，未知字段忽略（同版本内前向兼容）。
/// 领取串是兑换前凭证、用后即焚：不落盘、不写设置；日志只记串长与解码
/// 结果，串本体/码/ID 一律不记。
enum ClaimString {
    static let prefix = "hatchpet-code1:"

    struct Parsed {
        let code: String
        let tgId: NSNumber
    }

    /// 解析失败返回 nil 并记原因（只记长度，不记串本体）。
    static func parse(_ raw: String) -> Parsed? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(prefix) else {
            PetLog.d("[redeem] 领取串解码拒绝：缺少 hatchpet-code1: 前缀（len=\(s.count)）")
            return nil
        }
        var b64 = String(s.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            PetLog.d("[redeem] 领取串解码拒绝：base64url/JSON 解析失败（len=\(s.count)）")
            return nil
        }
        guard (obj["v"] as? NSNumber)?.intValue == 1,
              let code = obj["code"] as? String, !code.isEmpty,
              let tg = obj["tg"] as? NSNumber,
              tg.int64Value > 0, tg.doubleValue == Double(tg.int64Value) else {
            PetLog.d("[redeem] 领取串解码拒绝：字段校验未过（v/code/tg）（len=\(s.count)）")
            return nil
        }
        PetLog.d("[redeem] 领取串解码成功（len=\(s.count) codeLen=\(code.count) tgDigits=\(String(tg.int64Value).count)，串本体不记日志）")
        return Parsed(code: code, tgId: tg)
    }
}
