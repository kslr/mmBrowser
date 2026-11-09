import Foundation

/// 数据目录布局：
/// ```
/// <root>/db.sqlite
/// <root>/profiles/<profile-id>/   ← Chrome 的 --user-data-dir
/// ```
/// root 默认是 `~/Library/Application Support/mmBrowser`，可以用环境变量 `MMBROWSER_HOME` 覆盖。
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func `default`() -> AppPaths {
        if let custom = ProcessInfo.processInfo.environment["MMBROWSER_HOME"], !custom.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: base.appendingPathComponent("mmBrowser", isDirectory: true))
    }

    public var database: URL { root.appendingPathComponent("db.sqlite") }
    public var profilesDir: URL { root.appendingPathComponent("profiles", isDirectory: true) }

    public func profileDir(_ id: String) -> URL {
        profilesDir.appendingPathComponent(id, isDirectory: true)
    }

    /// 创建目录并收紧权限（仅当前用户可访问）。
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, profilesDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}
