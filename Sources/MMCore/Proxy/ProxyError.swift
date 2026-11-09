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
        case .timeout(let what): "超时：\(what)"
        case .connectFailed(let why): "连接失败：\(why)"
        case .authRequired: "上游代理要求认证，但没有配置账号密码"
        case .authFailed: "上游代理认证失败（账号或密码错误）"
        case .upstreamRejected(let code): "上游代理拒绝连接（SOCKS5 应答码 \(code)：\(Self.socksReplyText(code))）"
        case .httpStatus(let code, let line): "上游 HTTP 代理返回 \(code)：\(line)"
        case .protocolError(let why): "协议错误：\(why)"
        case .closed: "连接已关闭"
        }
    }

    static func socksReplyText(_ code: UInt8) -> String {
        switch code {
        case 1: "一般性失败"
        case 2: "规则不允许"
        case 3: "网络不可达"
        case 4: "主机不可达"
        case 5: "连接被拒绝"
        case 6: "TTL 过期"
        case 7: "不支持的命令"
        case 8: "不支持的地址类型"
        default: "未知"
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
