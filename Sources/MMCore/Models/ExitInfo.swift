import Foundation

/// 经由代理检测到的出口信息。
public struct ExitInfo: Codable, Hashable, Sendable {
    public var ip: String
    public var countryCode: String?
    public var country: String?
    public var region: String?
    public var city: String?
    public var timezone: String?
    public var org: String?
    public var latencyMs: Int?
    public var provider: String
    public var checkedAt: Date

    public init(ip: String, countryCode: String? = nil, country: String? = nil, region: String? = nil,
                city: String? = nil, timezone: String? = nil, org: String? = nil, latencyMs: Int? = nil,
                provider: String, checkedAt: Date = Date()) {
        self.ip = ip
        self.countryCode = countryCode
        self.country = country
        self.region = region
        self.city = city
        self.timezone = timezone
        self.org = org
        self.latencyMs = latencyMs
        self.provider = provider
        self.checkedAt = checkedAt
    }

    public var summary: String {
        let place = [countryCode, region, city].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " / ")
        var s = ip
        if !place.isEmpty { s += "  \(place)" }
        if let timezone { s += "  \(timezone)" }
        if let latencyMs { s += "  \(latencyMs)ms" }
        return s
    }
}
