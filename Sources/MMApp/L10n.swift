import Foundation
import MMCore

private let bundle = L10n.resourceBundle("mmBrowser_MMApp") { .module }

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: bundle)
}
