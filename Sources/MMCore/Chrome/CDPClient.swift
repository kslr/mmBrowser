import Foundation

/// 极简 Chrome DevTools Protocol 客户端。
///
/// **只用于环境的离线初始化**（无界面、不联网、一两秒内结束），正常启动的浏览器从不开调试端口。
/// CDP 返回的 JSON（只在初始化流程里顺序使用，标记为 Sendable 以便跨 actor 传递）。
struct CDPJSON: @unchecked Sendable {
    let value: Any?
    subscript(key: String) -> CDPJSON { CDPJSON(value: (value as? [String: Any])?[key]) }
    var string: String? { value as? String }
    var bool: Bool? { value as? Bool }
    var int: Int? { (value as? NSNumber)?.intValue }
}

actor CDPClient {
    struct CDPError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { "CDP：\(message)" }
    }

    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var receiveLoop: Task<Void, Never>?

    init(webSocketURL: URL) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: webSocketURL)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    func connect() {
        task.resume()
        receiveLoop = Task { [weak self] in
            while let self {
                do {
                    let msg = try await self.task.receive()
                    await self.dispatch(msg)
                } catch {
                    await self.failAll(error)
                    return
                }
            }
        }
    }

    private func dispatch(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] as? [String: Any] {
            cont.resume(throwing: CDPError(message: err["message"] as? String ?? "未知错误"))
        } else {
            cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
        }
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        all.values.forEach { $0.resume(throwing: error) }
    }

    @discardableResult
    func send(_ method: String, _ params: [String: Any] = [:], sessionId: String? = nil) async throws -> CDPJSON {
        CDPJSON(value: try await sendRaw(method, params, sessionId: sessionId))
    }

    private func sendRaw(_ method: String, _ params: [String: Any], sessionId: String?) async throws -> [String: Any] {
        nextId += 1
        let id = nextId
        var msg: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionId { msg["sessionId"] = sessionId }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            task.send(.string(text)) { error in
                if let error { Task { await self.fail(id: id, error) } }
            }
        }
    }

    private func fail(id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// 在页面里执行 JS（支持 Promise），返回值。
    func evaluate(_ expression: String, sessionId: String) async throws -> CDPJSON {
        let r = try await send("Runtime.evaluate",
                               ["expression": expression, "awaitPromise": true, "returnByValue": true],
                               sessionId: sessionId)
        if r["exceptionDetails"].value != nil {
            throw CDPError(message: r["exceptionDetails"]["exception"]["description"].string ?? "页面脚本异常")
        }
        return r["result"]["value"]
    }

    func close() {
        receiveLoop?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
