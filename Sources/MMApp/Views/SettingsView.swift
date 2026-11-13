import MMCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.chromePathKey) private var chromePath = ChromeInstallation.defaultExecutable.path
    @AppStorage(AppModel.defaultLanguageKey) private var defaultLanguage = LanguageTag.auto
    @State private var checkChoice = "browserscan"
    @State private var customCheckURL = ""
    @AppStorage(AppModel.maxRunningKey) private var maxRunning = 10
    @AppStorage(AppModel.trashDaysKey) private var trashDays = 30
    @State private var newExtension = ""
    @State private var extError: String?

    var body: some View {
        Form {
            Section("Google Chrome") {
                LabeledContent(L("settings.chrome.executable")) {
                    HStack {
                        Text(chromePath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button(L("settings.chrome.choose"), action: pickChrome)
                        Button(L("settings.chrome.reset")) {
                            chromePath = ChromeInstallation.defaultExecutable.path
                            model.reloadChrome()
                        }
                    }
                }
                LabeledContent(L("settings.chrome.version"), value: model.chromeVersion ?? L("settings.chrome.notFound"))
            }
            Section(L("settings.section.profiles")) {
                LanguagePicker(title: L("settings.defaultLanguage"), language: $defaultLanguage)
                Stepper(L("settings.maxRunning \(maxRunning)"), value: $maxRunning, in: 1...100)
                    .help(L("settings.maxRunning.help"))
                Stepper(L("settings.trashDays \(trashDays)"), value: $trashDays, in: 1...365)
                    .help(L("settings.trashDays.help"))
            }
            Section {
                Picker(L("settings.checkPage"), selection: $checkChoice) {
                    ForEach(CheckPage.Preset.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    Divider()
                    Text(L("settings.checkPage.custom")).tag("custom")
                    Text(L("settings.checkPage.none")).tag("none")
                }
                .onChange(of: checkChoice) { saveCheckPage() }
                if checkChoice == "custom" {
                    TextField(L("settings.checkPage.url"), text: $customCheckURL, prompt: Text(verbatim: "https://…"))
                        .onSubmit(saveCheckPage)
                }
            } header: {
                Text(L("settings.checkPage.header"))
            } footer: {
                Text(L("settings.checkPage.footer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                let _ = model.extensionLibraryVersion
                ForEach(model.extensionLibrary) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.name.isEmpty ? L("settings.extensions.pendingName") : e.name)
                            Text(e.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        let used = model.profiles.filter { $0.extensionIds.contains(e.id) }.count
                        Text(L("common.profileCount \(used)")).foregroundStyle(.secondary)
                        Toggle(L("settings.extensions.default"), isOn: Binding(
                            get: { e.isDefault },
                            set: { on in
                                var lib = model.extensionLibrary
                                if let i = lib.firstIndex(where: { $0.id == e.id }) { lib[i].isDefault = on }
                                model.saveExtensionLibrary(lib)
                            }))
                            .toggleStyle(.checkbox)
                            .help(L("settings.extensions.default.help"))
                        Button(role: .destructive) {
                            model.saveExtensionLibrary(model.extensionLibrary.filter { $0.id != e.id })
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help(L("settings.extensions.remove.help"))
                    }
                }
                HStack {
                    TextField(L("settings.extensions.add"), text: $newExtension, prompt: Text(L("settings.extensions.add.prompt")))
                        .onSubmit(addExtension)
                    Button(L("settings.extensions.addButton"), action: addExtension).disabled(newExtension.isEmpty)
                }
                if let extError { Text(extError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text(L("settings.extensions.header"))
            } footer: {
                Text(L("settings.extensions.footer")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("settings.section.data")) {
                LabeledContent(L("settings.data.folder")) {
                    HStack {
                        Text(model.paths.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button(L("common.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([model.paths.root]) }
                    }
                }
                Text(L("settings.data.note"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 700)
        .onAppear(perform: loadCheckPage)
    }

    private func loadCheckPage() {
        switch model.store?.checkPage ?? .default {
        case .preset(let p): checkChoice = p.rawValue
        case .custom(let url): checkChoice = "custom"; customCheckURL = url
        case .none: checkChoice = "none"
        }
    }

    private func saveCheckPage() {
        let page: CheckPage
        if let p = CheckPage.Preset(rawValue: checkChoice) { page = .preset(p) }
        else if checkChoice == "none" { page = .none }
        else {
            let t = customCheckURL.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            page = .custom(t.contains("://") ? t : "https://\(t)")
        }
        try? model.store?.setCheckPage(page)
    }

    private func addExtension() {
        guard let id = ExtensionID.extract(from: newExtension) else {
            extError = L("settings.extensions.invalid")
            return
        }
        var lib = model.extensionLibrary
        if !lib.contains(where: { $0.id == id }) {
            // 应用商店链接里通常带着扩展名（/detail/<名称>/<id>）
            var name = ""
            if let url = URL(string: newExtension), let i = url.pathComponents.firstIndex(of: id), i > 0 {
                let slug = url.pathComponents[i - 1]
                if slug != "detail" { name = slug.replacingOccurrences(of: "-", with: " ").capitalized }
            }
            lib.append(ExtensionEntry(id: id, name: name))
            model.saveExtensionLibrary(lib)
        }
        newExtension = ""
        extError = nil
    }

    private func pickChrome() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let app = panel.url else { return }
        // 选的是 .app 时，找里面的主程序
        if let bundle = Bundle(url: app), let exe = bundle.executableURL {
            chromePath = exe.path
        } else {
            chromePath = app.path
        }
        model.reloadChrome()
    }
}

#if DEBUG
#Preview {
    SettingsView().environment(AppModel.preview).frame(width: 600, height: 700)
}
#endif
