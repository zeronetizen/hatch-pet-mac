import Foundation

/// accesskey 的存放处：本机应用数据目录下的钥文件（自 v0.6 起，不再用系统钥匙串——
/// 钥匙串在自签名应用上会弹权限提示，自用场景没必要）。
/// 路径：~/Library/Application Support/MusePet/keys/<channel>.key
/// 目录权限 700、文件权限 600；内容就是钥原文（读时 trim）。绝不进 UserDefaults。
/// 所有操作记日志（只记通道名/长度/结果，不记钥内容）。
/// （v0.25 起目录名由 HatchPet 改为 MusePet；测试阶段不迁移旧目录。）
enum KeyFileStore {
    /// 钥目录：~/Library/Application Support/MusePet/keys
    static var keysDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MusePet/keys", isDirectory: true)
    }

    /// 通道名 → 安全文件名基：只保留 [A-Za-z0-9._-]，其余字符换成 "_"，防路径穿越。
    private static func safeName(for channel: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let safe = channel.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "channel" : name
    }

    /// 通道读钥文件：<channel>.key
    private static func fileURL(for channel: String) -> URL {
        keysDirectory.appendingPathComponent("\(safeName(for: channel)).key")
    }

    /// 管理钥文件（v0.31）：<channel>.mgmt.key——与通道读钥同目录、文件名区分，
    /// 同样 600 权限；只存本机、不显示、不能导出、不进通道码（见 MgmtService）。
    private static func mgmtFileURL(for channel: String) -> URL {
        keysDirectory.appendingPathComponent("\(safeName(for: channel)).mgmt.key")
    }

    private static func ensureDirectory() -> Bool {
        let fm = FileManager.default
        let dir = keysDirectory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // 目录已存在时 createDirectory 不改权限，显式钉一次 700
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            return true
        } catch {
            PetLog.d("钥目录准备失败 \(dir.path)：\(error.localizedDescription)")
            return false
        }
    }

    static func load(channel: String) -> String? {
        let url = fileURL(for: channel)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            PetLog.d("钥文件读取 channel=\(channel) 无记录（\(url.path) 不存在或不可读）")
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            PetLog.d("钥文件读取 channel=\(channel) 文件为空，视为未保存")
            return nil
        }
        PetLog.d("钥文件读取 channel=\(channel) 成功（len=\(value.count)，内容不记日志）")
        return value
    }

    static func save(key: String, channel: String) {
        guard ensureDirectory() else { return }
        let url = fileURL(for: channel)
        let fm = FileManager.default
        do {
            try Data(key.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            PetLog.d("钥文件保存 channel=\(channel) 成功（len=\(key.count)，权限 600）")
        } catch {
            PetLog.d("钥文件保存 channel=\(channel) 失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 管理钥（v0.31，<channel>.mgmt.key）

    static func loadMgmtKey(channel: String) -> String? {
        let url = mgmtFileURL(for: channel)
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            PetLog.d("[mgmt] mgmt 钥文件读取 channel=\(channel) 无记录（\(url.lastPathComponent) 不存在或不可读）")
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            PetLog.d("[mgmt] mgmt 钥文件读取 channel=\(channel) 文件为空，视为未保存")
            return nil
        }
        PetLog.d("[mgmt] mgmt 钥文件读取 channel=\(channel) 成功（len=\(value.count)，内容不记日志）")
        return value
    }

    static func saveMgmtKey(key: String, channel: String) {
        guard ensureDirectory() else { return }
        let url = mgmtFileURL(for: channel)
        let fm = FileManager.default
        do {
            try Data(key.utf8).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            PetLog.d("[mgmt] mgmt 钥文件保存 channel=\(channel) 成功（len=\(key.count)，文件 \(url.lastPathComponent)，权限 600）")
        } catch {
            PetLog.d("[mgmt] mgmt 钥文件保存 channel=\(channel) 失败：\(error.localizedDescription)")
        }
    }

    static func delete(channel: String) {
        let url = fileURL(for: channel)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            PetLog.d("钥文件删除 channel=\(channel)：本就不存在")
            return
        }
        do {
            try fm.removeItem(at: url)
            PetLog.d("钥文件删除 channel=\(channel) 成功")
        } catch {
            PetLog.d("钥文件删除 channel=\(channel) 失败：\(error.localizedDescription)")
        }
    }
}
