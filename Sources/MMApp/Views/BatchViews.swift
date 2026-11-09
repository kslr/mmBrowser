import MMCore
import SwiftUI

/// 批量操作的表单。
enum BatchSheet: Identifiable {
    case create(tag: String?)
    case edit([String])
    case assignProxies([String])
    case expiry([String])

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let ids): "edit-\(ids.count)"
        case .assignProxies(let ids): "assign-\(ids.count)"
        case .expiry(let ids): "expiry-\(ids.count)"
        }
    }
}

struct BatchSheetView: View {
    let sheet: BatchSheet
    var body: some View {
        switch sheet {
        case .create(let tag): BatchCreateView(tag: tag)
        case .edit(let ids): BatchEditView(ids: ids)
        case .assignProxies(let ids): AssignProxiesView(ids: ids)
        case .expiry(let ids): ExpiryView(ids: ids)
        }
    }
}

/// 表单底部的按钮栏。
struct SheetButtons: View {
    let error: String?
    let confirmTitle: String
    var confirmDisabled = false
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(3)
            }
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: onConfirm).keyboardShortcut(.defaultAction).disabled(confirmDisabled)
        }
        .padding(12)
    }
}

/// 代理文本框 + 实时解析结果。
struct ProxyTextArea: View {
    @Binding var text: String
    @Binding var kind: ProxyConfig.Kind
    let lines: [ProxyList.Line]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("代理列表（每行一个）").fixedSize()
                Spacer()
                Text("未写类型的按").foregroundStyle(.secondary).fixedSize()
                Picker("", selection: $kind) {
                    Text("SOCKS5").tag(ProxyConfig.Kind.socks5)
                    Text("HTTP").tag(ProxyConfig.Kind.http)
                }
                .labelsHidden()
                .fixedSize()
            }
            TextEditor(text: $text)
                .font(.callout.monospaced())
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 5))
            let bad = lines.filter { if case .failure = $0.result { true } else { false } }
            if !lines.isEmpty {
                Text(bad.isEmpty ? "识别到 \(lines.count) 个代理"
                     : "识别到 \(lines.count - bad.count) 个，第 \(bad.map { String($0.lineNumber) }.joined(separator: "、")) 行无法识别")
                    .font(.caption).foregroundStyle(bad.isEmpty ? Color.secondary : Color.red)
            }
            Text("支持 socks5://user:pass@host:port、http://host:port、host:port:user:pass、user:pass@host:port")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 批量新建

struct BatchCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tag: String?

    @State private var namePattern = "环境-{n}"
    @State private var startNumber = 1
    @State private var digits = 2
    @State private var count = 5
    @State private var proxyText = ""
    @State private var proxyKind = ProxyConfig.Kind.socks5
    @State private var draft = ProfileDraft(defaultLanguage: LanguageTag.auto)
    @State private var language = LanguageTag.auto
    @State private var expiryEnabled = false
    @State private var expiry = Date().addingTimeInterval(30 * 86_400)
    @State private var error: String?

    private var lines: [ProxyList.Line] { ProxyList.parse(proxyText, defaultKind: proxyKind) }
    private var total: Int { proxyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? count : lines.count }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("名称") {
                    TextField("名称模板", text: $namePattern, prompt: Text("用 {n} 表示编号，例如 客户A-{n}"))
                    HStack {
                        Stepper("起始编号 \(startNumber)", value: $startNumber, in: 0...99_999)
                        Spacer()
                        Stepper("编号位数 \(digits)", value: $digits, in: 1...6)
                    }
                    Text("预览：" + previewNames).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ProxyTextArea(text: $proxyText, kind: $proxyKind, lines: lines)
                    if proxyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Stepper("不填代理时新建 \(count) 个环境（之后再分配代理）", value: $count, in: 1...500)
                    }
                    Toggle("代理到期日", isOn: $expiryEnabled)
                    if expiryEnabled { DatePicker("到期日", selection: $expiry, displayedComponents: .date) }
                } header: {
                    Text("代理（每个代理新建一个环境）")
                }
                Section("共同设置") {
                    LabeledContent("标签") {
                        TagTokenField(tags: $draft.tags, suggestions: model.allTags, placeholder: "可选，输入后按回车")
                    }
                    LanguagePicker(language: $language)
                    Picker("时区", selection: Binding(
                        get: { draft.timezoneAuto ? "auto" : draft.timezone },
                        set: { v in if v == "auto" { draft.timezoneAuto = true } else { draft.timezoneAuto = false; draft.timezone = v } })) {
                        Text("跟随出口 IP（推荐）").tag("auto")
                        Divider()
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("备注", text: $draft.notes, prompt: Text("可选"))
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: error, confirmTitle: "新建 \(total) 个", confirmDisabled: total == 0, onConfirm: create)
        }
        .frame(width: 600, height: 700)
        .onAppear {
            draft = ProfileDraft(defaultLanguage: model.defaultLanguage, tags: tag.map { [$0] } ?? [])
            language = model.defaultLanguage
        }
    }

    private var previewNames: String {
        let names = (0..<min(3, max(total, 1))).map { i -> String in
            let num = String(format: "%0\(digits)d", startNumber + i)
            return namePattern.contains("{n}") ? namePattern.replacingOccurrences(of: "{n}", with: num) : namePattern + num
        }
        return names.joined(separator: "、") + (total > 3 ? "……" : "")
    }

    private func create() {
        do {
            let proxies = proxyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : try ProxyList.parseStrict(proxyText, defaultKind: proxyKind)
            guard !namePattern.trimmingCharacters(in: .whitespaces).isEmpty else { throw DraftError("请填写名称模板") }
            var template = Profile(name: "模板")
            var d = draft
            d.name = "模板"
            d.proxyMode = .proxy
            d.host = "placeholder"; d.portText = "1"   // 代理之后逐个替换
            try d.apply(to: &template)
            template.proxy = nil
            template.language = language
            template.proxyExpiresAt = expiryEnabled && !proxies.isEmpty ? expiry : nil
            model.batchCreate(template: template, namePattern: namePattern, startNumber: startNumber,
                              digits: digits, count: count, proxies: proxies)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 语言选择：跟随出口 IP（auto）或常用语言。
struct LanguagePicker: View {
    var title = "语言"
    @Binding var language: String
    var body: some View {
        Picker(title, selection: $language) {
            Text("跟随出口 IP（推荐）").tag(LanguageTag.auto)
            Divider()
            if language != LanguageTag.auto, !LanguageOptions.codes.contains(language) {
                Text(language).tag(language)
            }
            ForEach(LanguageOptions.codes, id: \.self) { Text(LanguageOptions.label($0)).tag($0) }
        }
    }
}

// MARK: - 批量编辑

struct BatchEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]

    @State private var edit = BatchEdit()
    @State private var addTags: [String] = []
    @State private var removeTags: [String] = []
    @State private var tzAuto = true
    @State private var tz = TimeZone.current.identifier
    @State private var windowPreset = "默认"
    @State private var addExt = Set<String>()
    @State private var removeExt = Set<String>()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("添加标签") {
                        TagTokenField(tags: $addTags, suggestions: model.allTags, placeholder: "可选")
                    }
                    LabeledContent("移除标签") {
                        TagTokenField(tags: $removeTags, suggestions: model.allTags, placeholder: "可选")
                    }
                } header: { Text("将修改 \(ids.count) 个环境，只改打开了开关的项") }

                Section("环境参数") {
                    Toggle("修改语言", isOn: $edit.setLanguage)
                    if edit.setLanguage { LanguagePicker(language: $edit.language) }
                    Toggle("修改时区", isOn: $edit.setTimezone)
                    if edit.setTimezone {
                        Toggle("跟随出口 IP", isOn: $tzAuto)
                        if !tzAuto {
                            Picker("时区", selection: $tz) {
                                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                    Toggle("修改定位权限", isOn: $edit.setGeolocation)
                    if edit.setGeolocation {
                        Picker("定位权限", selection: $edit.geolocation) {
                            Text("禁止").tag(GeolocationPolicy.block)
                            Text("询问").tag(GeolocationPolicy.ask)
                        }.pickerStyle(.segmented)
                    }
                    Toggle("修改窗口尺寸", isOn: $edit.setWindow)
                    if edit.setWindow {
                        Picker("窗口尺寸", selection: $windowPreset) {
                            ForEach(ProfileDraft.windowPresets.filter { $0 != "自定义" }, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                if !model.extensionLibrary.isEmpty {
                    Section("扩展") {
                        ForEach(model.extensionLibrary) { e in
                            HStack {
                                Text(e.name.isEmpty ? String(e.id.prefix(12)) + "…" : e.name)
                                    .lineLimit(1).truncationMode(.tail)
                                    .help(e.id)
                                Spacer(minLength: 12)
                                Picker("", selection: Binding(
                                    get: { addExt.contains(e.id) ? 1 : removeExt.contains(e.id) ? 2 : 0 },
                                    set: { v in
                                        addExt.remove(e.id); removeExt.remove(e.id)
                                        if v == 1 { addExt.insert(e.id) } else if v == 2 { removeExt.insert(e.id) }
                                    })) {
                                    Text("不变").tag(0); Text("安装").tag(1); Text("卸载").tag(2)
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: error, confirmTitle: "应用到 \(ids.count) 个环境", onConfirm: apply)
        }
        .frame(width: 560, height: 620)
        .onAppear { edit.language = LanguageTag.auto }
    }

    private func apply() {
        var e = edit
        e.addTags = addTags
        e.removeTags = removeTags
        if e.setLanguage, !LanguageTag.isValidSetting(e.language) { error = "语言代码无效：\(e.language)"; return }
        if e.setTimezone { e.timezone = tzAuto ? nil : tz }
        if e.setWindow {
            let wh = windowPreset.split(separator: "x").compactMap { Int($0) }
            e.window = wh.count == 2 ? (wh[0], wh[1]) : nil
        }
        e.addExtensions = Array(addExt)
        e.removeExtensions = Array(removeExt)
        model.batchEdit(ids, e)
        dismiss()
    }
}

// MARK: - 分配代理

struct AssignProxiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]

    @State private var text = ""
    @State private var kind = ProxyConfig.Kind.socks5
    @State private var expiryEnabled = false
    @State private var expiry = Date().addingTimeInterval(30 * 86_400)
    @State private var error: String?

    private var lines: [ProxyList.Line] { ProxyList.parse(text, defaultKind: kind) }
    private var targets: [Profile] { ids.compactMap(model.profile).sorted { $0.seq < $1.seq } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ProxyTextArea(text: $text, kind: $kind, lines: lines)
                    Toggle("同时设置到期日", isOn: $expiryEnabled)
                    if expiryEnabled { DatePicker("到期日", selection: $expiry, displayedComponents: .date) }
                } header: {
                    Text("按序号顺序，把代理逐个分配给选中的 \(targets.count) 个环境")
                } footer: {
                    Text("会替换这些环境原来的代理。分配后需要重新检测出口。").font(.caption).foregroundStyle(.secondary)
                }
                Section("对应关系预览") {
                    ForEach(Array(targets.prefix(12).enumerated()), id: \.offset) { i, p in
                        LabeledContent("#\(p.seq) \(p.name)") {
                            if i < lines.count, case .success(let c) = lines[i].result {
                                Text(verbatim: c.displayString).foregroundStyle(.secondary)
                            } else {
                                Text("（没有对应的代理）").foregroundStyle(.red)
                            }
                        }
                    }
                    if targets.count > 12 { Text("…… 共 \(targets.count) 个").foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: error, confirmTitle: "分配", confirmDisabled: lines.isEmpty, onConfirm: assign)
        }
        .frame(width: 600, height: 640)
    }

    private func assign() {
        do {
            let proxies = try ProxyList.parseStrict(text, defaultKind: kind)
            guard proxies.count == targets.count else {
                throw DraftError("选中了 \(targets.count) 个环境，但填了 \(proxies.count) 个代理")
            }
            model.assignProxies(ids, proxies: proxies, expiry: expiryEnabled ? expiry : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 到期日

struct ExpiryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]
    @State private var date = Date().addingTimeInterval(30 * 86_400)
    @State private var clear = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("设置 \(ids.count) 个环境的代理到期日") {
                    Toggle("清除到期日", isOn: $clear)
                    if !clear { DatePicker("到期日", selection: $date, displayedComponents: .date) }
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: nil, confirmTitle: "保存") {
                var e = BatchEdit()
                e.setExpiry = true
                e.expiry = clear ? nil : date
                model.batchEdit(ids, e)
                dismiss()
            }
        }
        .frame(width: 420, height: 220)
    }
}
