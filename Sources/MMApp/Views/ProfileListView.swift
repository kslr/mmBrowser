import MMCore
import SwiftUI

/// 表格的一行（把排序要用的字段算好）。
struct ProfileRow: Identifiable {
    let profile: Profile
    let tagsText: String
    let exitText: String
    let lastOpened: Date

    var id: String { profile.id }
    var seq: Int { profile.seq }
    var name: String { profile.name }

    init(_ p: Profile) {
        profile = p
        tagsText = p.tags.joined(separator: L("common.listSeparator"))
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
                           p.proxy?.host ?? "", p.lastExit?.ip ?? "", p.lastExit?.countryCode ?? ""]
                    .joined(separator: " ").lowercased()
                return hay.contains(q)
            }
            .map { ProfileRow($0) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.seq) { r in
                Text(verbatim: "\(r.seq)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 30, ideal: 36, max: 56)

            TableColumn(L("list.column.name"), value: \.name) { r in
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: r.profile.effectiveThemeColor)).frame(width: 8, height: 8)
                    Text(r.name).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 125)

            TableColumn(L("list.column.status")) { r in
                StatusBadge(state: model.state(of: r.id), error: model.lastError[r.id])
            }
            .width(min: 70, ideal: 90)

            TableColumn(L("list.column.tags"), value: \.tagsText) { r in
                Text(r.tagsText.isEmpty ? "—" : r.tagsText)
                    .lineLimit(1)
                    .foregroundStyle(r.tagsText.isEmpty ? .tertiary : .primary)
                    .help(r.tagsText)
            }
            .width(min: 60, ideal: 120)

            TableColumn(L("list.column.proxy")) { r in
                HStack(spacing: 5) {
                    if let proxy = r.profile.proxy {
                        Text(proxy.kind == .socks5 ? "S5" : "HTTP")
                            .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        Text(verbatim: "\(proxy.host):\(proxy.port)").lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(r.profile.allowDirect ? L("common.direct") : L("common.notConfigured")).foregroundStyle(.orange)
                    }
                }
                .help(r.profile.proxy?.displayString ?? "")
            }
            .width(min: 100, ideal: 155)

            TableColumn(L("list.column.exit"), value: \.exitText) { r in
                let shared = model.sharedExitIP(r.profile)
                HStack(spacing: 4) {
                    if model.checking.contains(r.id) { ProgressView().controlSize(.mini) }
                    if !shared.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(r.exitText.isEmpty ? L("common.notChecked") : r.exitText)
                        .foregroundStyle(r.exitText.isEmpty ? AnyShapeStyle(.tertiary) : shared.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                }
                .help(exitHelp(r.profile, shared: shared))
            }
            .width(min: 80, ideal: 115)

            TableColumn(L("list.column.languageTimezone")) { r in
                Text(verbatim: "\(r.profile.language == LanguageTag.auto ? L("common.auto") : r.profile.language) · \(r.profile.timezone ?? L("common.auto"))")
                    .lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 125)

            TableColumn(L("list.column.lastOpened"), value: \.lastOpened) { r in
                Text(r.profile.lastOpenedAt.map { $0.formatted(.relative(presentation: .named)) } ?? L("list.never"))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 75)

            TableColumn(L("list.column.notes")) { r in
                Text(r.profile.notes).lineLimit(1).foregroundStyle(.secondary).help(r.profile.notes)
            }
            .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: Array(ids))
        } primaryAction: { ids in
            guard !isTrash else { return }
            let list = Array(ids)
            if list.count == 1 { model.launch(list[0]) }  // 已在运行则切到前台
        }
        .searchable(text: $search, placement: .toolbar, prompt: L("list.search"))
        .toolbar { toolbar }
        .navigationTitle(title)
        .navigationSubtitle(L("common.profileCount \(rows.count)"))
        .confirmationDialog(L("list.purge.title \(confirmPurge?.count ?? 0)"), isPresented: Binding(
            get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } })) {
            Button(L("list.purge.confirm"), role: .destructive) { if let ids = confirmPurge { model.purge(ids); selection.removeAll() } }
        } message: {
            Text(L("list.purge.message"))
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: isTrash ? "trash" : "square.stack.3d.up",
                                       description: Text(isTrash || !search.isEmpty ? "" : L("list.empty.hint")))
            }
        }
        .confirmationDialog(L("list.importCSV.title \(pendingCSV?.count ?? 0)"), isPresented: Binding(
            get: { pendingCSV != nil }, set: { if !$0 { pendingCSV = nil } })) {
            Button(L("list.importCSV.confirm")) { if let rows = pendingCSV { model.importCSV(rows) } }
        } message: {
            Text(csvSummary)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            let expiring = model.expiringProxies()
            if !isTrash, !expiring.isEmpty {
                HStack {
                    Image(systemName: "calendar.badge.exclamationmark").foregroundStyle(.orange)
                    let names = expiring.prefix(3).map { "#\($0.seq) \($0.name)" }.joined(separator: L("common.listSeparator"))
                        + (expiring.count > 3 ? L("common.ellipsis") : "")
                    Text(L("list.expiringBanner \(expiring.count) \(names)"))
                        .lineLimit(1)
                    Spacer()
                    Button(L("list.expiringBanner.show"), action: showProxies).controlSize(.small)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.orange.opacity(0.12))
            }
        }
        .onChange(of: scope) { selection.removeAll() }
    }

    private var csvSummary: String {
        guard let rows = pendingCSV else { return "" }
        return L("list.importCSV.message \(rows.filter { $0.profile.proxy != nil }.count)")
    }

    private var title: String {
        switch scope {
        case .all: L("sidebar.all")
        case .running: L("sidebar.running")
        case .untagged: L("sidebar.untagged")
        case .tag(let t): L("list.title.tag \(t)")
        case .proxies: L("sidebar.proxies")
        case .trash: L("sidebar.trash")
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return L("list.empty.noMatch") }
        return isTrash ? L("list.empty.trash") : L("list.empty.none")
    }

    private func exitHelp(_ p: Profile, shared: [Profile]) -> String {
        guard let e = p.lastExit else { return "" }
        var s = "\(e.summary)\n\(e.org ?? "")\n" + L("list.exit.checkedAt \(e.checkedAt.formatted())")
        if !shared.isEmpty {
            let names = shared.map { "#\($0.seq) \($0.name)" }.joined(separator: L("common.listSeparator"))
            s += "\n\n" + L("list.exit.shared \(names)")
        }
        return s
    }

    private var selected: [String] { Array(selection) }

    /// 在某个标签视图里新建环境时，自动带上这个标签。
    private var currentTag: String? {
        if case .tag(let t) = scope { return t }
        return nil
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isTrash {
            ToolbarItemGroup {
                Button { model.restore(selected); selection.removeAll() } label: { Label(L("list.restore"), systemImage: "arrow.uturn.backward") }
                    .disabled(selection.isEmpty)
                Button(role: .destructive) { confirmPurge = selected } label: { Label(L("list.purge.confirm"), systemImage: "trash.slash") }
                    .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItemGroup {
                Button { model.launch(selected) } label: { Label(L("list.launch"), systemImage: "play.fill") }
                    .help(L("list.launch.help"))
                    .disabled(selection.isEmpty)
                Button { model.stop(selected) } label: { Label(L("common.close"), systemImage: "stop.fill") }
                    .help(L("list.close.help"))
                    .disabled(!selected.contains { model.state(of: $0).isActive })
                Button { selected.forEach(model.check) } label: { Label(L("list.checkProxy"), systemImage: "antenna.radiowaves.left.and.right") }
                    .help(L("list.checkProxy.help"))
                    .disabled(selection.isEmpty)
                Button {
                    if let id = selected.first { editing = .edit(id) }
                } label: { Label(L("list.edit"), systemImage: "pencil") }
                    .disabled(selection.count != 1)
                Menu {
                    Button(L("list.new.profile")) { editing = .new(tag: currentTag) }
                    Button(L("list.new.batch")) { batch = .create(tag: currentTag) }
                    Divider()
                    Button(L("list.new.importCSV")) { pendingCSV = model.pickCSVForImport() }
                    Button(L("list.new.importBackups")) { model.importBackups() }
                    Divider()
                    Button(L("list.new.exportCSV")) { model.exportCSV(rows.map(\.id)) }
                } label: {
                    Label(L("menu.newProfile"), systemImage: "plus")
                } primaryAction: {
                    editing = .new(tag: currentTag)
                }
                .help(L("list.new.help"))
            }
        }
    }

    @ViewBuilder
    private func menu(for ids: [String]) -> some View {
        if ids.isEmpty {
            EmptyView()
        } else if isTrash {
            Button(L("list.restore")) { model.restore(ids) }
            Button(L("list.menu.purge"), role: .destructive) { confirmPurge = ids }
        } else {
            let anyActive = ids.contains { model.state(of: $0).isActive }
            Button(L("list.launch")) { model.launch(ids) }
            if anyActive {
                Button(L("common.bringToFront")) { ids.forEach(model.activate) }
                Button(L("common.close")) { model.stop(ids) }
            }
            Divider()
            if ids.count == 1 { Button(L("list.menu.edit")) { editing = .edit(ids[0]) } }
            Button(L("list.menu.batchEdit")) { batch = .edit(ids) }
            Button(L("list.checkProxy")) { model.checkMany(ids) }
            Button(L("common.assignProxies")) { batch = .assignProxies(ids) }
            Button(L("list.menu.setExpiry")) { batch = .expiry(ids) }
            Menu(L("list.menu.addTag")) {
                ForEach(model.allTags, id: \.self) { t in Button(t) { model.addTag(t, to: ids) } }
                if !model.allTags.isEmpty { Divider() }
                Button(L("list.menu.newTag")) { batch = .edit(ids) }
            }
            let present = Array(Set(ids.compactMap(model.profile).flatMap(\.tags))).sorted()
            if !present.isEmpty {
                Menu(L("list.menu.removeTag")) {
                    ForEach(present, id: \.self) { t in Button(t) { model.removeTag(t, from: ids) } }
                }
            }
            if ids.count == 1 {
                Menu(L("list.menu.duplicate")) {
                    Button(L("list.menu.duplicate.settings")) { model.duplicate(ids[0], copyData: false) }
                    Button(L("list.menu.duplicate.withData")) { model.duplicate(ids[0], copyData: true) }
                }
                .disabled(anyActive)
                Menu(L("list.menu.cookies")) {
                    Button(L("list.menu.cookies.export")) { model.exportCookies(ids[0]) }
                    Button(L("list.menu.cookies.importMerge")) { model.importCookies(ids[0], replaceAll: false) }
                    Button(L("list.menu.cookies.importReplace")) { model.importCookies(ids[0], replaceAll: true) }
                }
                .disabled(anyActive)
                Button(L("list.menu.revealInFinder")) { model.revealInFinder(ids[0]) }
                Button(L("common.copyProxyAddress")) {
                    if let p = model.profile(ids[0])?.proxy {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(p.urlString, forType: .string)
                    }
                }
            }
            Divider()
            Button(L("list.menu.exportCSV")) { model.exportCSV(ids) }
            Button(L("list.menu.exportBackups")) { model.exportBackups(ids) }
                .disabled(anyActive)
            Divider()
            Button(L("list.menu.moveToTrash"), role: .destructive) { model.moveToTrash(ids); selection.subtract(ids) }
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
                    Text(L("common.failed")).foregroundStyle(.red)
                } else {
                    Circle().fill(.quaternary).frame(width: 7, height: 7)
                    Text(L("status.idle")).foregroundStyle(.secondary)
                }
            case .launching(let stage):
                ProgressView().controlSize(.mini)
                Text(stage).foregroundStyle(.secondary)
            case .running:
                Circle().fill(.green).frame(width: 7, height: 7)
                Text(L("status.running"))
            case .orphan:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(L("status.orphan")).foregroundStyle(.orange)
            case .stopping:
                ProgressView().controlSize(.mini)
                Text(L("status.stopping")).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .help(helpText)
    }

    private var helpText: String {
        switch state {
        case .idle: error ?? ""
        case .running(let r): L("status.running.help \(Int(r.pid)) \(Int(r.proxy?.port ?? 0)) \(r.timezone)")
        case .orphan(let pid): L("status.orphan.help \(Int(pid))")
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
