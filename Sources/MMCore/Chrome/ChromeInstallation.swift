import Foundation

public enum ChromeError: Error, LocalizedError {
    case notInstalled(String)
    case noProxy
    case alreadyRunning(pid: Int32)
    case noTimezone
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let path): L("error.chrome.notInstalled \(path)")
        case .noProxy: L("error.chrome.noProxy")
        case .alreadyRunning(let pid): L("error.chrome.alreadyRunning \(Int(pid))")
        case .noTimezone: L("error.chrome.noTimezone")
        case .startFailed(let why): L("error.chrome.startFailed \(why)")
        }
    }
}

/// 本机安装的官方 Chrome。
public struct ChromeInstallation: Sendable {
    public let executable: URL

    public static let defaultExecutable = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

    public init(executable: URL = ChromeInstallation.defaultExecutable) throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ChromeError.notInstalled(executable.path)
        }
        self.executable = executable
    }

    /// 读取 Info.plist 里的版本号，不需要启动 Chrome。
    public var version: String? {
        let plist = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }
}
