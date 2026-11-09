import Foundation
import Network

/// 代理引擎的事件，用于日志和状态展示。
public enum ProxyEvent: Sendable {
    case tunnelOpened(SocksTarget, connectMs: Int)
    case tunnelFailed(SocksTarget?, String)
    case tunnelClosed(SocksTarget, bytesUp: Int, bytesDown: Int)
}

/// 本地 SOCKS5 入口：只监听 127.0.0.1，无认证，只支持 CONNECT，
/// 所有请求都转给配置好的上游。上游失败就把失败返回给浏览器，绝不回落到直连。
public final class LocalProxyServer: @unchecked Sendable {
    public let upstream: Upstream
    private let dialer: Dialer
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listener: NWListener?
    private var active: [ObjectIdentifier: AsyncConnection] = [:]
    private var _port: UInt16 = 0
    private var stopped = false
    private let onEvent: (@Sendable (ProxyEvent) -> Void)?

    public init(upstream: Upstream, onEvent: (@Sendable (ProxyEvent) -> Void)? = nil) {
        self.upstream = upstream
        self.dialer = Dialer(upstream: upstream)
        self.queue = DispatchQueue(label: "mmbrowser.proxy")
        self.onEvent = onEvent
    }

    public var port: UInt16 { lock.withLock { _port } }

    public var activeTunnelCount: Int { lock.withLock { active.count / 2 } }

    /// `socks5://127.0.0.1:<port>`，交给 Chrome 的 --proxy-server。
    public var proxyServerArgument: String { "socks5://127.0.0.1:\(port)" }

    /// 开始监听，返回分配到的端口。
    @discardableResult
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            Task { await self.handle(conn) }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                case .cancelled: if once.fire() { cont.resume(throwing: ProxyError.closed) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        guard let p = listener.port?.rawValue else { throw ProxyError.protocolError(L("error.proxy.noPort")) }
        lock.withLock {
            self.listener = listener
            self._port = p
        }
        return p
    }

    /// 停止监听并切断所有已建立的隧道。
    public func stop() {
        let (l, conns): (NWListener?, [AsyncConnection]) = lock.withLock {
            stopped = true
            let l = listener
            listener = nil
            let c = Array(active.values)
            active.removeAll()
            return (l, c)
        }
        l?.cancel()
        conns.forEach { $0.cancel() }
    }

    private func track(_ c: AsyncConnection) -> Bool {
        lock.withLock {
            if stopped { return false }
            active[ObjectIdentifier(c)] = c
            return true
        }
    }

    private func untrack(_ c: AsyncConnection) {
        _ = lock.withLock { active.removeValue(forKey: ObjectIdentifier(c)) }
    }

    // MARK: - 处理一个本地连接

    private func handle(_ nw: NWConnection) async {
        let client = AsyncConnection(nw, queue: queue)
        guard track(client) else { nw.cancel(); return }
        defer { client.cancel(); untrack(client) }

        var target: SocksTarget?
        do {
            try await client.start(timeout: 5, label: L("proxy.localClient"))
            client.armDeadline(10)
            target = try await readRequest(client)
            client.disarmDeadline()
        } catch ProxyError.protocolError(let why) {
            onEvent?(.tunnelFailed(nil, L("error.proxy.localHandshake \(why)")))
            return
        } catch {
            return  // 客户端没发完请求就断开或重置（Chrome 预建连接后放弃很常见），不算错误
        }
        guard let target else { return }

        let started = Date()
        let remote: AsyncConnection
        do {
            remote = try await dialer.connect(to: target, queue: queue)
        } catch {
            let code = (error as? ProxyError)?.socksReplyCode ?? 1
            try? await client.send(Self.reply(code))
            onEvent?(.tunnelFailed(target, error.localizedDescription))
            return
        }
        guard track(remote) else { remote.cancel(); return }
        defer { remote.cancel(); untrack(remote) }

        do {
            try await client.send(Self.reply(0))
        } catch {
            return
        }
        onEvent?(.tunnelOpened(target, connectMs: Int(Date().timeIntervalSince(started) * 1000)))
        let (up, down) = await Self.relay(client, remote)
        onEvent?(.tunnelClosed(target, bytesUp: up, bytesDown: down))
    }

    /// 读取 SOCKS5 问候和 CONNECT 请求。不支持的情况会先回应失败再抛错。
    private func readRequest(_ c: AsyncConnection) async throws -> SocksTarget {
        let greet = try await c.readExactly(2)
        guard greet[0] == 0x05 else { throw ProxyError.protocolError(L("error.proxy.notSocksRequest")) }
        let methods = try await c.readExactly(Int(greet[1]))
        guard methods.contains(0x00) else {
            try await c.send(Data([0x05, 0xFF]))
            throw ProxyError.protocolError(L("error.proxy.clientAuthentication"))
        }
        try await c.send(Data([0x05, 0x00]))

        let head = try await c.readExactly(4)
        guard head[0] == 0x05 else { throw ProxyError.protocolError(L("error.proxy.requestVersion")) }
        let target: SocksTarget
        do {
            target = try await SocksTarget.read(atyp: head[3], from: c)
        } catch {
            try? await c.send(Self.reply(8))
            throw error
        }
        guard head[1] == 0x01 else {
            try await c.send(Self.reply(7))
            throw ProxyError.protocolError(L("error.proxy.connectOnly \(Int(head[1]))"))
        }
        return target
    }

    static func reply(_ code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    /// 双向转发，支持半关闭。任何一边出错就两边一起断。返回 (上行字节, 下行字节)。
    static func relay(_ client: AsyncConnection, _ remote: AsyncConnection) async -> (Int, Int) {
        await withTaskGroup(of: (Bool, Int).self) { group in
            group.addTask { (true, await pump(from: client, to: remote)) }
            group.addTask { (false, await pump(from: remote, to: client)) }
            var up = 0, down = 0
            for await (isUp, n) in group {
                if isUp { up = n } else { down = n }
            }
            return (up, down)
        }
    }

    private static func pump(from src: AsyncConnection, to dst: AsyncConnection) async -> Int {
        var total = 0
        do {
            while true {
                guard let data = try await src.receiveSome() else {
                    dst.sendEOF()
                    return total
                }
                try await dst.send(data)
                total += data.count
            }
        } catch {
            src.cancel()
            dst.cancel()
            return total
        }
    }
}
