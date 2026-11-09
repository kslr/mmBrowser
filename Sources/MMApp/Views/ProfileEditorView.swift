import MMCore
import SwiftUI

/// 表单里可编辑的草稿（字符串形式，保存时校验）。
struct ProfileDraft {
    enum ProxyMode: String, CaseIterable { case proxy, direct }

    var name = ""
    var groupId: Int64?
    var tagsText = ""
    var notes = ""
    var startURLsText = ""
    var alwaysOpenStartURLs = false

    var proxyMode = ProxyMode.proxy
    var proxyKind = ProxyConfig.Kind.socks5
    var host = ""
    var portText = ""
    var username = ""
    var password = ""

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

    static let windowPresets = ["默认", "1280x800", "1366x768", "1440x900", "1536x864", "1680x1050", "1920x1080", "自定义"]

    init(defaultLanguage: String, groupId: Int64?) {
        language = defaultLanguage
        self.groupId = groupId
    }

    init(_ p: Profile) {
        name = p.name
        groupId = p.groupId
        tagsText = p.tags.joined(separator: ", ")
        notes = p.notes
        startURLsText = p.startURLs.joined(separator: "\n")
        alwaysOpenStartURLs = p.alwaysOpenStartURLs
        if let proxy = p.proxy {
            proxyMode = .proxy
            proxyKind = proxy.kind
            host = proxy.host
            portText = String(proxy.port)
            username = proxy.username ?? ""
            password = proxy.password ?? ""
        } else {
            proxyMode = p.allowDirect ? .direct : .proxy
        }
        language = p.language
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

    /// 校验并写入 profile。
    func apply(to p: inout Profile) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { throw DraftError("请填写名称") }
        p.name = trimmedName
        p.groupId = groupId
        p.tags = tagsText.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        p.notes = notes
        p.startURLs = try startURLsText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { s in
                let url = s.contains("://") ? s : "https://\(s)"
                guard URL(string: url)?.host != nil else { throw DraftError("启动页网址无效：\(s)") }
                return url
            }
        p.alwaysOpenStartURLs = alwaysOpenStartURLs

        switch proxyMode {
        case .proxy:
            guard !host.trimmingCharacters(in: .whitespaces).isEmpty else { throw DraftError("请填写代理主机") }
            guard let port = Int(portText), (1...65535).contains(port) else { throw DraftError("代理端口无效") }
            guard username.isEmpty == false || password.isEmpty else { throw DraftError("填了密码但没有用户名") }
            p.proxy = ProxyConfig(kind: proxyKind, host: host.trimmingCharacters(in: .whitespaces), port: port,
                                  username: username, password: password)
            p.allowDirect = false
        case .direct:
            p.proxy = nil
            p.allowDirect = true
        }

        guard LanguageTag.isValid(language) else { throw DraftError("语言代码无效：\(language)（例如 en-US、ja-JP）") }
        p.language = language
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
    }
}

struct DraftError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// 常用语言（显示名用系统当前语言）。
enum LanguageOptions {
    static let codes: [String] = {
        let fromCountries = Set(["en-US", "en-GB", "zh-CN", "zh-TW", "zh-HK", "ja-JP", "ko-KR", "de-DE", "fr-FR", "es-ES",
                                 "es-MX", "pt-BR", "pt-PT", "it-IT", "ru-RU", "nl-NL", "pl-PL", "tr-TR", "ar-SA", "th-TH",
                                 "vi-VN", "id-ID", "ms-MY", "en-CA", "en-AU", "en-SG", "en-IN", "sv-SE", "uk-UA", "he-IL"])
        return fromCountries.sorted()
    }()

    static func label(_ code: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: code) ?? code
        return "\(name)（\(code)）"
    }
}

struct ProfileEditorView: View {
    /// 表单高度（截图自检时会临时调高，以便看到全部内容）。
    @MainActor static var height: CGFloat = 720
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var draft = ProfileDraft(defaultLanguage: "en-US", groupId: nil)
    @State private var original: Profile?
    @State private var loaded = false
    @State private var quickProxy = ""
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
                advancedSection
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
        .frame(width: 620, height: Self.height)
        .onAppear(perform: load)
    }

    // MARK: - 分区

    private var basicSection: some View {
        Section("基本") {
            TextField("名称", text: $draft.name, prompt: Text("例如：客户A-01"))
            Picker("分组", selection: $draft.groupId) {
                Text("未分组").tag(Int64?.none)
                ForEach(model.groups) { g in Text(g.name).tag(Int64?.some(g.id!)) }
            }
            TextField("标签", text: $draft.tagsText, prompt: Text("用逗号分隔"))
            TextField("备注", text: $draft.notes, axis: .vertical).lineLimit(1...4)
            VStack(alignment: .leading, spacing: 4) {
                Text("启动页（每行一个）")
                TextEditor(text: $draft.startURLsText)
                    .font(.body.monospaced())
                    .frame(height: 54)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
            }
            Toggle("每次启动都打开启动页", isOn: $draft.alwaysOpenStartURLs)
                .help("关闭时，启动页只在第一次打开环境时打开，之后恢复上次的标签页")
        }
    }

    private var proxySection: some View {
        Section {
            Picker("连接方式", selection: $draft.proxyMode) {
                Text("代理").tag(ProfileDraft.ProxyMode.proxy)
                Text("直连（不走代理）").tag(ProfileDraft.ProxyMode.direct)
            }
            .pickerStyle(.segmented)

            if draft.proxyMode == .proxy {
                HStack {
                    TextField("快速填写", text: $quickProxy, prompt: Text("粘贴 socks5://user:pass@host:port 或 host:port:user:pass"))
                        .onSubmit(parseQuick)
                    Button("解析", action: parseQuick).disabled(quickProxy.isEmpty)
                }
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
            Text("一个代理只能绑定一个环境。浏览器通过本地入口连接这个代理，代理断开时浏览器直接断网，不会回落到直连。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var checkResultView: some View {
        switch checkResult {
        case .success(let info):
            VStack(alignment: .trailing, spacing: 4) {
                Text(info.summary).font(.callout).textSelection(.enabled)
                if let org = info.org { Text(org).font(.caption).foregroundStyle(.secondary) }
                if let rec = CountryLocale.recommendedLanguage(for: info.countryCode),
                   rec != draft.language || !draft.timezoneAuto {
                    Button("按出口设置：语言 \(rec)，时区跟随出口") {
                        draft.language = rec
                        draft.timezoneAuto = true
                    }
                    .controlSize(.small)
                }
            }
        case .failure(let e):
            Text(e.localizedDescription).font(.callout).foregroundStyle(.red).multilineTextAlignment(.trailing)
        case nil:
            EmptyView()
        }
    }

    private var environmentSection: some View {
        Section {
            HStack {
                TextField("语言", text: $draft.language)
                Menu {
                    ForEach(LanguageOptions.codes, id: \.self) { code in
                        Button(LanguageOptions.label(code)) { draft.language = code }
                    }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Toggle("时区跟随出口 IP", isOn: $draft.timezoneAuto)
            if !draft.timezoneAuto {
                Picker("时区", selection: $draft.timezone) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
            }
            Picker("定位权限", selection: $draft.geolocation) {
                Text("禁止").tag(GeolocationPolicy.block)
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
                .help("按环境编号自动挑一个颜色，方便区分窗口")
            if !draft.themeAuto {
                ColorPicker("工具栏颜色", selection: $draft.themeColor, supportsOpacity: false)
            }
        } header: {
            Text("环境参数")
        } footer: {
            Text("语言同时影响网页看到的语言和 Chrome 自身界面的语言。定位权限设为禁止可以避免网站拿到本机真实位置。修改在下次启动环境时生效。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section("高级") {
            VStack(alignment: .leading, spacing: 4) {
                Text("额外的 Chrome 启动参数（每行一个）")
                TextEditor(text: $draft.extraArgsText)
                    .font(.body.monospaced())
                    .frame(height: 44)
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
                LabeledContent("编号", value: "#\(p.seq) · \(p.id)")
                    .font(.caption)
            }
        }
    }

    // MARK: - 动作

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new(let gid):
            draft = ProfileDraft(defaultLanguage: model.defaultLanguage, groupId: gid)
        case .edit(let id):
            if let p = model.profile(id) {
                original = p
                draft = ProfileDraft(p)
                if let e = p.lastExit { checkResult = .success(e) }
            }
        }
    }

    private func parseQuick() {
        do {
            draft.fill(from: try ProxyConfig.parse(quickProxy, defaultKind: draft.proxyKind))
            quickProxy = ""
            error = nil
        } catch {
            self.error = error.localizedDescription
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
