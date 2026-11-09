import MMCore
import SwiftUI

/// 表格的一行（把排序要用的字段算好）。
struct ProfileRow: Identifiable {
    let profile: Profile
    let groupName: String
    let exitText: String
    let lastOpened: Date

    var id: String { profile.id }
    var seq: Int { profile.seq }
    var name: String { profile.name }

    init(_ p: Profile, groupName: String?) {
        profile = p
        self.groupName = groupName ?? ""
        if let e = p.lastExit {
            exitText = [e.countryCode, e.ip].compactMap { $0 }.joined(separator: " ")
        } else {
            exitText = ""
        }
        lastOpened = p.lastOpenedAt ?? .distantPast
    }
}

struct ProfileListView: View {
    @Environment(AppModel.self) private var model
    let scope: SidebarItem
    @Binding var editing: EditorTarget?
    @Binding var batch: BatchSheet?
    var showProxies: () -> Void = {}
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProfileRow.seq)]
    @State private var confirmPurge: [String]?
    @State private var pendingCSV: [ProfileCSV.Row]?

    private var isTrash: Bool { scope == .trash }

    private var rows: [ProfileRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return model.profiles(in: scope)
            .filter { p in
                guard !q.isEmpty else { return true }
                let hay = [p.name, p.notes, "#\(p.seq)", p.tags.joined(separator: " "),
                           p.proxy?.host ?? "", p.lastExit?.ip ?? "", p.lastExit?.countryCode ?? "",
                           model.groupName(p.groupId) ?? ""].joined(separator: " ").lowercased()
                return hay.contains(q)
            }
            .map { ProfileRow($0, groupName: model.groupName($0.groupId)) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.seq) { r in
                Text(verbatim: "\(r.seq)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 30, ideal: 36, max: 56)

            TableColumn("名称", value: \.name) { r in
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: r.profile.effectiveThemeColor)).frame(width: 8, height: 8)
                    Text(r.name).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("状态") { r in
                StatusBadge(state: model.state(of: r.id), error: model.lastError[r.id])
            }
            .width(min: 70, ideal: 95)

            TableColumn("分组", value: \.groupName) { r in
                Text(r.groupName.isEmpty ? "—" : r.groupName).foregroundStyle(r.groupName.isEmpty ? .tertiary : .primary)
            }
            .width(min: 50, ideal: 80)

            TableColumn("代理") { r in
                HStack(spacing: 5) {
                    if let proxy = r.profile.proxy {
                        Text(proxy.kind == .socks5 ? "S5" : "HTTP")
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        Text(verbatim: "\(proxy.host):\(proxy.port)").lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(r.profile.allowDirect ? "直连" : "未配置").foregroundStyle(.orange)
                    }
                }
                .help(r.profile.proxy?.displayString ?? "")
            }
            .width(min: 100, ideal: 155)

            TableColumn("出口", value: \.exitText) { r in
                let shared = model.sharedExitIP(r.profile)
                HStack(spacing: 4) {
                    if model.checking.contains(r.id) { ProgressView().controlSize(.mini) }
                    if !shared.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(r.exitText.isEmpty ? "未检测" : r.exitText)
                        .foregroundStyle(r.exitText.isEmpty ? AnyShapeStyle(.tertiary) : shared.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                }
                .help(exitHelp(r.profile, shared: shared))
            }
            .width(min: 80, ideal: 115)

            TableColumn("语言 / 时区") { r in
                Text("\(r.profile.language == LanguageTag.auto ? "自动" : r.profile.language) · \(r.profile.timezone ?? "自动")")
                    .lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("标签") { r in
                Text(r.profile.tags.joined(separator: ", ")).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 60)

            TableColumn("最后打开", value: \.lastOpened) { r in
                Text(r.profile.lastOpenedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "从未")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("备注") { r in
                Text(r.profile.notes).lineLimit(1).foregroundStyle(.secondary).help(r.profile.notes)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: Array(ids))
        } primaryAction: { ids in
            guard !isTrash else { return }
            let list = Array(ids)
            if list.count == 1 { model.launch(list[0]) }  // 已在运行则切到前台
        }
        .searchable(text: $search, placement: .toolbar, prompt: "搜索名称、备注、IP、标签…")
        .toolbar { toolbar }
        .navigationTitle(title)
        .navigationSubtitle("\(rows.count) 个环境")
        .confirmationDialog("彻底删除 \(confirmPurge?.count ?? 0) 个环境？", isPresented: Binding(
            get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } })) {
            Button("彻底删除", role: .destructive) { if let ids = confirmPurge { model.purge(ids); selection.removeAll() } }
        } message: {
            Text("环境目录会一起删除，里面保存的密码、Cookie、浏览记录都无法恢复。")
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: isTrash ? "trash" : "square.stack.3d.up",
                                       description: Text(isTrash || !search.isEmpty ? "" : "点工具栏的 + 新建环境"))
            }
        }
        .confirmationDialog("导入 \(pendingCSV?.count ?? 0) 个环境？", isPresented: Binding(
            get: { pendingCSV != nil }, set: { if !$0 { pendingCSV = nil } })) {
            Button("导入") { if let rows = pendingCSV { model.importCSV(rows) } }
        } message: {
            Text(csvSummary)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            let expiring = model.expiringProxies()
            if !isTrash, !expiring.isEmpty {
                HStack {
                    Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                    Text("\(expiring.count) 个代理已到期或 7 天内到期：" +
                         expiring.prefix(3).map { "#\($0.seq) \($0.name)" }.joined(separator: "、") + (expiring.count > 3 ? "……" : ""))
                        .lineLimit(1)
                    Spacer()
                    Button("查看", action: showProxies).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.orange.opacity(0.12))
            }
        }
        .onChange(of: scope) { selection.removeAll() }
    }

    private var csvSummary: String {
        guard let rows = pendingCSV else { return "" }
        let groups = Set(rows.compactMap(\.groupName)).subtracting(model.groups.map(\.name))
        var s = "代理：\(rows.filter { $0.profile.proxy != nil }.count) 个环境有代理。"
        if !groups.isEmpty { s += "\n将新建分组：\(groups.sorted().joined(separator: "、"))。" }
        s += "\n代理已被其它环境占用的行会导入失败，结束后会列出。"
        return s
    }

    private var title: String {
        switch scope {
        case .all: "全部环境"
        case .running: "运行中"
        case .ungrouped: "未分组"
        case .group(let id): model.groupName(id) ?? "分组"
        case .tag(let t): "标签：\(t)"
        case .proxies: "代理"
        case .trash: "回收站"
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "没有匹配的环境" }
        return isTrash ? "回收站是空的" : "还没有环境"
    }

    private func exitHelp(_ p: Profile, shared: [Profile]) -> String {
        guard let e = p.lastExit else { return "" }
        var s = "\(e.summary)\n\(e.org ?? "")\n检测于 \(e.checkedAt.formatted())"
        if !shared.isEmpty {
            s += "\n\n⚠️ 与 " + shared.map { "#\($0.seq) \($0.name)" }.joined(separator: "、") + " 的出口 IP 相同"
        }
        return s
    }

    private var selected: [String] { Array(selection) }

    private var currentGroupId: Int64? {
        if case .group(let id) = scope { return id }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isTrash {
            ToolbarItemGroup {
                Button { model.restore(selected); selection.removeAll() } label: { Label("恢复", systemImage: "arrow.uturn.backward") }
                    .disabled(selection.isEmpty)
                Button(role: .destructive) { confirmPurge = selected } label: { Label("彻底删除", systemImage: "trash.slash") }
                    .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItemGroup {
                Button { model.launch(selected) } label: { Label("启动", systemImage: "play.fill") }
                    .help("启动选中的环境（已运行的切到前台）")
                    .disabled(selection.isEmpty)
                Button { model.stop(selected) } label: { Label("关闭", systemImage: "stop.fill") }
                    .help("关闭选中的环境")
                    .disabled(!selected.contains { model.state(of: $0).isActive })
                Button { selected.forEach(model.check) } label: { Label("检测代理", systemImage: "antenna.radiowaves.left.and.right") }
                    .help("检测选中环境的代理出口")
                    .disabled(selection.isEmpty)
                Button {
                    if let id = selected.first { editing = .edit(id) }
                } label: { Label("编辑", systemImage: "pencil") }
                    .disabled(selection.count != 1)
                Menu {
                    Button("新建环境…") { editing = .new(groupId: currentGroupId) }
                    Button("批量新建…") { batch = .create(groupId: currentGroupId) }
                    Divider()
                    Button("从 CSV 导入…") { pendingCSV = model.pickCSVForImport() }
                    Button("导入环境备份…") { model.importBackups() }
                    Divider()
                    Button("把当前列表导出为 CSV…") { model.exportCSV(rows.map(\.id)) }
                } label: {
                    Label("新建环境", systemImage: "plus")
                } primaryAction: {
                    editing = .new(groupId: currentGroupId)
                }
                .help("新建环境（⌘N）；点箭头可批量新建、导入")
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: [String]) -> some View {
        if ids.isEmpty {
            EmptyView()
        } else if isTrash {
            Button("恢复") { model.restore(ids) }
            Button("彻底删除…", role: .destructive) { confirmPurge = ids }
        } else {
            let anyActive = ids.contains { model.state(of: $0).isActive }
            Button("启动") { model.launch(ids) }
            if anyActive {
                Button("切到前台") { ids.forEach(model.activate) }
                Button("关闭") { model.stop(ids) }
            }
            Divider()
            if ids.count == 1 { Button("编辑…") { editing = .edit(ids[0]) } }
            Button("批量编辑…") { batch = .edit(ids) }
            Button("检测代理") { model.checkMany(ids) }
            Button("分配代理…") { batch = .assignProxies(ids) }
            Button("设置代理到期日…") { batch = .expiry(ids) }
            Menu("移到分组") {
                Button("未分组") { model.move(ids, toGroup: nil) }
                Divider()
                ForEach(model.groups) { g in Button(g.name) { model.move(ids, toGroup: g.id) } }
            }
            if ids.count == 1 {
                Menu("复制环境") {
                    Button("只复制设置") { model.duplicate(ids[0], copyData: false) }
                    Button("连同浏览器数据（登录状态、Cookie、密码、扩展）") { model.duplicate(ids[0], copyData: true) }
                }
                .disabled(anyActive)
                Menu("Cookie") {
                    Button("导出…") { model.exportCookies(ids[0]) }
                    Button("导入（与现有合并）…") { model.importCookies(ids[0], replaceAll: false) }
                    Button("导入（先清空现有）…") { model.importCookies(ids[0], replaceAll: true) }
                }
                .disabled(anyActive)
                Button("在 Finder 中显示环境目录") { model.revealInFinder(ids[0]) }
                Button("复制代理地址") {
                    if let p = model.profile(ids[0])?.proxy {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p.urlString, forType: .string)
                    }
                }
            }
            Divider()
            Button("导出为 CSV…") { model.exportCSV(ids) }
            Button("导出环境备份…") { model.exportBackups(ids) }
                .disabled(anyActive)
            Divider()
            Button("移到回收站", role: .destructive) { model.moveToTrash(ids); selection.subtract(ids) }
                .disabled(anyActive)
        }
    }
}

struct StatusBadge: View {
    let state: RunState
    let error: String?

    var body: some View {
        HStack(spacing: 5) {
            switch state {
            case .idle:
                if error != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("失败").foregroundStyle(.red)
                } else {
                    Circle().fill(.quaternary).frame(width: 7, height: 7)
                    Text("未运行").foregroundStyle(.secondary)
                }
            case .launching(let stage):
                ProgressView().controlSize(.mini)
                Text(stage).foregroundStyle(.secondary)
            case .running:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("运行中")
            case .orphan:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("残留·已断网").foregroundStyle(.orange)
            case .stopping:
                ProgressView().controlSize(.mini)
                Text("正在关闭").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .idle: error ?? ""
        case .running(let r): "PID \(r.pid) · 本地入口 127.0.0.1:\(r.proxy?.port ?? 0) · 时区 \(r.timezone)"
        case .orphan(let pid): "PID \(pid) 不是本次启动的（可能是应用上次异常退出），它的代理入口已关闭，浏览器无法联网。关闭后重新启动即可。"
        default: ""
        }
    }
}

extension Color {
    /// `#RRGGBB`
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}
