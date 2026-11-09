import Foundation

public enum L10n {
    /// 打包后的 App 和内嵌 mmctl 共用 Contents/Resources，开发时使用 SwiftPM 资源包。
    public static func resourceBundle(_ name: String, dev: () -> Bundle) -> Bundle {
        if let executable = Bundle.main.executableURL {
            let url = executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/\(name).bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return dev()
    }
}

private let bundle = L10n.resourceBundle("mmBrowser_MMCore") { .module }

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: bundle)
}
