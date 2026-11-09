import MMCore
import SwiftUI

/// 表单里可编辑的草稿（字符串形式，保存时校验）。
struct ProfileDraft {
    enum ProxyMode: String, CaseIterable { case proxy, direct }

    var name = ""
    var groupId: Int64?
    var tagsText = ""
    var notes = ""

    var proxyMode = ProxyMode.proxy
    var proxyKind = ProxyConfig.Kind.socks5
    var host = ""
    var portText = ""
    var username = ""
    var password = ""
    var expiryEnabled = false
    var expiry = Date().addingTimeInterval(30 * 86_400)

    var languageAuto = true
    var language = "en-US"
    var timezoneAuto = true
    var timezone = TimeZone.current.identifier
    var geolocation = GeolocationPolicy.block
    var windowPreset = "默认"
    var windowWidthText = ""
    var windowHeightText = ""
    var themeAuto = true
    var themeColor = Color(hex: "#1A73E8")
    var extraArgsText = ""
    var extensionIds: [String] = []

    static let windowPresets = ["默认", "1280x800", "1366x768", "1440x900", "1536x864", "1680x1050", "1920x1080", "自定义"]

    init(defaultLanguage: String, groupId: Int64?) {
        languageAuto = defaultLanguage == LanguageTag.auto
        language = languageAuto ? "en-US" : defaultLanguage
        self.groupId = groupId
    }

    init(_ p: Profile) {
        name = p.name
        groupId = p.groupId
        tagsText = p.tags.joined(separator: ", ")
        notes = p.notes
        if let proxy = p.proxy {
            proxyMode = .proxy
            fill(from: proxy)
        } else {
            proxyMode = p.allowDirect ? .direct : .proxy
        }
        if let e = p.proxyExpiresAt { expiryEnabled = true; expiry = e }
        languageAuto = p.language == LanguageTag.auto
        language = languageAuto ? (CountryLocale.recommendedLanguage(for: p.lastExit?.countryCode) ?? "en-US") : p.language
        timezoneAuto = p.timezone == nil
        timezone = p.timezone ?? p.lastExit?.timezone ?? TimeZone.current.identifier
        geolocation = p.geolocation
        if let w = p.windowWidth, let h = p.windowHeight {
            let key = "\(w)x\(h)"
            windowPreset = Self.windowPresets.contains(key) ? key : "自定义"
            windowWidthText = String(w)
            windowHeightText = String(h)
        }
        themeAuto = p.themeColor == nil
        themeColor = Color(hex: p.effectiveThemeColor)
        extraArgsText = p.extraArgs.joined(separator: "\n")
        extensionIds = p.extensionIds
    }

    /// 当前填写的代理（不完整时返回 nil）。
    var proxyConfig: ProxyConfig? {
        guard proxyMode == .proxy, !host.trimmingCharacters(in: .whitespaces).isEmpty,
              let port = Int(portText), (1...65535).contains(port) else { return nil }
        return ProxyConfig(kind: proxyKind, host: host.trimmingCharacters(in: .whitespaces), port: port,
                           username: username, password: password)
    }

    mutating func fill(from proxy: ProxyConfig) {
        proxyMode = .proxy
        proxyKind = proxy.kind
        host = proxy.host
        portText = String(proxy.port)
        username = proxy.username ?? ""
        password = proxy.password ?? ""
    }

    /// 校验并写入 profile。名称可以为空（保存时自动命名）。启动页不在表单里编辑，保持原值。
    func apply(to p: inout Profile) throws {
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.groupId = groupId
        p.tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.notes = notes

        switch proxyMode {
        case .proxy:
            guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw DraftError("请填写代理（或者选择直连）") }
            guard let port = Int(portText), (1...65535).contains(port) else { throw DraftError("代理端口无效") }
            guard username.isEmpty == false || password.isEmpty else { throw DraftError("填了密码但没有用户名") }
            p.proxy = ProxyConfig(kind: proxyKind, host: host.trimmingCharacters(in: .whitespaces), port: port,
                                  username: username, password: password)
            p.allowDirect = false
            p.proxyExpiresAt = expiryEnabled ? expiry : nil
        case .direct:
            p.proxy = nil
            p.allowDirect = true
            p.proxyExpiresAt = nil
        }

        if languageAuto {
            p.language = LanguageTag.auto
        } else {
            guard LanguageTag.isValid(language) else { throw DraftError("语言代码无效：\(language)（例如 en-US、ja-JP）") }
            p.language = language
        }
        if timezoneAuto {
            p.timezone = nil
        } else {
            guard TimeZone(identifier: timezone) != nil else { throw DraftError("时区无效：\(timezone)") }
            p.timezone = timezone
        }
        p.geolocation = geolocation

        switch windowPreset {
        case "默认":
            p.windowWidth = nil; p.windowHeight = nil
        case "自定义":
            guard let w = Int(windowWidthText), let h = Int(windowHeightText), w >= 400, h >= 300 else {
                throw DraftError("自定义窗口尺寸无效（宽至少 400，高至少 300）")
            }
            p.windowWidth = w; p.windowHeight = h
        default:
            let parts = windowPreset.split(separator: "x").compactMap { Int($0) }
            p.windowWidth = parts[0]; p.windowHeight = parts[1]
        }
        p.themeColor = themeAuto ? nil : themeColor.hexString
        p.extraArgs = extraArgsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.extensionIds = extensionIds
    }
}

struct DraftError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// 常用语言（显示名用系统当前语言）。
enum LanguageOptions {
    static let codes: [String] = [
        "en-US", "en-GB", "en-CA", "en-AU", "en-SG", "en-IN", "zh-CN", "zh-TW", "zh-HK", "ja-JP", "ko-KR",
        "de-DE", "fr-FR", "es-ES", "es-MX", "pt-BR", "pt-PT", "it-IT", "nl-NL", "sv-SE", "pl-PL", "ru-RU",
        "uk-UA", "tr-TR", "ar-SA", "he-IL", "th-TH", "vi-VN", "id-ID", "ms-MY",
    ]

    static func label(_ code: String) -> String {
        if code == LanguageTag.auto { return "跟随出口 IP" }
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return "\(name)（\(code)）"
    }
}

struct ProfileEditorView: View {
    /// 表单高度（截图自检时会临时调高，以便看到全部内容）。
    @MainActor static var height: CGFloat = 660
    @MainActor static var expandAllForSnapshot = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var draft = ProfileDraft(defaultLanguage: LanguageTag.auto, groupId: nil)
    @State private var original: Profile?
    @State private var loaded = false
    @State private var proxyText = ""
    @State private var proxyParseError: String?
    @State private var showProxyFields = false
    @State private var showMore = false
    @State private var showPassword = false
    @State private var checkResult: Result<ExitInfo, Error>?
    @State private var checking = false
    @State private var error: String?

    private var isNew: Bool { if case .new = target { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                basicSection
                proxySection
                environmentSection
                moreSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: Self.height)
        .onAppear(perform: load)
    }

    // MARK: - 基本

    private var basicSection: some View {
        Section("基本") {
            TextField("名称", text: $draft.name, prompt: Text(isNew ? "留空自动命名，如 环境-12" : ""))
            Picker("分组", selection: $draft.groupId) {
                Text("未分组").tag(Int64?.none)
                ForEach(model.groups) { g in Text(g.name).tag(Int64?.some(g.id!)) }
            }
            TextField("标签", text: $draft.tagsText, prompt: Text("可选，用逗号分隔"))
            TextField("备注", text: $draft.notes, prompt: Text("可选"), axis: .vertical).lineLimit(1...3)
        }
    }

    // MARK: - 代理

    private var proxySection: some View {
        Section {
            Picker("连接方式", selection: $draft.proxyMode) {
                Text("代理").tag(ProfileDraft.ProxyMode.proxy)
                Text("直连（不走代理）").tag(ProfileDraft.ProxyMode.direct)
            }
            .pickerStyle(.segmented)

            if draft.proxyMode == .proxy {
                TextField("代理", text: $proxyText,
                          prompt: Text(draft.proxyConfig == nil ? "粘贴 socks5://user:pass@host:port 等" : "粘贴新的代理即可替换"))
                    .onChange(of: proxyText) { parseProxyText() }
                proxySummary
                ExpandRow(title: "逐项填写", subtitle: nil, expanded: $showProxyFields)
                if showProxyFields {
                    Picker("类型", selection: $draft.proxyKind) {
                        Text("SOCKS5").tag(ProxyConfig.Kind.socks5)
                        Text("HTTP").tag(ProxyConfig.Kind.http)
                    }
                    .pickerStyle(.segmented)
                    TextField("主机", text: $draft.host)
                    TextField("端口", text: $draft.portText)
                    TextField("用户名", text: $draft.username, prompt: Text("可选"))
                    HStack {
                        if showPassword {
                            TextField("密码", text: $draft.password, prompt: Text("可选"))
                        } else {
                            SecureField("密码", text: $draft.password, prompt: Text("可选"))
                        }
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                    }
                }
                Toggle("记录到期日（到期前提醒）", isOn: $draft.expiryEnabled)
                if draft.expiryEnabled {
                    DatePicker("到期日", selection: $draft.expiry, displayedComponents: .date)
                }
            } else {
                Label("直连时浏览器使用本机网络，出口就是你自己的 IP。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top) {
                Button(checking ? "检测中…" : "检测出口") { check() }
                    .disabled(checking || (draft.proxyMode == .proxy && draft.proxyConfig == nil))
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                checkResultView
            }
        } header: {
            Text("代理")
        } footer: {
            Text("一个代理只能绑定一个环境。代理断开时浏览器直接断网，不会回落到直连。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 解析结果：类型 · 主机:端口 · 账号
    @ViewBuilder
    private var proxySummary: some View {
        if let proxyParseError {
            Label(proxyParseError, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        } else if let cfg = draft.proxyConfig {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(cfg.kind == .socks5 ? "SOCKS5" : "HTTP").font(.caption.weight(.medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                Text(verbatim: "\(cfg.host):\(cfg.port)").textSelection(.enabled)
                if let u = cfg.username {
                    Text("账号 \(u)").foregroundStyle(.secondary)
                    Text(cfg.password == nil ? "无密码" : "有密码").foregroundStyle(.secondary)
                } else {
                    Text("无认证").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var checkResultView: some View {
        switch checkResult {
        case .success(let info):
            VStack(alignment: .trailing, spacing: 2) {
                Text(info.summary).font(.callout).textSelection(.enabled)
                if let org = info.org { Text(org).font(.caption).foregroundStyle(.secondary) }
            }
        case .failure(let e):
            Text(e.localizedDescription).font(.callout).foregroundStyle(.red).multilineTextAlignment(.trailing)
        case nil:
            EmptyView()
        }
    }

    // MARK: - 语言和时区

    private var lastExit: ExitInfo? {
        if case .success(let info) = checkResult { return info }
        return nil
    }

    private var environmentSection: some View {
        Section {
            Picker("语言", selection: Binding(
                get: { draft.languageAuto ? LanguageTag.auto : draft.language },
                set: { v in
                    if v == LanguageTag.auto { draft.languageAuto = true } else { draft.languageAuto = false; draft.language = v }
                })) {
                Text("跟随出口 IP（推荐）").tag(LanguageTag.auto)
                Divider()
                if !draft.languageAuto, !LanguageOptions.codes.contains(draft.language) {
                    Text(draft.language).tag(draft.language)
                }
                ForEach(LanguageOptions.codes, id: \.self) { Text(LanguageOptions.label($0)).tag($0) }
            }
            Picker("时区", selection: Binding(
                get: { draft.timezoneAuto ? "auto" : draft.timezone },
                set: { v in
                    if v == "auto" { draft.timezoneAuto = true } else { draft.timezoneAuto = false; draft.timezone = v }
                })) {
                Text("跟随出口 IP（推荐）").tag("auto")
                Divider()
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
            if let e = lastExit, draft.languageAuto || draft.timezoneAuto {
                let lang = draft.languageAuto ? LanguageTag.resolve(LanguageTag.auto, countryCode: e.countryCode) : draft.language
                let tz = draft.timezoneAuto ? (e.timezone ?? "?") : draft.timezone
                LabeledContent("按当前出口") {
                    Text("\(LanguageOptions.label(lang)) · \(tz)").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("语言和时区")
        } footer: {
            Text("每次启动都会按当时检测到的出口 IP 设置。语言也会影响 Chrome 自身界面的语言。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 更多设置

    private var moreSection: some View {
        Section {
            ExpandRow(title: "更多设置", subtitle: moreSummary, expanded: $showMore)
            if showMore {
                Picker("定位权限", selection: $draft.geolocation) {
                    Text("禁止（推荐）").tag(GeolocationPolicy.block)
                    Text("询问").tag(GeolocationPolicy.ask)
                }
                .pickerStyle(.segmented)
                Picker("窗口尺寸", selection: $draft.windowPreset) {
                    ForEach(ProfileDraft.windowPresets, id: \.self) { Text($0).tag($0) }
                }
                if draft.windowPreset == "自定义" {
                    HStack {
                        TextField("宽", text: $draft.windowWidthText)
                        Text("×")
                        TextField("高", text: $draft.windowHeightText)
                    }
                }
                Toggle("工具栏自动配色", isOn: $draft.themeAuto)
                if !draft.themeAuto {
                    ColorPicker("工具栏颜色", selection: $draft.themeColor, supportsOpacity: false)
                }
                extensionRows
                VStack(alignment: .leading, spacing: 4) {
                    Text("额外的 Chrome 启动参数（每行一个）")
                    TextEditor(text: $draft.extraArgsText)
                        .font(.body.monospaced())
                        .frame(height: 40)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
                }
                if let p = original {
                    LabeledContent("环境目录") {
                        HStack {
                            Text(model.paths.profileDir(p.id).path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button("显示") { model.revealInFinder(p.id) }.controlSize(.small)
                        }
                    }
                    LabeledContent("编号", value: "#\(p.seq) · \(p.id)").font(.caption)
                }
            }
        }
    }

    /// 折叠时显示的摘要，一眼看出有没有改过默认值。
    private var moreSummary: String {
        var parts = [draft.geolocation == .block ? "定位禁止" : "定位询问",
                     draft.windowPreset == "默认" ? "窗口默认" : "窗口 \(draft.windowPreset)"]
        if !draft.extensionIds.isEmpty { parts.append("\(draft.extensionIds.count) 个扩展") }
        if !draft.extraArgsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("有额外参数") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var extensionRows: some View {
        let lib = model.extensionLibrary
        if lib.isEmpty && draft.extensionIds.isEmpty {
            LabeledContent("预装扩展") {
                Text("扩展库是空的（设置 → 扩展库）").foregroundStyle(.secondary)
            }
        }
        ForEach(lib) { e in
            Toggle(isOn: Binding(
                get: { draft.extensionIds.contains(e.id) },
                set: { on in
                    draft.extensionIds.removeAll { $0 == e.id }
                    if on { draft.extensionIds.append(e.id) }
                })) {
                Text("扩展：" + (e.name.isEmpty ? String(e.id.prefix(12)) + "…" : e.name)).help(e.id)
            }
        }
        ForEach(draft.extensionIds.filter { id in !lib.contains { $0.id == id } }, id: \.self) { id in
            Toggle(isOn: Binding(get: { true }, set: { if !$0 { draft.extensionIds.removeAll { $0 == id } } })) {
                Text("扩展：" + String(id.prefix(12)) + "…").help(id)
            }
        }
    }

    // MARK: - 动作

    private func load() {
        guard !loaded else { return }
        loaded = true
        if Self.expandAllForSnapshot { showMore = true }
        switch target {
        case .new(let gid):
            draft = ProfileDraft(defaultLanguage: model.defaultLanguage, groupId: gid)
        case .edit(let id):
            if let p = model.fresh(id) ?? model.profile(id) {
                original = p
                draft = ProfileDraft(p)
                if let e = p.lastExit { checkResult = .success(e) }
            }
        }
    }

    private func parseProxyText() {
        let t = proxyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { proxyParseError = nil; return }
        do {
            draft.fill(from: try ProxyConfig.parse(t, defaultKind: draft.proxyKind))
            proxyParseError = nil
            checkResult = nil  // 代理换了，之前的检测结果作废
        } catch {
            proxyParseError = error.localizedDescription
        }
    }

    private func check() {
        let upstream: Upstream
        if draft.proxyMode == .direct { upstream = .direct }
        else if let cfg = draft.proxyConfig { upstream = .proxy(cfg) }
        else { return }
        checking = true
        checkResult = nil
        Task {
            do {
                checkResult = .success(try await GeoCheck.check(upstream: upstream))
            } catch {
                checkResult = .failure(error)
            }
            checking = false
        }
    }

    private func save() {
        do {
            var p = original ?? Profile(name: "")
            try draft.apply(to: &p)
            let saved = try model.save(p, isNew: isNew)
            // 表单里刚检测过且代理没变，就顺手记下出口
            if case .success(let info) = checkResult, saved.proxy == draft.proxyConfig, saved.lastExit != info {
                try? model.store?.recordExit(info, for: saved.id)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 表单里可展开/收起的一行（展开后的内容作为普通表单行显示）。
struct ExpandRow: View {
    let title: String
    let subtitle: String?
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let subtitle, !expanded {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
