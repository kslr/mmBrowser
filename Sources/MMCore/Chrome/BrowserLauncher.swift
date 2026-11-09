import Foundation

/// 启动过程中的阶段，用于界面或命令行显示进度。
public enum LaunchStage: Sendable {
    case startingProxy
    case checkingExit
    case exitChecked(ExitInfo)
    case initializing
    case seeding
    case startingChrome
}

public final class BrowserLauncher: Sendable {
    public let store: Store
    public let chrome: ChromeInstallation

    public init(store: Store, chrome: ChromeInstallation) {
        self.store = store
        self.chrome = chrome
    }

    /// 环境是否已经有 Chrome 在跑（不管是不是本程序启动的）。依据是 Chrome 的 SingletonLock（指向 "主机名-PID"）。
    public func runningPID(of profileId: String) -> Int32? {
        let lock = store.paths.profileDir(profileId).appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pidStr = target.split(separator: "-").last, let pid = Int32(pidStr) else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    /// 启动一个环境。任何一步失败都会清理已经起来的东西并抛错，不会留下一个没有代理的浏览器。
    public func launch(
        profileId: String,
        progress: (@Sendable (LaunchStage) -> Void)? = nil,
        proxyEvents: (@Sendable (ProxyEvent) -> Void)? = nil
    ) async throws -> RunningBrowser {
        guard let profile = try store.profile(id: profileId), !profile.isDeleted else {
            throw StoreError.notFound(profileId)
        }
        if let pid = runningPID(of: profile.id) { throw ChromeError.alreadyRunning(pid: pid) }

        let upstream: Upstream
        if let proxy = profile.proxy {
            upstream = .proxy(proxy)
        } else if profile.allowDirect {
            upstream = .direct
        } else {
            throw ChromeError.noProxy
        }

        // 1. 本地入口
        progress?(.startingProxy)
        let server = LocalProxyServer(upstream: upstream, onEvent: proxyEvents)
        let port = try await server.start()

        do {
            // 2. 出口检测（失败就不启动）
            progress?(.checkingExit)
            let exit = try await GeoCheck.check(localSocksPort: port)
            try store.recordExit(exit, for: profile.id)
            progress?(.exitChecked(exit))

            guard let timezone = profile.timezone ?? exit.timezone, TimeZone(identifier: timezone) != nil else {
                throw ChromeError.noTimezone
            }

            // 3. 首次初始化 + 写入配置
            let dir = store.paths.profileDir(profile.id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            progress?(.seeding)
            try ProfileSeed.apply(profile: profile, userDataDir: dir)
            if ProfileInitializer.needsInitialization(userDataDir: dir) {
                progress?(.initializing)
                try await ProfileInitializer.initialize(userDataDir: dir, chrome: chrome)
            }

            // 4. 启动 Chrome
            progress?(.startingChrome)
            let firstOpen = profile.lastOpenedAt == nil
            let plan = LaunchPlan.make(profile: profile, userDataDir: dir, localProxyPort: port, timezone: timezone,
                                       openStartURLs: firstOpen || profile.alwaysOpenStartURLs)
            let process = makeProcess(arguments: plan.arguments, environment: plan.environment)
            let running = RunningBrowser(profileId: profile.id, process: process, proxy: server, exit: exit, timezone: timezone)
            process.terminationHandler = { _ in running.markExited() }  // 先挂回调再启动，避免错过立即退出
            do {
                try process.run()
            } catch {
                throw ChromeError.startFailed(error.localizedDescription)
            }

            do {
                try await waitUntilOwnsProfile(dir: dir, process: process)
            } catch {
                await running.terminate(timeout: 5)
                throw error
            }

            try store.recordOpened(profile.id)
            return running
        } catch {
            server.stop()
            throw error
        }
    }

    private func makeProcess(arguments: [String], environment: [String: String]) -> Process {
        let p = Process()
        p.executableURL = chrome.executable
        p.arguments = arguments
        p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// 等到 SingletonLock 指向我们启动的进程，说明它确实成了这个环境的主进程。
    private func waitUntilOwnsProfile(dir: URL, process: Process, timeout: TimeInterval = 20) async throws {
        let lock = dir.appendingPathComponent("SingletonLock").path
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard process.isRunning else {
                throw ChromeError.startFailed("Chrome 提前退出（退出码 \(process.terminationStatus)）")
            }
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
               target.hasSuffix("-\(process.processIdentifier)") {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChromeError.startFailed("等待 Chrome 就绪超时")
    }
}
