import Foundation
import GRDB

public enum StoreError: Error, LocalizedError, Equatable {
    case proxyAlreadyBound(profileName: String, seq: Int)
    case notFound(String)
    case ambiguous(String, [String])

    public var errorDescription: String? {
        switch self {
        case .proxyAlreadyBound(let name, let seq):
            "这个代理已经绑定在环境 #\(seq)「\(name)」上（一个代理只能对应一个环境）"
        case .notFound(let ref):
            "找不到环境：\(ref)"
        case .ambiguous(let ref, let names):
            "「\(ref)」匹配到多个环境：\(names.joined(separator: "、"))"
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
            // 一个代理只能绑定一个未删除的环境（兜底约束，正常情况下先用 proxyOwner 检查给出友好提示）
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
        return m
    }

    // MARK: - 环境

    public func profiles(includeDeleted: Bool = false, onlyDeleted: Bool = false) throws -> [Profile] {
        try db.read { db in
            var request = Profile.order(Column("seq"))
            if onlyDeleted {
                request = request.filter(Column("deletedAt") != nil)
            } else if !includeDeleted {
                request = request.filter(Column("deletedAt") == nil)
            }
            return try request.fetchAll(db)
        }
    }

    public func profile(id: String) throws -> Profile? {
        try db.read { try Profile.fetchOne($0, key: id) }
    }

    /// 按引用查找：`#12` / `12`（序号）、id 或 id 前缀（≥4 位）、名称（完全匹配）。
    public func resolve(_ ref: String, includeDeleted: Bool = false) throws -> Profile {
        let all = try profiles(includeDeleted: includeDeleted)
        let trimmed = ref.hasPrefix("#") ? String(ref.dropFirst()) : ref
        if let seq = Int(trimmed), let p = all.first(where: { $0.seq == seq }) { return p }
        if let p = all.first(where: { $0.id == ref }) { return p }
        let byName = all.filter { $0.name == ref }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw StoreError.ambiguous(ref, byName.map { "#\($0.seq)" }) }
        if ref.count >= 4 {
            let byPrefix = all.filter { $0.id.hasPrefix(ref.lowercased()) }
            if byPrefix.count == 1 { return byPrefix[0] }
            if byPrefix.count > 1 { throw StoreError.ambiguous(ref, byPrefix.map { "#\($0.seq) \($0.name)" }) }
        }
        throw StoreError.notFound(ref)
    }

    /// 返回已经绑定这个代理的其他未删除环境（没有则 nil）。
    public func proxyOwner(of proxy: ProxyConfig, excluding profileId: String? = nil) throws -> Profile? {
        try db.read { db in
            var request = Profile
                .filter(Column("deletedAt") == nil)
                .filter(sql: "lower(proxyHost) = lower(?) AND proxyPort = ? AND IFNULL(proxyUsername, '') = ?",
                        arguments: [proxy.host, proxy.port, proxy.username ?? ""])
            if let profileId { request = request.filter(Column("id") != profileId) }
            return try request.fetchOne(db)
        }
    }

    /// 插入新环境，自动分配序号。
    @discardableResult
    public func insert(_ profile: Profile) throws -> Profile {
        var p = profile
        if let proxy = p.proxy, let owner = try proxyOwner(of: proxy) {
            throw StoreError.proxyAlreadyBound(profileName: owner.name, seq: owner.seq)
        }
        try db.write { db in
            let maxSeq = try Int.fetchOne(db, sql: "SELECT MAX(seq) FROM profile") ?? 0
            p.seq = maxSeq + 1
            p.createdAt = Date()
            p.updatedAt = p.createdAt
            try p.insert(db)
        }
        return p
    }

    public func update(_ profile: Profile) throws {
        var p = profile
        if let proxy = p.proxy, !p.isDeleted, let owner = try proxyOwner(of: proxy, excluding: p.id) {
            throw StoreError.proxyAlreadyBound(profileName: owner.name, seq: owner.seq)
        }
        p.updatedAt = Date()
        try db.write { try p.update($0) }
    }

    /// 只更新检测结果和打开时间这类运行时字段，不触发代理唯一性检查。
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

    /// 从回收站恢复。代理如果已经被别的环境占用，会抛错。
    public func restore(_ profileId: String) throws {
        guard var p = try profile(id: profileId) else { throw StoreError.notFound(profileId) }
        p.deletedAt = nil
        try update(p)
    }

    /// 彻底删除：数据库记录和环境目录一起删。
    public func purge(_ profileId: String) throws {
        _ = try db.write { db in try Profile.deleteOne(db, key: profileId) }
        let dir = paths.profileDir(profileId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - 批量

    /// 批量插入，逐个检查代理唯一性（包括这一批内部互相重复）。返回成功的和失败的（名称 + 原因）。
    public func insertMany(_ items: [Profile]) throws -> (inserted: [Profile], failed: [(String, String)]) {
        var inserted: [Profile] = []
        var failed: [(String, String)] = []
        for p in items {
            do {
                inserted.append(try insert(p))
            } catch {
                failed.append((p.name, error.localizedDescription))
            }
        }
        return (inserted, failed)
    }

    /// 批量修改。transform 改完后逐个保存，代理冲突等错误会收集起来返回。
    public func updateMany(_ ids: [String], _ transform: (inout Profile) -> Void) throws -> [(String, String)] {
        var failed: [(String, String)] = []
        for id in ids {
            guard var p = try profile(id: id) else { continue }
            transform(&p)
            do { try update(p) } catch { failed.append((p.name, error.localizedDescription)) }
        }
        return failed
    }

    /// 复制环境：设置全部复制，代理不复制（一个代理只能对应一个环境）。
    /// copyData 为 true 时连浏览器数据（登录状态、Cookie、保存的密码、扩展）一起复制。
    public func duplicate(_ id: String, name: String? = nil, copyData: Bool = false) throws -> Profile {
        guard let src = try profile(id: id) else { throw StoreError.notFound(id) }
        var p = src
        p.id = UUID().uuidString.lowercased()
        p.name = name ?? "\(src.name) 副本"
        p.proxy = nil
        p.proxyExpiresAt = nil
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

    // MARK: - 分组

    public func groups() throws -> [ProfileGroup] {
        try db.read { try ProfileGroup.order(Column("sortOrder"), Column("name")).fetchAll($0) }
    }

    /// 按名称取分组，不存在就创建。
    public func group(named name: String) throws -> ProfileGroup {
        try db.write { db in
            if let g = try ProfileGroup.filter(Column("name") == name).fetchOne(db) { return g }
            let maxOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM profileGroup") ?? 0
            var g = ProfileGroup(name: name, sortOrder: maxOrder + 1)
            try g.insert(db)
            return g
        }
    }

    public func renameGroup(_ id: Int64, to name: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE profileGroup SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// 删除分组，组内环境变为未分组（外键 ON DELETE SET NULL）。
    public func deleteGroup(_ id: Int64) throws {
        _ = try db.write { db in try ProfileGroup.deleteOne(db, key: id) }
    }

    /// 把一批环境移到某个分组（nil 表示未分组）。
    public func move(_ profileIds: [String], toGroup groupId: Int64?) throws {
        try db.write { db in
            for id in profileIds {
                try db.execute(sql: "UPDATE profile SET groupId = ?, updatedAt = ? WHERE id = ?",
                               arguments: [groupId, Date(), id])
            }
        }
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
