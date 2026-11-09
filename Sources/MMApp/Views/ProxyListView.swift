import MMCore
import SwiftUI

/// 代理视图：集中查看各环境的代理、出口、延迟、到期日，批量检测。
struct ProxyListView: View {
    @Environment(AppModel.self) private var model
    @Binding var batch: BatchSheet?
    @Binding var editing: EditorTarget?
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProxyRow.expirySort)]

    struct ProxyRow: Identifiable {
        let profile: Profile
        var id: String { profile.id }
        var seq: Int { profile.seq }
        var name: String { profile.name }
        var host: String { profile.proxy.map { "\($0.host):\($0.port)" } ?? "" }
        var expirySort: Date { profile.proxyExpiresAt ?? .distantFuture }
        var latency: Int { profile.lastExit?.latencyMs ?? Int.max }
        var checkedAt: Date { profile.lastExit?.checkedAt ?? .distantPast }
    }

    private var rows: [ProxyRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.profiles
            .filter { q.isEmpty || [$0.name, $0.proxy?.host ?? "", $0.lastExit?.ip ?? "", "#\($0.seq)"].joined(separator: " ").lowercased().contains(q) }
            .map(ProxyRow.init).sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.seq) { r in Text(verbatim: "\(r.seq)").foregroundStyle(.secondary) }
                .width(min: 30, ideal: 36, max: 56)
            TableColumn(L("proxies.column.profile"), value: \.name) { r in Text(r.name).lineLimit(1) }
                .width(min: 90, ideal: 140)
            TableColumn(L("proxies.column.proxy"), value: \.host) { r in
                if let p = r.profile.proxy {
                    HStack(spacing: 5) {
                        Text(p.kind == .socks5 ? "S5" : "HTTP").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        Text(verbatim: "\(p.host):\(p.port)").lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text(r.profile.allowDirect ? L("common.direct") : L("common.notConfigured")).foregroundStyle(.orange)
                }
            }
            .width(min: 120, ideal: 190)
            TableColumn(L("proxies.column.username")) { r in Text(r.profile.proxy?.username ?? "—").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 50, ideal: 90)
            TableColumn(L("proxies.column.exit")) { r in
                HStack(spacing: 4) {
                    if model.checking.contains(r.id) { ProgressView().controlSize(.mini) }
                    if model.checkFailed.contains(r.id), let err = model.lastError[r.id] {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(L("common.failed")).foregroundStyle(.red).help(err)
                    } else if let e = r.profile.lastExit {
                        Text(verbatim: "\(e.countryCode ?? "") \(e.ip)").lineLimit(1)
                            .foregroundStyle(model.sharedExitIP(r.profile).isEmpty ? .primary : Color.orange)
                            .help("\(e.summary)\n\(e.org ?? "")")
                    } else {
                        Text(L("common.notChecked")).foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 100, ideal: 150)
            TableColumn(L("proxies.column.latency"), value: \.latency) { r in
                if let ms = r.profile.lastExit?.latencyMs {
                    Text(verbatim: "\(ms) ms").monospacedDigit()
                        .foregroundStyle(ms < 800 ? Color.green : ms < 2000 ? Color.orange : Color.red)
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 50, ideal: 70)
            TableColumn(L("proxies.column.lastChecked"), value: \.checkedAt) { r in
                Text(r.profile.lastExit.map { $0.checkedAt.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 115)
            TableColumn(L("proxies.column.expiry"), value: \.expirySort) { r in ExpiryText(date: r.profile.proxyExpiresAt) }
                .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let list = Array(ids)
            if !list.isEmpty {
                Button(L("proxies.menu.check")) { model.checkMany(list) }
                Button(L("common.assignProxies")) { batch = .assignProxies(list) }
                Button(L("proxies.menu.setExpiry")) { batch = .expiry(list) }
                if list.count == 1 {
                    Button(L("proxies.menu.editProfile")) { editing = .edit(list[0]) }
                    Button(L("common.copyProxyAddress")) {
                        if let p = model.profile(list[0])?.proxy {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(p.urlString, forType: .string)
                        }
                    }
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { editing = .edit(id) }
        }
        .searchable(text: $search, placement: .toolbar, prompt: L("proxies.search"))
        .toolbar {
            ToolbarItemGroup {
                Button { model.checkMany(selection.isEmpty ? rows.map(\.id) : Array(selection)) } label: {
                    Label(selection.isEmpty ? L("proxies.toolbar.checkAll") : L("proxies.toolbar.checkSelected"), systemImage: "antenna.radiowaves.left.and.right")
                }
                .help(selection.isEmpty ? L("proxies.toolbar.checkAll.help") : L("proxies.toolbar.checkSelected.help"))
                Button { batch = .assignProxies(Array(selection)) } label: { Label(L("proxies.toolbar.assign"), systemImage: "arrow.left.arrow.right") }
                    .disabled(selection.isEmpty).help(L("proxies.toolbar.assign.help"))
                Button { batch = .expiry(Array(selection)) } label: { Label(L("proxies.toolbar.expiry"), systemImage: "calendar.badge.clock") }
                    .disabled(selection.isEmpty).help(L("proxies.toolbar.expiry.help"))
            }
        }
        .navigationTitle(L("proxies.title"))
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let checking = model.checking.count
        let expiring = model.expiringProxies().count
        var parts = [L("common.profileCount \(rows.count)")]
        if checking > 0 { parts.append(L("proxies.subtitle.checking \(checking)")) }
        if expiring > 0 { parts.append(L("proxies.subtitle.expiring \(expiring)")) }
        return parts.joined(separator: " · ")
    }
}

/// 到期日：已过期红色，7 天内橙色。
struct ExpiryText: View {
    let date: Date?
    var body: some View {
        if let date {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                       to: Calendar.current.startOfDay(for: date)).day ?? 0
            let text = days < 0 ? L("expiry.overdue \(-days)") : days == 0 ? L("expiry.today") : L("expiry.inDays \(days)")
            Text(text)
                .foregroundStyle(days < 0 ? Color.red : days <= 7 ? Color.orange : Color.secondary)
                .help(date.formatted(date: .long, time: .omitted))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
