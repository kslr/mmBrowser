import AppKit
import Foundation
import MMCore
import UniformTypeIdentifiers

/// 扩展库里的一项（全局，供各环境勾选）。
struct ExtensionEntry: Codable, Hashable, Identifiable {
    var id: String
    var name: String
}

/// 批量编辑：只改勾选了的字段。
struct BatchEdit {
    var addTags: [String] = []
    var removeTags: [String] = []
    var setLanguage = false
    var language = "en-US"
    var setTimezone = false
    var timezone: String?          // nil = 自动
    var setGeolocation = false
    var geolocation = GeolocationPolicy.block
    var setWindow = false
    var window: (Int, Int)?        // nil = 默认
    var setStartURLs = false
    var startURLs: [String] = []
    var alwaysOpenStartURLs = false
    var addExtensions: [String] = []
    var removeExtensions: [String] = []
    var setExpiry = false
    var expiry: Date?

    func apply(to p: inout Profile) {
        if !addTags.isEmpty { p.tags = Array(NSOrderedSet(array: p.tags + addTags)) as? [String] ?? p.tags }
        if !removeTags.isEmpty { p.tags.removeAll { removeTags.contains($0) } }
        if setLanguage { p.language = language }
        if setTimezone { p.timezone = timezone }
        if setGeolocation { p.geolocation = geolocation }
        if setWindow { p.windowWidth = window?.0; p.windowHeight = window?.1 }
        if setStartURLs { p.startURLs = startURLs; p.alwaysOpenStartURLs = alwaysOpenStartURLs }
        if !addExtensions.isEmpty { p.extensionIds = Array(NSOrderedSet(array: p.extensionIds + addExtensions)) as? [String] ?? p.extensionIds }
        if !removeExtensions.isEmpty { p.extensionIds.removeAll { removeExtensions.contains($0) } }
        if setExpiry { p.proxyExpiresAt = expiry }
    }
}

extension UTType {
    static let mmprofile = UTType(filenameExtension: ProfileBackup.fileExtension, conformingTo: .zip) ?? .zip
}

@MainActor
extension AppModel {
    /// 直接从数据库读最新的环境。按 id 执行操作时用它，不依赖内存列表
    /// （数据库观察是异步推送的，批量写入后内存列表可能短暂落后）。
    func fresh(_ id: String) -> Profile? {
        try? store?.profile(id: id)
    }

    // MARK: - 结果提示

    func report(_ title: String, ok: Int, failed: [(String, String)], extra: [String] = []) {
        var lines = extra
        if !failed.isEmpty {
            lines.append(L("report.failedHeader \(failed.count)"))
            lines += failed.prefix(20).map { L("report.failedItem \($0.0) \($0.1)") }
            if failed.count > 20 { lines.append(L("report.more \(failed.count - 20)")) }
        }
        alert = AppAlert(title: failed.isEmpty ? L("report.title \(title) \(ok)") : L("report.titleWithFailures \(title) \(ok) \(failed.count)"),
                         message: lines.joined(separator: "\n"))
    }

    // MARK: - 批量新建 / 编辑 / 复制

    /// 批量新建：proxies 非空时每个代理建一个环境，否则建 count 个没有代理的环境。
    /// 名称用模板，`{n}` 替换为编号（从 startNumber 开始，按位数补零）。
    func batchCreate(template: Profile, namePattern: String, startNumber: Int, digits: Int,
                     count: Int, proxies: [ProxyConfig]) {
        guard let store else { return }
        let n = proxies.isEmpty ? count : proxies.count
        var items: [Profile] = []
        for i in 0..<n {
            var p = template
            p.id = UUID().uuidString.lowercased()
            let num = String(format: "%0\(max(1, digits))d", startNumber + i)
            p.name = namePattern.contains("{n}") ? namePattern.replacingOccurrences(of: "{n}", with: num) : "\(namePattern)\(num)"
            p.proxy = proxies.isEmpty ? template.proxy : proxies[i]
            items.append(p)
        }
        do {
            let r = try store.insertMany(items)
            report(L("report.batchCreate"), ok: r.inserted.count, failed: r.failed)
        } catch {
            alert = AppAlert(title: L("alert.batchCreateFailed"), message: error.localizedDescription)
        }
    }

    func batchEdit(_ ids: [String], _ edit: BatchEdit) {
        guard let store else { return }
        do {
            let failed = try store.updateMany(ids) { edit.apply(to: &$0) }
            if !failed.isEmpty { report(L("report.batchEdit"), ok: ids.count - failed.count, failed: failed) }
        } catch {
            alert = AppAlert(title: L("alert.batchEditFailed"), message: error.localizedDescription)
        }
    }

    /// 把代理按顺序分配给环境（按序号排序）。代理数量必须和环境数量一致。
    func assignProxies(_ ids: [String], proxies: [ProxyConfig], expiry: Date?) {
        guard let store else { return }
        let ordered = ids.compactMap(fresh).sorted { $0.seq < $1.seq }
        guard ordered.count == proxies.count else {
            alert = AppAlert(title: L("alert.countMismatch"), message: L("alert.countMismatch.message \(ordered.count) \(proxies.count)"))
            return
        }
        // 先清掉这批环境原来的代理，避免"互换代理"时撞上唯一约束
        do {
            _ = try store.updateMany(ordered.map(\.id)) { $0.proxy = nil }
            var failed: [(String, String)] = []
            for (p, proxy) in zip(ordered, proxies) {
                let f = try store.updateMany([p.id]) {
                    $0.proxy = proxy
                    $0.allowDirect = false
                    $0.lastExit = nil
                    if let expiry { $0.proxyExpiresAt = expiry }
                }
                failed += f
            }
            report(L("report.assignProxies"), ok: ordered.count - failed.count, failed: failed)
        } catch {
            alert = AppAlert(title: L("alert.assignProxiesFailed"), message: error.localizedDescription)
        }
    }

    @discardableResult
    func duplicate(_ id: String, copyData: Bool) -> Profile? {
        guard let store else { return nil }
        do {
            return try store.duplicate(id, copyData: copyData)
        } catch {
            alert = AppAlert(title: L("alert.duplicateFailed"), message: error.localizedDescription)
            return nil
        }
    }

    // MARK: - 检测

    /// 批量检测：每批 5 个并发，一批做完再做下一批。
    func checkMany(_ ids: [String]) {
        let queue = ids.filter { !checking.contains($0) }
        guard !queue.isEmpty else { return }
        queue.forEach { checking.insert($0) }  // 排队的也先显示为检测中
        let chunks = stride(from: 0, to: queue.count, by: 5).map { Array(queue[$0..<min($0 + 5, queue.count)]) }
        Task {
            for chunk in chunks {
                await withTaskGroup(of: Void.self) { group in
                    for id in chunk { group.addTask { await self.checkAndWait(id) } }
                }
            }
        }
    }

    private func checkAndWait(_ id: String) async {
        defer { checking.remove(id) }
        guard let store, let p = fresh(id) else { return }
        let upstream: Upstream
        if let proxy = p.proxy { upstream = .proxy(proxy) } else if p.allowDirect { upstream = .direct } else { return }
        do {
            let info = try await GeoCheck.check(upstream: upstream)
            try store.recordExit(info, for: id)
            lastError[id] = nil
            checkFailed.remove(id)
        } catch {
            lastError[id] = L("list.checkFailed \(error.localizedDescription)")
            checkFailed.insert(id)
        }
    }

    /// 已过期或 days 天内到期的代理。
    func expiringProxies(within days: Int = 7) -> [Profile] {
        let limit = Date().addingTimeInterval(Double(days) * 86_400)
        return profiles.filter { $0.proxy != nil && ($0.proxyExpiresAt.map { $0 <= limit } ?? false) }
            .sorted { ($0.proxyExpiresAt ?? .distantFuture) < ($1.proxyExpiresAt ?? .distantFuture) }
    }

    // MARK: - CSV

    func exportCSV(_ ids: [String]) {
        let list = ids.compactMap(fresh).sorted { $0.seq < $1.seq }
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = L("export.csv.fileName \(Date().formatted(.iso8601.year().month().day()))")
        panel.message = L("export.csv.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ProfileCSV.export(list)
        do {
            // 带 BOM，Excel 打开中文不乱码
            try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            alert = AppAlert(title: L("alert.exportFailed"), message: error.localizedDescription)
        }
    }

    /// 读取并解析 CSV（不入库），返回解析结果供确认。
    func pickCSVForImport() -> [ProfileCSV.Row]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return try ProfileCSV.parseImport(text, defaultLanguage: defaultLanguage)
        } catch {
            alert = AppAlert(title: L("alert.csvImportFailed"), message: error.localizedDescription)
            return nil
        }
    }

    func importCSV(_ rows: [ProfileCSV.Row]) {
        guard let store else { return }
        var failed: [(String, String)] = []
        var ok = 0
        for row in rows {
            let p = row.profile
            do {
                try store.insert(p)
                ok += 1
            } catch {
                failed.append((L("report.csvLine \(row.lineNumber) \(p.name)"), error.localizedDescription))
            }
        }
        report(L("report.importCSV"), ok: ok, failed: failed)
    }

    // MARK: - Cookie

    private func ensureStopped(_ id: String) -> Bool {
        if state(of: id).isActive {
            alert = AppAlert(title: L("alert.closeProfileFirst"), message: L("alert.closeProfileFirst.message"))
            return false
        }
        return true
    }

    func exportCookies(_ id: String) {
        guard let p = fresh(id), ensureStopped(id) else { return }
        do {
            let cookies = try ChromeCookies.read(userDataDir: paths.profileDir(id))
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(p.seq)-\(p.name)-cookies.json"
            panel.message = L("export.cookies.message \(cookies.count)")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ChromeCookies.exportJSON(cookies).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            alert = AppAlert(title: L("alert.exportCookiesFailed"), message: error.localizedDescription)
        }
    }

    func importCookies(_ id: String, replaceAll: Bool) {
        guard ensureStopped(id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let cookies = try ChromeCookies.importJSON(try Data(contentsOf: url))
            let n = try ChromeCookies.write(cookies, userDataDir: paths.profileDir(id), replaceAll: replaceAll)
            alert = AppAlert(title: L("alert.cookiesImported \(n)"),
                             message: replaceAll ? L("alert.cookiesImported.replaced") : L("alert.cookiesImported.merged"))
        } catch {
            alert = AppAlert(title: L("alert.importCookiesFailed"), message: error.localizedDescription)
        }
    }

    // MARK: - 备份

    func exportBackups(_ ids: [String]) {
        guard let store else { return }
        let list = ids.compactMap(fresh).sorted { $0.seq < $1.seq }
        guard !list.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("export.backup.prompt")
        panel.message = L("export.backup.message")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            var failed: [(String, String)] = []
            for p in list {
                let safe = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let file = dir.appendingPathComponent("\(p.seq)-\(safe).\(ProfileBackup.fileExtension)")
                do {
                    try ProfileBackup.export(profileId: p.id, store: store, isRunning: state(of: p.id).isActive, to: file)
                } catch {
                    failed.append(("#\(p.seq) \(p.name)", error.localizedDescription))
                }
            }
            report(L("report.exportBackups"), ok: list.count - failed.count, failed: failed, extra: [L("report.location \(dir.path)")])
        }
    }

    func importBackups() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mmprofile, .zip]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            var ok = 0
            var failed: [(String, String)] = []
            var notes: [String] = []
            for url in urls {
                do {
                    let r = try ProfileBackup.import(from: url, store: store)
                    ok += 1
                    notes += r.warnings.map { L("report.warning \(r.profile.seq) \(r.profile.name) \($0)") }
                } catch {
                    failed.append((url.lastPathComponent, error.localizedDescription))
                }
            }
            report(L("report.importBackups"), ok: ok, failed: failed, extra: notes)
        }
    }

    // MARK: - 扩展库

    var extensionLibrary: [ExtensionEntry] {
        (try? store?.setting("extensionLibrary", as: [ExtensionEntry].self)) ?? []
    }

    func saveExtensionLibrary(_ list: [ExtensionEntry]) {
        try? store?.setSetting("extensionLibrary", list)
        extensionLibraryVersion += 1
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
        saveExtensionLibrary(lib)
    }

    func extensionName(_ id: String) -> String {
        let n = extensionLibrary.first { $0.id == id }?.name ?? ""
        return n.isEmpty ? String(id.prefix(8)) + "…" : n
    }
}
