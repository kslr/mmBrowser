import Foundation
import Network

/// CONNECT 的目标地址。
public struct SocksTarget: Hashable, Sendable, CustomStringConvertible {
    public enum Host: Hashable, Sendable {
        case domain(String)
        case ipv4(Data)   // 4 字节
        case ipv6(Data)   // 16 字节
    }

    public var host: Host
    public var port: UInt16

    public init(host: Host, port: UInt16) {
        self.host = host
        self.port = port
    }

    public init(_ hostString: String, port: UInt16) {
        if let v4 = IPv4Address(hostString) {
            host = .ipv4(v4.rawValue)
        } else if let v6 = IPv6Address(hostString) {
            host = .ipv6(v6.rawValue)
        } else {
            host = .domain(hostString)
        }
        self.port = port
    }

    public var hostString: String {
        switch host {
        case .domain(let d): d
        case .ipv4(let b): IPv4Address(b).map { "\($0)" } ?? "?"
        case .ipv6(let b): IPv6Address(b).map { "\($0)" } ?? "?"
        }
    }

    /// `host:port`，IPv6 加方括号（HTTP CONNECT 和日志用）。
    public var authority: String {
        if case .ipv6 = host { return "[\(hostString)]:\(port)" }
        return "\(hostString):\(port)"
    }

    public var description: String { authority }

    var nwEndpoint: NWEndpoint {
        let h: NWEndpoint.Host = switch host {
        case .domain(let d): .name(d, nil)
        case .ipv4(let b): IPv4Address(b).map { .ipv4($0) } ?? .name(hostString, nil)
        case .ipv6(let b): IPv6Address(b).map { .ipv6($0) } ?? .name(hostString, nil)
        }
        return .hostPort(host: h, port: NWEndpoint.Port(rawValue: port)!)
    }

    /// SOCKS5 地址编码：ATYP + 地址 + 端口（大端）。域名原样交给上游解析，避免本地 DNS 泄漏。
    var socksAddressBytes: Data {
        var d = Data()
        switch host {
        case .ipv4(let b): d.append(0x01); d.append(b)
        case .domain(let s):
            let bytes = Data(s.utf8.prefix(255))
            d.append(0x03); d.append(UInt8(bytes.count)); d.append(bytes)
        case .ipv6(let b): d.append(0x04); d.append(b)
        }
        d.append(UInt8(port >> 8)); d.append(UInt8(port & 0xFF))
        return d
    }

    /// 从连接上读取 SOCKS5 地址（ATYP 已读出）。
    static func read(atyp: UInt8, from c: AsyncConnection) async throws -> SocksTarget {
        let host: Host
        switch atyp {
        case 0x01: host = .ipv4(try await c.readExactly(4))
        case 0x03:
            let len = Int(try await c.readExactly(1)[0])
            let raw = try await c.readExactly(len)
            guard let s = String(data: raw, encoding: .utf8), !s.isEmpty else {
                throw ProxyError.protocolError(L("error.proxy.domainEncoding"))
            }
            host = .domain(s)
        case 0x04: host = .ipv6(try await c.readExactly(16))
        default: throw ProxyError.protocolError(L("error.proxy.addressType \(Int(atyp))"))
        }
        let p = try await c.readExactly(2)
        return SocksTarget(host: host, port: UInt16(p[0]) << 8 | UInt16(p[1]))
    }
}
