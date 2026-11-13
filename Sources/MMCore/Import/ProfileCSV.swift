import Foundation

/// 环境 ⇄ CSV。导出用中文表头；导入同时认中文和英文表头，列的顺序随意，只有"名称"是必需的。
public enum ProfileCSV {
    enum Column: String, CaseIterable {
        case seq, name, tags, notes, proxy, proxyExpires, startURLs, alwaysOpenStartURLs
        case language, timezone, geolocation, window, color, extraArgs, extensions, exitIP, exitCountry

        var title: String {
            switch self {
            case .seq: L("csv.header.seq")
            case .name: L("csv.header.name")
            case .tags: L("csv.header.tags")
            case .notes: L("csv.header.notes")
            case .proxy: L("csv.header.proxy")
            case .proxyExpires: L("csv.header.proxyExpires")
            case .startURLs: L("csv.header.startURLs")
            case .alwaysOpenStartURLs: L("csv.header.alwaysOpenStartURLs")
            case .language: L("csv.header.language")
            case .timezone: L("csv.header.timezone")
            case .geolocation: L("csv.header.geolocation")
            case .window: L("csv.header.window")
            case .color: L("csv.header.color")
            case .extraArgs: L("csv.header.extraArgs")
            case .extensions: L("csv.header.extensions")
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
            case .startURLs: "启动页"
            case .alwaysOpenStartURLs: "每次打开启动页"
            case .language: "语言"
            case .timezone: "时区"
            case .geolocation: "定位权限"
            case .window: "窗口尺寸"
            case .color: "主题色"
            case .extraArgs: "启动参数"
            case .extensions: "扩展"
            case .exitIP: "出口IP"
            case .exitCountry: "出口国家"
            }
        }

        var aliases: [String] {
            [chineseAlias.lowercased(), rawValue.lowercased()] + {
                switch self {
                case .startURLs: ["start_urls", "urls", "url"]
                case .proxyExpires: ["proxy_expires", "expires"]
                case .extraArgs: ["extra_args", "args"]
                case .alwaysOpenStartURLs: ["always_open_start_urls"]
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
                case .startURLs: p.startURLs.joined(separator: " ")
                case .alwaysOpenStartURLs: p.alwaysOpenStartURLs ? L("csv.value.yes") : ""
                case .language: p.language
                case .timezone: p.timezone ?? "auto"
                case .geolocation: p.geolocation == .block ? L("csv.value.block") : L("csv.value.ask")
                case .window: p.windowWidth.map { "\($0)x\(p.windowHeight ?? 0)" } ?? ""
                case .color: p.themeColor ?? ""
                case .extraArgs: p.extraArgs.joined(separator: " ")
                case .extensions: p.extensionIds.joined(separator: ",")
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
        /// 文件里有没有扩展列。没有时由调用方套用默认扩展；有但为空表示明确不装。
        public var hasExtensionsColumn = true
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
            p.startURLs = v(.startURLs).split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "|" })
                .map(String.init).filter { !$0.isEmpty }
                .map { $0.contains("://") ? $0 : "https://\($0)" }
            p.alwaysOpenStartURLs = ["是", "true", "1", "yes", "y"].contains(v(.alwaysOpenStartURLs).lowercased())

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
                let wh = v(.window).lowercased().split(whereSeparator: { $0 == "x" || $0 == "*" || $0 == "×" }).compactMap { Int($0) }
                guard wh.count == 2, wh[0] >= 400, wh[1] >= 300 else { throw ImportError.badLine(line, L("error.csv.window")) }
                p.windowWidth = wh[0]; p.windowHeight = wh[1]
            }
            let color = v(.color)
            if !color.isEmpty {
                guard color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                    throw ImportError.badLine(line, L("error.csv.color"))
                }
                p.themeColor = color.uppercased()
            }
            p.extraArgs = v(.extraArgs).split(separator: " ").map(String.init).filter { !$0.isEmpty }
            p.extensionIds = v(.extensions).split(whereSeparator: { $0 == "," || $0 == " " })
                .map(String.init).filter(ExtensionID.isValid)

            rows.append(Row(profile: p, lineNumber: line, hasExtensionsColumn: index[.extensions] != nil))
        }
        guard !rows.isEmpty else { throw ImportError.empty }
        return rows
    }
}

/// Chrome 扩展 ID：32 个 a–p 的小写字母。
public enum ExtensionID {
    public static func isValid(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("a"..."p").contains($0) }
    }

    /// 从应用商店链接或纯 ID 里提取扩展 ID。
    public static func extract(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValid(t) { return t }
        for part in t.split(whereSeparator: { "/?#&=".contains($0) }) where isValid(String(part)) {
            return String(part)
        }
        return nil
    }
}
