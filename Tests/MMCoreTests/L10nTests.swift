import Foundation
import Testing
@testable import MMCore

@Suite("本地化资源")
struct L10nTests {
    // catalog 的完整性和占位符一致性由 scripts/check-l10n.py 检查（CI 里也会跑）。

    @Test("插值能命中资源并保持参数类型", arguments: ["en", "zh-Hans"])
    func interpolation(language: String) throws {
        let url = try #require(L10n.bundle.url(forResource: language, withExtension: "lproj"))
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
