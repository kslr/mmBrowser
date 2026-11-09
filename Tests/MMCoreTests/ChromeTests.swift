import Foundation
import Testing
@testable import MMCore

@Suite("Chrome 启动参数与配置种子")
struct ChromeTests {
    func sampleProfile() -> Profile {
        var p = Profile(name: "客户A-01", proxy: ProxyConfig(kind: .socks5, host: "h", port: 1),
                        language: "ja-JP", startURLs: ["https://example.com/", "https://example.org/"])
        p.windowWidth = 1440; p.windowHeight = 900
        p.extraArgs = ["--force-dark-mode"]
        return p
    }

    @Test("一步启动：代理与防泄漏参数、语言写法不会被当成网址；启动页按需附加")
    func plan() {
        let dir = URL(fileURLWithPath: "/tmp/mm/p1")
        let first = LaunchPlan.make(profile: sampleProfile(), userDataDir: dir, localProxyPort: 40000,
                                    timezone: "Asia/Tokyo", openStartURLs: true)
        #expect(first.environment == ["TZ": "Asia/Tokyo"])
        let args = first.arguments
        #expect(args.contains("--user-data-dir=/tmp/mm/p1"))
        #expect(args.contains("--use-mock-keychain"))
        #expect(args.contains("--proxy-server=socks5://127.0.0.1:40000"))
        #expect(args.contains("--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"))
        #expect(args.contains("--force-webrtc-ip-handling-policy=disable_non_proxied_udp"))
        #expect(args.contains("--lang=ja-JP"))
        #expect(args.contains("--accept-lang=ja-JP,ja"))
        #expect(args.contains("--window-size=1440,900"))
        #expect(args.contains("--force-dark-mode"))
        #expect(!args.contains("--no-startup-window"))
        #expect(!args.contains("-AppleLocale"))
        #expect(args.suffix(4) == ["-AppleLanguages", "(\"ja-JP\", \"<\")", "https://example.com/", "https://example.org/"])

        let later = LaunchPlan.make(profile: sampleProfile(), userDataDir: dir, localProxyPort: 40000,
                                    timezone: "Asia/Tokyo", openStartURLs: false)
        #expect(later.arguments.suffix(2) == ["-AppleLanguages", "(\"ja-JP\", \"<\")"])
    }

    @Test("非法语言代码回落到 en-US，避免拼坏 plist")
    func badLanguage() {
        var p = sampleProfile(); p.language = "ja\", \"x"
        let plan = LaunchPlan.make(profile: p, userDataDir: URL(fileURLWithPath: "/tmp/x"), localProxyPort: 1,
                                   timezone: "UTC", openStartURLs: false)
        #expect(plan.arguments.contains("(\"en-US\", \"<\")"))
        #expect(LanguageTag.isValid("zh-Hant-TW"))
        #expect(!LanguageTag.isValid("en_US"))
    }

    @Test("直连环境不带代理参数")
    func directPlan() {
        var p = sampleProfile(); p.proxy = nil; p.allowDirect = true
        let plan = LaunchPlan.make(profile: p, userDataDir: URL(fileURLWithPath: "/tmp/x"), localProxyPort: nil,
                                   timezone: "UTC", openStartURLs: false)
        #expect(!plan.arguments.contains { $0.hasPrefix("--proxy-server") })
    }

    @Test("SkColor 换算")
    func skColor() {
        #expect(ProfileSeed.skColor(hex: "#1A73E8") == Int(Int32(bitPattern: 0xFF1A73E8)))
        #expect(ProfileSeed.skColor(hex: "#000000") == -16_777_216)
    }

    @Test("种子：更新管理项，保留 Chrome 自己写的其它配置")
    func seed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmseed-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var p = sampleProfile()
        try ProfileSeed.apply(profile: p, userDataDir: dir)

        let prefsURL = dir.appendingPathComponent("Default/Preferences")
        var prefs = try ProfileSeed.readJSON(prefsURL)
        #expect((prefs["profile"] as? [String: Any])?["name"] as? String == "客户A-01")
        #expect(((prefs["profile"] as? [String: Any])?["default_content_setting_values"] as? [String: Any])?["geolocation"] as? Int == 2)
        #expect(prefs["session"] == nil, "受校验的项不写文件，交给 ProfileInitializer")

        // 模拟 Chrome 运行后写了自己的配置
        ProfileSeed.set(&prefs, "chrome_owned.some_key", "keep me")
        try ProfileSeed.writeJSON(prefs, to: prefsURL)

        p.name = "改名"; p.geolocation = .ask
        try ProfileSeed.apply(profile: p, userDataDir: dir)
        prefs = try ProfileSeed.readJSON(prefsURL)
        #expect((prefs["profile"] as? [String: Any])?["name"] as? String == "改名")
        #expect(((prefs["profile"] as? [String: Any])?["default_content_setting_values"] as? [String: Any])?["geolocation"] as? Int == 3)
        #expect((prefs["chrome_owned"] as? [String: Any])?["some_key"] as? String == "keep me")

        let state = try ProfileSeed.readJSON(dir.appendingPathComponent("Local State"))
        let info = ((state["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?["Default"] as? [String: Any]
        #expect(info?["name"] as? String == "改名")
        let mode = try FileManager.default.attributesOfItem(atPath: prefsURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
