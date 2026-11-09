import Foundation
import Testing
@testable import MMCore

@Suite("存储")
struct StoreTests {
    func makeStore() throws -> Store {
        try Store(inMemory: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }

    @Test func seqAndResolve() throws {
        let s = try makeStore()
        let a = try s.insert(Profile(name: "A"))
        let b = try s.insert(Profile(name: "B", tags: ["x"]))
        #expect(a.seq == 1 && b.seq == 2)
        #expect(try s.resolve("#2").id == b.id)
        #expect(try s.resolve("2").id == b.id)
        #expect(try s.resolve("A").id == a.id)
        #expect(try s.resolve(String(b.id.prefix(6))).id == b.id)
        #expect(try s.resolve("B").tags == ["x"])
        #expect(throws: StoreError.notFound("nope")) { try s.resolve("nope") }
    }

    @Test func proxyIsUniquePerProfile() throws {
        let s = try makeStore()
        let proxy = ProxyConfig(kind: .socks5, host: "Proxy.Example.com", port: 1080, username: "u", password: "1")
        let a = try s.insert(Profile(name: "A", proxy: proxy))
        var dup = proxy; dup.host = "proxy.example.com"; dup.password = "other"
        #expect(throws: StoreError.proxyAlreadyBound(profileName: "A", seq: 1)) {
            try s.insert(Profile(name: "B", proxy: dup))
        }
        // 同主机端口、不同用户名（很多代理商用用户名区分会话）是允许的
        var otherUser = proxy; otherUser.username = "u2"
        try s.insert(Profile(name: "C", proxy: otherUser))

        // 删除到回收站后代理释放；恢复时如果被占用就报错
        try s.softDelete(a.id)
        let b = try s.insert(Profile(name: "B", proxy: dup))
        #expect(throws: StoreError.proxyAlreadyBound(profileName: "B", seq: b.seq)) { try s.restore(a.id) }
    }

    @Test func exitInfoPersists() throws {
        let s = try makeStore()
        let a = try s.insert(Profile(name: "A"))
        let info = ExitInfo(ip: "203.0.113.5", countryCode: "US", timezone: "America/New_York", provider: "test")
        try s.recordExit(info, for: a.id)
        let back = try #require(try s.profile(id: a.id)?.lastExit)
        #expect(back.ip == info.ip && back.timezone == info.timezone)
        #expect(abs(back.checkedAt.timeIntervalSince(info.checkedAt)) < 0.01)
    }
}

@Suite("分组")
struct GroupTests {
    @Test func renameDeleteMove() throws {
        let s = try Store(inMemory: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let g = try s.group(named: "客户A")
        let h = try s.group(named: "客户B")
        #expect(try s.group(named: "客户A").id == g.id)
        let a = try s.insert(Profile(name: "a", groupId: g.id))
        let b = try s.insert(Profile(name: "b"))
        try s.move([b.id], toGroup: h.id)
        #expect(try s.profile(id: b.id)?.groupId == h.id)
        try s.renameGroup(g.id!, to: "客户A2")
        #expect(try s.groups().map(\.name) == ["客户A2", "客户B"])
        try s.deleteGroup(g.id!)
        #expect(try s.profile(id: a.id)?.groupId == nil)
    }
}

@Suite("检测页设置")
struct CheckPageTests {
    @Test func defaultAndSet() throws {
        let s = try Store(inMemory: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        #expect(s.checkPage == .preset(.browserscan) && s.checkPage.url == "https://www.browserscan.net/")
        try s.setCheckPage(.custom("https://my.check/"))
        #expect(s.checkPage.url == "https://my.check/")
        try s.setCheckPage(.none)
        #expect(s.checkPage.url == nil)
    }
}
