import Foundation
import GRDB

public enum StoreError: Error, LocalizedError, Equatable {
    case notFound(String)
    case ambiguous(String, [String])

    public var errorDescription: String? {
        switch self {
        case .notFound(let ref):
            L("error.store.notFound \(ref)")
        case .ambiguous(let ref, let names):
            L("error.store.ambiguous \(ref) \(names.joined(separator: L("common.listSeparator")))")
        }
    }
}

/// SQLite 存储。数据库文件权限 0600，不使用钥匙串。
public final class Store: Sendable {
    public let db: DatabaseQueue
    public let paths: AppPaths

    public init(paths: AppPaths) throws {
        try paths.ensureDirectories()
        self.paths = paths
        var config = Configuration()
        config.foreignKeysEnabled = true
        db = try DatabaseQueue(path: paths.database.path, configuration: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.database.path)
        try Self.migrator.migrate(db)
    }

    /// 内存数据库，用于测试。
    public init(inMemory paths: AppPaths) throws {
        self.paths = paths
        db = try DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "profileGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "profile") { t in
                t.primaryKey("id", .text)
                t.column("seq", .integer).notNull().unique()
                t.column("name", .text).notNull()
                t.column("groupId", .integer).references("profileGroup", onDelete: .setNull)
                t.column("tags", .text).notNull()          // JSON 数组
                t.column("notes", .text).notNull()
                t.column("startURLs", .text).notNull()     // JSON 数组
                t.column("proxyKind", .text)
                t.column("proxyHost", .text)
                t.column("proxyPort", .integer)
                t.column("proxyUsername", .text)
                t.column("proxyPassword", .text)
                t.column("allowDirect", .boolean).notNull()
                t.column("language", .text).notNull()
                t.column("timezone", .text)
                t.column("geolocation", .text).notNull()
                t.column("windowWidth", .integer)
                t.column("windowHeight", .integer)
                t.column("themeColor", .text)
                t.column("extraArgs", .text).notNull()     // JSON 数组
                t.column("lastExit", .text)                // JSON 对象
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime)
                t.column("deletedAt", .datetime)
            }
            // 曾经限制一个代理只能绑定一个环境，v5 已取消
            try db.execute(sql: """
                CREATE UNIQUE INDEX profile_proxy_unique
                ON profile(lower(proxyHost), proxyPort, IFNULL(proxyUsername, ''))
                WHERE proxyHost IS NOT NULL AND deletedAt IS NULL
                """)
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "profile") { t in
                t.add(column: "proxyExpiresAt", .datetime)
                t.add(column: "extensionIds", .text).notNull().defaults(to: "[]")
            }
            try db.create(table: "appSetting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()   // JSON
            }
        }
        // 注意：已经发布的迁移不能再改。alwaysOpenStartURLs 曾被错误地加进了 v1，
        // 导致更早建库的数据库缺这一列；这里按需补上，已有这一列的库跳过。
        m.registerMigration("v3") { db in
            let columns = try db.columns(in: "profile").map(\.name)
            if !columns.contains("alwaysOpenStartURLs") {
                try db.alter(table: "profile") { t in
                    t.add(column: "alwaysOpenStartURLs", .boolean).notNull().defaults(to: false)
                }
            }
        }
        // 只用标签，不再有分组：重建 profile 表去掉 groupId（SQLite 不能直接删带外键的列），删掉分组表。
        m.registerMigration("v4") { db in
            try db.create(table: "profile_new") { t in
                t.primaryKey("id", .text)
                t.column("seq", .integer).notNull().unique()
                t.column("name", .text).notNull()
                t.column("tags", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("startURLs", .text).notNull()
                t.column("alwaysOpenStartURLs", .boolean).notNull().defaults(to: false)
                t.column("proxyKind", .text)
                t.column("proxyHost", .text)
                t.column("proxyPort", .integer)
                t.column("proxyUsername", .text)
                t.column("proxyPassword", .text)
                t.column("proxyExpiresAt", .datetime)
                t.column("allowDirect", .boolean).notNull()
                t.column("language", .text).notNull()
                t.column("timezone", .text)
                t.column("geolocation", .text).notNull()
                t.column("windowWidth", .integer)
                t.column("windowHeight", .integer)
                t.column("themeColor", .text)
                t.column("extraArgs", .text).notNull()
                t.column("extensionIds", .text).notNull().defaults(to: "[]")
                t.column("lastExit", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("lastOpenedAt", .datetime)
                t.column("deletedAt", .datetime)
            }
            let cols = ["id", "seq", "name", "tags", "notes", "startURLs", "alwaysOpenStartURLs", "proxyKind", "proxyHost",
                        "proxyPort", "proxyUsername", "proxyPassword", "proxyExpiresAt", "allowDirect", "language", "timezone",
                        "geolocation", "windowWidth", "windowHeight", "themeColor", "extraArgs", "extensionIds", "lastExit",
                        "createdAt", "updatedAt", "lastOpenedAt", "deletedAt"].map { "\"\($0)\"" }.joined(separator: ", ")
            try db.execute(sql: "INSERT INTO profile_new (\(cols)) SELECT \(cols) FROM profile")
            try db.drop(table: "profile")
            try db.rename(table: "profile_new", to: "profile")
            try db.drop(table: "profileGroup")
            try db.execute(sql: """
                CREATE UNIQUE INDEX profile_proxy_unique
                ON profile(lower(proxyHost), proxyPort, IFNULL(proxyUsername, ''))
                WHERE proxyHost IS NOT NULL AND deletedAt IS NULL
                """)
        }
        // 取消"一个代理只能对应一个环境"的限制
        m.registerMigration("v5") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS profile_proxy_unique")
        }
        // 环境不再有自己的启动页（每次启动打开全局的检测页）
        m.registerMigration("v6") { db in
            try db.execute(sql: "ALTER TABLE profile DROP COLUMN startURLs")
            try db.execute(sql: "ALTER TABLE profile DROP COLUMN alwaysOpenStartURLs")
        }
        // 不再预装扩展（已经装进各环境的扩展留在环境目录里，不受影响）
        m.registerMigration("v7") { db in
            try db.execute(sql: "ALTER TABLE profile DROP COLUMN extensionIds")
            try db.execute(sql: "DELETE FROM appSetting WHERE key IN ('extensionLibrary', 'extensionLibrarySeeded')")
        }
        return m
    }

    // MARK: - 环境

    public enum Scope: Sendable {
        case active, trash, all
    }

    /// 按序号排列的环境：未删除的、回收站里的，或者全部。
    public func profiles(_ scope: Scope = .active) throws -> [Profile] {
        try db.read { db in
            let ordered = Profile.order(Column("seq"))
            let request = switch scope {
            case .active: ordered.filter(Column("deletedAt") == nil)
            case .trash: ordered.filter(Column("deletedAt") != nil)
            case .all: ordered
            }
            return try request.fetchAll(db)
        }
    }

    public func profile(id: String) throws -> Profile? {
        try db.read { try Profile.fetchOne($0, key: id) }
    }

    /// 按引用查找：`#12` / `12`（序号）、id 或 id 前缀（≥4 位）、名称（完全匹配）。
    public func resolve(_ ref: String, includeDeleted: Bool = false) throws -> Profile {
        let all = try profiles(includeDeleted ? .all : .active)
        let trimmed = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
        if let seq = Int(trimmed), let p = all.first(where: { $0.seq == seq }) { return p }
        if let p = all.first(where: { $0.id == ref }) { return p }
        let byName = all.filter { $0.name == ref }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw StoreError.ambiguous(ref, byName.map { "#\($0.seq)" }) }
        if ref.count >= 4 {
            let byPrefix = all.filter { $0.id.hasPrefix(ref.lowercased()) }
            if byPrefix.count == 1 { return byPrefix[0] }
            if byPrefix.count > 1 { throw StoreError.ambiguous(ref, byPrefix.map(\.numberedName)) }
        }
        throw StoreError.notFound(ref)
    }

    /// 插入新环境，自动分配序号；名称留空时命名为"环境-序号"。
    @discardableResult
    public func insert(_ profile: Profile) throws -> Profile {
        try db.write { try Self.insert(profile, into: $0) }
    }

    /// 一次插入一批（同一个事务，要么全部成功，要么都不插入）。
    @discardableResult
    public func insertMany(_ items: [Profile]) throws -> [Profile] {
        try db.write { db in try items.map { try Self.insert($0, into: db) } }
    }

    private static func insert(_ profile: Profile, into db: Database) throws -> Profile {
        var p = profile
        p.seq = (try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM profile") ?? 0) + 1
        fillDefaultName(&p)
        p.createdAt = Date()
        p.updatedAt = p.createdAt
        try p.insert(db)
        return p
    }

    public func update(_ profile: Profile) throws {
        try db.write { try Self.update(profile, in: $0) }
    }

    /// 批量修改：transform 改完后在同一个事务里保存。
    public func updateMany(_ ids: [String], _ transform: (inout Profile) -> Void) throws {
        try db.write { db in
            for id in ids {
                guard var p = try Profile.fetchOne(db, key: id) else { continue }
                transform(&p)
                try Self.update(p, in: db)
            }
        }
    }

    private static func update(_ profile: Profile, in db: Database) throws {
        var p = profile
        fillDefaultName(&p)
        p.updatedAt = Date()
        try p.update(db)
    }

    private static func fillDefaultName(_ p: inout Profile) {
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        if p.name.isEmpty { p.name = L("profile.defaultName \(p.seq)") }
    }

    /// 只更新检测结果和打开时间这类运行时字段，不改 updatedAt。
    public func recordExit(_ info: ExitInfo, for profileId: String) throws {
        let json = String(decoding: try JSONEncoder.store.encode(info), as: UTF8.self)
        try db.write { db in
            try db.execute(sql: "UPDATE profile SET lastExit = ? WHERE id = ?", arguments: [json, profileId])
        }
    }

    public func recordOpened(_ profileId: String, at date: Date = Date()) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE profile SET lastOpenedAt = ? WHERE id = ?", arguments: [date, profileId])
        }
    }

    /// 移入回收站。
    public func softDelete(_ profileId: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE profile SET deletedAt = ? WHERE id = ?", arguments: [Date(), profileId])
        }
    }

    /// 从回收站恢复。
    public func restore(_ profileId: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE profile SET deletedAt = NULL WHERE id = ?", arguments: [profileId])
        }
    }

    /// 彻底删除：数据库记录和环境目录一起删。
    public func purge(_ profileId: String) throws {
        _ = try db.write { db in try Profile.deleteOne(db, key: profileId) }
        let dir = paths.profileDir(profileId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// 复制环境：设置（包括代理）全部复制。
    /// copyData 为 true 时连浏览器数据（登录状态、Cookie、保存的密码、扩展）一起复制。
    public func duplicate(_ id: String, copyData: Bool = false) throws -> Profile {
        guard let src = try profile(id: id) else { throw StoreError.notFound(id) }
        var p = src
        p.id = UUID().uuidString.lowercased()
        p.name = L("profile.duplicateName \(src.name)")
        p.lastExit = nil
        p.lastOpenedAt = nil
        p.deletedAt = nil
        p.themeColor = nil
        let saved = try insert(p)
        if copyData {
            let from = paths.profileDir(src.id)
            if FileManager.default.fileExists(atPath: from.path) {
                try ProfileFiles.copyData(from: from, to: paths.profileDir(saved.id))
            }
        }
        return saved
    }

    /// 清理回收站里删除超过 days 天的环境，返回清理掉的 id。
    @discardableResult
    public func purgeTrash(olderThanDays days: Int, now: Date = Date()) throws -> [String] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let ids = try db.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM profile WHERE deletedAt IS NOT NULL AND deletedAt < ?",
                                arguments: [cutoff])
        }
        for id in ids { try purge(id) }
        return ids
    }

    // MARK: - 设置（JSON）

    public func setting<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        let json = try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM appSetting WHERE key = ?", arguments: [key])
        }
        guard let json else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    public func setSetting<T: Encodable>(_ key: String, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.write { db in
            try db.execute(sql: "INSERT INTO appSetting(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                           arguments: [key, json])
        }
    }

    // MARK: - 标签

    /// 重命名标签（所有环境，含回收站）。新名称已存在时两者合并。
    public func renameTag(_ old: String, to new: String) throws {
        let name = new.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != old else { return }
        let ids = try profiles(.all).filter { $0.tags.contains(old) }.map(\.id)
        try updateMany(ids) { p in
            var seen = Set<String>()
            p.tags = p.tags.map { $0 == old ? name : $0 }.filter { seen.insert($0).inserted }
        }
    }

    /// 从所有环境上移除这个标签。
    public func deleteTag(_ tag: String) throws {
        let ids = try profiles(.all).filter { $0.tags.contains(tag) }.map(\.id)
        try updateMany(ids) { $0.tags.removeAll { $0 == tag } }
    }
}

extension JSONEncoder {
    /// 与 GRDB 存 JSON 列的默认编码保持一致（日期为毫秒时间戳），手写 SQL 更新 JSON 列时使用。
    static var store: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }
}
