import Foundation
import GRDB

/// 地理位置权限的默认策略。官方 Chrome 改不了坐标，所以默认禁止，避免泄漏本机真实位置。
public enum GeolocationPolicy: String, Codable, Sendable, CaseIterable {
    case block
    case ask
}

/// 一个浏览器环境（对应一个独立的 Chrome user-data-dir）。
public struct Profile: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    /// 序号，从 1 开始递增，删除后不复用。
    public var seq: Int
    public var name: String
    public var tags: [String]
    public var notes: String

    // 代理（数据库里按字段扁平存储，代码里用 proxy 读写）
    public var proxyKind: ProxyConfig.Kind?
    public var proxyHost: String?
    public var proxyPort: Int?
    public var proxyUsername: String?
    public var proxyPassword: String?
    /// 代理到期日（手动填写，用于提醒续费）。
    public var proxyExpiresAt: Date?
    /// 显式允许直连（没有代理时才有意义）。默认 false：没有代理就拒绝启动。
    public var allowDirect: Bool

    // 环境参数
    public var language: String
    /// nil 表示根据出口 IP 自动设置。
    public var timezone: String?
    public var geolocation: GeolocationPolicy
    public var windowWidth: Int?
    public var windowHeight: Int?
    /// 工具栏主题色 `#RRGGBB`，nil 表示根据 id 自动生成。
    public var themeColor: String?
    public var extraArgs: [String]

    public var lastExit: ExitInfo?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastOpenedAt: Date?
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        proxy: ProxyConfig? = nil,
        language: String = LanguageTag.auto,
        timezone: String? = nil,
        tags: [String] = [],
        notes: String = ""
    ) {
        let now = Date()
        self.id = id
        self.seq = 0
        self.name = name
        self.tags = tags
        self.notes = notes
        self.allowDirect = false
        self.language = language
        self.timezone = timezone
        self.geolocation = .block
        self.extraArgs = []
        self.createdAt = now
        self.updatedAt = now
        self.proxy = proxy
    }

    public var proxy: ProxyConfig? {
        get {
            guard let proxyKind, let proxyHost, let proxyPort else { return nil }
            return ProxyConfig(kind: proxyKind, host: proxyHost, port: proxyPort,
                               username: proxyUsername, password: proxyPassword)
        }
        set {
            proxyKind = newValue?.kind
            proxyHost = newValue?.host
            proxyPort = newValue?.port
            proxyUsername = newValue?.username
            proxyPassword = newValue?.password
        }
    }

    /// 本地入口要转给的上游；既没有代理也没允许直连时为 nil（不能启动、不能检测）。
    public var upstream: Upstream? {
        if let proxy { return .proxy(proxy) }
        return allowDirect ? .direct : nil
    }

    public var windowSize: WindowSize? {
        get { windowWidth.flatMap { w in windowHeight.map { WindowSize(width: w, height: $0) } } }
        set { windowWidth = newValue?.width; windowHeight = newValue?.height }
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// `#序号 名称`，提示和列表里指代一个环境时用。
    public var numberedName: String { "#\(seq) \(name)" }

    /// 实际使用的主题色。
    public var effectiveThemeColor: String {
        if let themeColor { return themeColor }
        return ThemePalette.color(for: id)
    }
}

extension Profile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "profile"
}

/// 自动配色：一组区分度高、不刺眼的颜色。
public enum ThemePalette {
    public static let colors = [
        "#E8453C", "#F29900", "#1E8E3E", "#1A73E8", "#9334E6",
        "#D01884", "#12A4AF", "#B06000", "#5F6368", "#3367D6",
        "#0B8043", "#C5221F",
    ]

    /// 校验用户填写的 `#RRGGBB`，返回统一的大写写法；不合法时返回 nil。
    public static func parse(_ text: String) -> String? {
        text.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil ? text.uppercased() : nil
    }

    public static func color(for id: String) -> String {
        // FNV-1a，保证跨进程稳定（Swift 的 hashValue 每次运行都不同）
        var hash: UInt32 = 2_166_136_261
        for b in id.utf8 { hash = (hash ^ UInt32(b)) &* 16_777_619 }
        return colors[Int(hash % UInt32(colors.count))]
    }
}

/// 窗口尺寸，文本写法 `宽x高`（也认 `×` 和 `*`），最小 400×300。
public struct WindowSize: Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init?(_ text: String) {
        let wh = text.lowercased().split(whereSeparator: { "x×*".contains($0) })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard wh.count == 2, wh[0] >= 400, wh[1] >= 300 else { return nil }
        self.init(width: wh[0], height: wh[1])
    }

    public var description: String { "\(width)x\(height)" }
}
