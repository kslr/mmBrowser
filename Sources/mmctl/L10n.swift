import Foundation

/// mmctl 内嵌在 mmBrowser.app 的 Contents/MacOS 里运行，Bundle.main 就是 App；翻译在 App 的 mmctl 表里。
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, table: "mmctl", bundle: .main)
}
