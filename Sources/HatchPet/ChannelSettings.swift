import Foundation

/// 通道连接配置：服务器/通道名/轮询间隔存 UserDefaults；accesskey 只存钥匙串。
struct ChannelConfig {
    var server: String
    var channel: String
    var intervalSec: Int

    /// 归一化后的服务器基地址（去掉尾部斜杠）
    var baseURL: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum ChannelSettings {
    static let defaultServer = "https://relay.nonzero-e3c.workers.dev"
    static let defaultChannel = "hatch-pet"
    static let defaultInterval = 15
    static let intervalChoices = [5, 10, 15, 30]

    private enum Key {
        static let server = "channel.server"
        static let channel = "channel.name"
        static let interval = "channel.intervalSec"
    }

    static func load() -> ChannelConfig {
        let d = UserDefaults.standard
        let server = d.string(forKey: Key.server) ?? defaultServer
        let channel = d.string(forKey: Key.channel) ?? defaultChannel
        let savedInterval = d.object(forKey: Key.interval) as? Int
        let interval = savedInterval.flatMap { intervalChoices.contains($0) ? $0 : nil } ?? defaultInterval
        return ChannelConfig(server: server, channel: channel, intervalSec: interval)
    }

    static func save(_ config: ChannelConfig) {
        let d = UserDefaults.standard
        d.set(config.server, forKey: Key.server)
        d.set(config.channel, forKey: Key.channel)
        d.set(config.intervalSec, forKey: Key.interval)
        PetLog.d("通道配置已保存 server=\(config.baseURL) channel=\(config.channel) interval=\(config.intervalSec)s（钥在钥匙串，不在此处）")
    }

    static func accessKey(for channel: String) -> String? {
        KeychainStore.load(account: channel)
    }
}
