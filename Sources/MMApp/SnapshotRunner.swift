import AppKit
import MMCore
import SwiftUI

/// 开发自检：`mmBrowser --snapshot <目录>` 在不可见窗口里渲染主要界面并保存为 PNG。
/// 必须用 MMBROWSER_HOME 指向临时目录，避免把演示数据写进正式数据目录。
@MainActor
enum SnapshotRunner {
    static func run(outputDir: URL) async {
        guard ProcessInfo.processInfo.environment["MMBROWSER_HOME"] != nil else {
            FileHandle.standardError.write(Data((L("snapshot.error.home") + "\n").utf8))
            return
        }
        let model = AppModel.shared
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        seedDemoData(model)
        try? await Task.sleep(for: .milliseconds(500))

        await render(ContentView().environment(model), size: CGSize(width: 1280, height: 720),
                     to: outputDir.appendingPathComponent("main.png"))
        if let first = model.profiles.first {
            await render(ProfileEditorView(target: .edit(first.id)).environment(model), size: CGSize(width: 600, height: 660),
                         to: outputDir.appendingPathComponent("editor.png"))
            ProfileEditorView.height = 1500
            ProfileEditorView.expandAllForSnapshot = true
            await render(ProfileEditorView(target: .edit(first.id)).environment(model),
                         size: CGSize(width: 600, height: 1500), to: outputDir.appendingPathComponent("editor-full.png"))
            ProfileEditorView.expandAllForSnapshot = false
            ProfileEditorView.height = 660
            await render(ProfileEditorView(target: .new(tag: nil)).environment(model),
                         size: CGSize(width: 600, height: 660), to: outputDir.appendingPathComponent("editor-new.png"))
        }
        await render(SettingsView().environment(model), size: CGSize(width: 600, height: 700),
                     to: outputDir.appendingPathComponent("settings.png"))
        await render(ContentView(initialSidebar: .proxies).environment(model), size: CGSize(width: 1280, height: 720),
                     to: outputDir.appendingPathComponent("proxies.png"))
        await render(BatchCreateView(tag: nil).environment(model), size: CGSize(width: 600, height: 700),
                     to: outputDir.appendingPathComponent("batch-create.png"))
        let ids = model.profiles.prefix(3).map(\.id)
        await render(BatchEditView(ids: ids).environment(model), size: CGSize(width: 560, height: 620),
                     to: outputDir.appendingPathComponent("batch-edit.png"))
        await render(AssignProxiesView(ids: ids).environment(model), size: CGSize(width: 600, height: 640),
                     to: outputDir.appendingPathComponent("assign.png"))
    }

    /// 走界面同一套 AppModel：启动一个直连测试环境 → 等到运行中 → 截图 → 关闭 → 等回到未运行。
    static func selfTest(outputDir: URL) async {
        let model = AppModel.shared
        guard let store = model.store else { return }
        var p = Profile(name: "自检-直连", startURLs: ["https://example.com/"])
        p.allowDirect = true
        p.extraArgs = ["--window-position=-3000,-3000"]
        guard let saved = try? store.insert(p) else { print("selftest: " + L("snapshot.error.create")); return }
        model.refreshFromDisk()

        func waitFor(_ what: String, timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !cond(), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            let ok = cond()
            print("selftest: \(what) \(ok ? "✓" : "✗ " + L("snapshot.timeout"))")
            return ok
        }

        model.launch(saved.id)
        let started = await waitFor("启动后状态为运行中", timeout: 60) {
            if case .running = model.state(of: saved.id) { return true }
            return false
        }
        if !started {
            print("selftest: " + L("snapshot.error \(model.lastError[saved.id] ?? model.alert?.message ?? L("snapshot.none"))"))
            return
        }
        if case .running(let r) = model.state(of: saved.id) {
            print("selftest: " + L("snapshot.running \(Int(r.pid)) \(Int(r.proxy?.port ?? 0)) \(r.exit?.summary ?? "-")"))
        }
        await render(ContentView().environment(model), size: CGSize(width: 1280, height: 720),
                     to: outputDir.appendingPathComponent("running.png"))

        model.stop(saved.id)
        _ = await waitFor("关闭后状态回到未运行", timeout: 30) {
            if case .idle = model.state(of: saved.id) { return true }
            return false
        }
        _ = await waitFor("Chrome 进程已退出", timeout: 10) { model.launcher?.runningPID(of: saved.id) == nil }
    }

    /// 批量功能自检：全部通过 AppModel（界面用的同一套逻辑）。
    @discardableResult
    static func batchSelfTest() async -> Bool {
        let model = AppModel.shared
        guard let store = model.store else { return false }
        var failures = 0
        func check(_ what: String, _ ok: Bool) {
            print("batch: \(what) \(ok ? "✓" : "✗")")
            if !ok { failures += 1 }
        }
        func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !cond(), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            return cond()
        }

        // 两个本地上游（直连出口），当作两个不同的代理
        let up1 = LocalProxyServer(upstream: .direct), up2 = LocalProxyServer(upstream: .direct)
        guard let p1 = try? await up1.start(), let p2 = try? await up2.start() else { print("batch: " + L("snapshot.error.upstream")); return false }
        defer { up1.stop(); up2.stop() }
        let proxies = [ProxyConfig(kind: .socks5, host: "127.0.0.1", port: Int(p1)),
                       ProxyConfig(kind: .socks5, host: "127.0.0.1", port: Int(p2))]

        // 1. 批量新建
        var template = Profile(name: "t", language: "en-US")
        template.extraArgs = ["--window-position=-3000,-3000"]
        template.tags = ["自检组"]
        let before = model.profiles.count
        model.batchCreate(template: template, namePattern: "自检-{n}", startNumber: 1, digits: 2, count: 0, proxies: proxies)
        _ = await waitFor(5) { model.profiles.count == before + 2 }  // 等数据库观察推送到位
        let created = model.profiles.filter { $0.name.hasPrefix("自检-0") }.sorted { $0.seq < $1.seq }
        check("批量新建 2 个，名称 自检-01/02，标签正确", created.count == 2 && model.profiles.count == before + 2
              && created.map(\.name) == ["自检-01", "自检-02"] && created.allSatisfy { $0.tags == ["自检组"] })
        if created.count != 2 {
            print("batch:   before=\(before) now=\(model.profiles.count) created=\(created.map(\.name)) alert=\(model.alert?.title ?? "-")")
        }
        model.alert = nil
        guard created.count == 2 else { return false }
        let ids = created.map(\.id)

        // 2. 批量检测 + 重复出口提示
        model.checkMany(ids)
        let checked = await waitFor(60) { ids.allSatisfy { model.fresh($0)?.lastExit != nil } && model.checking.isEmpty }
        _ = await waitFor(5) { ids.allSatisfy { model.profile($0)?.lastExit != nil } }  // 列表也推送到位
        check("批量检测完成，都有出口信息", checked)
        if !checked {
            for id in ids {
                print("batch:   \(model.fresh(id)?.name ?? id) lastExit=\(model.fresh(id)?.lastExit?.ip ?? "nil") error=\(model.lastError[id] ?? "nil") checking=\(model.checking.contains(id))")
            }
        }
        if let a = model.profile(ids[0]) { check("两个环境出口相同 → 出口重复提示", !model.sharedExitIP(a).isEmpty) }

        // 3. 互换代理
        model.assignProxies(ids, proxies: [proxies[1], proxies[0]], expiry: Date().addingTimeInterval(86_400 * 3))
        model.alert = nil
        check("互换代理成功", model.fresh(ids[0])?.proxy == proxies[1] && model.fresh(ids[1])?.proxy == proxies[0])
        _ = await waitFor(5) { model.expiringProxies().contains { ids.contains($0.id) } }
        check("设置到期日后出现在到期提醒里", model.expiringProxies().contains { ids.contains($0.id) })

        // 4. 批量编辑
        var e = BatchEdit()
        e.addTags = ["自检标签"]
        e.setLanguage = true; e.language = "ja-JP"
        e.addExtensions = []
        model.batchEdit(ids, e)
        check("批量编辑：标签和语言", ids.allSatisfy { model.fresh($0)?.tags.contains("自检标签") == true && model.fresh($0)?.language == "ja-JP" })

        // 5. 复制
        let copy = model.duplicate(ids[0], copyData: false)
        check("复制环境：不带代理、保留标签", copy?.proxy == nil && copy?.tags.contains("自检标签") == true)

        // 6. CSV 往返
        let csv = ProfileCSV.export(ids.compactMap(model.fresh))
        let rows = (try? ProfileCSV.parseImport(csv)) ?? []
        check("CSV 导出再解析，代理和标签一致", rows.count == 2 && rows[0].profile.proxy == proxies[1] && rows[0].profile.tags.contains("自检组"))

        // 7. 运行上限 = 1：批量启动两个，只启动一个并提示
        let oldMax = UserDefaults.standard.object(forKey: AppModel.maxRunningKey)
        UserDefaults.standard.set(1, forKey: AppModel.maxRunningKey)
        model.launch(ids)
        check("超过上限时提示", model.alert?.title == L("alert.runningLimit.title \(1)"))
        model.alert = nil
        let oneRunning = await waitFor(60) { ids.contains { if case .running = model.state(of: $0) { true } else { false } } }
        check("只启动了 1 个", oneRunning && model.states.values.filter(\.isActive).count == 1)
        if let oldMax { UserDefaults.standard.set(oldMax, forKey: AppModel.maxRunningKey) }
        else { UserDefaults.standard.removeObject(forKey: AppModel.maxRunningKey) }

        // 8. 全部关闭
        await model.stopAll()
        let allStopped = await waitFor(20) { ids.allSatisfy { model.launcher?.runningPID(of: $0) == nil } }
        check("全部关闭后没有残留 Chrome", allStopped)

        // 清理
        model.moveToTrash(ids + [copy?.id].compactMap { $0 })
        model.purge(ids + [copy?.id].compactMap { $0 })
        _ = store
        print("batch: " + L("snapshot.batch.done \(failures)"))
        return failures == 0
    }

    private static func seedDemoData(_ model: AppModel) {
        guard let store = model.store, (try? store.profiles(includeDeleted: true).isEmpty) == true else { return }
        let samples: [(String, String, String, [String], String?)] = [
            ("客户A-广告户01", "socks5://u1:p@203.0.113.10:1080", "en-US", ["客户A", "广告"], "US"),
            ("客户A-广告户02", "http://u2:p@203.0.113.11:8080", "en-US", ["客户A", "广告", "重要"], "US"),
            ("日本店铺", "socks5://198.51.100.7:1080", "ja-JP", ["店铺"], "JP"),
            ("测试环境", "socks5://u3:p@192.0.2.44:1080", "de-DE", [], nil),
        ]
        for (name, proxy, lang, tags, cc) in samples {
            var p = Profile(name: name, proxy: try? ProxyConfig.parse(proxy), language: lang,
                            startURLs: ["https://example.com/"], tags: tags,
                            notes: name.hasPrefix("客户A") ? "BC 7012345678" : "")
            if let saved = try? store.insert(p), let cc {
                p = saved
                try? store.recordExit(ExitInfo(ip: cc == "US" ? "203.0.113.10" : "198.51.100.7", countryCode: cc,
                                               region: cc == "US" ? "California" : "Tokyo",
                                               city: cc == "US" ? "Los Angeles" : "Tokyo",
                                               timezone: cc == "US" ? "America/Los_Angeles" : "Asia/Tokyo",
                                               org: "AS0 Example", latencyMs: 230, provider: "demo"), for: p.id)
            }
        }
        if let last = try? store.insert(Profile(name: "已停用的环境")) { try? store.softDelete(last.id) }
        // 到期日：一个已过期、一个快到期、一个还早
        let all = (try? store.profiles()) ?? []
        let offsets: [Double] = [-2, 3, 60]
        for (p, d) in zip(all, offsets) {
            _ = try? store.updateMany([p.id]) { $0.proxyExpiresAt = Date().addingTimeInterval(d * 86_400) }
        }
        try? store.setSetting("extensionLibrary", [
            ExtensionEntry(id: "ddkjiahejlhfcafbddmgiahcphecmpfh", name: "uBlock Origin Lite"),
            ExtensionEntry(id: "eimadpbcbfnmbkopoojfekhnkhdbieeh", name: ""),
        ])
        if let first = all.first { _ = try? store.updateMany([first.id]) { $0.extensionIds = ["ddkjiahejlhfcafbddmgiahcphecmpfh"] } }
        model.refreshFromDisk()
    }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        window.displayIfNeeded()

        let target = window.contentView?.superview ?? host  // 包含标题栏和工具栏
        let bounds = target.bounds
        if let rep = target.bitmapImageRepForCachingDisplay(in: bounds) {
            target.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                print("saved \(url.path)")
            }
        }
        window.orderOut(nil)
    }
}
