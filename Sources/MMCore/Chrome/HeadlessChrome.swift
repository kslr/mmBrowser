import Foundation

/// 维护用的无界面 Chrome：只在环境关闭时、正式启动之前短暂运行，用 CDP 调 Chrome 自己的设置/扩展接口。
/// 调试端口只监听 127.0.0.1、端口随机、用完即关；正式启动的浏览器从不开调试端口。
final class HeadlessChrome: @unchecked Sendable {
    let process: Process
    let cdp: CDPClient
    private let portFile: URL
    private let userDataDir: URL
    private let savedWindowPlacement: Any?

    private init(process: Process, cdp: CDPClient, portFile: URL, userDataDir: URL, savedWindowPlacement: Any?) {
        self.process = process
        self.cdp = cdp
        self.portFile = portFile
        self.userDataDir = userDataDir
        self.savedWindowPlacement = savedWindowPlacement
    }

    static func sessionsDir(_ userDataDir: URL) -> URL { userDataDir.appendingPathComponent("Default/Sessions") }
    static func savedSessionsDir(_ userDataDir: URL) -> URL { userDataDir.appendingPathComponent("Default/Sessions.mm-saved") }

    /// 维护期间把用户的会话挪开：既不让无界面 Chrome 恢复（并在后台加载）用户的标签页，也不让维护过程覆盖它。
    static func stashSessions(_ userDataDir: URL) throws {
        recoverSessions(userDataDir)
        let fm = FileManager.default
        if fm.fileExists(atPath: sessionsDir(userDataDir).path) {
            try fm.moveItem(at: sessionsDir(userDataDir), to: savedSessionsDir(userDataDir))
        }
    }

    /// 丢弃维护产生的会话，放回用户的会话。也用于应用中途崩溃后的恢复（启动前都会调用）。
    public static func recoverSessions(_ userDataDir: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: savedSessionsDir(userDataDir).path) else { return }
        try? fm.removeItem(at: sessionsDir(userDataDir))
        try? fm.moveItem(at: savedSessionsDir(userDataDir), to: sessionsDir(userDataDir))
    }

    static let windowPlacementKey = "browser.window_placement"

    /// 正式浏览器上次的窗口位置和大小。无界面 Chrome 的虚拟屏幕只有 800×600，退出时会把这个值改成
    /// 约 756×556 存进去，下次正式打开窗口就变得很小。所以维护前先记下，维护后原样放回（原来没有就删掉）。
    static func windowPlacement(_ userDataDir: URL) -> Any? {
        let prefs = try? ProfileSeed.readJSON(userDataDir.appendingPathComponent("Default/Preferences"))
        return prefs.flatMap { ProfileSeed.get($0, windowPlacementKey) }
    }

    static func restoreWindowPlacement(_ saved: Any?, userDataDir: URL) {
        let url = userDataDir.appendingPathComponent("Default/Preferences")
        guard var prefs = try? ProfileSeed.readJSON(url), !prefs.isEmpty else { return }
        if let saved { ProfileSeed.set(&prefs, windowPlacementKey, saved) }
        else { ProfileSeed.remove(&prefs, windowPlacementKey) }
        try? ProfileSeed.writeJSON(prefs, to: url)
    }

    /// proxyPort 为 nil 时完全离线（代理指向不存在的端口）。
    static func start(userDataDir: URL, chrome: ChromeInstallation, proxyPort: UInt16?, timeout: TimeInterval = 30) async throws -> HeadlessChrome {
        let fm = FileManager.default
        let portFile = userDataDir.appendingPathComponent("DevToolsActivePort")
        try? fm.removeItem(at: portFile)
        try stashSessions(userDataDir)
        let placement = windowPlacement(userDataDir)

        let p = Process()
        p.executableURL = chrome.executable
        p.arguments = [
            "--headless=new",
            "--user-data-dir=\(userDataDir.path)",
            "--use-mock-keychain",
            "--no-first-run",
            "--no-default-browser-check",
            "--proxy-server=socks5://127.0.0.1:\(proxyPort ?? 1)",
            "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",  // 无界面不会弹警告条，多一层保险
            "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
            "--disable-quic",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "about:blank",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            recoverSessions(userDataDir)
            throw error
        }

        do {
            let deadline = Date().addingTimeInterval(timeout)
            var wsURL: URL?
            while wsURL == nil {
                guard Date() < deadline else { throw ChromeError.startFailed(L("error.chrome.maintenance.portTimeout")) }
                guard p.isRunning else { throw ChromeError.startFailed(L("error.chrome.maintenance.exited")) }
                if let text = try? String(contentsOf: portFile, encoding: .utf8) {
                    let lines = text.split(separator: "\n").map(String.init)
                    if lines.count >= 2, let port = Int(lines[0]) {
                        wsURL = URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
                    }
                }
                if wsURL == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
            let cdp = CDPClient(webSocketURL: wsURL!)
            await cdp.connect()
            return HeadlessChrome(process: p, cdp: cdp, portFile: portFile, userDataDir: userDataDir,
                                  savedWindowPlacement: placement)
        } catch {
            p.terminate()
            p.waitUntilExit()
            try? fm.removeItem(at: portFile)
            restoreWindowPlacement(placement, userDataDir: userDataDir)
            if fm.fileExists(atPath: savedSessionsDir(userDataDir).path) {
                recoverSessions(userDataDir)
            } else {
                try? fm.removeItem(at: sessionsDir(userDataDir))  // 原本没有会话：丢掉维护产生的
            }
            throw error
        }
    }

    /// 打开一个内置页面（如 chrome://settings），等页面里的某个接口就绪，返回 CDP 会话 id。
    func openPage(_ url: String, readyCheck: String, timeout: TimeInterval = 15) async throws -> String {
        let target = try await cdp.send("Target.createTarget", ["url": url])
        guard let targetId = target["targetId"].string else { throw ChromeError.startFailed(L("error.chrome.maintenance.open \(url)")) }
        let attach = try await cdp.send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
        guard let sessionId = attach["sessionId"].string else { throw ChromeError.startFailed(L("error.chrome.maintenance.attach \(url)")) }
        let deadline = Date().addingTimeInterval(timeout)
        while (try? await cdp.evaluate(readyCheck, sessionId: sessionId))?.bool != true {
            guard Date() < deadline else { throw ChromeError.startFailed(L("error.chrome.maintenance.notReady \(url)")) }
            try await Task.sleep(for: .milliseconds(100))
        }
        return sessionId
    }

    func evaluate(_ expression: String, sessionId: String) async throws -> CDPJSON {
        try await cdp.evaluate(expression, sessionId: sessionId)
    }

    /// 正常关闭（让 Chrome 写完配置），超时则强制结束。
    func close() async {
        _ = try? await cdp.send("Browser.close")
        await cdp.close()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        finish()
    }

    func kill() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        finish()
    }

    private func finish() {
        let fm = FileManager.default
        try? fm.removeItem(at: portFile)
        Self.restoreWindowPlacement(savedWindowPlacement, userDataDir: userDataDir)
        if fm.fileExists(atPath: Self.savedSessionsDir(userDataDir).path) {
            Self.recoverSessions(userDataDir)
        } else {
            try? fm.removeItem(at: Self.sessionsDir(userDataDir))  // 原本没有会话：丢掉维护产生的
        }
    }
}
