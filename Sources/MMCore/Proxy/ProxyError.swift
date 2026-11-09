import Foundation

public enum ProxyError: Error, LocalizedError, Equatable {
    case timeout(String)
    case connectFailed(String)
    /// 上游要求认证，但没有配置账号密码
    case authRequired
    case authFailed
    /// 上游 SOCKS5 拒绝 CONNECT，带 RFC 1928 的应答码
    case upstreamRejected(UInt8)
    case httpStatus(Int, String)
    case protocolError(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .timeout(let what): L("error.proxy.timeout \(what)")
        case .connectFailed(let why): L("error.proxy.connectFailed \(why)")
        case .authRequired: L("error.proxy.authRequired")
        case .authFailed: L("error.proxy.authFailed")
        case .upstreamRejected(let code): L("error.proxy.rejected \(Int(code)) \(Self.socksReplyText(code))")
        case .httpStatus(let code, let line): L("error.proxy.httpStatus \(Int(code)) \(line)")
        case .protocolError(let why): L("error.proxy.protocol \(why)")
        case .closed: L("error.proxy.closed")
        }
    }

    static func socksReplyText(_ code: UInt8) -> String {
        switch code {
        case 1: L("error.proxy.reply.general")
        case 2: L("error.proxy.reply.notAllowed")
        case 3: L("error.proxy.reply.networkUnreachable")
        case 4: L("error.proxy.reply.hostUnreachable")
        case 5: L("error.proxy.reply.refused")
        case 6: L("error.proxy.reply.ttlExpired")
        case 7: L("error.proxy.reply.commandUnsupported")
        case 8: L("error.proxy.reply.addressUnsupported")
        default: L("error.proxy.reply.unknown")
        }
    }

    /// 转成返回给本地客户端（Chrome）的 SOCKS5 应答码。
    var socksReplyCode: UInt8 {
        switch self {
        case .upstreamRejected(let code): code
        case .connectFailed: 5
        case .timeout: 4
        case .httpStatus(let code, _) where code == 502 || code == 504: 4
        default: 1
        }
    }
}
