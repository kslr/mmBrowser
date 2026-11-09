import AppKit
import MMCore
import SwiftUI

@main
struct MMBrowserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("mmBrowser", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 540)
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建环境") { NotificationCenter.default.post(name: .newProfile, object: nil) }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            Image(systemName: model.runningCount > 0 ? "globe.americas.fill" : "globe.americas")
        }
    }
}

extension Notification.Name {
    static let newProfile = Notification.Name("mmbrowser.newProfile")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 以普通应用方式运行（有程序坞图标、能获得焦点），直接 swift run 时也一样
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let selfTest = CommandLine.arguments.contains("--selftest")
            Task { @MainActor in
                let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                await SnapshotRunner.run(outputDir: dir)
                if selfTest { await SnapshotRunner.selfTest(outputDir: dir) }
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.activate()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.refreshFromDisk() }
    }

    /// 关掉主窗口后继续留在菜单栏（代理入口要一直工作）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 有环境在运行时，退出前确认：退出会让这些环境断网。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let active = model.states.values.filter(\.isActive).count
            guard active > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "还有 \(active) 个环境在运行"
            alert.informativeText = "退出 mmBrowser 会关闭它们的本地代理入口，浏览器将无法联网。要先关闭这些浏览器再退出吗？"
            alert.addButton(withTitle: "关闭浏览器并退出")
            alert.addButton(withTitle: "取消")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            Task { @MainActor in
                await model.stopAll()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
