import Foundation

/// 扩展预装。
///
/// 1. 在环境目录的 `External Extensions/<id>.json` 写入应用商店的更新地址，Chrome 启动时会自己下载；
///    删除这个文件，Chrome 下次启动时会自动卸载对应扩展。
/// 2. 外部安装的扩展默认是停用的（要用户确认，disable_reasons 含 8192）。启动前如果发现有这种情况，
///    就用无界面 Chrome 经由环境自己的代理下载并通过 chrome://extensions 的 management 接口启用。
///    用户自己手动停用的扩展不会被重新启用。
public enum ExtensionManager {
    static let updateURL = "https://clients2.google.com/service/update2/crx"
    static let disableReasonExternal = 8192

    public enum State: Equatable, Sendable {
        case notInstalled
        /// 已下载，但等待用户确认（外部安装）
        case pendingApproval
        /// 其它原因停用（比如用户自己关掉的）
        case disabled
        case enabled
    }

    static func externalDir(_ userDataDir: URL) -> URL {
        userDataDir.appendingPathComponent("External Extensions", isDirectory: true)
    }

    /// 让 External Extensions 目录和期望的扩展列表一致。
    public static func syncPreferences(ids: [String], userDataDir: URL) throws {
        let fm = FileManager.default
        let dir = externalDir(userDataDir)
        let wanted = Set(ids.filter(ExtensionID.isValid))
        if wanted.isEmpty, !fm.fileExists(atPath: dir.path) { return }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = Set((try fm.contentsOfDirectory(atPath: dir.path))
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        for id in existing.subtracting(wanted) {
            try fm.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
        let json = Data("{\"external_update_url\": \"\(updateURL)\"}\n".utf8)
        for id in wanted.subtracting(existing) {
            try json.write(to: dir.appendingPathComponent("\(id).json"))
        }
    }

    /// 从 Secure Preferences / Preferences 读取扩展的状态和名称。
    static func settings(_ userDataDir: URL) -> [String: [String: Any]] {
        var merged: [String: [String: Any]] = [:]
        for name in ["Preferences", "Secure Preferences"] {
            let url = userDataDir.appendingPathComponent("Default/\(name)")
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ext = (obj["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { continue }
            for (id, v) in ext {
                if let d = v as? [String: Any] { merged[id, default: [:]].merge(d) { _, new in new } }
            }
        }
        return merged
    }

    public static func states(ids: [String], userDataDir: URL) -> [String: State] {
        let s = settings(userDataDir)
        var out: [String: State] = [:]
        for id in ids {
            guard let entry = s[id], entry["manifest"] != nil || entry["path"] != nil else { out[id] = .notInstalled; continue }
            let reasons = (entry["disable_reasons"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            if reasons.isEmpty { out[id] = .enabled }
            else if Set(reasons) == [disableReasonExternal] { out[id] = .pendingApproval }
            else { out[id] = .disabled }
        }
        return out
    }

    /// 已安装扩展的名称（来自 manifest）。
    public static func installedNames(userDataDir: URL) -> [String: String] {
        settings(userDataDir).compactMapValues { ($0["manifest"] as? [String: Any])?["name"] as? String }
    }

    public static func needsMaintenance(ids: [String], userDataDir: URL) -> Bool {
        states(ids: ids, userDataDir: userDataDir).values.contains { $0 == .notInstalled || $0 == .pendingApproval }
    }

    /// 在线维护：无界面 Chrome 经由 proxyPort 下载缺失的扩展，并启用等待确认的扩展。返回维护后的状态。
    public static func ensureInstalled(ids: [String], userDataDir: URL, chrome: ChromeInstallation,
                                       proxyPort: UInt16?, timeout: TimeInterval = 90) async throws -> [String: State] {
        let before = states(ids: ids, userDataDir: userDataDir)
        let toEnable = Set(before.filter { $0.value == .notInstalled || $0.value == .pendingApproval }.keys)
        guard !toEnable.isEmpty else { return before }

        let headless = try await HeadlessChrome.start(userDataDir: userDataDir, chrome: chrome, proxyPort: proxyPort)
        do {
            let session = try await headless.openPage(
                "chrome://extensions/", readyCheck: "typeof chrome !== 'undefined' && typeof chrome.management === 'object'")
            let deadline = Date().addingTimeInterval(timeout)
            var remaining = toEnable
            while !remaining.isEmpty, Date() < deadline {
                for id in remaining {
                    let info = try await headless.evaluate(
                        "new Promise(r => chrome.management.get('\(id)', e => r(chrome.runtime.lastError ? 'missing' : (e.enabled ? 'enabled' : 'disabled'))))",
                        sessionId: session)
                    switch info.string {
                    case "enabled":
                        remaining.remove(id)
                    case "disabled":
                        _ = try await headless.evaluate(
                            "new Promise(r => chrome.management.setEnabled('\(id)', true, () => r(chrome.runtime.lastError ? chrome.runtime.lastError.message : 'ok')))",
                            sessionId: session)
                    default:
                        break  // 还在下载
                    }
                }
                if !remaining.isEmpty { try await Task.sleep(for: .seconds(1)) }
            }
        } catch {
            headless.kill()
            throw error
        }
        await headless.close()
        return states(ids: ids, userDataDir: userDataDir)
    }
}
