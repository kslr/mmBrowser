import Foundation
import Network

/// 只触发一次的标志，用来保证 continuation 只 resume 一次。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// NWConnection 的 async 封装，带读缓冲。
///
/// 约定：同一时刻只有一个任务在读、一个任务在写（握手阶段串行，转发阶段每个方向一个任务），
/// 所以内部状态不加锁，类型标记为 @unchecked Sendable。
final class AsyncConnection: @unchecked Sendable {
    let conn: NWConnection
    let queue: DispatchQueue
    private var buffer = Data()
    private var eofPending = false
    private var deadline: DispatchWorkItem?
    private(set) var deadlineFired = false

    init(_ conn: NWConnection, queue: DispatchQueue) {
        self.conn = conn
        self.queue = queue
    }

    /// 启动连接并等待就绪。`.waiting` 视为失败（不等待网络恢复，失败就让上层报错）。
    func start(timeout: TimeInterval, label: String) async throws {
        let conn = self.conn
        let queue = self.queue
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            // 超时后如果还没就绪就取消连接；已经 resume 过则什么都不做（由 OnceFlag 保证）
            let timer = DispatchWorkItem {
                if once.fire() {
                    cont.resume(throwing: ProxyError.timeout(L("error.proxy.connecting \(label)")))
                    conn.cancel()
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() }
                case .waiting(let error), .failed(let error):
                    if once.fire() {
                        conn.cancel()
                        cont.resume(throwing: ProxyError.connectFailed("\(label)：\(error.localizedDescription)"))
                    }
                case .cancelled:
                    if once.fire() { cont.resume(throwing: ProxyError.closed) }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout, execute: timer)
            conn.start(queue: queue)
        }
    }

    /// 到期后直接取消连接，让挂起的读写立刻失败。用于握手阶段的整体超时。
    func armDeadline(_ seconds: TimeInterval) {
        disarmDeadline()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deadlineFired = true
            self.conn.cancel()
        }
        deadline = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func disarmDeadline() {
        deadline?.cancel()
        deadline = nil
    }

    /// 读一块数据：优先返回缓冲区里的；nil 表示对端已关闭写方向（EOF）。
    func receiveSome(maximumLength: Int = 64 * 1024) async throws -> Data? {
        if !buffer.isEmpty {
            let d = buffer
            buffer = Data()
            return d
        }
        return try await receiveChunk(maximumLength: maximumLength)
    }

    func readExactly(_ n: Int) async throws -> Data {
        while buffer.count < n {
            guard let chunk = try await receiveChunk(maximumLength: 64 * 1024) else { throw ProxyError.closed }
            buffer.append(chunk)
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        return Data(out)
    }

    /// 读到分隔符为止（结果包含分隔符），超过 maxLength 报错。分隔符之后的数据留在缓冲区。
    func readUntil(_ delimiter: Data, maxLength: Int) async throws -> Data {
        var searchFrom = 0
        while true {
            if let r = buffer.range(of: delimiter, in: searchFrom..<buffer.count) {
                let out = buffer.prefix(upTo: r.upperBound)
                buffer.removeSubrange(..<r.upperBound)
                return Data(out)
            }
            if buffer.count > maxLength { throw ProxyError.protocolError(L("error.proxy.headersTooLong")) }
            searchFrom = max(0, buffer.count - delimiter.count + 1)
            guard let chunk = try await receiveChunk(maximumLength: 64 * 1024) else { throw ProxyError.closed }
            buffer.append(chunk)
        }
    }

    private func receiveChunk(maximumLength: Int) async throws -> Data? {
        if eofPending { return nil }
        while true {
            let (data, complete): (Data?, Bool) = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        cont.resume(returning: (data, isComplete))
                    } else if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume(returning: (nil, isComplete))
                    }
                }
            }
            if let data {
                if complete { eofPending = true }
                return data
            }
            if complete {
                eofPending = true
                return nil
            }
            // 既没有数据也没结束（理论上不会发生），继续读
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// 半关闭：告诉对端我方不会再发数据（TCP FIN）。
    func sendEOF() {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
    }

    func cancel() {
        disarmDeadline()
        conn.cancel()
    }
}
