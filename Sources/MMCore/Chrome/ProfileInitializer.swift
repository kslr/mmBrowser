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
        guard let s = try? String(contentsOf: marker, encoding: .utf8),
              let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return true }
        return v < currentVersion
    }

    public static func initialize(userDataDir: URL, chrome: ChromeInstallation) async throws {
        let headless = try await HeadlessChrome.start(userDataDir: userDataDir, chrome: chrome, proxyPort: nil)
        do {
            let session = try await headless.openPage(
                "chrome://settings/", readyCheck: "typeof chrome !== 'undefined' && typeof chrome.settingsPrivate === 'object'")
            // 1 = 启动时继续浏览上次打开的网页
            try await setPref("session.restore_on_startup", value: 1, headless: headless, sessionId: session)
        } catch {
            headless.kill()
            throw error
        }
        await headless.close()

        try String(currentVersion).write(to: userDataDir.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
    }

    private static func setPref(_ name: String, value: Int, headless: HeadlessChrome, sessionId: String) async throws {
        let ok = try await headless.evaluate(
            "new Promise(r => chrome.settingsPrivate.setPref('\(name)', \(value), '', ok => r(ok)))", sessionId: sessionId)
        let back = try await headless.evaluate(
            "new Promise(r => chrome.settingsPrivate.getPref('\(name)', p => r(p.value)))", sessionId: sessionId)
        guard ok.bool == true, back.int == value else {
            throw ChromeError.startFailed("初始化：设置 \(name) 失败")
        }
    }
}
