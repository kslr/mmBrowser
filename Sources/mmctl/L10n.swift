import Foundation
import MMCore

private let bundle = L10n.resourceBundle("mmBrowser_mmctl") { .module }

func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: bundle)
}
