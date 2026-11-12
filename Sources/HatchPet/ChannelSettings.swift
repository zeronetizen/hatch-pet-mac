import Foundation

/// 代理配置：走 UserDefaults（非敏感）。启用时 App 的会话经本机代理
/// 客户端（如 mihomo/Clash 的 127.0.0.1:7890）出海，绕开直连 TLS 被干扰的问题。
struct ProxyConfig {
    var enabled: Bool
    /// "http"（含 HTTPS CONNECT）或 "socks"（SOCKS5）
    var type: String
    var host: String
    var port: Int

    static let defaultType = "http"
    static let defaultHost = "127.0.0.1"
    static let defaultPort = 7890
    static let disabled = ProxyConfig(enabled: false, type: defaultType, host: defaultHost, port: defaultPort)

    /// 实际生效：启用且主机/端口有效
    var isActive: Bool { enabled && !host.isEmpty && port > 0 && port <= 65535 }
    var summary: String { isActive ? "\(type) \(host):\(port)" : "关" }
}

/// 通道连接配置：服务器/通道名/轮询间隔/代理存 UserDefaults；accesskey 存本机钥文件（见 KeyFileStore）。
struct ChannelConfig {
    var server: String
    var channel: String
    var intervalSec: Int
    var proxy: ProxyConfig

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
        static let proxyEnabled = "proxy.enabled"
        static let proxyType = "proxy.type"
        static let proxyHost = "proxy.host"
        static let proxyPort = "proxy.port"
    }

    static func load() -> ChannelConfig {
        let d = UserDefaults.standard
        let server = d.string(forKey: Key.server) ?? defaultServer
        let channel = d.string(forKey: Key.channel) ?? defaultChannel
        let savedInterval = d.object(forKey: Key.interval) as? Int
        let interval = savedInterval.flatMap { intervalChoices.contains($0) ? $0 : nil } ?? defaultInterval
        var proxy = ProxyConfig.disabled
        proxy.enabled = d.bool(forKey: Key.proxyEnabled)
        if let t = d.string(forKey: Key.proxyType), t == "socks" || t == "http" { proxy.type = t }
        if let h = d.string(forKey: Key.proxyHost), !h.isEmpty { proxy.host = h }
        if let p = d.object(forKey: Key.proxyPort) as? Int, p > 0, p <= 65535 { proxy.port = p }
        return ChannelConfig(server: server, channel: channel, intervalSec: interval, proxy: proxy)
    }

    static func save(_ config: ChannelConfig) {
        let d = UserDefaults.standard
        d.set(config.server, forKey: Key.server)
        d.set(config.channel, forKey: Key.channel)
        d.set(config.intervalSec, forKey: Key.interval)
        d.set(config.proxy.enabled, forKey: Key.proxyEnabled)
        d.set(config.proxy.type, forKey: Key.proxyType)
        d.set(config.proxy.host, forKey: Key.proxyHost)
        d.set(config.proxy.port, forKey: Key.proxyPort)
        PetLog.d("通道配置已保存 server=\(config.baseURL) channel=\(config.channel) interval=\(config.intervalSec)s proxy=\(config.proxy.summary)（钥在本机钥文件，不在此处）")
    }

    static func accessKey(for channel: String) -> String? {
        KeyFileStore.load(channel: channel)
    }
}
