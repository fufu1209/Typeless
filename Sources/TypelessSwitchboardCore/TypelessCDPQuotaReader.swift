import Foundation

// MARK: - v2.8.0：Typeless 渲染进程的 CDP 客户端
//
// 只做三件事：HTTP 发现（/json/version、/json/list）→ WebSocket 握手 →
// `Runtime.evaluate` 跑一段受控 JS 并取回结果。没有第三方依赖：
// `URLSessionWebSocketTask` 是系统自带的（macOS 12+，本项目最低 13）。

public enum TypelessCDPError: Error, Equatable, LocalizedError, Sendable {
    case portClosed(Int)
    case notTypeless(Int)
    case noRendererPage(Int)
    case websocketFailed(String)
    case timeout(TimeInterval)
    case commandFailed(String)
    case quotaMissing(String)

    public var errorDescription: String? {
        switch self {
        case .portClosed(let port):
            return "调试端口 \(port) 没有进程监听：Typeless 不是带 --remote-debugging-port 启动的（或没在运行）"
        case .notTypeless(let port):
            return "端口 \(port) 上不是 Typeless（User-Agent 不匹配），已拒绝读取"
        case .noRendererPage(let port):
            return "Typeless 已连上（端口 \(port)），但没有可用的渲染页面"
        case .websocketFailed(let reason):
            return "DevTools WebSocket 失败：\(reason)"
        case .timeout(let seconds):
            return "DevTools 调用超时（\(Int(seconds)) 秒）"
        case .commandFailed(let reason):
            return "DevTools 命令失败：\(reason)"
        case .quotaMissing(let reason):
            return "拿不到额度：\(reason)"
        }
    }
}

/// 一次性读取 Typeless 官方额度。
///
/// 用法：
/// ```swift
/// let reader = TypelessCDPQuotaReader(port: 9333)
/// if let snapshot = await reader.readQuota() { … }
/// ```
/// `readQuota()` 永不抛错：失败返回 nil，并把原因留在 `lastFailureDescription`，
/// 调用方可以据此决定是否降级到读屏 / 缓存，而不用被错误类型污染。
public actor TypelessCDPQuotaReader {
    private let port: Int
    private let timeout: TimeInterval

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var nextCommandID = 1
    private var collectedEvents: [[String: Any]] = []

    /// 最近一次失败原因（中文，可直接进日志 / UI）。
    public private(set) var lastFailureDescription: String?

    public init(port: Int = TypelessQuotaBridge.defaultPort, timeout: TimeInterval = 8) {
        self.port = TypelessQuotaBridge.normalizePort(port)
        self.timeout = max(2, min(timeout, 30))
    }

    // MARK: - 对外入口

    /// 读一次额度；失败返回 nil。
    public func readQuota() async -> TypelessQuotaSnapshot? {
        defer { closeSocket() }
        lastFailureDescription = nil
        do {
            let snapshot = try await performRead()
            return snapshot
        } catch let error as TypelessCDPError {
            lastFailureDescription = error.errorDescription
            return nil
        } catch {
            lastFailureDescription = "未知错误：\(error.localizedDescription)"
            return nil
        }
    }

    /// 自检用：把「端口 / 页面 / 客户端 chunk / 额度」一次性说清楚。
    public func diagnose() async -> String {
        defer { closeSocket() }
        do {
            let targets = try await fetchTargets()
            guard let target = TypelessQuotaBridge.preferredTarget(in: targets) else {
                return "端口 \(port) 可连，但没有 Typeless 渲染页面（找到 \(targets.count) 个 page）"
            }
            try openSocket(target.webSocketDebuggerURL)
            let raw = try await evaluate(TypelessQuotaBridge.probeExpression())
            if let snapshot = TypelessQuotaBridge.decodeProbe(raw) {
                let chunk = snapshot.clientChunk ?? "未知"
                return "直读正常：\(snapshot.summary)；页面 \(target.pageRole)；客户端 \(chunk)"
            }
            return "页面 \(target.pageRole) 连上了，但没找到可用的 API 客户端：\(Self.preview(raw))"
        } catch let error as TypelessCDPError {
            return error.errorDescription ?? "直读失败"
        } catch {
            return "直读失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 读取流程

    private func performRead() async throws -> TypelessQuotaSnapshot {
        _ = try await fetchVersion()
        let targets = try await fetchTargets()
        guard let target = TypelessQuotaBridge.preferredTarget(in: targets) else {
            throw TypelessCDPError.noRendererPage(port)
        }
        try openSocket(target.webSocketDebuggerURL)

        // 第一跳：modulepreload 列表。不开 Debugger，对 App 干扰最小。
        var raw = try await evaluate(TypelessQuotaBridge.probeExpression())
        if let snapshot = TypelessQuotaBridge.decodeProbe(raw) {
            return snapshot
        }

        // 第二跳：页面没有 modulepreload（旧版本 / 打包方式变了）时，
        // 用 Debugger 把「实际加载过的脚本」列出来再试一次。
        if let scriptURLs = try? await collectLoadedScriptURLs(), !scriptURLs.isEmpty {
            raw = try await evaluate(TypelessQuotaBridge.probeExpression(extraScriptURLs: scriptURLs))
            if let snapshot = TypelessQuotaBridge.decodeProbe(raw) {
                return snapshot
            }
        }
        throw TypelessCDPError.quotaMissing(Self.preview(raw))
    }

    // MARK: - HTTP 发现

    private func fetchVersion() async throws -> [String: Any] {
        let url = TypelessQuotaBridge.versionURL(port: port)
        guard let object = try? await fetchJSON(url) else {
            throw TypelessCDPError.portClosed(port)
        }
        let userAgent = (object["User-Agent"] as? String) ?? ""
        // 端口可能被别的 Electron 应用（或任何 DevTools 客户端）占用。
        // 只认 Typeless 自己的 UA；老版本万一不带产品名，退而认 Electron。
        if !userAgent.contains("Typeless") && !userAgent.contains("Electron") {
            throw TypelessCDPError.notTypeless(port)
        }
        return object
    }

    private func fetchTargets() async throws -> [TypelessQuotaBridge.CDPTarget] {
        let url = TypelessQuotaBridge.listURL(port: port)
        guard let data = try? await fetchData(url) else {
            throw TypelessCDPError.portClosed(port)
        }
        return TypelessQuotaBridge.decodeTargets(data)
    }

    private func fetchJSON(_ url: URL) async throws -> [String: Any] {
        let data = try await fetchData(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TypelessCDPError.commandFailed("响应不是 JSON 对象")
        }
        return object
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(timeout, 4)
        configuration.waitsForConnectivity = false
        let localSession = URLSession(configuration: configuration)
        defer { localSession.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = min(timeout, 4)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await localSession.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TypelessCDPError.commandFailed("HTTP \( (response as? HTTPURLResponse)?.statusCode ?? -1 )")
        }
        return data
    }

    // MARK: - WebSocket / JSON-RPC

    private func openSocket(_ rawURL: String) throws {
        closeSocket()
        guard let url = URL(string: rawURL) else {
            throw TypelessCDPError.websocketFailed("非法 URL")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let localSession = URLSession(configuration: configuration)
        let task = localSession.webSocketTask(with: url)
        task.resume()
        session = localSession
        socket = task
        collectedEvents = []
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        collectedEvents = []
    }

    private func evaluate(_ expression: String) async throws -> String {
        let response = try await sendCommand("Runtime.evaluate", [
            "expression": expression,
            "awaitPromise": true,
            "returnByValue": true,
            "userGesture": true,
            "timeout": Int(timeout * 1000)
        ])
        guard let result = response["result"] as? [String: Any] else {
            throw TypelessCDPError.commandFailed("Runtime.evaluate 无 result")
        }
        if let exception = result["exceptionDetails"] as? [String: Any] {
            let text = (exception["text"] as? String) ?? "JS 异常"
            let message = ((exception["exception"] as? [String: Any])?["description"] as? String) ?? text
            throw TypelessCDPError.commandFailed(TypelessQuotaBridge.redactSecrets(in: message))
        }
        guard let value = (result["result"] as? [String: Any])?["value"] as? String else {
            throw TypelessCDPError.commandFailed("Runtime.evaluate 返回值不是字符串")
        }
        return value
    }

    private func collectLoadedScriptURLs() async throws -> [String] {
        _ = try await sendCommand("Debugger.enable", [:])
        _ = try? await sendCommand("Debugger.setSkipAllPauses", ["skip": true])
        // Debugger.enable 之后，Chromium 会立刻把「已经解析过的脚本」以事件形式回放。
        // 这里给 300ms 收集窗口；收完立刻关掉，不留调试状态。
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            do {
                _ = try await receiveMessage(within: 0.05)
            } catch {
                break
            }
        }
        _ = try? await sendCommand("Debugger.disable", [:])
        let urls = collectedEvents
            .filter { ($0["method"] as? String) == "Debugger.scriptParsed" }
            .compactMap { ($0["params"] as? [String: Any])?["url"] as? String }
        return TypelessQuotaBridge.normalizedScriptURLs(urls)
    }

    private func sendCommand(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let socket else { throw TypelessCDPError.websocketFailed("尚未连接") }
        let id = nextCommandID
        nextCommandID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TypelessCDPError.commandFailed("命令序列化失败")
        }
        do {
            try await withTimeout(seconds: timeout) { [socket] in
                try await socket.send(.string(text))
            }
        } catch {
            throw TypelessCDPError.timeout(timeout)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try await receiveMessage(within: deadline.timeIntervalSinceNow)
            guard let responseID = message["id"] as? Int else {
                collectedEvents.append(message)
                continue
            }
            guard responseID == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String) ?? "未知错误"
                throw TypelessCDPError.commandFailed(TypelessQuotaBridge.redactSecrets(in: text))
            }
            return message
        }
        throw TypelessCDPError.timeout(timeout)
    }

    /// 收一条 WebSocket 消息；超时抛错。
    private func receiveMessage(within seconds: TimeInterval) async throws -> [String: Any] {
        guard let socket else { throw TypelessCDPError.websocketFailed("尚未连接") }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await withTimeout(seconds: max(seconds, 0.05)) {
                try await socket.receive()
            }
        } catch {
            throw TypelessCDPError.timeout(max(seconds, 0.05))
        }
        let body: String
        switch message {
        case .string(let text): body = text
        case .data(let data): body = String(decoding: data, as: UTF8.self)
        @unknown default: throw TypelessCDPError.commandFailed("未知消息类型")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw TypelessCDPError.commandFailed("消息不是 JSON 对象")
        }
        return object
    }

    private static func preview(_ raw: String) -> String {
        let safe = TypelessQuotaBridge.redactSecrets(in: raw)
        return safe.count > 240 ? String(safe.prefix(240)) + "…" : safe
    }
}

// MARK: - 超时竞争

/// 给任意 async 操作加超时。超时后抛 `TypelessCDPError.timeout`。
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.01) * 1_000_000_000))
            throw TypelessCDPError.timeout(seconds)
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw TypelessCDPError.timeout(seconds)
        }
        return value
    }
}
