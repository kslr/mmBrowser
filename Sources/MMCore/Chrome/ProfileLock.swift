import Foundation

/// Chrome 用 user-data-dir 里的 SingletonLock（指向 "主机名-PID" 的符号链接）标记哪个进程占着这个目录。
public enum ProfileLock {
    /// 锁里记下的 PID，不管进程还在不在。
    static func ownerPID(_ userDataDir: URL) -> Int32? {
        let lock = userDataDir.appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = target.split(separator: "-").last.flatMap({ Int32($0) }) else { return nil }
        return pid
    }

    /// 正在使用这个环境目录的 Chrome 的 PID（不管是不是本程序启动的）。
    public static func runningPID(_ userDataDir: URL) -> Int32? {
        ownerPID(userDataDir).flatMap { kill($0, 0) == 0 ? $0 : nil }
    }
}
