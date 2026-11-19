import Foundation

/// 环境 ⇄ CSV。导出用中文表头；导入同时认中文和英文表头，列的顺序随意，只有"名称"是必需的。
public enum ProfileCSV {
    enum Column: String, CaseIterable {
        case seq, name, tags, notes, proxy, proxyExpires
        case language, timezone, geolocation, window, color, extraArgs, exitIP, exitCountry

        var title: String {
            switch self {
            case .seq: L("csv.header.seq")
            case .name: L("csv.header.name")
            case .tags: L("csv.header.tags")
            case .notes: L("csv.header.notes")
            case .proxy: L("csv.header.proxy")
            case .proxyExpires: L("csv.header.proxyExpires")
            case .language: L("csv.header.language")
            case .timezone: L("csv.header.timezone")
            case .geolocation: L("csv.header.geolocation")
            case .window: L("csv.header.window")
            case .color: L("csv.header.color")
            case .extraArgs: L("csv.header.extraArgs")
            case .exitIP: L("csv.header.exitIP")
            case .exitCountry: L("csv.header.exitCountry")
            }
        }

        var chineseAlias: String {
            switch self {
            case .seq: "序号"
            case .name: "名称"
            case .tags: "标签"
            case .notes: "备注"
            case .proxy: "代理"
            case .proxyExpires: "代理到期"
            case .language: "语言"
            case .timezone: "时区"
            case .geolocation: "定位权限"
            case .window: "窗口尺寸"
            case .color: "主题色"
            case .extraArgs: "启动参数"
            case .exitIP: "出口IP"
            case .exitCountry: "出口国家"
            }
        }

        var aliases: [String] {
            [chineseAlias.lowercased(), rawValue.lowercased()] + {
                switch self {
                case .proxyExpires: ["proxy_expires", "expires"]
                case .extraArgs: ["extra_args", "args"]
                case .exitIP: ["exit_ip", "ip"]
                case .exitCountry: ["exit_country", "country"]
                default: []
                }
            }()
        }

        static func match(_ header: String) -> Column? {
            let h = header.trimmingCharacters(in: .whitespaces).lowercased()
            return allCases.first { $0.aliases.contains(h) }
        }
    }

    static func formatDate(_ d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func parseDate(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// 导出（包含代理密码，文件要妥善保管）。
    public static func export(_ profiles: [Profile]) -> String {
        var rows = [Column.allCases.map(\.title)]
        for p in profiles {
            rows.append(Column.allCases.map { col in
                switch col {
                case .seq: String(p.seq)
                case .name: p.name
                case .tags: p.tags.joined(separator: ",")
                case .notes: p.notes
                case .proxy: p.proxy?.urlString ?? (p.allowDirect ? "direct" : "")
                case .proxyExpires: p.proxyExpiresAt.map(formatDate) ?? ""
                case .language: p.language
                case .timezone: p.timezone ?? "auto"
                case .geolocation: p.geolocation == .block ? L("csv.value.block") : L("csv.value.ask")
                case .window: p.windowSize?.description ?? ""
                case .color: p.themeColor ?? ""
                case .extraArgs: p.extraArgs.joined(separator: " ")
                case .exitIP: p.lastExit?.ip ?? ""
                case .exitCountry: p.lastExit?.countryCode ?? ""
                }
            })
        }
        return CSV.encode(rows)
    }

    /// 导入解析出的一行：环境（未入库）和它在文件里的行号。
    public struct Row: Sendable {
        public var profile: Profile
        public let lineNumber: Int
    }

    /// 解析 CSV。任何一行有错都会抛出（带行号），不做部分导入，避免导入一半。
    public static func parseImport(_ text: String, defaultLanguage: String = LanguageTag.auto) throws -> [Row] {
        let table = CSV.parse(text)
        guard let header = table.first else { throw ImportError.empty }
        var index: [Column: Int] = [:]
        for (i, h) in header.enumerated() {
            if let c = Column.match(h), index[c] == nil { index[c] = i }
        }
        guard index[.name] != nil else { throw ImportError.missingColumn(L("csv.requiredName")) }

        var rows: [Row] = []
        for (r, cells) in table.dropFirst().enumerated() {
            let line = r + 2
            func v(_ c: Column) -> String {
                guard let i = index[c], i < cells.count else { return "" }
                return cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if cells.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            let name = v(.name)
            guard !name.isEmpty else { throw ImportError.badLine(line, L("error.csv.emptyName")) }

            var p = Profile(name: name, language: defaultLanguage)
            p.tags = v(.tags).split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            p.notes = v(.notes)

            let proxy = v(.proxy)
            if proxy.lowercased() == "direct" || proxy == "直连" {
                p.allowDirect = true
            } else if !proxy.isEmpty {
                do { p.proxy = try ProxyConfig.parse(proxy) } catch {
                    throw ImportError.badLine(line, error.localizedDescription)
                }
            }
            if !v(.proxyExpires).isEmpty {
                guard let d = parseDate(v(.proxyExpires)) else { throw ImportError.badLine(line, L("error.csv.proxyExpires")) }
                p.proxyExpiresAt = d
            }
            if !v(.language).isEmpty {
                let lang = ["自动", "auto"].contains(v(.language).lowercased()) ? LanguageTag.auto : v(.language)
                guard LanguageTag.isValidSetting(lang) else { throw ImportError.badLine(line, L("error.csv.language \(v(.language))")) }
                p.language = lang
            }
            let tz = v(.timezone)
            if !tz.isEmpty, tz.lowercased() != "auto", tz != "自动" {
                guard TimeZone(identifier: tz) != nil else { throw ImportError.badLine(line, L("error.csv.timezone \(tz)")) }
                p.timezone = tz
            }
            switch v(.geolocation).lowercased() {
            case "", "禁止", "block": p.geolocation = .block
            case "询问", "ask": p.geolocation = .ask
            default: throw ImportError.badLine(line, L("error.csv.geolocation"))
            }
            if !v(.window).isEmpty {
                guard let size = WindowSize(v(.window)) else { throw ImportError.badLine(line, L("error.csv.window")) }
                p.windowSize = size
            }
            if !v(.color).isEmpty {
                guard let color = ThemePalette.parse(v(.color)) else { throw ImportError.badLine(line, L("error.csv.color")) }
                p.themeColor = color
            }
            p.extraArgs = v(.extraArgs).split(separator: " ").map(String.init).filter { !$0.isEmpty }

            rows.append(Row(profile: p, lineNumber: line))
        }
        guard !rows.isEmpty else { throw ImportError.empty }
        return rows
    }
}
