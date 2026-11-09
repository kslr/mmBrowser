import Foundation
import Testing
@testable import MMCore

@Suite("本地化资源")
struct L10nTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func strings(target: String, language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Sources/\(target)/Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    /// 按参数位置比较，允许译文用 %2$@ 等形式调整顺序。
    private func placeholders(_ text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"%(?:(\d+)\$)?([-+#0 ]*\d*(?:\.\d+)?(?:hh|ll|[hlqztj])?[@diuoxXfFeEgGaAcCsSp%])"#)
        let source = text as NSString
        var next = 1
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let type = source.substring(with: match.range(at: 2))
            guard type != "%" else { return nil }
            let position: Int
            if match.range(at: 1).location != NSNotFound {
                position = Int(source.substring(with: match.range(at: 1)))!
            } else {
                position = next
                next += 1
            }
            return "\(position):\(type)"
        }.sorted()
    }

    @Test("三份资源的 key 和占位符一致", arguments: ["MMCore", "mmctl", "MMApp"])
    func resourceParity(target: String) throws {
        let en = try strings(target: target, language: "en")
        let zh = try strings(target: target, language: "zh-Hans")
        #expect(Set(en.keys) == Set(zh.keys))
        for key in en.keys.sorted() {
            let translated = try #require(zh[key], "\(target): \(key)")
            #expect(try placeholders(en[key]!) == placeholders(translated), "\(target): \(key)")
            #expect(try placeholders(key) == placeholders(translated), "\(target): \(key)")
        }
    }

    @Test("插值能命中资源并保持参数类型", arguments: ["en", "zh-Hans"])
    func interpolation(language: String) throws {
        let resources = L10n.resourceBundle("mmBrowser_MMCore") { .module }
        let url = try #require(resources.url(forResource: language, withExtension: "lproj"))
        let bundle = try #require(Bundle(url: url))
        let text = String(localized: "error.store.proxyBound \(12) \("Alpha")", bundle: bundle)
        let expected = language == "en"
            ? "This proxy is already assigned to profile #12 “Alpha” (one profile per proxy)."
            : "这个代理已经绑定在环境 #12「Alpha」上（一个代理只能对应一个环境）"
        #expect(text == expected)
    }

    @Test("CSV 始终接受中英文表头和取值")
    func csvAliases() throws {
        let chinese = "名称,代理,语言,时区,定位权限,每次打开启动页\nA,直连,自动,自动,询问,是\n"
        let english = "name,proxy,language,timezone,geolocation,alwaysOpenStartURLs\nA,direct,auto,auto,ask,yes\n"
        let a = try #require(ProfileCSV.parseImport(chinese).first?.profile)
        let b = try #require(ProfileCSV.parseImport(english).first?.profile)
        #expect(a.allowDirect && b.allowDirect)
        #expect(a.language == LanguageTag.auto && b.language == LanguageTag.auto)
        #expect(a.timezone == nil && b.timezone == nil)
        #expect(a.geolocation == .ask && b.geolocation == .ask)
        #expect(a.alwaysOpenStartURLs && b.alwaysOpenStartURLs)
        for column in ProfileCSV.Column.allCases {
            #expect(ProfileCSV.Column.match(column.chineseAlias) == column)
            #expect(ProfileCSV.Column.match(column.rawValue) == column)
        }
    }
}
