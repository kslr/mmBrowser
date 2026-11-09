import ArgumentParser
import Foundation
import MMCore

@main
struct MMCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mmctl",
        abstract: "mmBrowser 命令行（P1 测试入口）",
        discussion: "数据目录默认 ~/Library/Application Support/mmBrowser，可用环境变量 MMBROWSER_HOME 覆盖。",
        subcommands: [Create.self, List.self, Show.self, Set_.self, Check.self, Launch.self, Plan.self,
                      Remove.self, Restore.self, Serve.self, ChromeInfo.self]
    )
}

// MARK: - 共用

func openStore() throws -> Store {
    setvbuf(stdout, nil, _IOLBF, 0)  // 输出重定向到文件时也逐行写出
    return try Store(paths: .default())
}

struct ProfileOptions: ParsableArguments {
    @Option(help: "代理，如 socks5://user:pass@host:port、http://host:port、host:port:user:pass")
    var proxy: String?
    @Option(help: "代理字符串没写类型时按什么处理：socks5 或 http")
    var proxyType: ProxyConfig.Kind = .socks5
    @Flag(help: "允许直连（不走代理）")
    var direct = false
    @Option(help: "语言，如 en-US、ja-JP、zh-CN")
    var lang: String?
    @Option(help: "时区（IANA 名称，如 America/New_York）；auto 表示跟随出口 IP")
    var tz: String?
    @Option(name: .customLong("url"), help: "启动页，可以重复（默认只在第一次打开环境时打开）")
    var urls: [String] = []
    @Option(help: "每次启动都打开启动页：true 或 false")
    var alwaysOpenUrls: Bool?
    @Option(help: "分组名（不存在会自动创建）")
    var group: String?
    @Option(name: .customLong("tag"), help: "标签，可以重复")
    var tags: [String] = []
    @Option(help: "备注")
    var notes: String?
    @Option(help: "窗口尺寸，如 1440x900")
    var window: String?
    @Option(help: "工具栏主题色，如 #1A73E8")
    var color: String?
    @Option(help: "定位权限：block 或 ask")
    var geo: GeolocationPolicy?
    @Option(name: .customLong("arg"), parsing: .unconditionalSingleValue, help: "额外的 Chrome 启动参数，可以重复")
    var extraArgs: [String] = []

    func apply(to p: inout Profile, store: Store) throws {
        if let proxy { p.proxy = try ProxyConfig.parse(proxy, defaultKind: proxyType); p.allowDirect = false }
        if direct { p.proxy = nil; p.allowDirect = true }
        if let lang {
            guard LanguageTag.isValid(lang) else { throw ValidationError("无效的语言代码：\(lang)（例如 en-US、ja-JP）") }
            p.language = lang
        }
        if let alwaysOpenUrls { p.alwaysOpenStartURLs = alwaysOpenUrls }
        if let tz {
            if tz == "auto" {
                p.timezone = nil
            } else {
                guard TimeZone(identifier: tz) != nil else { throw ValidationError("无效的时区：\(tz)") }
                p.timezone = tz
            }
        }
        if !urls.isEmpty { p.startURLs = urls }
        if let group { p.groupId = try store.group(named: group).id }
        if !tags.isEmpty { p.tags = tags }
        if let notes { p.notes = notes }
        if let window {
            let parts = window.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2 else { throw ValidationError("窗口尺寸格式应为 宽x高，如 1440x900") }
            p.windowWidth = parts[0]; p.windowHeight = parts[1]
        }
        if let color {
            guard color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw ValidationError("颜色格式应为 #RRGGBB")
            }
            p.themeColor = color.uppercased()
        }
        if let geo { p.geolocation = geo }
        if !extraArgs.isEmpty { p.extraArgs = extraArgs }
    }
}

extension ProxyConfig.Kind: ExpressibleByArgument {}
extension GeolocationPolicy: ExpressibleByArgument {}

func describe(_ p: Profile, groups: [ProfileGroup], running: Int32?) -> String {
    let group = groups.first { $0.id == p.groupId }?.name
    var lines = [
        "#\(p.seq)  \(p.name)\(running.map { "  [运行中 PID \($0)]" } ?? "")",
        "  id:        \(p.id)",
        "  分组/标签:  \(group ?? "-") / \(p.tags.isEmpty ? "-" : p.tags.joined(separator: ", "))",
        "  代理:      \(p.proxy?.displayString ?? (p.allowDirect ? "直连（已允许）" : "未配置"))",
        "  语言/时区:  \(p.language) / \(p.timezone ?? "自动（跟随出口 IP）")",
        "  定位权限:   \(p.geolocation == .block ? "禁止" : "询问")",
        "  窗口/颜色:  \(p.windowWidth.map { "\($0)x\(p.windowHeight ?? 0)" } ?? "默认") / \(p.effectiveThemeColor)",
        "  启动页:    \(p.startURLs.isEmpty ? "-" : p.startURLs.joined(separator: "  "))\(p.alwaysOpenStartURLs ? "（每次启动都打开）" : "（仅首次打开）")",
    ]
    if !p.extraArgs.isEmpty { lines.append("  额外参数:   \(p.extraArgs.joined(separator: " "))") }
    if !p.notes.isEmpty { lines.append("  备注:      \(p.notes)") }
    if let e = p.lastExit {
        lines.append("  上次出口:   \(e.summary)  (\(e.provider), \(e.checkedAt.formatted(date: .numeric, time: .shortened)))")
    }
    if let d = p.deletedAt { lines.append("  已删除于:   \(d.formatted())") }
    return lines.joined(separator: "\n")
}

// MARK: - 命令

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "新建环境")
    @Option(help: "名称") var name: String
    @OptionGroup var options: ProfileOptions

    func run() async throws {
        let store = try openStore()
        var p = Profile(name: name)
        try options.apply(to: &p, store: store)
        if p.proxy == nil && !p.allowDirect {
            throw ValidationError("请用 --proxy 指定代理，或者用 --direct 明确允许直连")
        }
        let saved = try store.insert(p)
        print(describe(saved, groups: try store.groups(), running: nil))
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "列出环境")
    @Flag(help: "只看回收站") var deleted = false

    func run() async throws {
        let store = try openStore()
        let launcher = try? BrowserLauncher(store: store, chrome: ChromeInstallation())
        let groups = try store.groups()
        let rows = try store.profiles(onlyDeleted: deleted)
        if rows.isEmpty { print(deleted ? "回收站是空的" : "还没有环境，用 mmctl create 新建"); return }
        for p in rows {
            let group = groups.first { $0.id == p.groupId }?.name ?? "-"
            let status = launcher?.runningPID(of: p.id).map { _ in "运行中" } ?? ""
            let proxy = p.proxy?.displayString ?? (p.allowDirect ? "直连" : "未配置")
            let exit = p.lastExit.map { "\($0.ip) \($0.countryCode ?? "")" } ?? ""
            print(String(format: "#%-4d %@", p.seq, "\(p.name)  [\(group)]  \(proxy)  \(exit)  \(p.language)  \(status)"))
        }
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "查看环境详情")
    @Argument(help: "环境：#序号、名称或 id 前缀") var ref: String

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref, includeDeleted: true)
        let pid = (try? BrowserLauncher(store: store, chrome: ChromeInstallation()))?.runningPID(of: p.id)
        print(describe(p, groups: try store.groups(), running: pid))
        print("  目录:      \(store.paths.profileDir(p.id).path)")
    }
}

struct Set_: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "修改环境（只改给出的项，重启环境后生效）")
    @Argument(help: "环境：#序号、名称或 id 前缀") var ref: String
    @Option(help: "新名称") var name: String?
    @OptionGroup var options: ProfileOptions

    func run() async throws {
        let store = try openStore()
        var p = try store.resolve(ref)
        if let name { p.name = name }
        try options.apply(to: &p, store: store)
        try store.update(p)
        print(describe(try store.resolve(p.id), groups: try store.groups(), running: nil))
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "检测代理出口（IP、国家、时区、延迟）")
    @Argument(help: "环境：#序号、名称或 id 前缀（不填则用 --proxy）") var ref: String?
    @Option(help: "直接检测一个代理字符串") var proxy: String?
    @Option(help: "代理字符串没写类型时按什么处理") var proxyType: ProxyConfig.Kind = .socks5

    func run() async throws {
        let store = try openStore()
        let upstream: Upstream
        var profile: Profile?
        if let proxy {
            upstream = .proxy(try ProxyConfig.parse(proxy, defaultKind: proxyType))
        } else if let ref {
            let p = try store.resolve(ref)
            profile = p
            if let cfg = p.proxy { upstream = .proxy(cfg) } else if p.allowDirect { upstream = .direct } else { throw ChromeError.noProxy }
        } else {
            throw ValidationError("请给出环境或 --proxy")
        }
        let info = try await GeoCheck.check(upstream: upstream)
        if let profile { try store.recordExit(info, for: profile.id) }
        print("出口 IP:  \(info.ip)")
        print("位置:     \([info.countryCode, info.country, info.region, info.city].compactMap { $0 }.joined(separator: " / "))")
        print("时区:     \(info.timezone ?? "-")")
        print("运营商:   \(info.org ?? "-")")
        print("耗时:     \(info.latencyMs ?? 0) ms（\(info.provider)）")
        if let lang = CountryLocale.recommendedLanguage(for: info.countryCode) {
            let current = profile.map { "，当前 \($0.language)" } ?? ""
            print("推荐语言: \(lang)\(current)")
        }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "打印启动命令（不启动）")
    @Argument(help: "环境：#序号、名称或 id 前缀") var ref: String

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref)
        let tz = p.timezone ?? p.lastExit?.timezone ?? "<出口时区>"
        let plan = LaunchPlan.make(profile: p, userDataDir: store.paths.profileDir(p.id),
                                   localProxyPort: p.proxy == nil ? nil : 0, timezone: tz,
                                   openStartURLs: p.lastOpenedAt == nil || p.alwaysOpenStartURLs)
        print("环境变量: TZ=\(tz)（本地入口端口在启动时分配，这里显示为 0）")
        print("参数:\n  " + plan.arguments.joined(separator: "\n  "))
    }
}

/// 收到 Ctrl-C 时调用一次。
final class SignalWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    init(_ handler: @escaping @Sendable () -> Void) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler(handler: handler)
            s.resume()
            sources.append(s)
        }
    }
}

struct Launch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "启动环境（前台运行：本地代理入口跟随本命令，Ctrl-C 会正常关闭浏览器）")
    @Argument(help: "环境：#序号、名称或 id 前缀") var ref: String
    @Flag(name: .shortAndLong, help: "打印每条隧道的建立和关闭") var verbose = false

    func run() async throws {
        let store = try openStore()
        let chrome = try ChromeInstallation()
        let launcher = BrowserLauncher(store: store, chrome: chrome)
        let p = try store.resolve(ref)
        print("启动 #\(p.seq) \(p.name)（Chrome \(chrome.version ?? "?")）")
        let verbose = self.verbose
        let running = try await launcher.launch(profileId: p.id, progress: { stage in
            switch stage {
            case .startingProxy: print("· 启动本地代理入口")
            case .checkingExit: print("· 检测出口")
            case .exitChecked(let e): print("  出口 \(e.summary)")
            case .seeding: print("· 写入 Chrome 配置")
            case .initializing: print("· 首次初始化（离线设置启动时恢复会话）")
            case .startingChrome: print("· 启动 Chrome")
            }
        }, proxyEvents: { event in
            switch event {
            case .tunnelFailed(let t, let why): print("  ✗ \(t?.authority ?? "-")  \(why)")
            case .tunnelOpened(let t, let ms): if verbose { print("  → \(t.authority)  \(ms)ms") }
            case .tunnelClosed(let t, let up, let down): if verbose { print("  ← \(t.authority)  ↑\(up) ↓\(down)") }
            }
        })
        print("已启动：PID \(running.pid)，本地入口 127.0.0.1:\(running.proxy?.port ?? 0)，时区 \(running.timezone)")
        print("关闭浏览器（Cmd-Q）或在这里按 Ctrl-C 结束。")
        let watcher = SignalWatcher {
            print("\n正在关闭浏览器…")
            Task { await running.terminate() }
        }
        await running.waitUntilExit()
        _ = watcher
        print("浏览器已退出，本地代理入口已关闭。")
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "删除环境（默认移入回收站）")
    @Argument(help: "环境：#序号、名称或 id 前缀") var ref: String
    @Flag(help: "彻底删除，包括环境目录（保存的密码、Cookie 都会删掉）") var purge = false

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref, includeDeleted: true)
        if let pid = (try? BrowserLauncher(store: store, chrome: ChromeInstallation()))?.runningPID(of: p.id) {
            throw ChromeError.alreadyRunning(pid: pid)
        }
        if purge {
            try store.purge(p.id)
            print("已彻底删除 #\(p.seq) \(p.name)")
        } else {
            try store.softDelete(p.id)
            print("已移入回收站 #\(p.seq) \(p.name)（mmctl restore \(p.seq) 可恢复）")
        }
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "从回收站恢复")
    @Argument(help: "环境：#序号、名称或 id 前缀") var ref: String

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref, includeDeleted: true)
        try store.restore(p.id)
        print("已恢复 #\(p.seq) \(p.name)")
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "只运行一个本地 SOCKS5 入口（调试用，比如 curl --socks5-hostname 127.0.0.1:端口）")
    @Option(help: "上游代理字符串") var proxy: String?
    @Option(help: "代理字符串没写类型时按什么处理") var proxyType: ProxyConfig.Kind = .socks5
    @Flag(help: "上游直连") var direct = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let upstream: Upstream
        if let proxy { upstream = .proxy(try ProxyConfig.parse(proxy, defaultKind: proxyType)) }
        else if direct { upstream = .direct }
        else { throw ValidationError("请给出 --proxy 或 --direct") }
        let server = LocalProxyServer(upstream: upstream) { event in
            switch event {
            case .tunnelOpened(let t, let ms): print("→ \(t.authority)  \(ms)ms")
            case .tunnelFailed(let t, let why): print("✗ \(t?.authority ?? "-")  \(why)")
            case .tunnelClosed(let t, let up, let down): print("← \(t.authority)  ↑\(up) ↓\(down)")
            }
        }
        let port = try await server.start()
        print("本地入口：socks5://127.0.0.1:\(port)（Ctrl-C 结束）")
        let done = AsyncStream<Void> { cont in
            let w = SignalWatcher { cont.finish() }
            cont.onTermination = { _ in _ = w }
        }
        for await _ in done {}
        server.stop()
    }
}

struct ChromeInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chrome", abstract: "显示本机 Chrome 信息")
    func run() async throws {
        let c = try ChromeInstallation()
        print("路径: \(c.executable.path)")
        print("版本: \(c.version ?? "?")")
    }
}
