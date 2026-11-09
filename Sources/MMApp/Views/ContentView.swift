import MMCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var sidebar: SidebarItem? = .all
    @State private var editing: EditorTarget?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $sidebar)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            ProfileListView(scope: sidebar ?? .all, editing: $editing)
        }
        .sheet(item: $editing) { target in
            ProfileEditorView(target: target)
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
            editing = .new(groupId: currentGroupId)
        }
    }

    private var currentGroupId: Int64? {
        if case .group(let id) = sidebar { return id }
        return nil
    }
}

/// 编辑表单的对象：新建（可带默认分组）或编辑已有环境。
enum EditorTarget: Identifiable {
    case new(groupId: Int64?)
    case edit(String)

    var id: String {
        switch self {
        case .new: "new"
        case .edit(let id): id
        }
    }
}
