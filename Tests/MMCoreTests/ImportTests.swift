import Foundation
import Testing
@testable import MMCore

@Suite("导入导出与批量")
struct ImportTests {
    func makeStore() throws -> Store {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mmimp-\(UUID().uuidString)")
        return try Store(inMemory: AppPaths(root: root))
    }

    @Test func csvCodec() {
        let rows = [["a", "b,c", "d\"e"], ["多行\n文本", "", " 空格 "]]
        let text = CSV.encode(rows)
        #expect(CSV.parse(text) == rows)
        #expect(CSV.parse("\u{FEFF}x,y\r\n1,2") == [["x", "y"], ["1", "2"]])
        #expect(CSV.parse("a,b\n\n1,2\n") == [["a", "b"], ["1", "2"]])
    }

    @Test func proxyList() throws {
        let text = """
        # 注释
        socks5://u:p@1.1.1.1:1080

        2.2.2.2:8080:user:pass
        bad line
        """
        let lines = ProxyList.parse(text)
        #expect(lines.count == 3)
        #expect(lines[2].lineNumber == 5)
        #expect(throws: ImportError.badLine(5, ProxyParseError.invalidFormat("bad line").localizedDescription)) {
            try ProxyList.parseStrict(text)
        }
        #expect(try ProxyList.parseStrict("1.1.1.1:1\n1.1.1.1:1").count == 2)  // 同一代理可以分给多个环境
        #expect(try ProxyList.parseStrict("1.1.1.1:1\n1.1.1.1:2", defaultKind: .http).map(\.kind) == [.http, .http])
    }

    @Test("CSV 导出再导入，字段一致")
    func profileRoundTrip() throws {
        var p = Profile(name: "客户A, 01", proxy: ProxyConfig(kind: .http, host: "h.io", port: 8080, username: "u", password: "p,\"x"),
                        language: "ja-JP", timezone: "Asia/Tokyo", tags: ["广告", "重要"], notes: "多行\n备注")
        p.windowSize = WindowSize(width: 1440, height: 900)
        p.themeColor = "#112233"
        p.geolocation = .ask
        p.extraArgs = ["--force-dark-mode"]
        p.extensionIds = ["ddkjiahejlhfcafbddmgiahcphecmpfh"]
        p.proxyExpiresAt = ProfileCSV.parseDate("2026-12-31")
        let csv = ProfileCSV.export([p])
        let rows = try ProfileCSV.parseImport(csv)
        #expect(rows.count == 1)
        let q = rows[0].profile
        #expect(q.name == p.name && q.proxy == p.proxy && q.language == p.language && q.timezone == p.timezone)
        #expect(q.tags == p.tags && q.notes == p.notes)
        #expect(q.windowSize == p.windowSize && q.themeColor == "#112233" && q.geolocation == .ask)
        #expect(q.extraArgs == p.extraArgs && q.extensionIds == p.extensionIds)
        #expect(ProfileCSV.formatDate(q.proxyExpiresAt!) == "2026-12-31")
    }

    @Test("英文表头、最少列、错误带行号")
    func importVariants() throws {
        let rows = try ProfileCSV.parseImport("name,proxy,timezone\nA,1.2.3.4:1080,auto\nB,direct,\n", defaultLanguage: "zh-CN")
        #expect(rows.map(\.profile.name) == ["A", "B"])
        #expect(rows[0].profile.proxy?.port == 1080 && rows[0].profile.timezone == nil)
        #expect(rows[1].profile.allowDirect && rows[1].profile.language == "zh-CN")
        #expect(throws: ImportError.missingColumn(L("csv.requiredName"))) { try ProfileCSV.parseImport("proxy\n1.2.3.4:1\n") }
        #expect(throws: ImportError.badLine(3, L("error.csv.timezone \("Mars/Base")"))) { try ProfileCSV.parseImport("名称,时区\nA,UTC\nB,Mars/Base\n") }
        #expect(try ProfileCSV.parseImport("name,window\nA,1280×800\n")[0].profile.windowSize == WindowSize(width: 1280, height: 800))
        #expect(throws: ImportError.badLine(2, L("error.csv.window"))) { try ProfileCSV.parseImport("name,window\nA,300x200\n") }
    }

    @Test func extensionID() {
        #expect(ExtensionID.extract(from: "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=zh") == "ddkjiahejlhfcafbddmgiahcphecmpfh")
        #expect(ExtensionID.extract(from: "abc") == nil)
    }

    @Test("复制环境：连代理一起复制；回收站按天数清理")
    func duplicateAndTrash() throws {
        let s = try makeStore()
        var p = Profile(name: "src", proxy: ProxyConfig(kind: .socks5, host: "h", port: 1), tags: ["t"])
        p.language = "de-DE"
        let a = try s.insert(p)
        let b = try s.duplicate(a.id)
        #expect(b.name == L("profile.duplicateName \(a.name)") && b.proxy == a.proxy && b.tags == ["t"] && b.language == "de-DE" && b.seq == 2)

        try s.softDelete(b.id)
        #expect(try s.purgeTrash(olderThanDays: 30).isEmpty)
        #expect(try s.purgeTrash(olderThanDays: 30, now: Date().addingTimeInterval(31 * 86_400)) == [b.id])
        #expect(try s.profile(id: b.id) == nil)
    }

    @Test("复制环境目录时跳过缓存和锁文件")
    func copyData() throws {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent("mmsrc-\(UUID().uuidString)")
        let dst = fm.temporaryDirectory.appendingPathComponent("mmdst-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst) }
        try fm.createDirectory(at: src.appendingPathComponent("Default/Cache"), withIntermediateDirectories: true)
        try Data("c".utf8).write(to: src.appendingPathComponent("Default/Cookies"))
        try Data("x".utf8).write(to: src.appendingPathComponent("Default/Cache/big"))
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("SingletonLock").path, withDestinationPath: "host-1")
        try ProfileFiles.copyData(from: src, to: dst)
        #expect(fm.fileExists(atPath: dst.appendingPathComponent("Default/Cookies").path))
        #expect(!fm.fileExists(atPath: dst.appendingPathComponent("Default/Cache").path))
        #expect((try? fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("SingletonLock").path)) == nil)
    }
}

@Suite("Cookie 与备份")
struct DataTests {
    @Test("mock keychain 加解密往返")
    func crypto() throws {
        let plain = Data("hello 世界".utf8)
        let blob = try ChromeCrypto.encrypt(plain)
        #expect(blob.prefix(3) == Data("v10".utf8))
        #expect(try ChromeCrypto.decrypt(blob) == plain)
    }

    @Test("Cookie JSON 兼容多种写法")
    func cookieJSON() throws {
        let json = """
        [{"domain": ".a.com", "name": "x", "value": "1", "expirationDate": 1900000000, "sameSite": "no_restriction", "secure": true},
         {"domain": "b.com", "name": "y", "value": "2", "expires": -1, "sameSite": "Strict"},
         {"domain": "c.com", "name": "z", "value": "3", "hostOnly": false, "session": true}]
        """
        let c = try ChromeCookies.importJSON(Data(json.utf8))
        #expect(c[0].hostOnly == false && c[0].expirationDate == 1_900_000_000 && c[0].sameSite == "no_restriction")
        #expect(c[1].session && c[1].sameSite == "strict" && c[1].hostOnly)
        #expect(c[2].domain == ".c.com" && !c[2].hostOnly)
        let wrapped = try ChromeCookies.importJSON(Data("{\"cookies\": \(json)}".utf8))
        #expect(wrapped == c)
        #expect(try ChromeCookies.importJSON(try ChromeCookies.exportJSON(c)) == c)
    }

    @Test("备份导出再导入：新 id、代理和标签保留、数据目录跟着走（不含缓存）")
    func backupRoundTrip() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mmbk-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let store = try Store(paths: AppPaths(root: root))
        let proxy = ProxyConfig(kind: .socks5, host: "h", port: 1, username: "u", password: "p")
        var src = try store.insert(Profile(name: "源", proxy: proxy, tags: ["t"]))
        try store.recordOpened(src.id)
        src = try #require(try store.profile(id: src.id))
        let dir = store.paths.profileDir(src.id)
        try fm.createDirectory(at: dir.appendingPathComponent("Default/Cache"), withIntermediateDirectories: true)
        try Data("pw".utf8).write(to: dir.appendingPathComponent("Default/Login Data"))

        let file = root.appendingPathComponent("a.mmprofile")
        try ProfileBackup.export(profileId: src.id, store: store, isRunning: false, to: file)
        #expect(throws: ProfileBackup.BackupError.self) {
            try ProfileBackup.export(profileId: src.id, store: store, isRunning: true, to: file)
        }

        // 源环境还在，代理照样保留（一个代理可以给多个环境用）
        let r = try ProfileBackup.import(from: file, store: store)
        #expect(r.id != src.id && r.seq == 2 && r.name == "源")
        #expect(r.proxy == proxy)
        #expect(r.tags == ["t"])
        #expect(r.lastOpenedAt != nil)
        let newDir = store.paths.profileDir(r.id)
        #expect(try Data(contentsOf: newDir.appendingPathComponent("Default/Login Data")) == Data("pw".utf8))
        #expect(!fm.fileExists(atPath: newDir.appendingPathComponent("Default/Cache").path))
    }
}
