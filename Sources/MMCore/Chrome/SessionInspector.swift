import Foundation

/// 读取 Chrome 上次的会话文件（Default/Sessions/Session_*，SNSS 格式），推算哪些标签页还开着、停在哪个网址。
/// 只用于判断"检测页是不是已经开着"，避免每次启动都多开一个。解析不了就返回 nil（调用方照常打开）。
public enum SessionInspector {
    // components/sessions/core/session_service_commands.cc
    static let setTabWindow: UInt8 = 0
    static let tabNavigationPathPrunedFromBack: UInt8 = 5
    static let updateTabNavigation: UInt8 = 6
    static let setSelectedNavigationIndex: UInt8 = 7
    static let tabClosed: UInt8 = 16
    static let windowClosed: UInt8 = 17

    public static func openTabURLs(userDataDir: URL) -> [String]? {
        let dir = userDataDir.appendingPathComponent("Default/Sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        let latest = files.filter { $0.lastPathComponent.hasPrefix("Session_") }
            .max { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
        guard let latest else { return [] }
        guard let data = try? Data(contentsOf: latest) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> [String]? {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0x53, b[1] == 0x4E, b[2] == 0x53, b[3] == 0x53 else { return nil }  // "SNSS"
        func i32(_ o: Int) -> Int32? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }

        var navs: [Int32: [Int32: String]] = [:]
        var order: [Int32] = []
        var selected: [Int32: Int32] = [:]
        var closedTabs = Set<Int32>()
        var tabWindow: [Int32: Int32] = [:]
        var closedWindows = Set<Int32>()

        var pos = 8
        while pos + 2 <= b.count {
            let size = Int(b[pos]) | Int(b[pos + 1]) << 8
            pos += 2
            guard size > 0, pos + size <= b.count else { break }
            let id = b[pos]
            let p = pos + 1  // payload 起点
            pos += size
            switch id {
            case updateTabNavigation:
                // Pickle：uint32 负载长度，然后 tab_id、index、url（int32 长度 + 字节）
                guard let tab = i32(p + 4), let index = i32(p + 8), let len = i32(p + 12),
                      len >= 0, p + 16 + Int(len) <= b.count else { return nil }
                let url = String(decoding: b[(p + 16)..<(p + 16 + Int(len))], as: UTF8.self)
                if navs[tab] == nil { order.append(tab) }
                navs[tab, default: [:]][index] = url
            case setSelectedNavigationIndex:
                guard let tab = i32(p), let index = i32(p + 4) else { return nil }
                selected[tab] = index
            case tabNavigationPathPrunedFromBack:
                guard let tab = i32(p), let count = i32(p + 4) else { return nil }
                navs[tab] = navs[tab]?.filter { $0.key < count }
            case tabClosed:
                guard let tab = i32(p) else { return nil }
                closedTabs.insert(tab)
            case setTabWindow:
                guard let window = i32(p), let tab = i32(p + 4) else { return nil }
                tabWindow[tab] = window
            case windowClosed:
                guard let window = i32(p) else { return nil }
                closedWindows.insert(window)
            default:
                break
            }
        }

        return order.compactMap { tab -> String? in
            guard !closedTabs.contains(tab), let n = navs[tab], !n.isEmpty else { return nil }
            if let w = tabWindow[tab], closedWindows.contains(w) { return nil }
            if let s = selected[tab], let url = n[s] { return url }
            return n[n.keys.max()!]
        }
    }

    /// 两个网址是不是同一个检测站（比较主机名，忽略 www.）。
    public static func sameSite(_ a: String, _ b: String) -> Bool {
        func host(_ s: String) -> String? {
            URL(string: s)?.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        }
        guard let ha = host(a), let hb = host(b) else { return false }
        return ha == hb
    }
}
