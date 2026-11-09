import AppKit
import Foundation
import GRDB
import MMCore
import Observation

/// 一个环境当前的运行状态。
enum RunState {
    case idle
    case launching(String)
    case running(RunningBrowser)
    /// 有 Chrome 在用这个环境目录，但不是本次应用启动的（比如上次应用异常退出）。它的本地代理入口已经不在了，等于断网。
    case orphan(Int32)
    case stopping

    var isActive: Bool {
        switch self {
        case .idle: false
        default: true
        }
    }
}

/// 侧栏选中的范围。
enum SidebarItem: Hashable {
    case all
    case running
    case ungrouped
    case group(Int64)
    case tag(String)
    case trash
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let paths: AppPaths
    private(set) var store: Store?
    private(set) var launcher: BrowserLauncher?
    private(set) var setupError: String?

    private(set) var profiles: [Profile] = []
    private(set) var trash: [Profile] = []
    private(set) var groups: [ProfileGroup] = []
    private(set) var states: [String: RunState] = [:]
    private(set) var lastError: [String: String] = [:]
    private(set) var checking: Set<String> = []
    var alert: AppAlert?

    private var observationTask: Task<Void, Never>?
    private var orphanTimer: Timer?

    init(paths: AppPaths = .default()) {
        self.paths = paths
        do {
            let store = try Store(paths: paths)
            self.store = store
            startObserving(store)
        } catch {
            setupError = "无法打开数据目录 \(paths.root.path)：\(error.localizedDescription)"
        }
        reloadChrome()
        scanOrphans()
        orphanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.scanOrphans() }
        }
    }

    // MARK: - 设置

    static let chromePathKey = "chromePath"
    static let defaultLanguageKey = "defaultLanguage"

    var defaultLanguage: String {
        UserDefaults.standard.string(forKey: Self.defaultLanguageKey) ?? "en-US"
    }

    func reloadChrome() {
        guard let store else { return }
        let path = UserDefaults.standard.string(forKey: Self.chromePathKey)
        let url = path.map { URL(fileURLWithPath: $0) } ?? ChromeInstallation.defaultExecutable
        do {
            launcher = BrowserLauncher(store: store, chrome: try ChromeInstallation(executable: url))
            if setupError?.hasPrefix("找不到 Google Chrome") == true { setupError = nil }
        } catch {
            launcher = nil
            setupError = error.localizedDescription
        }
    }

    var chromeVersion: String? { launcher?.chrome.version }

    // MARK: - 数据

    private func startObserving(_ store: Store) {
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                (try Profile.order(Column("seq")).fetchAll(db),
                 try ProfileGroup.order(Column("sortOrder"), Column("name")).fetchAll(db))
            }
            do {
                for try await (all, groups) in observation.values(in: store.db) {
                    self?.apply(all: all, groups: groups)
                }
            } catch {
                self?.alert = AppAlert(title: "数据库错误", message: error.localizedDescription)
            }
        }
    }

    private func apply(all: [Profile], groups: [ProfileGroup]) {
        profiles = all.filter { !$0.isDeleted }
        trash = all.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        self.groups = groups
    }

    /// 别的进程（比如 mmctl）改了数据库时，本进程的观察收不到，切回应用时手动刷新一次。
    func refreshFromDisk() {
        guard let store else { return }
        if let all = try? store.profiles(includeDeleted: true), let groups = try? store.groups() {
            apply(all: all, groups: groups)
        }
        scanOrphans()
    }

    var allTags: [String] {
        Array(Set(profiles.flatMap(\.tags))).sorted()
    }

    /// 和这个环境出口 IP 相同的其他环境（按最近一次检测结果）。一个 IP 对应多个环境时容易被关联。
    func sharedExitIP(_ p: Profile) -> [Profile] {
        guard let ip = p.lastExit?.ip else { return [] }
        return profiles.filter { $0.id != p.id && $0.lastExit?.ip == ip }
    }

    func groupName(_ id: Int64?) -> String? {
        guard let id else { return nil }
        return groups.first { $0.id == id }?.name
    }

    func state(of id: String) -> RunState { states[id] ?? .idle }

    var runningCount: Int { states.values.filter { if case .running = $0 { true } else { false } }.count }

    func profiles(in item: SidebarItem) -> [Profile] {
        switch item {
        case .all: profiles
        case .running: profiles.filter { state(of: $0.id).isActive }
        case .ungrouped: profiles.filter { $0.groupId == nil }
        case .group(let id): profiles.filter { $0.groupId == id }
        case .tag(let t): profiles.filter { $0.tags.contains(t) }
        case .trash: trash
        }
    }

    func profile(_ id: String) -> Profile? {
        profiles.first { $0.id == id } ?? trash.first { $0.id == id }
    }

    // MARK: - 启动 / 关闭

    func launch(_ ids: [String]) {
        for id in ids { launch(id) }
    }

    func launch(_ id: String) {
        guard let launcher else {
            alert = AppAlert(title: "无法启动", message: setupError ?? "没有找到 Google Chrome")
            return
        }
        switch state(of: id) {
        case .running(let r): r.activate(); return
        case .orphan(let pid): RunningBrowser.activate(pid: pid); return
        case .launching, .stopping: return
        case .idle: break
        }
        lastError[id] = nil
        states[id] = .launching("准备")
        Task {
            do {
                let running = try await launcher.launch(profileId: id, progress: { stage in
                    let text = switch stage {
                    case .startingProxy: "启动代理入口"
                    case .checkingExit: "检测出口"
                    case .exitChecked: "出口正常"
                    case .seeding: "写入配置"
                    case .initializing: "首次初始化"
                    case .startingChrome: "启动 Chrome"
                    }
                    Task { @MainActor in
                        if case .launching = AppModel.shared.state(of: id) { AppModel.shared.states[id] = .launching(text) }
                    }
                })
                states[id] = .running(running)
                running.onExit {
                    Task { @MainActor in AppModel.shared.browserExited(id) }
                }
            } catch {
                states[id] = nil
                lastError[id] = error.localizedDescription
                let name = profile(id).map { "#\($0.seq) \($0.name)" } ?? id
                alert = AppAlert(title: "\(name) 启动失败", message: error.localizedDescription)
            }
        }
    }

    private func browserExited(_ id: String) {
        if case .running = state(of: id) { states[id] = nil }
        if case .stopping = state(of: id) { states[id] = nil }
    }

    func stop(_ ids: [String]) {
        for id in ids { stop(id) }
    }

    func stop(_ id: String) {
        switch state(of: id) {
        case .running(let r):
            states[id] = .stopping
            Task {
                await r.terminate()
                if case .stopping = state(of: id) { states[id] = nil }
            }
        case .orphan(let pid):
            states[id] = .stopping
            Task {
                await RunningBrowser.terminateOrphan(pid: pid)
                states[id] = nil
            }
        default:
            break
        }
    }

    func activate(_ id: String) {
        switch state(of: id) {
        case .running(let r): r.activate()
        case .orphan(let pid): RunningBrowser.activate(pid: pid)
        default: break
        }
    }

    /// 关闭所有本应用启动的和残留的环境。
    func stopAll() async {
        let targets = states
        await withTaskGroup(of: Void.self) { group in
            for (_, s) in targets {
                switch s {
                case .running(let r): group.addTask { await r.terminate() }
                case .orphan(let pid): group.addTask { await RunningBrowser.terminateOrphan(pid: pid) }
                default: break
                }
            }
        }
        states.removeAll()
    }

    /// 发现不是本应用启动、但正在使用环境目录的 Chrome。
    func scanOrphans() {
        guard let launcher else { return }
        for p in profiles + trash {
            switch state(of: p.id) {
            case .idle:
                if let pid = launcher.runningPID(of: p.id) { states[p.id] = .orphan(pid) }
            case .orphan:
                if launcher.runningPID(of: p.id) == nil { states[p.id] = nil }
            default:
                break
            }
        }
    }

    // MARK: - 检测

    func check(_ id: String) {
        guard let store, let p = profile(id), !checking.contains(id) else { return }
        let upstream: Upstream
        if let proxy = p.proxy { upstream = .proxy(proxy) }
        else if p.allowDirect { upstream = .direct }
        else { alert = AppAlert(title: "无法检测", message: "这个环境没有配置代理"); return }
        checking.insert(id)
        Task {
            defer { checking.remove(id) }
            do {
                let info = try await GeoCheck.check(upstream: upstream)
                try store.recordExit(info, for: id)
                lastError[id] = nil
            } catch {
                lastError[id] = error.localizedDescription
                alert = AppAlert(title: "#\(p.seq) \(p.name) 检测失败", message: error.localizedDescription)
            }
        }
    }

    // MARK: - 编辑

    /// 保存（新建或更新）。返回保存后的环境；失败抛错由调用方展示。
    @discardableResult
    func save(_ profile: Profile, isNew: Bool) throws -> Profile {
        guard let store else { throw StoreError.notFound("数据库未打开") }
        if isNew { return try store.insert(profile) }
        try store.update(profile)
        return profile
    }

    func moveToTrash(_ ids: [String]) {
        guard let store else { return }
        for id in ids where !state(of: id).isActive {
            try? store.softDelete(id)
        }
        if ids.contains(where: { state(of: $0).isActive }) {
            alert = AppAlert(title: "部分环境未删除", message: "正在运行的环境需要先关闭。")
        }
    }

    func restore(_ ids: [String]) {
        guard let store else { return }
        var failures: [String] = []
        for id in ids {
            do { try store.restore(id) } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { alert = AppAlert(title: "部分环境无法恢复", message: failures.joined(separator: "\n")) }
    }

    func purge(_ ids: [String]) {
        guard let store else { return }
        for id in ids where !state(of: id).isActive {
            do { try store.purge(id) } catch {
                alert = AppAlert(title: "删除失败", message: error.localizedDescription)
            }
        }
    }

    func move(_ ids: [String], toGroup groupId: Int64?) {
        try? store?.move(ids, toGroup: groupId)
    }

    @discardableResult
    func createGroup(_ name: String) -> Int64? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do { return try store?.group(named: trimmed).id } catch {
            alert = AppAlert(title: "创建分组失败", message: error.localizedDescription)
            return nil
        }
    }

    func renameGroup(_ id: Int64, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do { try store?.renameGroup(id, to: trimmed) } catch {
            alert = AppAlert(title: "重命名失败", message: "可能已有同名分组。")
        }
    }

    func deleteGroup(_ id: Int64) {
        try? store?.deleteGroup(id)
    }

    func revealInFinder(_ id: String) {
        let dir = paths.profileDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            alert = AppAlert(title: "环境目录还不存在", message: "第一次启动后才会创建。")
        }
    }
}
