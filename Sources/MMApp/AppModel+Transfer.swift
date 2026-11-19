import AppKit
import Foundation
import MMCore
import UniformTypeIdentifiers

extension UTType {
    static let mmprofile = UTType(filenameExtension: ProfileBackup.fileExtension, conformingTo: .zip) ?? .zip
}

/// 导入导出：CSV、Cookie、环境备份。都要用户选文件，结果用弹窗汇报。
@MainActor
extension AppModel {
    func report(_ title: String, ok: Int, failed: [(String, String)] = [], extra: [String] = []) {
        var lines = extra
        if !failed.isEmpty {
            lines.append(L("report.failedHeader \(failed.count)"))
            lines += failed.prefix(20).map { L("report.failedItem \($0.0) \($0.1)") }
            if failed.count > 20 { lines.append(L("report.more \(failed.count - 20)")) }
        }
        alert = AppAlert(title: failed.isEmpty ? L("report.title \(title) \(ok)") : L("report.titleWithFailures \(title) \(ok) \(failed.count)"),
                         message: lines.joined(separator: "\n"))
    }

    // MARK: - CSV

    func exportCSV(_ ids: [String]) {
        let list = ids.compactMap(fresh).sorted { $0.seq < $1.seq }
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = L("export.csv.fileName \(Date().formatted(.iso8601.year().month().day()))")
        panel.message = L("export.csv.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // 带 BOM，Excel 打开中文不乱码
            try writePrivate(Data([0xEF, 0xBB, 0xBF]) + Data(ProfileCSV.export(list).utf8), to: url)
        } catch {
            alert = AppAlert(title: L("alert.exportFailed"), message: error.localizedDescription)
        }
    }

    /// 读取并解析 CSV（不入库），返回解析结果供确认。
    func pickCSVForImport() -> [ProfileCSV.Row]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return try ProfileCSV.parseImport(text, defaultLanguage: defaultLanguage)
        } catch {
            alert = AppAlert(title: L("alert.csvImportFailed"), message: error.localizedDescription)
            return nil
        }
    }

    /// 整批导入：要么全部入库，要么一个都不入库。
    func importCSV(_ rows: [ProfileCSV.Row]) {
        let items = rows.map(\.profile)
        guard let added = attempt(L("alert.csvImportFailed"), { try $0.insertMany(items) }) else { return }
        report(L("report.importCSV"), ok: added.count)
        autoCheck(added.map(\.id))
    }

    // MARK: - Cookie

    private func ensureStopped(_ id: String) -> Bool {
        if state(of: id).isActive {
            alert = AppAlert(title: L("alert.closeProfileFirst"), message: L("alert.closeProfileFirst.message"))
            return false
        }
        return true
    }

    func exportCookies(_ id: String) {
        guard let p = fresh(id), ensureStopped(id) else { return }
        do {
            let cookies = try ChromeCookies.read(userDataDir: paths.profileDir(id))
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(p.seq)-\(p.name)-cookies.json"
            panel.message = L("export.cookies.message \(cookies.count)")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try writePrivate(try ChromeCookies.exportJSON(cookies), to: url)
        } catch {
            alert = AppAlert(title: L("alert.exportCookiesFailed"), message: error.localizedDescription)
        }
    }

    func importCookies(_ id: String, replaceAll: Bool) {
        guard ensureStopped(id) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let cookies = try ChromeCookies.importJSON(try Data(contentsOf: url))
            let n = try ChromeCookies.write(cookies, userDataDir: paths.profileDir(id), replaceAll: replaceAll)
            alert = AppAlert(title: L("alert.cookiesImported \(n)"),
                             message: replaceAll ? L("alert.cookiesImported.replaced") : L("alert.cookiesImported.merged"))
        } catch {
            alert = AppAlert(title: L("alert.importCookiesFailed"), message: error.localizedDescription)
        }
    }

    /// 导出的文件里有密码或登录状态，只让当前用户读写。
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - 备份

    func exportBackups(_ ids: [String]) {
        guard let store else { return }
        let list = ids.compactMap(fresh).sorted { $0.seq < $1.seq }
        guard !list.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("export.backup.prompt")
        panel.message = L("export.backup.message")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            var failed: [(String, String)] = []
            for p in list {
                let safe = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let file = dir.appendingPathComponent("\(p.seq)-\(safe).\(ProfileBackup.fileExtension)")
                do {
                    try ProfileBackup.export(profileId: p.id, store: store, isRunning: state(of: p.id).isActive, to: file)
                } catch {
                    failed.append((p.numberedName, error.localizedDescription))
                }
            }
            report(L("report.exportBackups"), ok: list.count - failed.count, failed: failed, extra: [L("report.location \(dir.path)")])
        }
    }

    func importBackups() {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mmprofile, .zip]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            var added: [String] = []
            var failed: [(String, String)] = []
            for url in urls {
                do {
                    added.append(try ProfileBackup.import(from: url, store: store).id)
                } catch {
                    failed.append((url.lastPathComponent, error.localizedDescription))
                }
            }
            report(L("report.importBackups"), ok: added.count, failed: failed)
            autoCheck(added)
        }
    }
}
