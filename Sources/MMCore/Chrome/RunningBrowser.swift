import AppKit
import Foundation

/// 一个正在运行的环境：Chrome 主进程 + 它专属的本地代理入口。
public final class RunningBrowser: @unchecked Sendable {
    public let profileId: String
    public let proxy: LocalProxyServer?
    public let exit: ExitInfo?
    public let timezone: String
    public let startedAt = Date()
    private let process: Process
    private let lock = NSLock()
    private var exitHandlers: [@Sendable () -> Void] = []
    private var exited = false

    init(profileId: String, process: Process, proxy: LocalProxyServer?, exit: ExitInfo?, timezone: String) {
        self.profileId = profileId
        self.process = process
        self.proxy = proxy
        self.exit = exit
        self.timezone = timezone
    }

    /// Chrome 主进程的 PID（进程启动后才有效）。
    public var pid: Int32 { process.processIdentifier }

    public var isRunning: Bool { lock.withLock { !exited } }

    /// Chrome 主进程退出时调用（已退出则立即调用）。
    public func onExit(_ handler: @escaping @Sendable () -> Void) {
        let already: Bool = lock.withLock {
            if exited { return true }
            exitHandlers.append(handler)
            return false
        }
        if already { handler() }
    }

    func markExited() {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            if exited { return [] }
            exited = true
            let h = exitHandlers
            exitHandlers = []
            return h
        }
        proxy?.stop()  // 断开即断网：浏览器退出后立刻回收入口
        handlers.forEach { $0() }
    }

    /// 等待浏览器退出。
    public func waitUntilExit() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            onExit { cont.resume() }
        }
    }

    /// 切到前台。
    @MainActor
    public func activate() {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }

    /// 正常退出（相当于 Cmd-Q，Chrome 会保存会话）。超时后强制结束。
    public func terminate(timeout: TimeInterval = 10) async {
        await Self.terminate(pid: pid, timeout: timeout) { [weak self] in self?.isRunning ?? false }
    }

    /// 结束任意一个 Chrome 进程（比如应用上次异常退出后残留、已经断网的环境）。
    public static func terminateOrphan(pid: Int32, timeout: TimeInterval = 10) async {
        await terminate(pid: pid, timeout: timeout) { kill(pid, 0) == 0 }
    }

    private static func terminate(pid: Int32, timeout: TimeInterval, alive: @Sendable () -> Bool) async {
        let app = NSRunningApplication(processIdentifier: pid)
        if app?.terminate() != true {
            kill(pid, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while alive(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if alive() { kill(pid, SIGKILL) }
    }

    /// 把任意 PID 的 Chrome 窗口切到前台。
    @MainActor
    public static func activate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
    }
}
