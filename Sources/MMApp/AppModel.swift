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
        if case .idle = self { false } else { true }
    }

    /// 有窗口可以切到前台的 Chrome 进程。
    var pid: Int32? {
        switch self {
        case .running(let r): r.pid
        case .orphan(let pid): pid
        default: nil
        }
    }
}

/// 一个环境最近一次失败的操作。
enum Failure {
    case launch(String)
    case check(String)

    var message: String {
        switch self {
        case .launch(let why): why
        case .check(let why): L("list.checkFailed \(why)")
        }
    }
}

/// 侧栏选中的范围。
enum SidebarItem: Hashable {
    case all
    case running
    case untagged
    case tag(String)
    case proxies
    case trash
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension LaunchStage {
    var text: String {
        switch self {
        case .startingProxy: L("launch.stage.startingProxy")
        case .checkingExit: L("launch.stage.checkingExit")
        case .exitChecked: L("launch.stage.exitChecked")
        case .seeding: L("launch.stage.seeding")
        case .installingExtensions: L("launch.stage.installingExtensions")
        case .warning(let w): w
        case .startingChrome: L("launch.stage.startingChrome")
        }
    }
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
    private(set) var states: [String: RunState] = [:]
    var failures: [String: Failure] = [:]
    var checking: Set<String> = []
    var alert: AppAlert?
    /// 扩展库（全局）：新建环境时自动装上里面的全部扩展
    var extensionLibrary: [ExtensionEntry] = []

    private var observationTask: Task<Void, Never>?
    private var orphanTimer: Timer?

    init(paths: AppPaths = .default()) {
        self.paths = paths
        do {
            let store = try Store(paths: paths)
            self.store = store
            startObserving(store)
            loadExtensionLibrary()
        } catch {
            setupError = L("alert.dataDirectory \(paths.root.path) \(error.localizedDescription)")
        }
        reloadChrome()
        purgeOldTrash()
        scanOrphans()
        orphanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanOrphans() }
        }
    }

    /// 执行一个要用到数据库的操作，失败时弹窗（标题是 failureTitle）。数据库没打开时什么都不做。
    @discardableResult
    func attempt<T>(_ failureTitle: String, _ body: (Store) throws -> T) -> T? {
        guard let store else { return nil }
        do {
            return try body(store)
        } catch {
            alert = AppAlert(title: failureTitle, message: error.localizedDescription)
            return nil
        }
    }

    func purgeOldTrash() {
        guard let store else { return }
        let ids = (try? store.purgeTrash(olderThanDays: trashRetentionDays)) ?? []
        if !ids.isEmpty { refreshFromDisk() }
    }

    // MARK: - 设置

    static let chromePathKey = "chromePath"
    static let defaultLanguageKey = "defaultLanguage"
    static let maxRunningKey = "maxRunning"
    static let trashDaysKey = "trashRetentionDays"

    var maxRunning: Int {
        let v = UserDefaults.standard.integer(forKey: Self.maxRunningKey)
        return v > 0 ? v : 10
    }

    var trashRetentionDays: Int {
        let v = UserDefaults.standard.integer(forKey: Self.trashDaysKey)
        return v > 0 ? v : 30
    }

    var defaultLanguage: String {
        UserDefaults.standard.string(forKey: Self.defaultLanguageKey) ?? LanguageTag.auto
    }

    func reloadChrome() {
        guard let store else { return }
        let path = UserDefaults.standard.string(forKey: Self.chromePathKey)
        let url = path.map { URL(fileURLWithPath: $0) } ?? ChromeInstallation.defaultExecutable
        do {
            launcher = BrowserLauncher(store: store, chrome: try ChromeInstallation(executable: url))
            setupError = nil
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
                try Profile.order(Column("seq")).fetchAll(db)
            }
            do {
                for try await all in observation.values(in: store.db) {
                    self?.apply(all: all)
                }
            } catch {
                self?.alert = AppAlert(title: L("alert.databaseError"), message: error.localizedDescription)
            }
        }
    }

    private func apply(all: [Profile]) {
        profiles = all.filter { !$0.isDeleted }
        trash = all.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// 别的进程（比如 mmctl）改了数据库时，本进程的观察收不到，切回应用时手动刷新一次。
    /// 本进程内的写入不要调用它：数据库观察会按顺序推送最终状态，手动刷新反而可能被随后到达的旧推送覆盖。
    func refreshFromDisk() {
        guard let store else { return }
        if let all = try? store.profiles(.all) {
            apply(all: all)
        }
        scanOrphans()
    }

    /// 直接从数据库读最新的环境。按 id 执行操作时用它，不依赖内存列表
    /// （数据库观察是异步推送的，批量写入后内存列表可能短暂落后）。
    func fresh(_ id: String) -> Profile? {
        try? store?.profile(id: id)
    }

    /// 内存列表里的环境（含回收站），界面展示用。
    func profile(_ id: String) -> Profile? {
        profiles.first { $0.id == id } ?? trash.first { $0.id == id }
    }

    var allTags: [String] {
        Array(Set(profiles.flatMap(\.tags))).sorted()
    }

    /// 按使用的环境数从多到少排，作为标签输入框下面的候选
    var tagsByUsage: [String] {
        Self.byUsage(profiles.flatMap(\.tags)).map(\.tag)
    }

    /// 标签和出现次数，次数多的在前，同样多的按名称排。
    static func byUsage(_ tags: [String]) -> [(tag: String, count: Int)] {
        tags.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .map { (tag: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.tag) > ($1.count, $0.tag) }
    }

    /// 和这个环境出口 IP 相同的其他环境（按最近一次检测结果）。一个 IP 对应多个环境时容易被关联。
    func sharedExitIP(_ p: Profile) -> [Profile] {
        guard let ip = p.lastExit?.ip else { return [] }
        return profiles.filter { $0.id != p.id && $0.lastExit?.ip == ip }
    }

    /// 已过期或 days 天内到期的代理。
    func expiringProxies(within days: Int = 7) -> [Profile] {
        let limit = Date().addingTimeInterval(Double(days) * 86_400)
        return profiles.filter { $0.proxy != nil && ($0.proxyExpiresAt.map { $0 <= limit } ?? false) }
            .sorted { ($0.proxyExpiresAt ?? .distantFuture) < ($1.proxyExpiresAt ?? .distantFuture) }
    }

    func state(of id: String) -> RunState { states[id] ?? .idle }

    func profiles(in item: SidebarItem) -> [Profile] {
        switch item {
        case .all, .proxies: profiles
        case .running: profiles.filter { state(of: $0.id).isActive }
        case .untagged: profiles.filter { $0.tags.isEmpty }
        case .tag(let t): profiles.filter { $0.tags.contains(t) }
        case .trash: trash
        }
    }

    // MARK: - 启动 / 关闭

    /// 批量启动。已经在运行的切到前台；超过"同时运行上限"的部分不启动，并提示。
    func launch(_ ids: [String]) {
        ids.filter { state(of: $0).isActive }.forEach(activate)
        let toStart = ids.filter { !state(of: $0).isActive }
        let room = max(0, maxRunning - states.values.filter(\.isActive).count)
        for id in toStart.prefix(room) { launch(id) }
        if toStart.count > room {
            alert = AppAlert(title: L("alert.runningLimit.title \(maxRunning)"),
                             message: L("alert.runningLimit.message \(toStart.count - room)"))
        }
    }

    /// 启动一个环境；已经在运行就切到前台。
    func launch(_ id: String) {
        guard let launcher else {
            alert = AppAlert(title: L("alert.cannotLaunch"), message: setupError ?? L("alert.chromeNotFound"))
            return
        }
        guard case .idle = state(of: id) else { activate(id); return }
        failures[id] = nil
        states[id] = .launching(L("launch.stage.preparing"))
        Task {
            do {
                let running = try await launcher.launch(profileId: id, progress: { stage in
                    Task { @MainActor in
                        if case .launching = self.state(of: id) { self.states[id] = .launching(stage.text) }
                    }
                })
                states[id] = .running(running)
                refreshExtensionNames()
                running.onExit {
                    Task { @MainActor in self.browserExited(id) }
                }
            } catch {
                states[id] = nil
                failures[id] = .launch(error.localizedDescription)
                let name = profile(id)?.numberedName ?? id
                alert = AppAlert(title: L("alert.launchFailed \(name)"), message: error.localizedDescription)
            }
        }
    }

    private func browserExited(_ id: String) {
        switch state(of: id) {
        case .running, .stopping: states[id] = nil
        default: break
        }
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
        if let pid = state(of: id).pid { RunningBrowser.activate(pid: pid) }
    }

    /// 关闭所有本应用启动的和残留的环境。
    func stopAll() async {
        let targets = states.values
        await withTaskGroup(of: Void.self) { group in
            for s in targets {
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
        for p in profiles + trash {
            switch state(of: p.id) {
            case .idle:
                if let pid = ProfileLock.runningPID(paths.profileDir(p.id)) { states[p.id] = .orphan(pid) }
            case .orphan:
                if ProfileLock.runningPID(paths.profileDir(p.id)) == nil { states[p.id] = nil }
            default:
                break
            }
        }
    }

    // MARK: - 检测

    /// 手动检测一个环境的出口，失败时弹窗。
    func check(_ id: String) {
        guard let p = fresh(id) else { return }
        guard p.upstream != nil else {
            alert = AppAlert(title: L("alert.cannotCheck"), message: L("alert.cannotCheck.noProxy"))
            return
        }
        checkMany([id], alertOnFailure: true)
    }

    /// 批量检测：每批 5 个并发，一批做完再做下一批。失败默认不弹窗，显示在列表里。
    func checkMany(_ ids: [String], alertOnFailure: Bool = false) {
        let queue = ids.filter { !checking.contains($0) }
        guard !queue.isEmpty else { return }
        queue.forEach { checking.insert($0) }  // 排队的也先显示为检测中
        let chunks = stride(from: 0, to: queue.count, by: 5).map { Array(queue[$0..<min($0 + 5, queue.count)]) }
        Task {
            for chunk in chunks {
                await withTaskGroup(of: Void.self) { group in
                    for id in chunk { group.addTask { await self.runCheck(id, alertOnFailure: alertOnFailure) } }
                }
            }
        }
    }

    /// 新增环境或换了代理后自动检测出口：只检测能检测、还没有检测结果的。
    func autoCheck(_ ids: [String]) {
        checkMany(ids.filter { id in fresh(id).map { $0.lastExit == nil && $0.upstream != nil } ?? false })
    }

    private func runCheck(_ id: String, alertOnFailure: Bool) async {
        defer { checking.remove(id) }
        guard let store, let p = fresh(id), let upstream = p.upstream else { return }
        do {
            try store.recordExit(try await GeoCheck.check(upstream: upstream), for: id)
            failures[id] = nil
        } catch {
            failures[id] = .check(error.localizedDescription)
            if alertOnFailure {
                alert = AppAlert(title: L("alert.checkFailed \(p.seq) \(p.name)"), message: error.localizedDescription)
            }
        }
    }

    // MARK: - 编辑

    /// 保存（新建或更新）。名称留空时由 Store 自动命名。返回保存后的环境；失败抛错由调用方展示。
    @discardableResult
    func save(_ profile: Profile, isNew: Bool) throws -> Profile {
        guard let store else { throw StoreError.notFound(L("alert.databaseNotOpen")) }
        if isNew { return try store.insert(profile) }
        var p = profile
        // 代理换了，旧的出口结果作废
        if let old = fresh(p.id), old.upstream != p.upstream { p.lastExit = nil }
        try store.update(p)
        return p
    }

    func moveToTrash(_ ids: [String]) {
        attempt(L("alert.trashPartial")) { store in
            for id in ids where !state(of: id).isActive { try store.softDelete(id) }
        }
        if ids.contains(where: { state(of: $0).isActive }) {
            alert = AppAlert(title: L("alert.trashPartial"), message: L("alert.trashPartial.message"))
        }
    }

    func restore(_ ids: [String]) {
        attempt(L("alert.restorePartial")) { store in
            for id in ids { try store.restore(id) }
        }
    }

    func purge(_ ids: [String]) {
        attempt(L("alert.purgeFailed")) { store in
            for id in ids where !state(of: id).isActive { try store.purge(id) }
        }
    }

    /// 给一批环境加标签 / 去标签。
    func addTag(_ tag: String, to ids: [String]) {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        try? store?.updateMany(ids) { if !$0.tags.contains(t) { $0.tags.append(t) } }
    }

    func removeTag(_ tag: String, from ids: [String]) {
        try? store?.updateMany(ids) { $0.tags.removeAll { $0 == tag } }
    }

    /// 重命名标签（所有环境）；新名称已存在时合并。
    func renameTag(_ old: String, to new: String) {
        attempt(L("alert.renameTagFailed")) { try $0.renameTag(old, to: new) }
    }

    /// 从所有环境上移除这个标签（环境本身不受影响）。
    func deleteTag(_ tag: String) {
        attempt(L("alert.deleteTagFailed")) { try $0.deleteTag(tag) }
    }

    func revealInFinder(_ id: String) {
        let dir = paths.profileDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            alert = AppAlert(title: L("alert.noProfileDirectory"), message: L("alert.noProfileDirectory.message"))
        }
    }

    func copyProxyAddress(_ id: String) {
        guard let proxy = profile(id)?.proxy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxy.urlString, forType: .string)
    }
}
