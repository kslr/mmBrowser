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
    var lastError: [String: String] = [:]
    /// 最近一次批量检测失败的环境（代理视图里显示为失败）
    var checkFailed: Set<String> = []
    /// 启动时遇到的非致命问题（如扩展没装好），显示在状态列的提示里
    var lastWarning: [String: String] = [:]
    var checking: Set<String> = []
    var alert: AppAlert?
    /// 扩展库变化时递增，用来刷新依赖它的界面
    var extensionLibraryVersion = 0

    private var observationTask: Task<Void, Never>?
    private var orphanTimer: Timer?

    init(paths: AppPaths = .default()) {
        self.paths = paths
        do {
            let store = try Store(paths: paths)
            self.store = store
            startObserving(store)
            seedBuiltinExtensions()
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
        if let all = try? store.profiles(includeDeleted: true) {
            apply(all: all)
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

    func state(of id: String) -> RunState { states[id] ?? .idle }

    var runningCount: Int { states.values.filter { if case .running = $0 { true } else { false } }.count }

    func profiles(in item: SidebarItem) -> [Profile] {
        switch item {
        case .all: profiles
        case .running: profiles.filter { state(of: $0.id).isActive }
        case .untagged: profiles.filter { $0.tags.isEmpty }
        case .tag(let t): profiles.filter { $0.tags.contains(t) }
        case .proxies: profiles
        case .trash: trash
        }
    }

    func profile(_ id: String) -> Profile? {
        profiles.first { $0.id == id } ?? trash.first { $0.id == id }
    }

    // MARK: - 启动 / 关闭

    /// 批量启动。超过"同时运行上限"的部分不启动，并提示。
    func launch(_ ids: [String]) {
        let toStart = ids.filter { !state(of: $0).isActive }
        let alreadyActive = ids.filter { state(of: $0).isActive }
        alreadyActive.forEach(activate)
        let room = max(0, maxRunning - states.values.filter(\.isActive).count)
        for id in toStart.prefix(room) { launch(id) }
        if toStart.count > room {
            alert = AppAlert(title: L("alert.runningLimit.title \(maxRunning)"),
                             message: L("alert.runningLimit.message \(toStart.count - room)"))
        }
    }

    func launch(_ id: String) {
        guard let launcher else {
            alert = AppAlert(title: L("alert.cannotLaunch"), message: setupError ?? L("alert.chromeNotFound"))
            return
        }
        switch state(of: id) {
        case .running(let r): r.activate(); return
        case .orphan(let pid): RunningBrowser.activate(pid: pid); return
        case .launching, .stopping: return
        case .idle: break
        }
        lastError[id] = nil
        checkFailed.remove(id)
        states[id] = .launching(L("launch.stage.preparing"))
        Task {
            do {
                let running = try await launcher.launch(profileId: id, progress: { stage in
                    let text = switch stage {
                    case .startingProxy: L("launch.stage.startingProxy")
                    case .checkingExit: L("launch.stage.checkingExit")
                    case .exitChecked: L("launch.stage.exitChecked")
                    case .seeding: L("launch.stage.seeding")
                    case .initializing: L("launch.stage.initializing")
                    case .installingExtensions: L("launch.stage.installingExtensions")
                    case .warning(let w): w
                    case .startingChrome: L("launch.stage.startingChrome")
                    }
                    if case .warning(let w) = stage {
                        Task { @MainActor in AppModel.shared.lastWarning[id] = w }
                    }
                    Task { @MainActor in
                        if case .launching = AppModel.shared.state(of: id) { AppModel.shared.states[id] = .launching(text) }
                    }
                })
                states[id] = .running(running)
                refreshExtensionNames()
                running.onExit {
                    Task { @MainActor in AppModel.shared.browserExited(id) }
                }
            } catch {
                states[id] = nil
                lastError[id] = error.localizedDescription
                let name = profile(id).map { "#\($0.seq) \($0.name)" } ?? id
                alert = AppAlert(title: L("alert.launchFailed \(name)"), message: error.localizedDescription)
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
        guard let store, let p = fresh(id), !checking.contains(id) else { return }
        let upstream: Upstream
        if let proxy = p.proxy { upstream = .proxy(proxy) }
        else if p.allowDirect { upstream = .direct }
        else { alert = AppAlert(title: L("alert.cannotCheck"), message: L("alert.cannotCheck.noProxy")); return }
        checking.insert(id)
        Task {
            defer { checking.remove(id) }
            do {
                let info = try await GeoCheck.check(upstream: upstream)
                try store.recordExit(info, for: id)
                lastError[id] = nil
                checkFailed.remove(id)
            } catch {
                lastError[id] = error.localizedDescription
                checkFailed.remove(id)
                alert = AppAlert(title: L("alert.checkFailed \(p.seq) \(p.name)"), message: error.localizedDescription)
            }
        }
    }

    // MARK: - 编辑

    /// 保存（新建或更新）。返回保存后的环境；失败抛错由调用方展示。
    @discardableResult
    func save(_ profile: Profile, isNew: Bool) throws -> Profile {
        guard let store else { throw StoreError.notFound(L("alert.databaseNotOpen")) }
        var p = profile
        if isNew {
            // 名称留空：先插入拿到序号，再命名为"环境-序号"
            let autoName = p.name.isEmpty
            if autoName { p.name = L("profile.placeholderName") }
            var saved = try store.insert(p)
            if autoName {
                saved.name = L("profile.defaultName \(saved.seq)")
                try store.update(saved)
            }
            return saved
        }
        if p.name.isEmpty { p.name = L("profile.defaultName \(p.seq)") }
        try store.update(p)
        return p
    }

    func moveToTrash(_ ids: [String]) {
        guard let store else { return }
        for id in ids where !state(of: id).isActive {
            try? store.softDelete(id)
        }
        if ids.contains(where: { state(of: $0).isActive }) {
            alert = AppAlert(title: L("alert.trashPartial"), message: L("alert.trashPartial.message"))
        }
    }

    func restore(_ ids: [String]) {
        guard let store else { return }
        var failures: [String] = []
        for id in ids {
            do { try store.restore(id) } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { alert = AppAlert(title: L("alert.restorePartial"), message: failures.joined(separator: "\n")) }
    }

    func purge(_ ids: [String]) {
        guard let store else { return }
        for id in ids where !state(of: id).isActive {
            do { try store.purge(id) } catch {
                alert = AppAlert(title: L("alert.purgeFailed"), message: error.localizedDescription)
            }
        }
    }

    /// 给一批环境加标签 / 去标签。
    func addTag(_ tag: String, to ids: [String]) {
        let t = tag.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        _ = try? store?.updateMany(ids) { if !$0.tags.contains(t) { $0.tags.append(t) } }
    }

    func removeTag(_ tag: String, from ids: [String]) {
        _ = try? store?.updateMany(ids) { $0.tags.removeAll { $0 == tag } }
    }

    /// 重命名标签（所有环境）；新名称已存在时合并。
    func renameTag(_ old: String, to new: String) {
        do { try store?.renameTag(old, to: new) } catch {
            alert = AppAlert(title: L("alert.renameTagFailed"), message: error.localizedDescription)
        }
    }

    /// 从所有环境上移除这个标签（环境本身不受影响）。
    func deleteTag(_ tag: String) {
        do { try store?.deleteTag(tag) } catch {
            alert = AppAlert(title: L("alert.deleteTagFailed"), message: error.localizedDescription)
        }
    }

    func revealInFinder(_ id: String) {
        let dir = paths.profileDir(id)
        if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } else {
            alert = AppAlert(title: L("alert.noProfileDirectory"), message: L("alert.noProfileDirectory.message"))
        }
    }
}
