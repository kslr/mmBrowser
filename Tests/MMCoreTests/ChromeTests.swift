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
        let first = LaunchPlan.make(profile: sampleProfile(), language: "ja-JP", userDataDir: dir, localProxyPort: 40000,
                                    timezone: "Asia/Tokyo", checkPageURL: "https://check.example/", openStartURLs: true)
        #expect(first.environment == ["TZ": "Asia/Tokyo"])
        let args = first.arguments
        #expect(args.contains("--user-data-dir=/tmp/mm/p1"))
        #expect(args.contains("--use-mock-keychain"))
        #expect(args.contains("--restore-last-session"))
        #expect(args.contains("--proxy-server=socks5://127.0.0.1:40000"))
        // Chrome 会对这个参数弹"不受支持的命令行标记"警告条
        #expect(!args.contains { $0.hasPrefix("--host-resolver-rules") })
        #expect(args.contains("--force-webrtc-ip-handling-policy=disable_non_proxied_udp"))
        #expect(args.contains("--lang=ja-JP"))
        #expect(args.contains("--accept-lang=ja-JP,ja"))
        #expect(args.contains("--window-size=1440,900"))
        #expect(args.contains("--force-dark-mode"))
        #expect(!args.contains("--no-startup-window"))
        #expect(!args.contains("-AppleLocale"))
        #expect(args.suffix(5) == ["-AppleLanguages", "(\"ja-JP\", \"<\")", "https://check.example/",
                                   "https://example.com/", "https://example.org/"])

        // 之后的启动：恢复会话 + 检测页；没有检测页时什么网址都不带
        let later = LaunchPlan.make(profile: sampleProfile(), language: "ja-JP", userDataDir: dir, localProxyPort: 40000,
                                    timezone: "Asia/Tokyo", checkPageURL: "https://check.example/", openStartURLs: false)
        #expect(later.arguments.suffix(3) == ["-AppleLanguages", "(\"ja-JP\", \"<\")", "https://check.example/"])
        let none = LaunchPlan.make(profile: sampleProfile(), language: "ja-JP", userDataDir: dir, localProxyPort: 40000,
                                   timezone: "Asia/Tokyo", checkPageURL: nil, openStartURLs: false)
        #expect(none.arguments.suffix(2) == ["-AppleLanguages", "(\"ja-JP\", \"<\")"])
    }

    @Test("非法语言代码回落到 en-US，避免拼坏 plist")
    func badLanguage() {
        let plan = LaunchPlan.make(profile: sampleProfile(), language: "ja\", \"x", userDataDir: URL(fileURLWithPath: "/tmp/x"),
                                   localProxyPort: 1, timezone: "UTC", checkPageURL: nil, openStartURLs: false)
        #expect(plan.arguments.contains("(\"en-US\", \"<\")"))
        #expect(LanguageTag.isValid("zh-Hant-TW"))
        #expect(!LanguageTag.isValid("en_US"))
        #expect(LanguageTag.resolve("auto", countryCode: "JP") == "ja-JP")
        #expect(LanguageTag.resolve("auto", countryCode: "XX") == "en-US")
        #expect(LanguageTag.resolve("de-DE", countryCode: "JP") == "de-DE")
        #expect(LanguageTag.isValidSetting("auto") && !LanguageTag.isValid("auto"))
    }

    @Test("直连环境不带代理参数")
    func directPlan() {
        var p = sampleProfile(); p.proxy = nil; p.allowDirect = true
        let plan = LaunchPlan.make(profile: p, language: "en-US", userDataDir: URL(fileURLWithPath: "/tmp/x"),
                                   localProxyPort: nil, timezone: "UTC", checkPageURL: nil, openStartURLs: false)
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
        try ProfileSeed.apply(profile: p, language: p.language, userDataDir: dir)

        let prefsURL = dir.appendingPathComponent("Default/Preferences")
        var prefs = try ProfileSeed.readJSON(prefsURL)
        #expect((prefs["profile"] as? [String: Any])?["name"] as? String == "客户A-01")
        #expect(((prefs["profile"] as? [String: Any])?["default_content_setting_values"] as? [String: Any])?["geolocation"] as? Int == 2)
        #expect(prefs["session"] == nil, "受校验的项不写文件，恢复会话用启动参数")

        // 模拟 Chrome 运行后写了自己的配置
        ProfileSeed.set(&prefs, "chrome_owned.some_key", "keep me")
        try ProfileSeed.writeJSON(prefs, to: prefsURL)

        p.name = "改名"; p.geolocation = .ask
        try ProfileSeed.apply(profile: p, language: p.language, userDataDir: dir)
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

    @Test("无界面维护写进的窗口大小会被撤销：原来没有就删掉，原来有就放回")
    func windowPlacementRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmwin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Default"), withIntermediateDirectories: true)
        let prefsURL = dir.appendingPathComponent("Default/Preferences")
        let headless: [String: Any] = ["left": 22, "top": 22, "right": 778, "bottom": 578]
        let user: [String: Any] = ["left": 10, "top": 35, "right": 1060, "bottom": 1045]

        // 首次初始化：之前没有窗口记录
        try ProfileSeed.writeJSON(["browser": ["has_seen_welcome_page": true]], to: prefsURL)
        let none = HeadlessChrome.windowPlacement(dir)
        #expect(none == nil)
        var prefs = try ProfileSeed.readJSON(prefsURL)
        ProfileSeed.set(&prefs, HeadlessChrome.windowPlacementKey, headless)
        try ProfileSeed.writeJSON(prefs, to: prefsURL)
        HeadlessChrome.restoreWindowPlacement(none, userDataDir: dir)
        prefs = try ProfileSeed.readJSON(prefsURL)
        #expect(ProfileSeed.get(prefs, HeadlessChrome.windowPlacementKey) == nil)
        #expect(ProfileSeed.get(prefs, "browser.has_seen_welcome_page") as? Bool == true)

        // 之后的维护（如装扩展）：放回用户自己的窗口大小
        ProfileSeed.set(&prefs, HeadlessChrome.windowPlacementKey, user)
        try ProfileSeed.writeJSON(prefs, to: prefsURL)
        let saved = HeadlessChrome.windowPlacement(dir)
        ProfileSeed.set(&prefs, HeadlessChrome.windowPlacementKey, headless)
        try ProfileSeed.writeJSON(prefs, to: prefsURL)
        HeadlessChrome.restoreWindowPlacement(saved, userDataDir: dir)
        prefs = try ProfileSeed.readJSON(prefsURL)
        #expect((ProfileSeed.get(prefs, HeadlessChrome.windowPlacementKey) as? [String: Any])?["right"] as? Int == 1060)
    }
}

@Suite("会话文件")
struct SessionTests {
    /// 构造一条 SNSS 命令：uint16 长度（含命令字节）+ 命令字节 + 负载
    func cmd(_ id: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let size = payload.count + 1
        return [UInt8(size & 0xFF), UInt8(size >> 8), id] + payload
    }
    func le(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func nav(tab: Int32, index: Int32, url: String) -> [UInt8] {
        var u = Array(url.utf8); while u.count % 4 != 0 { u.append(0) }
        let body = le(tab) + le(index) + le(Int32(url.utf8.count)) + u
        return cmd(6, le(Int32(body.count)) + body)
    }

    @Test func replay() {
        var file: [UInt8] = Array("SNSS".utf8) + le(3)
        file += cmd(0, le(1) + le(10))                       // tab 10 在窗口 1
        file += nav(tab: 10, index: 0, url: "https://www.browserscan.net/")
        file += nav(tab: 11, index: 0, url: "https://a.com/")
        file += nav(tab: 11, index: 1, url: "https://a.com/next")
        file += cmd(7, le(11) + le(1))                        // tab 11 选中第 1 条
        file += nav(tab: 12, index: 0, url: "https://closed.com/")
        file += cmd(16, le(12) + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 8))  // 关掉 tab 12
        #expect(SessionInspector.parse(Data(file)) == ["https://www.browserscan.net/", "https://a.com/next"])

        // 关掉检测页所在的窗口
        let closedWindow = file + cmd(17, le(1) + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 8))
        #expect(SessionInspector.parse(Data(closedWindow)) == ["https://a.com/next"])

        #expect(SessionInspector.parse(Data("XXXX".utf8)) == nil)
        #expect(SessionInspector.sameSite("https://www.browserscan.net/", "https://browserscan.net/x?y"))
        #expect(!SessionInspector.sameSite("https://ipinfo.io/", "https://browserscan.net/"))
    }
}
