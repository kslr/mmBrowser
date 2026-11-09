import Foundation

/// 一次启动要执行的命令。纯数据，便于测试和排查。
///
/// 只启动一次进程（不用 `--no-startup-window`），这样 Chrome 会正常执行"启动时恢复上次的会话"。
/// 语言用 `-AppleLanguages ("xx-YY", "<")`：macOS 把它解析成语言数组、取第一个；
/// Chrome 会把这个位置参数当网址，但因为含 `<` 是无效网址，会被跳过，不会多开标签页。
public struct LaunchPlan: Sendable, Equatable {
    public var arguments: [String]
    public var environment: [String: String]

    public static func make(
        profile: Profile,
        userDataDir: URL,
        localProxyPort: UInt16?,
        timezone: String,
        openStartURLs: Bool
    ) -> LaunchPlan {
        let language = LanguageTag.isValid(profile.language) ? profile.language : "en-US"
        var args: [String] = [
            "--user-data-dir=\(userDataDir.path)",
            "--use-mock-keychain",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        if let port = localProxyPort {
            args += [
                "--proxy-server=socks5://127.0.0.1:\(port)",
                // 除了本地入口，一律不在本地做 DNS 解析
                "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",
            ]
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
        args += profile.extraArgs
        args += ["-AppleLanguages", "(\"\(language)\", \"<\")"]
        if openStartURLs { args += profile.startURLs }
        return LaunchPlan(arguments: args, environment: ["TZ": timezone])
    }
}

/// BCP 47 语言标签的简单校验（只允许字母、数字和连字符），防止拼进 plist 字符串时出问题。
public enum LanguageTag {
    public static func isValid(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil
    }
}
