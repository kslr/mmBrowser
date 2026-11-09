import MMCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppModel.chromePathKey) private var chromePath = ChromeInstallation.defaultExecutable.path
    @AppStorage(AppModel.defaultLanguageKey) private var defaultLanguage = "en-US"

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
            Section("新建环境") {
                HStack {
                    TextField("默认语言", text: $defaultLanguage)
                    Menu {
                        ForEach(LanguageOptions.codes, id: \.self) { code in
                            Button(LanguageOptions.label(code)) { defaultLanguage = code }
                        }
                    } label: { Image(systemName: "list.bullet") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
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
        .frame(width: 560, height: 380)
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
