import Foundation
import GRDB

public struct ProfileGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var name: String
    public var sortOrder: Int

    public init(id: Int64? = nil, name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

extension ProfileGroup: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "profileGroup"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
