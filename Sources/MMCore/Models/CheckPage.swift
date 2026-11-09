import Foundation

/// 每次启动环境时自动打开的检测页（显示出口 IP、位置、时区、指纹一致性）。全局设置，不按环境区分。
public enum CheckPage: Codable, Hashable, Sendable {
    case preset(Preset)
    case custom(String)
    case none

    public enum Preset: String, Codable, CaseIterable, Sendable {
        case browserscan, pixelscan, ipinfo, ipleak

        public var title: String {
            switch self {
            case .browserscan: "BrowserScan（IP、位置、时区、指纹一致性）"
            case .pixelscan: "Pixelscan（指纹一致性检测）"
            case .ipinfo: "ipinfo.io（只看 IP 和位置）"
            case .ipleak: "IPLeak（IP、DNS、WebRTC 泄漏）"
            }
        }

        public var url: String {
            switch self {
            case .browserscan: "https://www.browserscan.net/"
            case .pixelscan: "https://pixelscan.net/fingerprint-check"
            case .ipinfo: "https://ipinfo.io/"
            case .ipleak: "https://ipleak.net/"
            }
        }
    }

    public static let `default` = CheckPage.preset(.browserscan)
    static let settingKey = "checkPage"

    public var url: String? {
        switch self {
        case .preset(let p): p.url
        case .custom(let s): s.isEmpty ? nil : s
        case .none: nil
        }
    }
}

extension Store {
    public var checkPage: CheckPage {
        get { (try? setting(CheckPage.settingKey, as: CheckPage.self)) ?? .default }
    }

    public func setCheckPage(_ page: CheckPage) throws {
        try setSetting(CheckPage.settingKey, page)
    }
}
