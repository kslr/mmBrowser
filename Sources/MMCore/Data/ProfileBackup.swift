import Foundation

/// 单个环境的备份文件（.mmprofile，本质是 zip）：
/// ```
/// profile.json   环境设置（含代理密码）
/// data/          浏览器数据（不含缓存）
/// ```
/// 因为用了 mock keychain，保存的密码和 Cookie 换一台 Mac 也能用。文件等同于明文密码，要妥善保管。
public enum ProfileBackup {
    public static let fileExtension = "mmprofile"
    static let formatVersion = 1

    struct Manifest: Codable {
        var formatVersion: Int
        var exportedAt: Date
        var groupName: String?
        var profile: Profile
    }

    public enum BackupError: Error, LocalizedError {
        case running
        case invalidFile(String)
        case tool(String)

        public var errorDescription: String? {
            switch self {
            case .running: "环境正在运行，请先关闭"
            case .invalidFile(let why): "不是有效的环境备份文件：\(why)"
            case .tool(let why): "压缩/解压失败：\(why)"
            }
        }
    }

    /// 导出到 file。环境必须处于关闭状态（否则数据库可能正在写）。
    public static func export(profileId: String, store: Store, isRunning: Bool, to file: URL) throws {
        guard !isRunning else { throw BackupError.running }
        guard let p = try store.profile(id: profileId) else { throw StoreError.notFound(profileId) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mmbackup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        let pkg = work.appendingPathComponent("pkg")
        try fm.createDirectory(at: pkg, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let groupName = try store.groups().first { $0.id == p.groupId }?.name
        let manifest = Manifest(formatVersion: formatVersion, exportedAt: Date(), groupName: groupName, profile: p)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: pkg.appendingPathComponent("profile.json"))

        let dataDir = store.paths.profileDir(p.id)
        if fm.fileExists(atPath: dataDir.path) {
            try ProfileFiles.copyData(from: dataDir, to: pkg.appendingPathComponent("data"))
        }
        try? fm.removeItem(at: file)
        try ditto(["-c", "-k", pkg.path, file.path])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public struct ImportResult: Sendable {
        public let profile: Profile
        public let warnings: [String]
    }

    /// 导入为一个新环境（新的 id 和序号）。
    public static func `import`(from file: URL, store: Store) throws -> ImportResult {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("mmrestore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try ditto(["-x", "-k", file.path, work.path])

        let manifestURL = work.appendingPathComponent("profile.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw BackupError.invalidFile("缺少 profile.json") }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch {
            throw BackupError.invalidFile(error.localizedDescription)
        }
        guard manifest.formatVersion <= formatVersion else { throw BackupError.invalidFile("文件来自更新版本的 mmBrowser") }

        var warnings: [String] = []
        var p = manifest.profile
        p.id = UUID().uuidString.lowercased()
        p.deletedAt = nil
        if let proxy = p.proxy, let owner = try store.proxyOwner(of: proxy) {
            warnings.append("代理 \(proxy.displayString) 已绑定在 #\(owner.seq)「\(owner.name)」上，导入的环境没有设置代理")
            p.proxy = nil
            p.proxyExpiresAt = nil
        }
        p.groupId = try manifest.groupName.map { try store.group(named: $0).id } ?? nil
        let saved = try store.insert(p)

        let src = work.appendingPathComponent("data")
        if fm.fileExists(atPath: src.path) {
            let dst = store.paths.profileDir(saved.id)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
            // Chrome 的配置签名和机器绑定，重新做一次首次初始化（恢复会话、扩展启用等）
            try? fm.removeItem(at: dst.appendingPathComponent(ProfileInitializer.markerName))
        }
        // lastOpenedAt 保留：已经用过的环境，启动时恢复会话而不是重新打开启动页
        try store.db.write { db in
            try db.execute(sql: "UPDATE profile SET lastOpenedAt = ?, lastExit = NULL WHERE id = ?",
                           arguments: [manifest.profile.lastOpenedAt, saved.id])
        }
        return ImportResult(profile: try store.profile(id: saved.id) ?? saved, warnings: warnings)
    }

    private static func ditto(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw BackupError.tool(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
