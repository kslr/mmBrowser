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
            Section(L("sidebar.section.profiles")) {
                row(L("sidebar.all"), "square.stack.3d.up", model.profiles.count).tag(SidebarItem.all)
                row(L("sidebar.running"), "play.circle", model.profiles(in: .running).count).tag(SidebarItem.running)
                HStack {
                    Label(L("sidebar.proxies"), systemImage: "network")
                    Spacer()
                    let expiring = model.expiringProxies().count
                    if expiring > 0 {
                        Text(verbatim: "\(expiring)").font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.orange, in: Capsule())
                            .help(L("sidebar.expiring.help \(expiring)"))
                    }
                }
                .tag(SidebarItem.proxies)
            }
            Section(L("sidebar.section.tags")) {
                ForEach(model.allTags, id: \.self) { t in
                    row(t, "tag", model.profiles(in: .tag(t)).count)
                        .tag(SidebarItem.tag(t))
                        .contextMenu {
                            Button(L("sidebar.tag.rename")) { renameText = t; renaming = t }
                            Button(L("sidebar.tag.delete"), role: .destructive) { confirmDelete = t }
                        }
                }
                row(L("sidebar.untagged"), "tag.slash", model.profiles(in: .untagged).count)
                    .tag(SidebarItem.untagged)
            }
            Section {
                row(L("sidebar.trash"), "trash", model.trash.count).tag(SidebarItem.trash)
            }
        }
        .listStyle(.sidebar)
        .alert(L("sidebar.renameTag.title"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("sidebar.renameTag.field"), text: $renameText)
            Button(L("common.save")) {
                if let old = renaming {
                    model.renameTag(old, to: renameText)
                    let new = renameText.trimmingCharacters(in: .whitespaces)
                    if selection == .tag(old), !new.isEmpty { selection = .tag(new) }
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("sidebar.renameTag.message"))
        }
        .confirmationDialog(L("sidebar.deleteTag.title \(confirmDelete ?? "")"), isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(L("sidebar.deleteTag.confirm"), role: .destructive) {
                if let t = confirmDelete {
                    if selection == .tag(t) { selection = .all }
                    model.deleteTag(t)
                }
            }
        } message: {
            Text(L("sidebar.deleteTag.message \(model.profiles(in: .tag(confirmDelete ?? "")).count)"))
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
