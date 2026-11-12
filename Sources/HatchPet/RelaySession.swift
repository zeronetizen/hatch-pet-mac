import Foundation

/// URLSession 工厂：轮询器与「测试连接」共用。代理启用时给 configuration 设
/// connectionProxyDictionary，让请求经本机代理客户端出海（直连 *.workers.dev
/// 的 TLS 握手在本机网络下会被干扰，代理可绕开）。
/// 字典键即 CFNetwork 的 kCFNetworkProxies* 常量对应的字符串值：
/// HTTPEnable/HTTPProxy/HTTPPort、HTTPSEnable/HTTPSProxy/HTTPSPort、
/// SOCKSEnable/SOCKSProxy/SOCKSPort。
enum RelaySession {
    static func makeConfiguration(proxy: ProxyConfig) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        guard proxy.isActive else {
            PetLog.d("会话配置：直连（proxy=\(proxy.summary)）")
            return config
        }
        var dict: [String: Any] = [:]
        if proxy.type == "socks" {
            dict["SOCKSEnable"] = 1
            dict["SOCKSProxy"] = proxy.host
            dict["SOCKSPort"] = proxy.port
        } else {
            // HTTP 类型：http 与 https 都走该代理（https 由代理 CONNECT 隧道承载）
            dict["HTTPEnable"] = 1
            dict["HTTPProxy"] = proxy.host
            dict["HTTPPort"] = proxy.port
            dict["HTTPSEnable"] = 1
            dict["HTTPSProxy"] = proxy.host
            dict["HTTPSPort"] = proxy.port
        }
        config.connectionProxyDictionary = dict
        PetLog.d("会话配置：经代理 type=\(proxy.type) host=\(proxy.host) port=\(proxy.port)")
        return config
    }

    static func makeSession(proxy: ProxyConfig) -> URLSession {
        URLSession(configuration: makeConfiguration(proxy: proxy))
    }
}
