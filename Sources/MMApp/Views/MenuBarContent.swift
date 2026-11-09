import MMCore
import SwiftUI

/// 菜单栏图标的菜单：运行中的环境、打开主窗口、退出。
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = model.profiles.filter { model.state(of: $0.id).isActive }
        if active.isEmpty {
            Text("没有运行中的环境")
        } else {
            Text("运行中（\(active.count)）")
            ForEach(active) { p in
                Menu(String("#\(p.seq) \(p.name)\(suffix(p.id))")) {
                    Button("切到前台") { model.activate(p.id) }
                    Button("关闭") { model.stop(p.id) }
                }
            }
            Divider()
            Button("全部关闭") { Task { await model.stopAll() } }
        }
        Divider()
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 mmBrowser") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func suffix(_ id: String) -> String {
        switch model.state(of: id) {
        case .launching: "（启动中）"
        case .orphan: "（残留·已断网）"
        case .stopping: "（正在关闭）"
        default: ""
        }
    }
}
