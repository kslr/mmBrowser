import Foundation

/// 上游代理配置。一个环境对应一个代理（1:1）。
public struct ProxyConfig: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case socks5
        case http
    }

    public var kind: Kind
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?

    public init(kind: Kind, host: String, port: Int, username: String? = nil, password: String? = nil) {
        self.kind = kind
        self.host = host
        self.port = port
        self.username = username.flatMap { $0.isEmpty ? nil : $0 }
        self.password = password.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var hasCredentials: Bool { username != nil }

    /// 用于展示：密码打码。
    public var displayString: String {
        var s = "\(kind.rawValue)://"
        if let username { s += "\(username):***@" }
        s += "\(hostForURL):\(port)"
        return s
    }

    /// 完整 URL（含密码，百分号编码）。用于导出。
    public var urlString: String {
        var s = "\(kind.rawValue)://"
        if let username {
            s += Self.encode(username)
            if let password { s += ":" + Self.encode(password) }
            s += "@"
        }
        s += "\(hostForURL):\(port)"
        return s
    }

    private var hostForURL: String { host.contains(":") ? "[\(host)]" : host }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

public enum ProxyParseError: Error, LocalizedError, Equatable {
    case empty
    case unsupportedScheme(String)
    case invalidFormat(String)
    case invalidPort(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "代理字符串为空"
        case .unsupportedScheme(let s): "不支持的代理类型：\(s)（支持 socks5、http）"
        case .invalidFormat(let s): "无法识别的代理格式：\(s)"
        case .invalidPort(let s): "端口无效：\(s)"
        }
    }
}

extension ProxyConfig {
    /// 解析常见代理写法：
    /// - `socks5://user:pass@host:port`、`socks5h://…`、`socks://…`、`http://…`
    /// - `user:pass@host:port`（类型取 defaultKind）
    /// - `host:port` 或 `host:port:user:pass`（类型取 defaultKind；密码里可以有冒号）
    public static func parse(_ raw: String, defaultKind: Kind = .socks5) throws -> ProxyConfig {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProxyParseError.empty }

        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            let kind: Kind
            switch scheme {
            case "socks5", "socks5h", "socks": kind = .socks5
            case "http": kind = .http
            default: throw ProxyParseError.unsupportedScheme(scheme)
            }
            return try parseAuthority(String(text[schemeRange.upperBound...]), kind: kind, original: text)
        }

        if text.contains("@") {
            return try parseAuthority(text, kind: defaultKind, original: text)
        }

        // host:port[:user:pass]，IPv6 需要用 [] 包起来
        let (host, rest) = try splitHost(text, original: text)
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let portStr = parts.first, !portStr.isEmpty else { throw ProxyParseError.invalidFormat(text) }
        let port = try parsePort(portStr)
        switch parts.count {
        case 1:
            return ProxyConfig(kind: defaultKind, host: host, port: port)
        case 3:
            return ProxyConfig(kind: defaultKind, host: host, port: port, username: parts[1], password: parts[2])
        default:
            throw ProxyParseError.invalidFormat(text)
        }
    }

    private static func parseAuthority(_ authority: String, kind: Kind, original: String) throws -> ProxyConfig {
        var hostPort = authority
        var username: String?
        var password: String?
        if let at = authority.lastIndex(of: "@") {
            let userInfo = String(authority[..<at])
            hostPort = String(authority[authority.index(after: at)...])
            if let colon = userInfo.firstIndex(of: ":") {
                username = String(userInfo[..<colon]).removingPercentEncoding
                password = String(userInfo[userInfo.index(after: colon)...]).removingPercentEncoding
            } else {
                username = userInfo.removingPercentEncoding
            }
        }
        if hostPort.hasSuffix("/") { hostPort.removeLast() }
        let (host, rest) = try splitHost(hostPort, original: original)
        guard !rest.isEmpty, !rest.contains(":") else { throw ProxyParseError.invalidFormat(original) }
        return ProxyConfig(kind: kind, host: host, port: try parsePort(rest), username: username, password: password)
    }

    /// 返回 (host, host 之后冒号后面的部分)。
    private static func splitHost(_ s: String, original: String) throws -> (String, String) {
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { throw ProxyParseError.invalidFormat(original) }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":") else { throw ProxyParseError.invalidFormat(original) }
            return (host, String(after.dropFirst()))
        }
        guard let colon = s.firstIndex(of: ":") else { throw ProxyParseError.invalidFormat(original) }
        let host = String(s[..<colon])
        guard !host.isEmpty else { throw ProxyParseError.invalidFormat(original) }
        return (host, String(s[s.index(after: colon)...]))
    }

    private static func parsePort(_ s: String) throws -> Int {
        guard let p = Int(s), (1...65535).contains(p) else { throw ProxyParseError.invalidPort(s) }
        return p
    }
}
