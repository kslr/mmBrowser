import Foundation

/// 一次启动要执行的命令。纯数据，便于测试和排查。
///
/// 恢复上次的会话用 `--restore-last-session`（macOS 作为登录项重开 Chrome 时 Chrome 自己也会加这个参数），
/// 它覆盖"启动时"设置，不用改受签名保护的配置；新建的环境第一次打开时它不生效，正好打开起始页。
/// 只启动一次进程（不用 `--no-startup-window`）。
/// 语言用 `-AppleLanguages ("xx-YY", "<")`：macOS 把它解析成语言数组、取第一个；
/// Chrome 会把这个位置参数当网址，但因为含 `<` 是无效网址，会被跳过，不会多开标签页。
public struct LaunchPlan: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]

    /// - language: 实际使用的语言（"自动"已经按出口解析好）
    /// - checkPageURL: 每次启动都打开的检测页
    public static func make(
        profile: Profile,
        language resolved: String,
        userDataDir: URL,
        localProxyPort: UInt16?,
        timezone: String,
        checkPageURL: String?,
        openStartURLs: Bool
    ) -> LaunchPlan {
        let language = LanguageTag.isValid(resolved) ? resolved : "en-US"
        var args: [String] = [
            "--user-data-dir=\(userDataDir.path)",
            "--use-mock-keychain",
            "--no-first-run",
            "--no-default-browser-check",
            "--restore-last-session",
        ]
        if let port = localProxyPort {
            // 不加 --host-resolver-rules：Chrome 把它列为"不受支持的参数"，会在窗口顶部弹警告条，也容易被识别。
            // 也不需要它：SOCKS5 下域名总是交给代理解析；走代理的网址，预连接也会跳过本地 DNS 预解析。
            args.append("--proxy-server=socks5://127.0.0.1:\(port)")
        }
        args += [
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--disable-quic",
            "--lang=\(language)",
            "--accept-lang=\(CountryLocale.acceptLanguage(for: language))",
        ]
        if let w = profile.windowWidth, let h = profile.windowHeight {
            args.append("--window-size=\(w),\(h)")
        }
        args += ChromeFlags.withDisabledFeatures(profile.extraArgs)
        args += ["-AppleLanguages", "(\"\(language)\", \"<\")"]
        if let checkPageURL { args.append(checkPageURL) }
        if openStartURLs { args += profile.startURLs.filter { $0 != checkPageURL } }
        return LaunchPlan(arguments: args, environment: ["TZ": timezone])
    }
}

/// 正式启动和无界面维护都要加的 Chrome 参数。
public enum ChromeFlags {
    /// 总是关掉的功能：
    /// - MacAppCodeSignClone：Chrome 启动时会用硬链接把自己的 app 包克隆到临时目录（防止运行中被更新替换）。
    ///   由本程序启动时，macOS 的「App 管理」把这当成本程序在修改别的 App，拒绝并弹出
    ///  「mmBrowser 已被阻止修改你 Mac 上的 App」。关掉后只少了这层防护：Chrome 在运行中被更新时，
    ///   和以前一样需要重开。
    static let disabledFeatures = ["MacAppCodeSignClone"]

    /// 在 args 里合并出唯一一个 `--disable-features`：Chrome 只认最后一个，分开写会互相覆盖。
    /// 用户自己写的会保留，放在原来第一次出现的位置。
    public static func withDisabledFeatures(_ args: [String]) -> [String] {
        let prefix = "--disable-features="
        var features: [String] = []
        var out: [String] = []
        var slot: Int?
        for a in args {
            if a.hasPrefix(prefix) {
                features += a.dropFirst(prefix.count).split(separator: ",").map(String.init)
                if slot == nil { slot = out.count; out.append("") }
            } else {
                out.append(a)
            }
        }
        for f in disabledFeatures where !features.contains(f) { features.append(f) }
        let merged = prefix + features.filter { !$0.isEmpty }.joined(separator: ",")
        if let slot { out[slot] = merged } else { out.append(merged) }
        return out
    }
}

/// BCP 47 语言标签的简单校验（只允许字母、数字和连字符），防止拼进 plist 字符串时出问题。
public enum LanguageTag {
    /// 环境语言设为这个值时，按出口 IP 所在国家自动决定。
    public static let auto = "auto"

    /// 解析"自动"：按出口国家推荐，找不到就用 fallback。
    public static func resolve(_ language: String, countryCode: String?, fallback: String = "en-US") -> String {
        guard language == auto else { return language }
        return CountryLocale.recommendedLanguage(for: countryCode) ?? fallback
    }

    /// 合法的语言设置：auto 或 BCP 47 标签。
    public static func isValidSetting(_ s: String) -> Bool { s == auto || isValid(s) }

    public static func isValid(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
    }
}
