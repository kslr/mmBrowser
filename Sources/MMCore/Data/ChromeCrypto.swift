import CommonCrypto
import CryptoKit
import Foundation

/// Chrome 在 `--use-mock-keychain` 下的加密（macOS OSCrypt "v10"）：
/// key = PBKDF2-HMAC-SHA1("mock_password", "saltysalt", 1003 次, 16 字节)，AES-128-CBC，IV 为 16 个空格，PKCS#7 填充。
enum ChromeCrypto {
    static let prefix = Data("v10".utf8)

    static let key: Data = {
        let password = Array("mock_password".utf8)
        let salt = Array("saltysalt".utf8)
        var out = [UInt8](repeating: 0, count: 16)
        let status = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &out, out.count)
        }
        precondition(status == kCCSuccess)
        return Data(out)
    }()

    static let iv = Data(repeating: 0x20, count: 16)

    enum CryptoError: Error { case badPrefix, cryptFailed(Int32) }

    static func decrypt(_ blob: Data) throws -> Data {
        guard blob.starts(with: prefix) else { throw CryptoError.badPrefix }
        return try aes(CCOperation(kCCDecrypt), Data(blob.dropFirst(3)))
    }

    static func encrypt(_ plain: Data) throws -> Data {
        prefix + (try aes(CCOperation(kCCEncrypt), plain))
    }

    private static func aes(_ op: CCOperation, _ input: Data) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress, i.baseAddress, input.count,
                                o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cryptFailed(status) }
        return out.prefix(moved)
    }

    /// Cookies 库版本 ≥ 24 时，明文前面加上 SHA256(host_key)，用来防止把一个域名的 cookie 挪给另一个域名。
    static func hostDigest(_ host: String) -> Data {
        Data(SHA256.hash(data: Data(host.utf8)))
    }
}
