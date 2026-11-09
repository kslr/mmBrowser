import Foundation
import Network

/// 本地入口把 CONNECT 请求交给哪里。
public enum Upstream: Sendable, Hashable {
    case proxy(ProxyConfig)
    /// 显式直连（环境必须打开 allowDirect 才会用到）
    case direct
}

struct Dialer: Sendable {
    let upstream: Upstream
    var connectTimeout: TimeInterval = 10
    var handshakeTimeout: TimeInterval = 15

    /// 建立到 target 的隧道，返回可以直接双向转发的连接。
    func connect(to target: SocksTarget, queue: DispatchQueue) async throws -> AsyncConnection {
        switch upstream {
        case .direct:
            let c = AsyncConnection(NWConnection(to: target.nwEndpoint, using: .tcp), queue: queue)
            try await c.start(timeout: connectTimeout, label: target.authority)
            return c
        case .proxy(let cfg):
            let endpoint = NWEndpoint.hostPort(host: .init(cfg.host), port: NWEndpoint.Port(rawValue: UInt16(cfg.port))!)
            let c = AsyncConnection(NWConnection(to: endpoint, using: .tcp), queue: queue)
            try await c.start(timeout: connectTimeout, label: L("proxy.upstream \(cfg.host) \(cfg.port)"))
            c.armDeadline(handshakeTimeout)
            do {
                switch cfg.kind {
                case .socks5: try await Self.socks5Handshake(c, cfg: cfg, target: target)
                case .http: try await Self.httpConnectHandshake(c, cfg: cfg, target: target)
                }
                c.disarmDeadline()
                return c
            } catch {
                let timedOut = c.deadlineFired
                c.cancel()
                if timedOut { throw ProxyError.timeout(L("proxy.handshake")) }
                throw error
            }
        }
    }

    // MARK: SOCKS5（RFC 1928 / RFC 1929）

    static func socks5Handshake(_ c: AsyncConnection, cfg: ProxyConfig, target: SocksTarget) async throws {
        let methods: [UInt8] = cfg.hasCredentials ? [0x00, 0x02] : [0x00]
        try await c.send(Data([0x05, UInt8(methods.count)] + methods))
        let choice = try await c.readExactly(2)
        guard choice[0] == 0x05 else { throw ProxyError.protocolError(L("error.proxy.notSocks")) }
        switch choice[1] {
        case 0x00:
            break
        case 0x02:
            guard let user = cfg.username else { throw ProxyError.authRequired }
            let u = Data(user.utf8.prefix(255))
            let p = Data((cfg.password ?? "").utf8.prefix(255))
            var auth = Data([0x01, UInt8(u.count)]); auth.append(u)
            auth.append(UInt8(p.count)); auth.append(p)
            try await c.send(auth)
            let status = try await c.readExactly(2)
            guard status[1] == 0x00 else { throw ProxyError.authFailed }
        case 0xFF:
            throw cfg.hasCredentials ? ProxyError.authFailed : ProxyError.authRequired
        default:
            throw ProxyError.protocolError(L("error.proxy.authenticationMethod \(Int(choice[1]))"))
        }

        var req = Data([0x05, 0x01, 0x00])
        req.append(target.socksAddressBytes)
        try await c.send(req)
        let head = try await c.readExactly(4)
        guard head[0] == 0x05 else { throw ProxyError.protocolError(L("error.proxy.replyVersion")) }
        guard head[1] == 0x00 else { throw ProxyError.upstreamRejected(head[1]) }
        _ = try await SocksTarget.read(atyp: head[3], from: c)  // 丢弃 BND.ADDR / BND.PORT
    }

    // MARK: HTTP CONNECT

    static func httpConnectHandshake(_ c: AsyncConnection, cfg: ProxyConfig, target: SocksTarget) async throws {
        var req = "CONNECT \(target.authority) HTTP/1.1\r\nHost: \(target.authority)\r\n"
        if let user = cfg.username {
            let token = Data("\(user):\(cfg.password ?? "")".utf8).base64EncodedString()
            req += "Proxy-Authorization: Basic \(token)\r\n"
        }
        req += "Proxy-Connection: Keep-Alive\r\n\r\n"
        try await c.send(Data(req.utf8))

        let header = try await c.readUntil(Data("\r\n\r\n".utf8), maxLength: 16 * 1024)
        let text = String(decoding: header, as: UTF8.self)
        let statusLine = text.components(separatedBy: "\r\n").first ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw ProxyError.protocolError(L("error.proxy.notHTTP \(String(statusLine.prefix(80)))"))
        }
        switch code {
        case 200..<300: return
        case 407: throw cfg.hasCredentials ? ProxyError.authFailed : ProxyError.authRequired
        default: throw ProxyError.httpStatus(code, statusLine)
        }
    }
}
