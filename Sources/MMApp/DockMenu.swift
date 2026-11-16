import AppKit

/// Dock 图标右键菜单：运行中的环境（切到前台、关闭）、全部关闭。
/// 系统会在下面接上窗口列表、"选项"、"退出"等。每次弹出菜单时重新生成。
@MainActor
enum DockMenu {
    static func make(_ model: AppModel) -> NSMenu {
        let menu = NSMenu()
        let active = model.profiles.filter { model.state(of: $0.id).isActive }
        guard !active.isEmpty else { return menu }

        let header = NSMenuItem(title: L("dock.running \(active.count)"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for p in active {
            let item = NSMenuItem(title: "#\(p.seq) \(p.name)\(suffix(model.state(of: p.id)))", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.addItem(ActionItem(L("common.bringToFront")) { model.activate(p.id) })
            sub.addItem(ActionItem(L("common.close")) { model.stop(p.id) })
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem(L("dock.closeAll")) { Task { await model.stopAll() } })
        return menu
    }

    private static func suffix(_ state: RunState) -> String {
        switch state {
        case .launching: L("dock.suffix.launching")
        case .orphan: L("dock.suffix.orphan")
        case .stopping: L("dock.suffix.stopping")
        default: ""
        }
    }
}

/// 用闭包响应点击的菜单项（target 是弱引用，所以由菜单项自己持有并作为 target）。
@MainActor
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
