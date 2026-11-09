import Foundation
import GRDB

/// 导入导出用的 Cookie 格式（与 Cookie-Editor / EditThisCookie 的 JSON 兼容，也接受 Puppeteer 的写法）。
public struct CookieRecord: Codable, Hashable, Sendable {
    public var domain: String
    public var name: String
    public var value: String
    public var path: String
    /// Unix 秒；nil 表示会话 Cookie。
    public var expirationDate: Double?
    public var secure: Bool
    public var httpOnly: Bool
    /// "no_restriction" / "lax" / "strict" / "unspecified"
    public var sameSite: String
    public var hostOnly: Bool
    public var session: Bool

    public init(domain: String, name: String, value: String, path: String = "/", expirationDate: Double? = nil,
                secure: Bool = false, httpOnly: Bool = false, sameSite: String = "unspecified", hostOnly: Bool? = nil) {
        self.domain = domain
        self.name = name
        self.value = value
        self.path = path
        self.expirationDate = expirationDate
        self.secure = secure
        self.httpOnly = httpOnly
        self.sameSite = sameSite
        self.hostOnly = hostOnly ?? !domain.hasPrefix(".")
        self.session = expirationDate == nil
    }

    enum CodingKeys: String, CodingKey {
        case domain, name, value, path, expirationDate, secure, httpOnly, sameSite, hostOnly, session
        case expires  // Puppeteer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawDomain = try c.decode(String.self, forKey: .domain)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? false
        httpOnly = try c.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? false
        let ss = (try c.decodeIfPresent(String.self, forKey: .sameSite) ?? "unspecified").lowercased()
        sameSite = switch ss {
        case "none", "no_restriction": "no_restriction"
        case "lax": "lax"
        case "strict": "strict"
        default: "unspecified"
        }
        var exp = try c.decodeIfPresent(Double.self, forKey: .expirationDate)
        if exp == nil, let e = try c.decodeIfPresent(Double.self, forKey: .expires), e > 0 { exp = e }
        let session = try c.decodeIfPresent(Bool.self, forKey: .session) ?? (exp == nil)
        expirationDate = session ? nil : exp
        self.session = expirationDate == nil
        if let hostOnly = try c.decodeIfPresent(Bool.self, forKey: .hostOnly) {
            self.hostOnly = hostOnly
            domain = hostOnly ? (rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain)
                              : (rawDomain.hasPrefix(".") ? rawDomain : "." + rawDomain)
        } else {
            hostOnly = !rawDomain.hasPrefix(".")
            domain = rawDomain
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(domain, forKey: .domain)
        try c.encode(name, forKey: .name)
        try c.encode(value, forKey: .value)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(expirationDate, forKey: .expirationDate)
        try c.encode(secure, forKey: .secure)
        try c.encode(httpOnly, forKey: .httpOnly)
        try c.encode(sameSite, forKey: .sameSite)
        try c.encode(hostOnly, forKey: .hostOnly)
        try c.encode(session, forKey: .session)
    }
}

public enum CookieError: Error, LocalizedError {
    case noDatabase
    case running
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .noDatabase: "这个环境还没有 Cookie 数据库，请先启动一次"
        case .running: "环境正在运行，请先关闭再导入导出 Cookie"
        case .unsupportedVersion(let v): "不认识的 Cookies 数据库版本 \(v)"
        }
    }
}

/// 直接读写 Chrome 的 `Default/Cookies`（环境必须处于关闭状态）。
public enum ChromeCookies {
    /// 1601-01-01 到 1970-01-01 的秒数
    static let windowsEpochOffset: Double = 11_644_473_600

    static func toChromeTime(_ unix: Double) -> Int64 { Int64((unix + windowsEpochOffset) * 1_000_000) }
    static func fromChromeTime(_ t: Int64) -> Double { Double(t) / 1_000_000 - windowsEpochOffset }

    static func databaseURL(_ userDataDir: URL) -> URL {
        userDataDir.appendingPathComponent("Default/Cookies")
    }

    private static func open(_ userDataDir: URL) throws -> (DatabaseQueue, Int) {
        let url = databaseURL(userDataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CookieError.noDatabase }
        let q = try DatabaseQueue(path: url.path)
        let version = try q.read { try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'version'") } ?? 0
        guard (18...30).contains(version) else { throw CookieError.unsupportedVersion(version) }
        return (q, version)
    }

    public static func read(userDataDir: URL) throws -> [CookieRecord] {
        let (q, version) = try open(userDataDir)
        return try q.read { db in
            try Row.fetchAll(db, sql: """
                SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly,
                       has_expires, is_persistent, samesite
                FROM cookies WHERE top_frame_site_key = ''
                """).compactMap { row -> CookieRecord? in
                let host: String = row["host_key"]
                var value: String = row["value"]
                let blob: Data = row["encrypted_value"] ?? Data()
                if value.isEmpty, !blob.isEmpty {
                    guard var plain = try? ChromeCrypto.decrypt(blob) else { return nil }
                    if version >= 24, plain.count >= 32 { plain = plain.dropFirst(32) }
                    value = String(decoding: plain, as: UTF8.self)
                }
                let persistent: Bool = row["is_persistent"]
                let ss: Int = row["samesite"]
                return CookieRecord(
                    domain: host, name: row["name"], value: value, path: row["path"],
                    expirationDate: persistent ? fromChromeTime(row["expires_utc"]) : nil,
                    secure: row["is_secure"], httpOnly: row["is_httponly"],
                    sameSite: [0: "no_restriction", 1: "lax", 2: "strict"][ss] ?? "unspecified")
            }
        }
    }

    /// 写入 Cookie。replaceAll 为 true 时先清空原有的（不分区的）Cookie。返回写入条数。
    @discardableResult
    public static func write(_ cookies: [CookieRecord], userDataDir: URL, replaceAll: Bool = false) throws -> Int {
        let (q, version) = try open(userDataDir)
        let now = toChromeTime(Date().timeIntervalSince1970)
        return try q.write { db in
            if replaceAll { try db.execute(sql: "DELETE FROM cookies WHERE top_frame_site_key = ''") }
            var n = 0
            for (i, c) in cookies.enumerated() {
                let host = c.hostOnly ? (c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain)
                                      : (c.domain.hasPrefix(".") ? c.domain : "." + c.domain)
                var plain = Data(c.value.utf8)
                if version >= 24 { plain = ChromeCrypto.hostDigest(host) + plain }
                let encrypted = try ChromeCrypto.encrypt(plain)
                let samesite = ["no_restriction": 0, "lax": 1, "strict": 2][c.sameSite] ?? -1
                let created = now + Int64(i)  // creation_utc 需要唯一性较好
                try db.execute(sql: """
                    INSERT OR REPLACE INTO cookies(creation_utc, host_key, top_frame_site_key, name, value, encrypted_value,
                        path, expires_utc, is_secure, is_httponly, last_access_utc, has_expires, is_persistent, priority,
                        samesite, source_scheme, source_port, last_update_utc, source_type, has_cross_site_ancestor)
                    VALUES (?, ?, '', ?, '', ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, 3, 0)
                    """, arguments: [
                        created, host, c.name, encrypted, c.path.isEmpty ? "/" : c.path,
                        c.expirationDate.map(toChromeTime) ?? 0, c.secure, c.httpOnly, now,
                        c.expirationDate != nil, c.expirationDate != nil, samesite,
                        c.secure ? 2 : 1, c.secure ? 443 : 80, now,
                    ])
                n += 1
            }
            return n
        }
    }

    public static func exportJSON(_ cookies: [CookieRecord]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(cookies)
    }

    /// 解析 JSON（数组，或带 cookies 字段的对象）。
    public static func importJSON(_ data: Data) throws -> [CookieRecord] {
        if let arr = try? JSONDecoder().decode([CookieRecord].self, from: data) { return arr }
        struct Wrapped: Decodable { let cookies: [CookieRecord] }
        return try JSONDecoder().decode(Wrapped.self, from: data).cookies
    }
}
