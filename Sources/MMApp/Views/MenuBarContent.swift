import MMCore
import SwiftUI

/// 菜单栏图标的菜单：运行中的环境、打开主窗口、退出。
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let active = model.profiles.filter { model.state(of: $0.id).isActive }
        if active.isEmpty {
            Text(L("menuBar.noneRunning"))
        } else {
            Text(L("menuBar.running \(active.count)"))
            ForEach(active) { p in
                Menu(String("#\(p.seq) \(p.name)\(suffix(p.id))")) {
                    Button(L("common.bringToFront")) { model.activate(p.id) }
                    Button(L("common.close")) { model.stop(p.id) }
                }
            }
            Divider()
            Button(L("menuBar.closeAll")) { Task { await model.stopAll() } }
        }
        Divider()
        Button(L("menuBar.openMainWindow")) {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        SettingsLink { Text(L("menuBar.settings")) }
        Divider()
        Button(L("menuBar.quit")) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func suffix(_ id: String) -> String {
        switch model.state(of: id) {
        case .launching: L("menuBar.suffix.launching")
        case .orphan: L("menuBar.suffix.orphan")
        case .stopping: L("menuBar.suffix.stopping")
        default: ""
        }
    }
}
