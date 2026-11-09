import Foundation

/// 多行代理文本的批量解析（每行一个，空行和 # 开头的行忽略）。
public enum ProxyList {
    public struct Line: Sendable {
        public let lineNumber: Int
        public let text: String
        public let result: Result<ProxyConfig, ProxyParseError>
    }

    public static func parse(_ text: String, defaultKind: ProxyConfig.Kind = .socks5) -> [Line] {
        var out: [Line] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            do {
                out.append(Line(lineNumber: i + 1, text: s, result: .success(try ProxyConfig.parse(s, defaultKind: defaultKind))))
            } catch let e as ProxyParseError {
                out.append(Line(lineNumber: i + 1, text: s, result: .failure(e)))
            } catch {
                out.append(Line(lineNumber: i + 1, text: s, result: .failure(.invalidFormat(s))))
            }
        }
        return out
    }

    /// 只取解析成功的代理；如果有失败的行，抛出第一条错误（带行号）。
    public static func parseStrict(_ text: String, defaultKind: ProxyConfig.Kind = .socks5) throws -> [ProxyConfig] {
        let lines = parse(text, defaultKind: defaultKind)
        if let bad = lines.first(where: { if case .failure = $0.result { true } else { false } }),
           case .failure(let e) = bad.result {
            throw ImportError.badLine(bad.lineNumber, e.localizedDescription)
        }
        // 这一批内部重复也算错误
        var seen = Set<String>()
        for l in lines {
            if case .success(let p) = l.result {
                let key = "\(p.host.lowercased()):\(p.port):\(p.username ?? "")"
                if !seen.insert(key).inserted { throw ImportError.badLine(l.lineNumber, L("error.import.duplicateProxy \(p.displayString)")) }
            }
        }
        return lines.compactMap { try? $0.result.get() }
    }
}

public enum ImportError: Error, LocalizedError, Equatable {
    case badLine(Int, String)
    case missingColumn(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .badLine(let n, let why): L("error.import.badLine \(n) \(why)")
        case .missingColumn(let c): L("error.import.missingColumn \(c)")
        case .empty: L("error.import.empty")
        }
    }
}
