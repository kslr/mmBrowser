import MMCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem?

    init(initialSidebar: SidebarItem = .all) {
        _sidebar = State(initialValue: initialSidebar)
    }
    @State private var editing: EditorTarget?
    @State private var batch: BatchSheet?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            if sidebar == .proxies {
                ProxyListView(batch: $batch, editing: $editing)
            } else {
                ProfileListView(scope: sidebar ?? .all, editing: $editing, batch: $batch,
                                showProxies: { sidebar = .proxies })
            }
        }
        .sheet(item: $editing) { target in
            ProfileEditorView(target: target)
                .environment(model)
        }
        .sheet(item: $batch) { sheet in
            BatchSheetView(sheet: sheet)
                .environment(model)
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message))
        }
        .overlay(alignment: .top) {
            if let err = model.setupError {
                Text(err)
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 6)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProfile)) { _ in
            editing = .new(tag: currentTag)
        }
    }

    private var currentTag: String? {
        if case .tag(let t) = sidebar { return t }
        return nil
    }
}

/// 编辑表单的对象：新建（可带默认分组）或编辑已有环境。
enum EditorTarget: Identifiable {
    /// 新建；tag 不为空时预先带上这个标签
    case new(tag: String?)
    case edit(String)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id
        }
    }
}
