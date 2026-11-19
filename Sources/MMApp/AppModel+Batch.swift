import Foundation
import MMCore

/// 批量新建的名称模板：`{n}` 替换为编号（从 start 开始，按位数补零）；没有 `{n}` 时编号接在后面。
struct NamePattern {
    var pattern: String
    var start = 1
    var digits = 2

    func name(_ index: Int) -> String {
        let num = String(format: "%0\(max(1, digits))d", start + index)
        return pattern.contains("{n}") ? pattern.replacingOccurrences(of: "{n}", with: num) : pattern + num
    }
}

/// 批量编辑：只改勾选了的字段。
struct BatchEdit {
    var addTags: [String] = []
    var removeTags: [String] = []
    var setLanguage = false
    var language = LanguageTag.auto
    var setTimezone = false
    var timezone: String?          // nil = 自动
    var setGeolocation = false
    var geolocation = GeolocationPolicy.block
    var setWindow = false
    var window: WindowSize?        // nil = 默认
    var setExpiry = false
    var expiry: Date?

    func apply(to p: inout Profile) {
        p.tags += addTags.filter { !p.tags.contains($0) }
        p.tags.removeAll { removeTags.contains($0) }
        if setLanguage { p.language = language }
        if setTimezone { p.timezone = timezone }
        if setGeolocation { p.geolocation = geolocation }
        if setWindow { p.windowSize = window }
        if setExpiry { p.proxyExpiresAt = expiry }
    }
}

@MainActor
extension AppModel {
    /// 批量新建：proxies 非空时每个代理建一个环境，否则建 count 个和模板一样的环境。
    func batchCreate(template: Profile, names: NamePattern, count: Int, proxies: [ProxyConfig]) {
        let items = (0..<(proxies.isEmpty ? count : proxies.count)).map { i in
            var p = template
            p.id = UUID().uuidString.lowercased()
            p.name = names.name(i)
            if !proxies.isEmpty { p.proxy = proxies[i] }
            return p
        }
        guard let inserted = attempt(L("alert.batchCreateFailed"), { try $0.insertMany(items) }) else { return }
        report(L("report.batchCreate"), ok: inserted.count)
        autoCheck(inserted.map(\.id))
    }

    func batchEdit(_ ids: [String], _ edit: BatchEdit) {
        attempt(L("alert.batchEditFailed")) { try $0.updateMany(ids) { edit.apply(to: &$0) } }
    }

    /// 把代理按序号顺序分配给环境。代理数量必须和环境数量一致。
    func assignProxies(_ ids: [String], proxies: [ProxyConfig], expiry: Date?) {
        let ordered = ids.compactMap(fresh).sorted { $0.seq < $1.seq }.map(\.id)
        guard ordered.count == proxies.count else {
            alert = AppAlert(title: L("alert.countMismatch"), message: L("alert.countMismatch.message \(ordered.count) \(proxies.count)"))
            return
        }
        let assigned = Dictionary(uniqueKeysWithValues: zip(ordered, proxies))
        let saved: Void? = attempt(L("alert.assignProxiesFailed")) { store in
            try store.updateMany(ordered) {
                $0.proxy = assigned[$0.id]
                $0.allowDirect = false
                $0.lastExit = nil
                if let expiry { $0.proxyExpiresAt = expiry }
            }
        }
        guard saved != nil else { return }
        report(L("report.assignProxies"), ok: ordered.count)
        autoCheck(ordered)
    }

    @discardableResult
    func duplicate(_ id: String, copyData: Bool) -> Profile? {
        guard let p = attempt(L("alert.duplicateFailed"), { try $0.duplicate(id, copyData: copyData) }) else { return nil }
        autoCheck([p.id])
        return p
    }
}
