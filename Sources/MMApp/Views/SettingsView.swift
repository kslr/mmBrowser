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
                LabeledContent("可执行文件") {
                    HStack {
                        Text(chromePath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("选择…", action: pickChrome)
                        Button("恢复默认") {
                            chromePath = ChromeInstallation.defaultExecutable.path
                            model.reloadChrome()
                        }
                    }
                }
                LabeledContent("版本", value: model.chromeVersion ?? "未找到")
            }
            Section("环境") {
                LanguagePicker(title: "新环境默认语言", language: $defaultLanguage)
                Stepper("同时运行上限：\(maxRunning) 个", value: $maxRunning, in: 1...100)
                    .help("16GB 内存建议不超过 10–12 个")
                Stepper("回收站保留：\(trashDays) 天", value: $trashDays, in: 1...365)
                    .help("超过天数的环境（连同浏览器数据）会在应用启动时彻底删除")
            }
            Section {
                Picker("检测页", selection: $checkChoice) {
                    ForEach(CheckPage.Preset.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    Divider()
                    Text("自定义网址").tag("custom")
                    Text("不打开").tag("none")
                }
                .onChange(of: checkChoice) { saveCheckPage() }
                if checkChoice == "custom" {
                    TextField("网址", text: $customCheckURL, prompt: Text("https://…"))
                        .onSubmit(saveCheckPage)
                }
            } header: {
                Text("启动时打开的检测页")
            } footer: {
                Text("每次启动环境都会打开它，用来确认出口 IP、位置和时区。对所有环境生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                let _ = model.extensionLibraryVersion
                ForEach(model.extensionLibrary) { e in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(e.name.isEmpty ? "（名称待安装后获取）" : e.name)
                            Text(e.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        let used = model.profiles.filter { $0.extensionIds.contains(e.id) }.count
                        Text("\(used) 个环境").foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            model.saveExtensionLibrary(model.extensionLibrary.filter { $0.id != e.id })
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("从扩展库移除（已勾选它的环境不受影响，可以在环境里取消勾选）")
                    }
                }
                HStack {
                    TextField("添加扩展", text: $newExtension, prompt: Text("粘贴 Chrome 应用商店链接或扩展 ID"))
                        .onSubmit(addExtension)
                    Button("添加", action: addExtension).disabled(newExtension.isEmpty)
                }
                if let extError { Text(extError).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("扩展库")
            } footer: {
                Text("添加后在环境的编辑表单或批量编辑里勾选，即可预装到对应环境。").font(.caption).foregroundStyle(.secondary)
            }
            Section("数据") {
                LabeledContent("数据目录") {
                    HStack {
                        Text(model.paths.root.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.paths.root]) }
                    }
                }
                Text("代理密码以明文保存在数据库里（文件权限仅本人可读），各环境保存的网站密码和 Cookie 也用公开密钥加密。请开启 FileVault。")
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
            extError = "没有找到有效的扩展 ID（32 个 a–p 的字母）"
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
