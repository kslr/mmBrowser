import Foundation
import MMCore

/// 扩展库里的一项（全局）。新建环境时自动装上扩展库里的全部扩展，之后可以在各环境里单独取消。
struct ExtensionEntry: Codable, Hashable, Identifiable {
    var id: String
    /// 还没装过、不知道名称时为空
    var name: String

    /// 内置的常用扩展，首次使用时放进扩展库。ID 已在 Chrome 应用商店核对过。
    static let builtin: [ExtensionEntry] = [
        ExtensionEntry(id: "ddkjiahejlhfcafbddmgiahcphecmpfh", name: "uBlock Origin Lite"),
        ExtensionEntry(id: "nngceckbapebfimnlniiiahkandclblb", name: "Bitwarden"),
        ExtensionEntry(id: "bhghoamapcdpbohphigoooaddinpkbai", name: "Authenticator"),
    ]
}

@MainActor
extension AppModel {
    private static let libraryKey = "extensionLibrary"
    private static let librarySeededKey = "extensionLibrarySeeded"

    /// 读出扩展库；第一次使用时并入内置的常用扩展（之后用户删掉的不会再加回来）。
    func loadExtensionLibrary() {
        guard let store else { return }
        extensionLibrary = (try? store.setting(Self.libraryKey, as: [ExtensionEntry].self)) ?? []
        guard (try? store.setting(Self.librarySeededKey, as: Bool.self)) == nil else { return }
        let known = Set(extensionLibrary.map(\.id))
        saveExtensionLibrary(extensionLibrary + ExtensionEntry.builtin.filter { !known.contains($0.id) })
        try? store.setSetting(Self.librarySeededKey, true)
    }

    func saveExtensionLibrary(_ list: [ExtensionEntry]) {
        extensionLibrary = list
        try? store?.setSetting(Self.libraryKey, list)
    }

    /// 新建环境要装的扩展：扩展库里的全部（单个新建、批量新建、没有扩展列的 CSV 导入）。
    var newProfileExtensionIds: [String] {
        extensionLibrary.map(\.id)
    }

    /// 从各环境已安装的扩展里补全扩展库中缺失的名称。
    func refreshExtensionNames() {
        var lib = extensionLibrary
        guard lib.contains(where: { $0.name.isEmpty }) else { return }
        for p in profiles where !p.extensionIds.isEmpty {
            let names = ExtensionManager.installedNames(userDataDir: paths.profileDir(p.id))
            for i in lib.indices where lib[i].name.isEmpty {
                if let n = names[lib[i].id] { lib[i].name = n }
            }
        }
        if lib != extensionLibrary { saveExtensionLibrary(lib) }
    }

    /// 扩展的显示名：扩展库里的名称，不知道名称时显示 ID 的前几位。
    func extensionName(_ id: String) -> String {
        let n = extensionLibrary.first { $0.id == id }?.name ?? ""
        return n.isEmpty ? String(id.prefix(12)) + "…" : n
    }
}
