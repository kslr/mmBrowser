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
            Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
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
                Text(L("batch.proxyList")).fixedSize()
                Spacer()
                Text(L("batch.proxyList.defaultKind")).foregroundStyle(.secondary).fixedSize()
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
                let badLines = bad.map { String($0.lineNumber) }.joined(separator: L("common.listSeparator"))
                Text(bad.isEmpty ? L("batch.proxyList.recognized \(lines.count)")
                     : L("batch.proxyList.partial \(lines.count - bad.count) \(badLines)"))
                    .font(.caption).foregroundStyle(bad.isEmpty ? Color.secondary : Color.red)
            }
            Text(L("batch.proxyList.formats"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 批量新建

struct BatchCreateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tag: String?

    @State private var names = NamePattern(pattern: L("batchCreate.defaultPattern"))
    @State private var count = 5
    @State private var proxyText = ""
    @State private var proxyKind = ProxyConfig.Kind.socks5
    @State private var tags: [String] = []
    @State private var notes = ""
    @State private var language = LanguageTag.auto
    @State private var timezone: String?
    @State private var expiryEnabled = false
    @State private var expiry = Date().addingTimeInterval(30 * 86_400)
    @State private var error: String?

    private var hasProxies: Bool { !proxyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var lines: [ProxyList.Line] { ProxyList.parse(proxyText, defaultKind: proxyKind) }
    private var total: Int { hasProxies ? lines.count : count }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("batchCreate.section.name")) {
                    TextField(L("batchCreate.pattern"), text: $names.pattern, prompt: Text(L("batchCreate.pattern.prompt")))
                    HStack {
                        Stepper(L("batchCreate.startNumber \(names.start)"), value: $names.start, in: 0...99_999)
                        Spacer()
                        Stepper(L("batchCreate.digits \(names.digits)"), value: $names.digits, in: 1...6)
                    }
                    Text(L("batchCreate.preview \(previewNames)")).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ProxyTextArea(text: $proxyText, kind: $proxyKind, lines: lines)
                    if !hasProxies {
                        Stepper(L("batchCreate.count \(count)"), value: $count, in: 1...500)
                    }
                    Toggle(L("batchCreate.expiry"), isOn: $expiryEnabled)
                    if expiryEnabled { DatePicker(L("common.expiryDate"), selection: $expiry, displayedComponents: .date) }
                } header: {
                    Text(L("batchCreate.section.proxies"))
                }
                Section(L("batchCreate.section.common")) {
                    LabeledContent(L("editor.tags")) {
                        TagEditor(tags: $tags, suggestions: model.tagsByUsage, placeholder: L("editor.tags.placeholder"))
                    }
                    LanguagePicker(language: $language)
                    TimezonePicker(timezone: $timezone)
                    TextField(L("editor.notes"), text: $notes, prompt: Text(L("common.optional")))
                    NewProfileExtensionsRow()
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: error, confirmTitle: L("batchCreate.confirm \(total)"), confirmDisabled: total == 0, onConfirm: create)
        }
        .frame(width: 600, height: 700)
        .onAppear {
            tags = tag.map { [$0] } ?? []
            language = model.defaultLanguage
        }
    }

    private var previewNames: String {
        let shown = (0..<min(3, max(total, 1))).map(names.name)
        return shown.joined(separator: L("common.listSeparator")) + (total > 3 ? L("common.ellipsis") : "")
    }

    private func create() {
        do {
            let proxies = hasProxies ? try ProxyList.parseStrict(proxyText, defaultKind: proxyKind) : []
            guard !names.pattern.trimmingCharacters(in: .whitespaces).isEmpty else { throw DraftError(L("batchCreate.error.pattern")) }
            var template = Profile(name: "", language: language, timezone: timezone, tags: tags, notes: notes)
            template.extensionIds = model.newProfileExtensionIds
            template.proxyExpiresAt = expiryEnabled && !proxies.isEmpty ? expiry : nil
            model.batchCreate(template: template, names: names, count: count, proxies: proxies)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 批量编辑

struct BatchEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [String]

    @State private var edit = BatchEdit()
    @State private var windowPreset = ProfileDraft.defaultWindowPreset
    @State private var addExt = Set<String>()
    @State private var removeExt = Set<String>()
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(L("batchEdit.addTags")) {
                        TagEditor(tags: $edit.addTags, suggestions: model.tagsByUsage, placeholder: L("common.optional"))
                    }
                    LabeledContent(L("batchEdit.removeTags")) { removeTagsPicker }
                } header: { Text(L("batchEdit.header \(ids.count)")) }

                Section(L("batchEdit.section.environment")) {
                    Toggle(L("batchEdit.setLanguage"), isOn: $edit.setLanguage)
                    if edit.setLanguage { LanguagePicker(language: $edit.language) }
                    Toggle(L("batchEdit.setTimezone"), isOn: $edit.setTimezone)
                    if edit.setTimezone { TimezonePicker(timezone: $edit.timezone) }
                    Toggle(L("batchEdit.setGeolocation"), isOn: $edit.setGeolocation)
                    if edit.setGeolocation {
                        Picker(L("common.geolocation"), selection: $edit.geolocation) {
                            Text(L("batchEdit.geolocation.block")).tag(GeolocationPolicy.block)
                            Text(L("common.geolocation.ask")).tag(GeolocationPolicy.ask)
                        }.pickerStyle(.segmented)
                    }
                    Toggle(L("batchEdit.setWindow"), isOn: $edit.setWindow)
                    if edit.setWindow {
                        Picker(L("common.windowSize"), selection: $windowPreset) {
                            ForEach(ProfileDraft.windowPresets.filter { $0 != ProfileDraft.customWindowPreset }, id: \.self) {
                                Text(ProfileDraft.windowPresetLabel($0)).tag($0)
                            }
                        }
                    }
                }

                if !model.extensionLibrary.isEmpty {
                    Section(L("batchEdit.section.extensions")) {
                        ForEach(model.extensionLibrary) { e in
                            HStack {
                                Text(model.extensionName(e.id))
                                    .lineLimit(1).truncationMode(.tail)
                                    .help(e.id)
                                Spacer(minLength: 12)
                                Picker("", selection: Binding(
                                    get: { addExt.contains(e.id) ? 1 : removeExt.contains(e.id) ? 2 : 0 },
                                    set: { v in
                                        addExt.remove(e.id); removeExt.remove(e.id)
                                        if v == 1 { addExt.insert(e.id) } else if v == 2 { removeExt.insert(e.id) }
                                    })) {
                                    Text(L("batchEdit.extension.keep")).tag(0)
                                    Text(L("batchEdit.extension.install")).tag(1)
                                    Text(L("batchEdit.extension.uninstall")).tag(2)
                                }
                                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: error, confirmTitle: L("batchEdit.confirm \(ids.count)"), onConfirm: apply)
        }
        .frame(width: 560, height: 620)
    }

    /// 只列出这批环境身上已有的标签（带个数），点一下标记为移除，再点取消。
    @ViewBuilder private var removeTagsPicker: some View {
        let present = AppModel.byUsage(ids.compactMap(model.profile).flatMap(\.tags))
        if present.isEmpty {
            Text(L("batchEdit.removeTags.none")).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(present, id: \.tag) { t, n in
                    let on = edit.removeTags.contains(t)
                    Button {
                        if on { edit.removeTags.removeAll { $0 == t } } else { edit.removeTags.append(t) }
                    } label: {
                        TagChip(title: t, systemImage: on ? "minus.circle.fill" : nil, detail: "\(n)", tint: on ? .red : nil)
                    }
                    .buttonStyle(.plain)
                    .help(L("batchEdit.removeTags.help \(t) \(n)"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func apply() {
        var e = edit
        if e.setLanguage, !LanguageTag.isValidSetting(e.language) { error = L("batchEdit.error.language \(e.language)"); return }
        e.window = WindowSize(windowPreset)  // "默认" 解析不出尺寸，就是 nil
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
                    Toggle(L("assign.setExpiry"), isOn: $expiryEnabled)
                    if expiryEnabled { DatePicker(L("common.expiryDate"), selection: $expiry, displayedComponents: .date) }
                } header: {
                    Text(L("assign.header \(targets.count)"))
                } footer: {
                    Text(L("assign.footer")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("assign.preview")) {
                    ForEach(Array(targets.prefix(12).enumerated()), id: \.offset) { i, p in
                        LabeledContent(p.numberedName) {
                            if i < lines.count, case .success(let c) = lines[i].result {
                                Text(verbatim: c.urlString).foregroundStyle(.secondary)
                            } else {
                                Text(L("assign.preview.noProxy")).foregroundStyle(.red)
                            }
                        }
                    }
                    if targets.count > 12 { Text(L("assign.preview.total \(targets.count)")).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: error, confirmTitle: L("assign.confirm"), confirmDisabled: lines.isEmpty, onConfirm: assign)
        }
        .frame(width: 600, height: 640)
    }

    private func assign() {
        do {
            let proxies = try ProxyList.parseStrict(text, defaultKind: kind)
            guard proxies.count == targets.count else {
                throw DraftError(L("assign.error.count \(targets.count) \(proxies.count)"))
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
                Section(L("expiry.header \(ids.count)")) {
                    Toggle(L("expiry.clear"), isOn: $clear)
                    if !clear { DatePicker(L("common.expiryDate"), selection: $date, displayedComponents: .date) }
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetButtons(error: nil, confirmTitle: L("common.save")) {
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

#if DEBUG
#Preview("批量新建") {
    BatchCreateView(tag: nil).environment(AppModel.preview)
}

#Preview("批量编辑") {
    BatchEditView(ids: AppModel.preview.profiles.prefix(3).map(\.id)).environment(AppModel.preview)
}

#Preview("分配代理") {
    AssignProxiesView(ids: AppModel.preview.profiles.prefix(3).map(\.id)).environment(AppModel.preview)
}
#endif
