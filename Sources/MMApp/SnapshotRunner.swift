import AppKit
import MMCore
import SwiftUI

/// 开发自检：`mmBrowser --snapshot <目录>` 在不可见窗口里渲染主要界面并保存为 PNG。
/// 必须用 MMBROWSER_HOME 指向临时目录，避免把演示数据写进正式数据目录。
@MainActor
enum SnapshotRunner {
    static func run(outputDir: URL) async {
        guard ProcessInfo.processInfo.environment["MMBROWSER_HOME"] != nil else {
            FileHandle.standardError.write(Data("截图模式需要设置 MMBROWSER_HOME 指向临时目录\n".utf8))
            return
        }
        let model = AppModel.shared
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        seedDemoData(model)
        try? await Task.sleep(for: .milliseconds(500))

        await render(ContentView().environment(model), size: CGSize(width: 1280, height: 720),
                     to: outputDir.appendingPathComponent("main.png"))
        if let first = model.profiles.first {
            await render(ProfileEditorView(target: .edit(first.id)).environment(model), size: CGSize(width: 620, height: 720),
                         to: outputDir.appendingPathComponent("editor.png"))
            ProfileEditorView.height = 1560
            await render(ProfileEditorView(target: .edit(first.id)).environment(model),
                         size: CGSize(width: 620, height: 1560), to: outputDir.appendingPathComponent("editor-full.png"))
            ProfileEditorView.height = 720
        }
        await render(SettingsView().environment(model), size: CGSize(width: 560, height: 380),
                     to: outputDir.appendingPathComponent("settings.png"))
    }

    /// 走界面同一套 AppModel：启动一个直连测试环境 → 等到运行中 → 截图 → 关闭 → 等回到未运行。
    static func selfTest(outputDir: URL) async {
        let model = AppModel.shared
        guard let store = model.store else { return }
        var p = Profile(name: "自检-直连", startURLs: ["https://example.com/"])
        p.allowDirect = true
        p.extraArgs = ["--window-position=-3000,-3000"]
        guard let saved = try? store.insert(p) else { print("selftest: 创建环境失败"); return }
        model.refreshFromDisk()

        func waitFor(_ what: String, timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !cond(), Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            let ok = cond()
            print("selftest: \(what) \(ok ? "✓" : "✗ 超时")")
            return ok
        }

        model.launch(saved.id)
        let started = await waitFor("启动后状态为运行中", timeout: 60) {
            if case .running = model.state(of: saved.id) { return true }
            return false
        }
        if !started {
            print("selftest: 错误 = \(model.lastError[saved.id] ?? model.alert?.message ?? "无")")
            return
        }
        if case .running(let r) = model.state(of: saved.id) {
            print("selftest: PID \(r.pid)，本地入口 127.0.0.1:\(r.proxy?.port ?? 0)，出口 \(r.exit?.summary ?? "-")")
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

    private static func seedDemoData(_ model: AppModel) {
        guard let store = model.store, (try? store.profiles(includeDeleted: true).isEmpty) == true else { return }
        let a = try? store.group(named: "客户A")
        _ = try? store.group(named: "客户B")
        let samples: [(String, String, String, Int64?, [String], String?)] = [
            ("客户A-广告户01", "socks5://u1:p@203.0.113.10:1080", "en-US", a?.id, ["广告"], "US"),
            ("客户A-广告户02", "http://u2:p@203.0.113.11:8080", "en-US", a?.id, ["广告", "重要"], "US"),
            ("日本店铺", "socks5://198.51.100.7:1080", "ja-JP", nil, ["店铺"], "JP"),
            ("测试环境", "socks5://u3:p@192.0.2.44:1080", "de-DE", nil, [], nil),
        ]
        for (name, proxy, lang, gid, tags, cc) in samples {
            var p = Profile(name: name, proxy: try? ProxyConfig.parse(proxy), language: lang,
                            startURLs: ["https://example.com/"], groupId: gid, tags: tags,
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
