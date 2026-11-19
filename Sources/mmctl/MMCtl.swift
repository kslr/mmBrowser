import ArgumentParser
import Foundation
import MMCore

@main
struct MMCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mmctl",
        abstract: L("cli.abstract"),
        discussion: L("cli.discussion"),
        subcommands: [Create.self, List.self, Show.self, Set_.self, Check.self, Launch.self, Plan.self,
                      Remove.self, Restore.self, Serve.self, ChromeInfo.self, Cookies.self]
    )
}

// MARK: - 共用

func openStore() throws -> Store {
    setvbuf(stdout, nil, _IOLBF, 0)  // 输出重定向到文件时也逐行写出
    return try Store(paths: .default())
}

/// 正在使用这个环境的 Chrome（不管是不是 mmBrowser 启动的）。
func runningPID(_ p: Profile, _ store: Store) -> Int32? {
    ProfileLock.runningPID(store.paths.profileDir(p.id))
}

struct ProfileOptions: ParsableArguments {
    @Option(help: ArgumentHelp(L("cli.profile.help.proxy")))
    var proxy: String?
    @Option(help: ArgumentHelp(L("cli.profile.help.proxyType")))
    var proxyType: ProxyConfig.Kind = .socks5
    @Flag(help: ArgumentHelp(L("cli.profile.help.direct")))
    var direct = false
    @Option(help: ArgumentHelp(L("cli.profile.help.lang")))
    var lang: String?
    @Option(help: ArgumentHelp(L("cli.profile.help.tz")))
    var tz: String?
    @Option(name: .customLong("tag"), help: ArgumentHelp(L("cli.profile.help.tags")))
    var tags: [String] = []
    @Option(help: ArgumentHelp(L("cli.profile.help.notes")))
    var notes: String?
    @Option(help: ArgumentHelp(L("cli.profile.help.window")))
    var window: String?
    @Option(help: ArgumentHelp(L("cli.profile.help.color")))
    var color: String?
    @Option(help: ArgumentHelp(L("cli.profile.help.geo")))
    var geo: GeolocationPolicy?
    @Option(name: .customLong("arg"), parsing: .unconditionalSingleValue, help: ArgumentHelp(L("cli.profile.help.extraArgs")))
    var extraArgs: [String] = []

    func apply(to p: inout Profile) throws {
        if let proxy { p.proxy = try ProxyConfig.parse(proxy, defaultKind: proxyType); p.allowDirect = false }
        if direct { p.proxy = nil; p.allowDirect = true }
        if let lang {
            guard LanguageTag.isValidSetting(lang) else { throw ValidationError(L("cli.error.language \(lang)")) }
            p.language = lang
        }
        if let tz {
            if tz == "auto" {
                p.timezone = nil
            } else {
                guard TimeZone(identifier: tz) != nil else { throw ValidationError(L("cli.error.timezone \(tz)")) }
                p.timezone = tz
            }
        }
        if !tags.isEmpty { p.tags = tags }
        if let notes { p.notes = notes }
        if let window {
            guard let size = WindowSize(window) else { throw ValidationError(L("cli.error.window")) }
            p.windowSize = size
        }
        if let color {
            guard let hex = ThemePalette.parse(color) else { throw ValidationError(L("cli.error.color")) }
            p.themeColor = hex
        }
        if let geo { p.geolocation = geo }
        if !extraArgs.isEmpty { p.extraArgs = extraArgs }
    }
}

extension ProxyConfig.Kind: @retroactive ExpressibleByArgument {}
extension GeolocationPolicy: @retroactive ExpressibleByArgument {}

func describe(_ p: Profile, running: Int32?) -> String {
    var lines = [
        "#\(p.seq)  \(p.name)\(running.map { L("cli.profile.runningPID \(Int($0))") } ?? "")",
        L("cli.profile.id \(p.id)"),
        L("cli.profile.tags \(p.tags.isEmpty ? "-" : p.tags.joined(separator: ", "))"),
        L("cli.profile.proxy \(p.proxy?.displayString ?? (p.allowDirect ? L("common.directAllowed") : L("common.notConfigured")))"),
        L("cli.profile.languageTimezone \(p.language == LanguageTag.auto ? L("common.autoExitIP") : p.language) \(p.timezone ?? L("common.autoExitIP"))"),
        L("cli.profile.geolocation \(p.geolocation == .block ? L("common.block") : L("common.ask"))"),
        L("cli.profile.windowColor \(p.windowSize?.description ?? L("common.default")) \(p.effectiveThemeColor)"),
    ]
    if !p.extraArgs.isEmpty { lines.append(L("cli.profile.extraArgs \(p.extraArgs.joined(separator: " "))")) }
    if !p.notes.isEmpty { lines.append(L("cli.profile.notes \(p.notes)")) }
    if let e = p.lastExit {
        lines.append(L("cli.profile.exit \(e.summary) \(e.provider) \(e.checkedAt.formatted(date: .numeric, time: .shortened))"))
    }
    if let d = p.deletedAt { lines.append(L("cli.profile.deletedAt \(d.formatted())")) }
    return lines.joined(separator: "\n")
}

// MARK: - 命令

struct Create: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("cli.create.abstract"))
    @Option(help: ArgumentHelp(L("cli.create.help.name"))) var name: String
    @OptionGroup var options: ProfileOptions

    func run() async throws {
        let store = try openStore()
        var p = Profile(name: name)
        try options.apply(to: &p)
        if p.upstream == nil {
            throw ValidationError(L("cli.create.error.proxyRequired"))
        }
        let saved = try store.insert(p)
        print(describe(saved, running: nil))
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("cli.list.abstract"))
    @Flag(help: ArgumentHelp(L("cli.list.help.deleted"))) var deleted = false

    func run() async throws {
        let store = try openStore()
        let rows = try store.profiles(deleted ? .trash : .active)
        if rows.isEmpty { print(deleted ? L("cli.list.emptyTrash") : L("cli.list.empty")); return }
        for p in rows {
            let status = runningPID(p, store) == nil ? "" : L("common.running")
            let proxy = p.proxy?.displayString ?? (p.allowDirect ? L("common.direct") : L("common.notConfigured"))
            let exit = p.lastExit.map { "\($0.ip) \($0.countryCode ?? "")" } ?? ""
            print(String(format: "#%-4d %@", p.seq, "\(p.name)  \(p.tags.isEmpty ? "" : "[" + p.tags.joined(separator: ",") + "]  ")\(proxy)  \(exit)  \(p.language)  \(status)"))
        }
    }
}

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("cli.show.abstract"))
    @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref, includeDeleted: true)
        print(describe(p, running: runningPID(p, store)))
        print(L("cli.profile.directory \(store.paths.profileDir(p.id).path)"))
    }
}

struct Set_: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: L("cli.set.abstract"))
    @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String
    @Option(help: ArgumentHelp(L("cli.set.help.name"))) var name: String?
    @OptionGroup var options: ProfileOptions

    func run() async throws {
        let store = try openStore()
        var p = try store.resolve(ref)
        if let name { p.name = name }
        try options.apply(to: &p)
        try store.update(p)
        print(describe(try store.resolve(p.id), running: nil))
    }
}

struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("cli.check.abstract"))
    @Argument(help: ArgumentHelp(L("cli.check.help.profile"))) var ref: String?
    @Option(help: ArgumentHelp(L("cli.check.help.proxy"))) var proxy: String?
    @Option(help: ArgumentHelp(L("cli.help.proxyType"))) var proxyType: ProxyConfig.Kind = .socks5

    func run() async throws {
        let store = try openStore()
        let upstream: Upstream
        var profile: Profile?
        if let proxy {
            upstream = .proxy(try ProxyConfig.parse(proxy, defaultKind: proxyType))
        } else if let ref {
            let p = try store.resolve(ref)
            profile = p
            guard let u = p.upstream else { throw ChromeError.noProxy }
            upstream = u
        } else {
            throw ValidationError(L("cli.check.error.profileRequired"))
        }
        let info = try await GeoCheck.check(upstream: upstream)
        if let profile { try store.recordExit(info, for: profile.id) }
        print(L("cli.check.ip \(info.ip)"))
        print(L("cli.check.location \([info.countryCode, info.country, info.region, info.city].compactMap { $0 }.joined(separator: " / "))"))
        print(L("cli.check.timezone \(info.timezone ?? "-")"))
        print(L("cli.check.org \(info.org ?? "-")"))
        print(L("cli.check.latency \(info.latencyMs ?? 0) \(info.provider)"))
        if let lang = CountryLocale.recommendedLanguage(for: info.countryCode) {
            let current = profile.map { L("cli.check.currentLanguage \($0.language)") } ?? ""
            print(L("cli.check.language \(lang) \(current)"))
        }
    }
}

struct Plan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("cli.plan.abstract"))
    @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref)
        let tz = p.timezone ?? p.lastExit?.timezone ?? L("cli.plan.exitTimezone")
        let lang = LanguageTag.resolve(p.language, countryCode: p.lastExit?.countryCode)
        let dir = store.paths.profileDir(p.id)
        var checkURL = store.checkPage.url
        if let url = checkURL, SessionInspector.hasOpenTab(sameSiteAs: url, userDataDir: dir) {
            checkURL = nil
            print(L("cli.plan.checkPageOpen"))
        }
        // 本地入口的端口启动时才分配，这里用 0 占位
        let plan = LaunchPlan.make(profile: p, language: lang, userDataDir: dir, localProxyPort: 0, timezone: tz,
                                   checkPageURL: checkURL)
        print(L("cli.plan.environment \(tz)"))
        print(L("cli.plan.arguments") + plan.arguments.joined(separator: "\n  "))
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
        abstract: L("cli.launch.abstract"))
    @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String
    @Flag(name: .shortAndLong, help: ArgumentHelp(L("cli.launch.help.verbose"))) var verbose = false

    func run() async throws {
        let store = try openStore()
        let chrome = try ChromeInstallation()
        let launcher = BrowserLauncher(store: store, chrome: chrome)
        let p = try store.resolve(ref)
        print(L("cli.launch.starting \(p.seq) \(p.name) \(chrome.version ?? "?")"))
        let verbose = self.verbose
        let running = try await launcher.launch(profileId: p.id, progress: { stage in
            switch stage {
            case .startingProxy: print(L("cli.launch.progress.proxy"))
            case .checkingExit: print(L("cli.launch.progress.exit"))
            case .exitChecked(let e): print(L("cli.launch.exit \(e.summary)"))
            case .seeding: print(L("cli.launch.progress.seed"))
            case .startingChrome: print(L("cli.launch.progress.chrome"))
            }
        }, proxyEvents: { event in
            switch event {
            case .tunnelFailed(let t, let why): print("  ✗ \(t?.authority ?? "-")  \(why)")
            case .tunnelOpened(let t, let ms): if verbose { print("  → \(t.authority)  \(ms)ms") }
            case .tunnelClosed(let t, let up, let down): if verbose { print("  ← \(t.authority)  ↑\(up) ↓\(down)") }
            }
        })
        print(L("cli.launch.started \(Int(running.pid)) \(Int(running.proxy.port)) \(running.timezone)"))
        print(L("cli.launch.quitHint"))
        let watcher = SignalWatcher {
            print(L("cli.launch.closing"))
            Task { await running.terminate() }
        }
        await running.waitUntilExit()
        _ = watcher
        print(L("cli.launch.exited"))
    }
}

struct Remove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: L("cli.remove.abstract"))
    @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String
    @Flag(help: ArgumentHelp(L("cli.remove.help.purge"))) var purge = false

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref, includeDeleted: true)
        if let pid = runningPID(p, store) { throw ChromeError.alreadyRunning(pid: pid) }
        if purge {
            try store.purge(p.id)
            print(L("cli.remove.purged \(p.seq) \(p.name)"))
        } else {
            try store.softDelete(p.id)
            print(L("cli.remove.trashed \(p.seq) \(p.name) \(p.seq)"))
        }
    }
}

struct Restore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: L("cli.restore.abstract"))
    @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String

    func run() async throws {
        let store = try openStore()
        let p = try store.resolve(ref, includeDeleted: true)
        try store.restore(p.id)
        print(L("cli.restore.restored \(p.seq) \(p.name)"))
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("cli.serve.abstract"))
    @Option(help: ArgumentHelp(L("cli.serve.help.proxy"))) var proxy: String?
    @Option(help: ArgumentHelp(L("cli.help.proxyType"))) var proxyType: ProxyConfig.Kind = .socks5
    @Flag(help: ArgumentHelp(L("cli.serve.help.direct"))) var direct = false

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let upstream: Upstream
        if let proxy { upstream = .proxy(try ProxyConfig.parse(proxy, defaultKind: proxyType)) }
        else if direct { upstream = .direct }
        else { throw ValidationError(L("cli.serve.error.proxyRequired")) }
        let server = LocalProxyServer(upstream: upstream) { event in
            switch event {
            case .tunnelOpened(let t, let ms): print("→ \(t.authority)  \(ms)ms")
            case .tunnelFailed(let t, let why): print("✗ \(t?.authority ?? "-")  \(why)")
            case .tunnelClosed(let t, let up, let down): print("← \(t.authority)  ↑\(up) ↓\(down)")
            }
        }
        let port = try await server.start()
        print(L("cli.serve.listening \(Int(port))"))
        let done = AsyncStream<Void> { cont in
            let w = SignalWatcher { cont.finish() }
            cont.onTermination = { _ in _ = w }
        }
        for await _ in done {}
        server.stop()
    }
}

struct ChromeInfo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chrome", abstract: L("cli.chrome.abstract"))
    func run() async throws {
        let c = try ChromeInstallation()
        print(L("cli.chrome.path \(c.executable.path)"))
        print(L("cli.chrome.version \(c.version ?? "?")"))
    }
}

struct Cookies: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: L("cli.cookies.abstract"),
        subcommands: [Export.self, Import.self])

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: L("cli.cookies.export.abstract"))
        @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String
        @Argument(help: ArgumentHelp(L("cli.cookies.export.help.file"))) var file: String?

        func run() async throws {
            let store = try openStore()
            let p = try store.resolve(ref)
            if runningPID(p, store) != nil { throw CookieError.running }
            let cookies = try ChromeCookies.read(userDataDir: store.paths.profileDir(p.id))
            let data = try ChromeCookies.exportJSON(cookies)
            if let file {
                try data.write(to: URL(fileURLWithPath: file))
                print(L("cli.cookies.exported \(cookies.count) \(file)"))
            } else {
                print(String(decoding: data, as: UTF8.self))
            }
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: L("cli.cookies.import.abstract"))
        @Argument(help: ArgumentHelp(L("cli.help.profile"))) var ref: String
        @Argument(help: ArgumentHelp(L("cli.cookies.import.help.file"))) var file: String
        @Flag(help: ArgumentHelp(L("cli.cookies.import.help.replace"))) var replace = false

        func run() async throws {
            let store = try openStore()
            let p = try store.resolve(ref)
            if runningPID(p, store) != nil { throw CookieError.running }
            let cookies = try ChromeCookies.importJSON(try Data(contentsOf: URL(fileURLWithPath: file)))
            let n = try ChromeCookies.write(cookies, userDataDir: store.paths.profileDir(p.id), replaceAll: replace)
            print(L("cli.cookies.imported \(n)"))
        }
    }
}
