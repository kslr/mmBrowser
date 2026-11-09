import Foundation
import Network

public enum GeoCheckError: Error, LocalizedError {
    case allProvidersFailed([String])

    public var errorDescription: String? {
        switch self {
        case .allProvidersFailed(let errors): L("error.geo.failed \(errors.joined(separator: L("common.errorSeparator")))")
        }
    }
}

/// 经由代理查询出口 IP 和地理信息。
///
/// 请求走的是和 Chrome 完全相同的路径（本地 SOCKS5 入口 → 上游），所以检测通过就说明浏览器也能连通。
public enum GeoCheck {
    struct Provider: Sendable {
        let name: String
        let url: URL
        let parse: @Sendable (Data) throws -> ExitInfo
    }

    static let providers: [Provider] = [
        Provider(name: "ipinfo.io", url: URL(string: "https://ipinfo.io/json")!) { data in
            struct R: Decodable { let ip: String; let city, region, country, timezone, org: String? }
            let r = try JSONDecoder().decode(R.self, from: data)
            return ExitInfo(ip: r.ip, countryCode: r.country, region: r.region, city: r.city,
                            timezone: r.timezone, org: r.org, provider: "ipinfo.io")
        },
        Provider(name: "ipwho.is", url: URL(string: "https://ipwho.is/")!) { data in
            struct TZ: Decodable { let id: String? }
            struct Conn: Decodable { let org, isp: String? }
            struct R: Decodable {
                let ip: String; let success: Bool?; let country, country_code, region, city: String?
                let timezone: TZ?; let connection: Conn?
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            return ExitInfo(ip: r.ip, countryCode: r.country_code, country: r.country, region: r.region,
                            city: r.city, timezone: r.timezone?.id, org: r.connection?.org ?? r.connection?.isp,
                            provider: "ipwho.is")
        },
        Provider(name: "ip.sb", url: URL(string: "https://api.ip.sb/geoip")!) { data in
            struct R: Decodable { let ip: String; let country, country_code, region, city, timezone, organization: String? }
            let r = try JSONDecoder().decode(R.self, from: data)
            return ExitInfo(ip: r.ip, countryCode: r.country_code, country: r.country, region: r.region,
                            city: r.city, timezone: r.timezone, org: r.organization, provider: "ip.sb")
        },
    ]

    /// 临时起一个本地入口做检测，检测完关闭。
    public static func check(upstream: Upstream, timeout: TimeInterval = 10) async throws -> ExitInfo {
        let server = LocalProxyServer(upstream: upstream)
        let port = try await server.start()
        defer { server.stop() }
        return try await check(localSocksPort: port, timeout: timeout)
    }

    /// 通过一个已经在运行的本地入口检测。依次尝试多个查询服务，第一个成功的为准。
    public static func check(localSocksPort port: UInt16, timeout: TimeInterval = 10) async throws -> ExitInfo {
        let config = URLSessionConfiguration.ephemeral
        config.proxyConfigurations = [
            ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        ]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "curl/8.7.1"]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var errors: [String] = []
        for p in providers {
            let started = Date()
            do {
                let (data, resp) = try await session.data(from: p.url)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    errors.append("\(p.name) HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                    continue
                }
                var info = try p.parse(data)
                info.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                info.checkedAt = Date()
                return info
            } catch {
                errors.append("\(p.name) \(error.localizedDescription)")
            }
        }
        throw GeoCheckError.allProvidersFailed(errors)
    }
}
