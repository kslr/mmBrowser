import Foundation

public enum ChromeError: Error, LocalizedError {
    case notInstalled(String)
    case noProxy
    case alreadyRunning(pid: Int32)
    case noTimezone
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let path): "找不到 Google Chrome：\(path)"
        case .noProxy: "这个环境没有配置代理，也没有允许直连，拒绝启动"
        case .alreadyRunning(let pid): "这个环境已经在运行（PID \(pid)）"
        case .noTimezone: "无法根据出口 IP 确定时区，请在环境里手动指定时区"
        case .startFailed(let why): "Chrome 启动失败：\(why)"
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
