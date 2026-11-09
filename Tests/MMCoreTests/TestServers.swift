import Foundation
import Network
@testable import MMCore

/// 测试用的通用 TCP 服务器：只监听 127.0.0.1。
final class TestServer: @unchecked Sendable {
    let queue = DispatchQueue(label: "test.server")
    private var listener: NWListener!
    private(set) var port: UInt16 = 0
    private let handler: @Sendable (AsyncConnection) async -> Void

    init(handler: @escaping @Sendable (AsyncConnection) async -> Void) {
        self.handler = handler
    }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        let queue = self.queue
        let handler = self.handler
        listener.newConnectionHandler = { nw in
            Task {
                let c = AsyncConnection(nw, queue: queue)
                do { try await c.start(timeout: 5, label: "test") } catch { return }
                await handler(c)
                c.cancel()
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port!.rawValue
        return port
    }

    func stop() { listener?.cancel() }
}

/// 收到什么回什么，直到对端关闭。
func makeEchoServer() -> TestServer {
    TestServer { c in
        while let d = try? await c.receiveSome() {
            try? await c.send(d)
        }
        c.sendEOF()
    }
}

/// 记录上游收到的目标地址，用于断言"域名没有在本地解析"。
final class TargetRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _targets: [SocksTarget] = []
    func add(_ t: SocksTarget) { lock.withLock { _targets.append(t) } }
    var targets: [SocksTarget] { lock.withLock { _targets } }
}

/// 假的上游 SOCKS5：要求用户名密码认证，认证通过后直连目标。
func makeFakeSocks5Upstream(user: String, pass: String, recorder: TargetRecorder) -> TestServer {
    TestServer { c in
        do {
            let g = try await c.readExactly(2)
            let methods = try await c.readExactly(Int(g[1]))
            guard methods.contains(0x02) else { try await c.send(Data([5, 0xFF])); return }
            try await c.send(Data([5, 0x02]))
            _ = try await c.readExactly(1)
            let u = String(decoding: try await c.readExactly(Int(try await c.readExactly(1)[0])), as: UTF8.self)
            let p = String(decoding: try await c.readExactly(Int(try await c.readExactly(1)[0])), as: UTF8.self)
            guard u == user, p == pass else { try await c.send(Data([1, 1])); return }
            try await c.send(Data([1, 0]))
            let head = try await c.readExactly(4)
            let target = try await SocksTarget.read(atyp: head[3], from: c)
            recorder.add(target)
            let remote = try await Dialer(upstream: .direct).connect(to: target, queue: c.queue)
            try await c.send(LocalProxyServer.reply(0))
            _ = await LocalProxyServer.relay(c, remote)
        } catch {}
    }
}

/// 假的上游 HTTP 代理：要求 Basic 认证，只支持 CONNECT。
func makeFakeHTTPUpstream(user: String, pass: String, recorder: TargetRecorder) -> TestServer {
    TestServer { c in
        do {
            let header = String(decoding: try await c.readUntil(Data("\r\n\r\n".utf8), maxLength: 8192), as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            guard parts.count == 3, parts[0] == "CONNECT" else {
                try await c.send(Data("HTTP/1.1 405 Method Not Allowed\r\n\r\n".utf8)); return
            }
            let expected = "Proxy-Authorization: Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
            guard lines.contains(expected) else {
                try await c.send(Data("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n".utf8)); return
            }
            let authority = String(parts[1])
            let colon = authority.lastIndex(of: ":")!
            var host = String(authority[..<colon])
            if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
            let target = SocksTarget(host, port: UInt16(authority[authority.index(after: colon)...])!)
            recorder.add(target)
            let remote = try await Dialer(upstream: .direct).connect(to: target, queue: c.queue)
            try await c.send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
            _ = await LocalProxyServer.relay(c, remote)
        } catch {}
    }
}

/// 测试端的 SOCKS5 客户端（模拟 Chrome）。返回 (应答码, 连接)。
func socksConnect(localPort: UInt16, target: SocksTarget) async throws -> (UInt8, AsyncConnection) {
    let queue = DispatchQueue(label: "test.client")
    let nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!, using: .tcp)
    let c = AsyncConnection(nw, queue: queue)
    try await c.start(timeout: 5, label: "local")
    try await c.send(Data([5, 1, 0]))
    let m = try await c.readExactly(2)
    precondition(m == Data([5, 0]))
    var req = Data([5, 1, 0]); req.append(target.socksAddressBytes)
    try await c.send(req)
    let head = try await c.readExactly(4)
    _ = try await SocksTarget.read(atyp: head[3], from: c)
    return (head[1], c)
}
