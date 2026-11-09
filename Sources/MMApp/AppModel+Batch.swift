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
    var setGroup = false
    var groupId: Int64?
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
        if setGroup { p.groupId = groupId }
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
            lines.append("失败 \(failed.count) 个：")
            lines += failed.prefix(20).map { "· \($0.0)：\($0.1)" }
            if failed.count > 20 { lines.append("…… 另有 \(failed.count - 20) 个") }
        }
        alert = AppAlert(title: "\(title)：成功 \(ok) 个" + (failed.isEmpty ? "" : "，失败 \(failed.count) 个"),
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
            report("批量新建", ok: r.inserted.count, failed: r.failed)
        } catch {
            alert = AppAlert(title: "批量新建失败", message: error.localizedDescription)
        }
    }

    func batchEdit(_ ids: [String], _ edit: BatchEdit) {
        guard let store else { return }
        do {
            let failed = try store.updateMany(ids) { edit.apply(to: &$0) }
            if !failed.isEmpty { report("批量编辑", ok: ids.count - failed.count, failed: failed) }
        } catch {
            alert = AppAlert(title: "批量编辑失败", message: error.localizedDescription)
        }
    }

    /// 把代理按顺序分配给环境（按序号排序）。代理数量必须和环境数量一致。
    func assignProxies(_ ids: [String], proxies: [ProxyConfig], expiry: Date?) {
        guard let store else { return }
        let ordered = ids.compactMap(fresh).sorted { $0.seq < $1.seq }
        guard ordered.count == proxies.count else {
            alert = AppAlert(title: "数量不一致", message: "选中了 \(ordered.count) 个环境，但填了 \(proxies.count) 个代理。")
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
            report("分配代理", ok: ordered.count - failed.count, failed: failed)
        } catch {
            alert = AppAlert(title: "分配代理失败", message: error.localizedDescription)
        }
    }

    func duplicate(_ id: String, copyData: Bool) {
        guard let store else { return }
        do {
            _ = try store.duplicate(id, copyData: copyData)
        } catch {
            alert = AppAlert(title: "复制失败", message: error.localizedDescription)
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
        } catch {
            lastError[id] = "检测失败：\(error.localizedDescription)"
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
        panel.nameFieldStringValue = "mmBrowser-环境-\(Date().formatted(.iso8601.year().month().day())).csv"
        panel.message = "导出的文件包含代理密码，请妥善保管"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ProfileCSV.export(list) { self.groupName($0) }
        do {
            // 带 BOM，Excel 打开中文不乱码
            try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            alert = AppAlert(title: "导出失败", message: error.localizedDescription)
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
            alert = AppAlert(title: "无法导入 CSV", message: error.localizedDescription)
            return nil
        }
    }

    func importCSV(_ rows: [ProfileCSV.Row]) {
        guard let store else { return }
        var failed: [(String, String)] = []
        var ok = 0
        for row in rows {
            var p = row.profile
            do {
                if let g = row.groupName { p.groupId = try store.group(named: g).id }
                try store.insert(p)
                ok += 1
            } catch {
                failed.append(("第 \(row.lineNumber) 行 \(p.name)", error.localizedDescription))
            }
        }
        report("导入 CSV", ok: ok, failed: failed)
    }

    // MARK: - Cookie

    private func ensureStopped(_ id: String) -> Bool {
        if state(of: id).isActive {
            alert = AppAlert(title: "请先关闭环境", message: "Cookie 和备份只能在环境关闭时读写。")
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
            panel.message = "共 \(cookies.count) 条 Cookie。文件包含登录凭据，请妥善保管"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try ChromeCookies.exportJSON(cookies).write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            alert = AppAlert(title: "导出 Cookie 失败", message: error.localizedDescription)
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
            alert = AppAlert(title: "已导入 \(n) 条 Cookie", message: replaceAll ? "原有 Cookie 已清空。" : "已与原有 Cookie 合并（同名覆盖）。")
        } catch {
            alert = AppAlert(title: "导入 Cookie 失败", message: error.localizedDescription)
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
        panel.prompt = "导出到这里"
        panel.message = "每个环境导出为一个 .mmprofile 文件（包含代理密码、Cookie、保存的密码），请妥善保管"
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
            report("导出备份", ok: list.count - failed.count, failed: failed, extra: ["位置：\(dir.path)"])
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
                    notes += r.warnings.map { "#\(r.profile.seq) \(r.profile.name)：\($0)" }
                } catch {
                    failed.append((url.lastPathComponent, error.localizedDescription))
                }
            }
            report("导入备份", ok: ok, failed: failed, extra: notes)
        }
    }

    // MARK: - 窗口

    func arrangeWindows(_ layout: WindowArranger.Layout) {
        let pids: [Int32] = profiles.compactMap {
            switch state(of: $0.id) {
            case .running(let r): r.pid
            case .orphan(let pid): pid
            default: nil
            }
        }
        guard !pids.isEmpty else {
            alert = AppAlert(title: "没有运行中的环境", message: "")
            return
        }
        guard WindowArranger.isTrusted(prompt: true) else {
            alert = AppAlert(title: "需要辅助功能权限",
                             message: "请在 系统设置 → 隐私与安全性 → 辅助功能 里允许 mmBrowser，然后再试一次。")
            WindowArranger.openAccessibilitySettings()
            return
        }
        WindowArranger.arrange(pids: pids, layout: layout)
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
