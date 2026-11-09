import Foundation

/// 环境首次初始化：让 Chrome 自己写入受完整性校验的配置项。
///
/// 背景：`session.restore_on_startup` 等配置受 "Secure Preferences" 里的 HMAC 保护，直接写文件会被 Chrome
/// 当作篡改而丢弃。所以初始化时以无界面、不联网的方式临时启动一次 Chrome，在 chrome://settings 里通过
/// Chrome 自己的 settingsPrivate 接口修改，再正常退出，签名就是 Chrome 自己算的。
public enum ProfileInitializer {
    /// 初始化步骤的版本。以后要加新的一次性设置时递增，已初始化的环境会补跑。
    public static let currentVersion = 1
    static let markerName = ".mm-initialized"

    public static func needsInitialization(userDataDir: URL) -> Bool {
        let marker = userDataDir.appendingPathComponent(markerName)
        guard let s = try? String(contentsOf: marker, encoding: .utf8), let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return true
        }
        return v < currentVersion
    }

    public static func initialize(userDataDir: URL, chrome: ChromeInstallation, timeout: TimeInterval = 30) async throws {
        let fm = FileManager.default
        let portFile = userDataDir.appendingPathComponent("DevToolsActivePort")
        try? fm.removeItem(at: portFile)

        let p = Process()
        p.executableURL = chrome.executable
        p.arguments = [
            "--headless=new",
            "--user-data-dir=\(userDataDir.path)",
            "--use-mock-keychain",
            "--no-first-run",
            "--no-default-browser-check",
            // 不联网：代理指向不存在的端口，且禁止本地 DNS
            "--proxy-server=socks5://127.0.0.1:1",
            "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "about:blank",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()

        do {
            let deadline = Date().addingTimeInterval(timeout)
            // 端口为 0 时 Chrome 自己选端口，写在 DevToolsActivePort 里（第一行端口，第二行路径）
            var wsURL: URL?
            while wsURL == nil {
                guard Date() < deadline else { throw ChromeError.startFailed("初始化：等待调试端口超时") }
                guard p.isRunning else { throw ChromeError.startFailed("初始化：Chrome 提前退出") }
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
            defer { Task { await cdp.close() } }

            let target = try await cdp.send("Target.createTarget", ["url": "chrome://settings/"])
            guard let targetId = target["targetId"].string else { throw ChromeError.startFailed("初始化：无法打开设置页") }
            let attach = try await cdp.send("Target.attachToTarget", ["targetId": targetId, "flatten": true])
            guard let sessionId = attach["sessionId"].string else { throw ChromeError.startFailed("初始化：无法连接设置页") }

            // 等设置页的 settingsPrivate 接口就绪
            while (try? await cdp.evaluate("typeof chrome !== 'undefined' && typeof chrome.settingsPrivate", sessionId: sessionId))?.string != "object" {
                guard Date() < deadline else { throw ChromeError.startFailed("初始化：设置页未就绪") }
                try await Task.sleep(for: .milliseconds(100))
            }

            // 1 = 启动时继续浏览上次打开的网页
            try await setPref("session.restore_on_startup", value: 1, cdp: cdp, sessionId: sessionId)

            _ = try? await cdp.send("Browser.close")
        } catch {
            p.terminate()
            throw error
        }

        // 等它正常退出
        let exitDeadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < exitDeadline { try await Task.sleep(for: .milliseconds(100)) }
        if p.isRunning { p.terminate(); throw ChromeError.startFailed("初始化：Chrome 没有按时退出") }

        // 初始化这次的会话（设置页、空白页）不能被恢复出来
        try? fm.removeItem(at: userDataDir.appendingPathComponent("Default/Sessions"))
        try? fm.removeItem(at: portFile)
        try String(currentVersion).write(to: userDataDir.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
    }

    private static func setPref(_ name: String, value: Int, cdp: CDPClient, sessionId: String) async throws {
        let ok = try await cdp.evaluate(
            "new Promise(r => chrome.settingsPrivate.setPref('\(name)', \(value), '', ok => r(ok)))", sessionId: sessionId)
        let back = try await cdp.evaluate(
            "new Promise(r => chrome.settingsPrivate.getPref('\(name)', p => r(p.value)))", sessionId: sessionId)
        guard ok.bool == true, back.int == value else {
            throw ChromeError.startFailed("初始化：设置 \(name) 失败")
        }
    }
}
