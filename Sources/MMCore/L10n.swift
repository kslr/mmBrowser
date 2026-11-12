import Foundation

public enum L10n {
    /// MMCore.framework 自己的资源（App、内嵌的 mmctl 和测试都从这里取 MMCore 的翻译）。
    public static let bundle = Bundle(for: BundleToken.self)
}

private final class BundleToken {}

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle)
}
