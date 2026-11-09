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
            TableColumn("环境", value: \.name) { r in Text(r.name).lineLimit(1) }
                .width(min: 90, ideal: 140)
            TableColumn("代理", value: \.host) { r in
                if let p = r.profile.proxy {
                    HStack(spacing: 5) {
                        Text(p.kind == .socks5 ? "S5" : "HTTP").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        Text(verbatim: "\(p.host):\(p.port)").lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    Text(r.profile.allowDirect ? "直连" : "未配置").foregroundStyle(.orange)
                }
            }
            .width(min: 120, ideal: 190)
            TableColumn("账号") { r in Text(r.profile.proxy?.username ?? "—").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 50, ideal: 90)
            TableColumn("出口") { r in
                HStack(spacing: 4) {
                    if model.checking.contains(r.id) { ProgressView().controlSize(.mini) }
                    if let err = model.lastError[r.id], err.hasPrefix("检测失败") {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text("失败").foregroundStyle(.red).help(err)
                    } else if let e = r.profile.lastExit {
                        Text(verbatim: "\(e.countryCode ?? "") \(e.ip)").lineLimit(1)
                            .foregroundStyle(model.sharedExitIP(r.profile).isEmpty ? .primary : Color.orange)
                            .help("\(e.summary)\n\(e.org ?? "")")
                    } else {
                        Text("未检测").foregroundStyle(.tertiary)
                    }
                }
            }
            .width(min: 100, ideal: 150)
            TableColumn("延迟", value: \.latency) { r in
                if let ms = r.profile.lastExit?.latencyMs {
                    Text(verbatim: "\(ms) ms").monospacedDigit()
                        .foregroundStyle(ms < 800 ? Color.green : ms < 2000 ? Color.orange : Color.red)
                } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 50, ideal: 70)
            TableColumn("上次检测", value: \.checkedAt) { r in
                Text(r.profile.lastExit.map { $0.checkedAt.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("到期", value: \.expirySort) { r in ExpiryText(date: r.profile.proxyExpiresAt) }
                .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let list = Array(ids)
            if !list.isEmpty {
                Button("检测") { model.checkMany(list) }
                Button("分配代理…") { batch = .assignProxies(list) }
                Button("设置到期日…") { batch = .expiry(list) }
                if list.count == 1 {
                    Button("编辑环境…") { editing = .edit(list[0]) }
                    Button("复制代理地址") {
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
        .searchable(text: $search, placement: .toolbar, prompt: "搜索环境、代理主机、IP…")
        .toolbar {
            ToolbarItemGroup {
                Button { model.checkMany(selection.isEmpty ? rows.map(\.id) : Array(selection)) } label: {
                    Label(selection.isEmpty ? "检测全部" : "检测选中", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help(selection.isEmpty ? "检测全部代理（同时 5 个）" : "检测选中的代理")
                Button { batch = .assignProxies(Array(selection)) } label: { Label("分配代理", systemImage: "arrow.left.arrow.right") }
                    .disabled(selection.isEmpty).help("把一批代理按顺序分配给选中的环境")
                Button { batch = .expiry(Array(selection)) } label: { Label("到期日", systemImage: "calendar.badge.clock") }
                    .disabled(selection.isEmpty).help("设置选中代理的到期日")
            }
        }
        .navigationTitle("代理")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let checking = model.checking.count
        let expiring = model.expiringProxies().count
        var parts = ["\(rows.count) 个环境"]
        if checking > 0 { parts.append("正在检测 \(checking) 个") }
        if expiring > 0 { parts.append("\(expiring) 个即将到期或已到期") }
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
            let text = days < 0 ? "已过期 \(-days) 天" : days == 0 ? "今天到期" : "\(days) 天后"
            Text(text)
                .foregroundStyle(days < 0 ? Color.red : days <= 7 ? Color.orange : Color.secondary)
                .help(date.formatted(date: .long, time: .omitted))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
