import Foundation

/// RFC 4180 风格的 CSV 编解码（支持引号、转义引号、字段内换行、CRLF、UTF-8 BOM）。
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")  // 保证最后一行被提交
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        return rows
    }

    public static func encode(_ rows: [[String]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || s.hasPrefix(" ") || s.hasSuffix(" ")
        else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
