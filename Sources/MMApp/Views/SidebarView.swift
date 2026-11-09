import MMCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var confirmDelete: String?

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
            Section("标签") {
                ForEach(model.allTags, id: \.self) { t in
                    row(t, "tag", model.profiles(in: .tag(t)).count)
                        .tag(SidebarItem.tag(t))
                        .contextMenu {
                            Button("重命名…") { renameText = t; renaming = t }
                            Button("删除标签…", role: .destructive) { confirmDelete = t }
                        }
                }
                row("无标签", "tag.slash", model.profiles(in: .untagged).count)
                    .tag(SidebarItem.untagged)
            }
            Section {
                row("回收站", "trash", model.trash.count).tag(SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
        .alert("重命名标签", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("标签名称", text: $renameText)
            Button("保存") {
                if let old = renaming {
                    model.renameTag(old, to: renameText)
                    let new = renameText.trimmingCharacters(in: .whitespaces)
                    if selection == .tag(old), !new.isEmpty { selection = .tag(new) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有环境上的这个标签都会改名；如果新名称已经存在，两者会合并。")
        }
        .confirmationDialog("删除标签「\(confirmDelete ?? "")」？", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("删除标签", role: .destructive) {
                if let t = confirmDelete {
                    if selection == .tag(t) { selection = .all }
                    model.deleteTag(t)
                }
            }
        } message: {
            Text("只是从 \(model.profiles(in: .tag(confirmDelete ?? "")).count) 个环境上去掉这个标签，环境本身不会删除。")
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
