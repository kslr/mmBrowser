import MMCore
import SwiftUI

/// 表单里可编辑的草稿（字符串形式，保存时校验）。
struct ProfileDraft {
    enum ProxyMode: String, CaseIterable { case proxy, direct }

    var name = ""
    var tags: [String] = []
    var notes = ""

    var proxyMode = ProxyMode.proxy
    var proxyKind = ProxyConfig.Kind.socks5
    var host = ""
    var portText = ""
    var username = ""
    var password = ""
    var expiryEnabled = false
    var expiry = Date().addingTimeInterval(30 * 86_400)

    /// LanguageTag.auto 表示跟随出口 IP
    var language = LanguageTag.auto
    /// nil 表示跟随出口 IP
    var timezone: String?
    var geolocation = GeolocationPolicy.block
    var windowPreset = Self.defaultWindowPreset
    var windowWidthText = ""
    var windowHeightText = ""
    var themeAuto = true
    var themeColor = Color(hex: "#1A73E8")
    var extraArgsText = ""
    var extensionIds: [String] = []

    static let defaultWindowPreset = "default"
    static let customWindowPreset = "custom"
    static let windowPresets = [defaultWindowPreset, "1280x800", "1366x768", "1440x900", "1536x864", "1680x1050", "1920x1080",
                                customWindowPreset]

    static func windowPresetLabel(_ preset: String) -> String {
        switch preset {
        case defaultWindowPreset: L("editor.window.default")
        case customWindowPreset: L("editor.window.custom")
        default: preset
        }
    }

    init(defaultLanguage: String, tags: [String] = []) {
        language = defaultLanguage
        self.tags = tags
    }

    init(_ p: Profile) {
        name = p.name
        tags = p.tags
        notes = p.notes
        if let proxy = p.proxy {
            proxyMode = .proxy
            fill(from: proxy)
        } else {
            proxyMode = p.allowDirect ? .direct : .proxy
        }
        if let e = p.proxyExpiresAt { expiryEnabled = true; expiry = e }
        language = p.language
        timezone = p.timezone
        geolocation = p.geolocation
        if let size = p.windowSize {
            windowPreset = Self.windowPresets.contains(size.description) ? size.description : Self.customWindowPreset
            windowWidthText = String(size.width)
            windowHeightText = String(size.height)
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

    /// 按当前填写能检测的上游（代理没填完整时为 nil）。
    var upstream: Upstream? {
        proxyMode == .direct ? .direct : proxyConfig.map(Upstream.proxy)
    }

    mutating func fill(from proxy: ProxyConfig) {
        proxyMode = .proxy
        proxyKind = proxy.kind
        host = proxy.host
        portText = String(proxy.port)
        username = proxy.username ?? ""
        password = proxy.password ?? ""
    }

    /// 校验并写入 profile。名称可以为空（保存时自动命名）。
    func apply(to p: inout Profile) throws {
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.tags = tags
        p.notes = notes

        switch proxyMode {
        case .proxy:
            guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw DraftError(L("editor.error.proxyRequired")) }
            guard let port = Int(portText), (1...65535).contains(port) else { throw DraftError(L("editor.error.port")) }
            guard username.isEmpty == false || password.isEmpty else { throw DraftError(L("editor.error.passwordWithoutUsername")) }
            p.proxy = ProxyConfig(kind: proxyKind, host: host.trimmingCharacters(in: .whitespaces), port: port,
                                  username: username, password: password)
            p.allowDirect = false
            p.proxyExpiresAt = expiryEnabled ? expiry : nil
        case .direct:
            p.proxy = nil
            p.allowDirect = true
            p.proxyExpiresAt = nil
        }

        guard LanguageTag.isValidSetting(language) else { throw DraftError(L("editor.error.language \(language)")) }
        p.language = language
        if let timezone, TimeZone(identifier: timezone) == nil { throw DraftError(L("editor.error.timezone \(timezone)")) }
        p.timezone = timezone
        p.geolocation = geolocation

        switch windowPreset {
        case Self.defaultWindowPreset:
            p.windowSize = nil
        case Self.customWindowPreset:
            guard let size = WindowSize("\(windowWidthText)x\(windowHeightText)") else { throw DraftError(L("editor.error.window")) }
            p.windowSize = size
        default:
            p.windowSize = WindowSize(windowPreset)
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
        if code == LanguageTag.auto { return L("language.auto") }
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return L("language.option \(name) \(code)")
    }
}

/// 语言选择：跟随出口 IP（auto）或常用语言。
struct LanguagePicker: View {
    var title = L("common.language")
    @Binding var language: String

    var body: some View {
        Picker(title, selection: $language) {
            Text(L("common.followExitIP.recommended")).tag(LanguageTag.auto)
            Divider()
            if language != LanguageTag.auto, !LanguageOptions.codes.contains(language) {
                Text(language).tag(language)
            }
            ForEach(LanguageOptions.codes, id: \.self) { Text(LanguageOptions.label($0)).tag($0) }
        }
    }
}

/// 时区选择：跟随出口 IP（nil）或指定时区。
struct TimezonePicker: View {
    @Binding var timezone: String?

    var body: some View {
        Picker(L("common.timezone"), selection: $timezone) {
            Text(L("common.followExitIP.recommended")).tag(String?.none)
            Divider()
            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }
}

struct ProfileEditorView: View {
    /// 表单高度（截图自检时会临时调高，以便看到全部内容）。
    @MainActor static var height: CGFloat = 660
    @MainActor static var expandAllForSnapshot = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var draft = ProfileDraft(defaultLanguage: LanguageTag.auto)
    @State private var original: Profile?
    @State private var loaded = false
    @State private var proxyText = ""
    @State private var proxyParseError: String?
    @State private var showProxyFields = false
    @State private var showMore = false
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
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? L("editor.create") : L("common.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: Self.height)
        .onAppear(perform: load)
    }

    // MARK: - 基本

    private var basicSection: some View {
        Section(L("editor.section.basic")) {
            TextField(L("editor.name"), text: $draft.name, prompt: Text(isNew ? L("editor.name.prompt") : ""))
            LabeledContent(L("editor.tags")) {
                TagEditor(tags: $draft.tags, suggestions: model.tagsByUsage, placeholder: L("editor.tags.placeholder"))
            }
            TextField(L("editor.notes"), text: $draft.notes, prompt: Text(L("common.optional")), axis: .vertical).lineLimit(1...3)
        }
    }

    // MARK: - 代理

    private var proxySection: some View {
        Section {
            Picker(L("editor.proxy.mode"), selection: $draft.proxyMode) {
                Text(L("editor.proxy.mode.proxy")).tag(ProfileDraft.ProxyMode.proxy)
                Text(L("editor.proxy.mode.direct")).tag(ProfileDraft.ProxyMode.direct)
            }
            .pickerStyle(.segmented)

            if draft.proxyMode == .proxy {
                TextField(L("editor.proxy.field"), text: $proxyText,
                          prompt: Text(draft.proxyConfig == nil ? L("editor.proxy.prompt") : L("editor.proxy.prompt.replace")),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .onChange(of: proxyText) {
                        let t = proxyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if t != proxyText { proxyText = t; return }
                        parseProxyText()
                    }
                proxySummary
                ExpandRow(title: L("editor.proxy.fields"), subtitle: nil, expanded: $showProxyFields)
                if showProxyFields {
                    Picker(L("editor.proxy.kind"), selection: $draft.proxyKind) {
                        Text("SOCKS5").tag(ProxyConfig.Kind.socks5)
                        Text("HTTP").tag(ProxyConfig.Kind.http)
                    }
                    .pickerStyle(.segmented)
                    TextField(L("editor.proxy.host"), text: $draft.host)
                    TextField(L("editor.proxy.port"), text: $draft.portText)
                    TextField(L("editor.proxy.username"), text: $draft.username, prompt: Text(L("common.optional")))
                    TextField(L("editor.proxy.password"), text: $draft.password, prompt: Text(L("common.optional")))
                }
                Toggle(L("editor.proxy.expiry.toggle"), isOn: $draft.expiryEnabled)
                if draft.expiryEnabled {
                    DatePicker(L("common.expiryDate"), selection: $draft.expiry, displayedComponents: .date)
                }
            } else {
                Label(L("editor.proxy.directWarning"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            HStack(alignment: .top) {
                Button(checking ? L("editor.proxy.checking") : L("editor.proxy.check")) { check() }
                    .disabled(checking || draft.upstream == nil)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                checkResultView
            }
        } header: {
            Text(L("editor.proxy.header"))
        } footer: {
            Text(L("editor.proxy.footer"))
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
                // 完整地址（含密码），方便直接选中复制
                Text(verbatim: cfg.urlString).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
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
            LanguagePicker(language: $draft.language)
            TimezonePicker(timezone: $draft.timezone)
            if let e = lastExit, draft.language == LanguageTag.auto || draft.timezone == nil {
                let lang = LanguageTag.resolve(draft.language, countryCode: e.countryCode)
                let tz = draft.timezone ?? e.timezone ?? "?"
                LabeledContent(L("editor.environment.current")) {
                    Text(verbatim: "\(LanguageOptions.label(lang)) · \(tz)").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("editor.environment.header"))
        } footer: {
            Text(L("editor.environment.footer"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 更多设置

    private var moreSection: some View {
        Section {
            ExpandRow(title: L("editor.more"), subtitle: moreSummary, expanded: $showMore)
            if showMore {
                Picker(L("common.geolocation"), selection: $draft.geolocation) {
                    Text(L("editor.geolocation.block.recommended")).tag(GeolocationPolicy.block)
                    Text(L("common.geolocation.ask")).tag(GeolocationPolicy.ask)
                }
                .pickerStyle(.segmented)
                Picker(L("common.windowSize"), selection: $draft.windowPreset) {
                    ForEach(ProfileDraft.windowPresets, id: \.self) { Text(ProfileDraft.windowPresetLabel($0)).tag($0) }
                }
                if draft.windowPreset == ProfileDraft.customWindowPreset {
                    HStack {
                        TextField(L("editor.window.width"), text: $draft.windowWidthText)
                        Text("×")
                        TextField(L("editor.window.height"), text: $draft.windowHeightText)
                    }
                }
                Toggle(L("editor.theme.auto"), isOn: $draft.themeAuto)
                if !draft.themeAuto {
                    ColorPicker(L("editor.theme.color"), selection: $draft.themeColor, supportsOpacity: false)
                }
                extensionRows
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("editor.extraArgs"))
                    TextEditor(text: $draft.extraArgsText)
                        .font(.body.monospaced())
                        .frame(height: 40)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
                }
                if let p = original {
                    LabeledContent(L("editor.profileFolder")) {
                        HStack {
                            Text(model.paths.profileDir(p.id).path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button(L("editor.profileFolder.show")) { model.revealInFinder(p.id) }.controlSize(.small)
                        }
                    }
                    LabeledContent(L("editor.id"), value: "#\(p.seq) · \(p.id)").font(.caption)
                }
            }
        }
    }

    /// 折叠时显示的摘要，一眼看出有没有改过默认值。
    private var moreSummary: String {
        var parts = [draft.geolocation == .block ? L("editor.more.geolocation.block") : L("editor.more.geolocation.ask"),
                     draft.windowPreset == ProfileDraft.defaultWindowPreset ? L("editor.more.window.default")
                         : L("editor.more.window \(ProfileDraft.windowPresetLabel(draft.windowPreset))")]
        if !draft.extensionIds.isEmpty { parts.append(L("editor.more.extensions \(draft.extensionIds.count)")) }
        if !draft.extraArgsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(L("editor.more.extraArgs")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var extensionRows: some View {
        let lib = model.extensionLibrary
        if isNew {
            // 新建时不用挑：扩展库里的都会装上，建好后可在编辑里单独取消
            NewProfileExtensionsRow()
        } else {
            if lib.isEmpty && draft.extensionIds.isEmpty {
                LabeledContent(L("editor.extensions")) {
                    Text(L("editor.extensions.empty")).foregroundStyle(.secondary)
                }
            }
            ForEach(lib) { e in
                Toggle(isOn: Binding(
                    get: { draft.extensionIds.contains(e.id) },
                    set: { on in
                        draft.extensionIds.removeAll { $0 == e.id }
                        if on { draft.extensionIds.append(e.id) }
                    })) {
                    Text(L("editor.extension \(model.extensionName(e.id))")).help(e.id)
                }
            }
            ForEach(draft.extensionIds.filter { id in !lib.contains { $0.id == id } }, id: \.self) { id in
                Toggle(isOn: Binding(get: { true }, set: { if !$0 { draft.extensionIds.removeAll { $0 == id } } })) {
                    Text(L("editor.extension \(model.extensionName(id))")).help(id)
                }
            }
        }
    }

    // MARK: - 动作

    private func load() {
        guard !loaded else { return }
        loaded = true
        if Self.expandAllForSnapshot { showMore = true }
        switch target {
        case .new(let tag):
            draft = ProfileDraft(defaultLanguage: model.defaultLanguage, tags: tag.map { [$0] } ?? [])
            draft.extensionIds = model.newProfileExtensionIds
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
        guard let upstream = draft.upstream else { return }
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
            // 新建，或代理换了（保存时已清掉旧的出口结果），就自动检测一次
            let proxyChanged = original.map { $0.upstream != saved.upstream } ?? true
            if proxyChanged { model.autoCheck([saved.id]) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 新建表单里的「预装扩展」：只展示扩展库里会装上的扩展，不用逐个勾选。
struct NewProfileExtensionsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lib = model.extensionLibrary
        LabeledContent(L("editor.extensions")) {
            if lib.isEmpty {
                Text(L("editor.extensions.empty")).foregroundStyle(.secondary)
            } else {
                Text(lib.map { model.extensionName($0.id) }.formatted(.list(type: .and, width: .narrow)))
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .help(L("editor.extensions.new.help"))
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

#if DEBUG
#Preview("编辑环境") {
    ProfileEditorView(target: .edit(AppModel.preview.profiles[0].id)).environment(AppModel.preview)
}

#Preview("新建环境") {
    ProfileEditorView(target: .new(tag: nil)).environment(AppModel.preview)
}
#endif
