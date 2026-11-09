import Foundation
import Testing
@testable import MMCore

@Suite("代理引擎", .serialized)
struct ProxyEngineTests {

    private func roundTrip(_ c: AsyncConnection, _ text: String) async throws -> String {
        try await c.send(Data(text.utf8))
        return String(decoding: try await c.readExactly(text.utf8.count), as: UTF8.self)
    }

    @Test("SOCKS5 上游（带认证）：数据往返，域名交给上游解析")
    func socks5Upstream() async throws {
        let echo = makeEchoServer(); let echoPort = try await echo.start()
        let rec = TargetRecorder()
        let up = makeFakeSocks5Upstream(user: "u1", pass: "p:@1", recorder: rec); let upPort = try await up.start()
        let server = LocalProxyServer(upstream: .proxy(ProxyConfig(kind: .socks5, host: "127.0.0.1", port: Int(upPort), username: "u1", password: "p:@1")))
        let port = try await server.start()
        defer { server.stop(); up.stop(); echo.stop() }

        let (code, c) = try await socksConnect(localPort: port, target: SocksTarget(host: .domain("localhost"), port: echoPort))
        #expect(code == 0)
        #expect(try await roundTrip(c, "hello socks5") == "hello socks5")
        let big = String(repeating: "x", count: 300_000)
        #expect(try await roundTrip(c, big) == big)
        c.cancel()
        #expect(rec.targets.first?.host == .domain("localhost"))
    }

    @Test("SOCKS5 上游密码错误：返回失败应答")
    func socks5WrongPassword() async throws {
        let rec = TargetRecorder()
        let up = makeFakeSocks5Upstream(user: "u1", pass: "right", recorder: rec); let upPort = try await up.start()
        let server = LocalProxyServer(upstream: .proxy(ProxyConfig(kind: .socks5, host: "127.0.0.1", port: Int(upPort), username: "u1", password: "wrong")))
        let port = try await server.start()
        defer { server.stop(); up.stop() }
        let (code, c) = try await socksConnect(localPort: port, target: SocksTarget("example.com", port: 443))
        #expect(code != 0)
        c.cancel()
        #expect(rec.targets.isEmpty)
    }

    @Test("SOCKS5 上游要求认证但没配置账号")
    func socks5MissingCredentials() async throws {
        let up = makeFakeSocks5Upstream(user: "u1", pass: "p", recorder: TargetRecorder()); let upPort = try await up.start()
        defer { up.stop() }
        let dialer = Dialer(upstream: .proxy(ProxyConfig(kind: .socks5, host: "127.0.0.1", port: Int(upPort))))
        await #expect(throws: ProxyError.authRequired) {
            _ = try await dialer.connect(to: SocksTarget("example.com", port: 443), queue: DispatchQueue(label: "t"))
        }
    }

    @Test("HTTP 上游（带认证）：数据往返")
    func httpUpstream() async throws {
        let echo = makeEchoServer(); let echoPort = try await echo.start()
        let rec = TargetRecorder()
        let up = makeFakeHTTPUpstream(user: "hu", pass: "hp", recorder: rec); let upPort = try await up.start()
        let server = LocalProxyServer(upstream: .proxy(ProxyConfig(kind: .http, host: "127.0.0.1", port: Int(upPort), username: "hu", password: "hp")))
        let port = try await server.start()
        defer { server.stop(); up.stop(); echo.stop() }

        let (code, c) = try await socksConnect(localPort: port, target: SocksTarget(host: .domain("localhost"), port: echoPort))
        #expect(code == 0)
        #expect(try await roundTrip(c, "hello http") == "hello http")
        c.cancel()
        #expect(rec.targets.first?.authority == "localhost:\(echoPort)")
    }

    @Test("HTTP 上游密码错误：Dialer 报认证失败，本地返回失败应答")
    func httpWrongPassword() async throws {
        let up = makeFakeHTTPUpstream(user: "hu", pass: "hp", recorder: TargetRecorder()); let upPort = try await up.start()
        defer { up.stop() }
        let cfg = ProxyConfig(kind: .http, host: "127.0.0.1", port: Int(upPort), username: "hu", password: "bad")
        await #expect(throws: ProxyError.authFailed) {
            _ = try await Dialer(upstream: .proxy(cfg)).connect(to: SocksTarget("example.com", port: 443), queue: DispatchQueue(label: "t"))
        }
        let server = LocalProxyServer(upstream: .proxy(cfg))
        let port = try await server.start()
        defer { server.stop() }
        let (code, c) = try await socksConnect(localPort: port, target: SocksTarget("example.com", port: 443))
        #expect(code != 0)
        c.cancel()
    }

    @Test("上游不可达：快速失败，不回落直连")
    func upstreamUnreachable() async throws {
        let echo = makeEchoServer(); let echoPort = try await echo.start()
        defer { echo.stop() }
        // 拿一个端口然后关掉，保证没人监听
        let tmp = makeEchoServer(); let deadPort = try await tmp.start(); tmp.stop()
        try await Task.sleep(for: .milliseconds(100))
        let server = LocalProxyServer(upstream: .proxy(ProxyConfig(kind: .socks5, host: "127.0.0.1", port: Int(deadPort))))
        let port = try await server.start()
        defer { server.stop() }
        let started = Date()
        let (code, c) = try await socksConnect(localPort: port, target: SocksTarget("127.0.0.1", port: echoPort))
        #expect(code == 5)
        #expect(Date().timeIntervalSince(started) < 5)
        c.cancel()
    }

    @Test("stop() 切断已建立的隧道，并拒绝新连接")
    func stopCutsTunnels() async throws {
        let echo = makeEchoServer(); let echoPort = try await echo.start()
        let server = LocalProxyServer(upstream: .direct)
        let port = try await server.start()
        defer { echo.stop() }
        let (code, c) = try await socksConnect(localPort: port, target: SocksTarget("127.0.0.1", port: echoPort))
        #expect(code == 0)
        #expect(try await roundTrip(c, "before") == "before")
        #expect(server.activeTunnelCount == 1)

        server.stop()
        // 已有隧道：再读应当得到 EOF 或错误
        try? await c.send(Data("after".utf8))
        let after = try? await c.receiveSome()
        #expect(after == nil || after == Optional(Data()))
        c.cancel()
        // 新连接：应当连不上
        await #expect(throws: (any Error).self) {
            _ = try await socksConnect(localPort: port, target: SocksTarget("127.0.0.1", port: echoPort))
        }
    }
}
