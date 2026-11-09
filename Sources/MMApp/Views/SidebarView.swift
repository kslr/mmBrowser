import MMCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var newGroupName = ""
    @State private var showingNewGroup = false
    @State private var renaming: ProfileGroup?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selection) {
            Section("环境") {
                row("全部环境", "square.stack.3d.up", model.profiles.count).tag(SidebarItem.all)
                row("运行中", "play.circle", model.profiles(in: .running).count).tag(SidebarItem.running)
                HStack {
                    Label("代理", systemImage: "network")
                    Spacer()
                    let expiring = model.expiringProxies().count
                    if expiring > 0 {
                        Text(verbatim: "\(expiring)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.orange, in: Capsule())
                            .help("\(expiring) 个代理已到期或 7 天内到期")
                    }
                }
                .tag(SidebarItem.proxies)
            }
            Section {
                ForEach(model.groups) { g in
                    row(g.name, "folder", model.profiles(in: .group(g.id!)).count)
                        .tag(SidebarItem.group(g.id!))
                        .contextMenu {
                            Button("重命名…") { renameText = g.name; renaming = g }
                            Button("删除分组（环境保留，变为未分组）", role: .destructive) {
                                if selection == .group(g.id!) { selection = .all }
                                model.deleteGroup(g.id!)
                            }
                        }
                }
                row("未分组", "tray", model.profiles(in: .ungrouped).count)
                    .tag(SidebarItem.ungrouped)
            } header: {
                HStack {
                    Text("分组")
                    Spacer()
                    Button { newGroupName = ""; showingNewGroup = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("新建分组")
                }
            }
            if !model.allTags.isEmpty {
                Section("标签") {
                    ForEach(model.allTags, id: \.self) { t in
                        row(t, "tag", model.profiles(in: .tag(t)).count).tag(SidebarItem.tag(t))
                    }
                }
            }
            Section {
                row("回收站", "trash", model.trash.count).tag(SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
        .alert("新建分组", isPresented: $showingNewGroup) {
            TextField("分组名称", text: $newGroupName)
            Button("创建") {
                if let id = model.createGroup(newGroupName) { selection = .group(id) }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名分组", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("分组名称", text: $renameText)
            Button("保存") { if let g = renaming { model.renameGroup(g.id!, to: renameText) } }
            Button("取消", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            if count > 0 {
                Text(verbatim: "\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
