import Foundation
import Security

/// accesskey 的唯一存放处：macOS 钥匙串（generic password）。
/// 绝不写入 UserDefaults 或任何文件。所有操作记日志（只记结果码，不记钥内容）。
enum KeychainStore {
    static let service = "com.nonzero.hatchpet.mac"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            PetLog.d("钥匙串读取 account=\(account) status=\(status)（无记录时为 errSecItemNotFound=-25300）")
            return nil
        }
        PetLog.d("钥匙串读取 account=\(account) 成功（len=\(value.count)，内容不记日志）")
        return value
    }

    static func save(key: String, account: String) {
        let data = Data(key.utf8)
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            PetLog.d("钥匙串更新 account=\(account) 成功（len=\(key.count)）")
            return
        }
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(attrs as CFDictionary, nil)
        PetLog.d("钥匙串保存 account=\(account) updateStatus=\(updateStatus) addStatus=\(addStatus)（len=\(key.count)）")
    }

    static func delete(account: String) {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        PetLog.d("钥匙串删除 account=\(account) status=\(status)")
    }
}
