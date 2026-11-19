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
