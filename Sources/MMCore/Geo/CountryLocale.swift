import Foundation

/// 按出口国家推荐浏览器语言（用户可以改）。
public enum CountryLocale {
    static let map: [String: String] = [
        "US": "en-US", "GB": "en-GB", "CA": "en-CA", "AU": "en-AU", "NZ": "en-NZ", "IE": "en-IE",
        "SG": "en-SG", "IN": "en-IN", "PH": "en-PH", "ZA": "en-ZA", "NG": "en-NG",
        "CN": "zh-CN", "TW": "zh-TW", "HK": "zh-HK", "MO": "zh-MO",
        "JP": "ja-JP", "KR": "ko-KR", "TH": "th-TH", "VN": "vi-VN", "ID": "id-ID", "MY": "ms-MY",
        "DE": "de-DE", "AT": "de-AT", "CH": "de-CH", "FR": "fr-FR", "BE": "fr-BE", "ES": "es-ES",
        "IT": "it-IT", "PT": "pt-PT", "NL": "nl-NL", "SE": "sv-SE", "NO": "nb-NO", "DK": "da-DK",
        "FI": "fi-FI", "PL": "pl-PL", "CZ": "cs-CZ", "GR": "el-GR", "RO": "ro-RO", "HU": "hu-HU",
        "UA": "uk-UA", "RU": "ru-RU", "TR": "tr-TR", "IL": "he-IL",
        "SA": "ar-SA", "AE": "ar-AE", "EG": "ar-EG",
        "BR": "pt-BR", "MX": "es-MX", "AR": "es-AR", "CO": "es-CO", "CL": "es-CL", "PE": "es-PE",
    ]

    public static func recommendedLanguage(for countryCode: String?) -> String? {
        guard let cc = countryCode?.uppercased() else { return nil }
        return map[cc]
    }

    /// `en-US` → `en-US,en`；`en` → `en`。用于 --accept-lang。
    public static func acceptLanguage(for language: String) -> String {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return base == language ? language : "\(language),\(base)"
    }

    /// `en-US` → `en_US`。用于 -AppleLocale。
    public static func appleLocale(for language: String) -> String {
        language.replacingOccurrences(of: "-", with: "_")
    }
}
