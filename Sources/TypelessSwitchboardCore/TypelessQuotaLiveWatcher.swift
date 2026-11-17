import Foundation

// MARK: - v2.8.0：额度实时监听（CDP 事件流）
//
// 轮询（`TypelessCDPQuotaReader`）解决的是「我不知道额度，去问一次」；
// 这里解决的是「App 自己刷新额度时，我要立刻知道」——Typeless 每次打开首页、
// 切回主页都会自己请求 `usage_stats`，我们在 DevTools 的 `Network` 事件里
// 就能拿到**同一份响应**：
//
//   * 不额外发请求（App 发一次，我们只是旁听）；
//   * 不解析界面文字；
//   * 延迟 = App 自己的刷新延迟。
//
// 生命周期：GUI 常驻时跟着 App 走；Typeless 重启/端口变化时自动重连（指数退避）。
// 拿不到事件时完全无害：轮询链路仍在跑。

public actor TypelessQuotaLiveWatcher {
    private let port: Int
    private let reconnectBaseSeconds: UInt64
    private let receiveTimeout: TimeInterval

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var nextCommandID = 1
    private var isFetchingBody = false
    private var loopTask: Task<Void, Never>?
    private var targetMonitorTask: Task<Void, Never>?
    private var connectedTargetID: String?
    private var continuation: AsyncStream<TypelessQuotaSnapshot>.Continuation?

    /// 最近一次连接错误（中文），供 UI/日志显示。
    public private(set) var lastFailureDescription: String?
    /// 是否已连上并处于监听状态。
    public private(set) var isConnected = false

    public init(
        port: Int = TypelessQuotaBridge.defaultPort,
        reconnectBaseSeconds: UInt64 = 3,
        receiveTimeout: TimeInterval = 300
    ) {
        self.port = TypelessQuotaBridge.normalizePort(port)
        self.reconnectBaseSeconds = max(reconnectBaseSeconds, 1)
        self.receiveTimeout = max(receiveTimeout, 5)
    }

    /// 启动监听并返回快照流。重复调用返回同一条流（幂等）。
    public func start() -> AsyncStream<TypelessQuotaSnapshot> {
        if let existing = currentStream {
            return existing
        }
        let (stream, continuation) = AsyncStream<TypelessQuotaSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(4)
        )
        self.continuation = continuation
        currentStream = stream
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
        // 页面拓扑会变：hub 可能一会儿在、一会儿不在（用户关掉主窗口）。
        // 每 8 秒对一次目标，换页就重连 —— 否则会一直黏在浮条上，错过 hub 的刷新。
        targetMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                await self?.refreshTargetIfNeeded()
            }
        }
        return stream
    }

    /// 停止监听（幂等）。
    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        targetMonitorTask?.cancel()
        targetMonitorTask = nil
        connectedTargetID = nil
        continuation?.finish()
        continuation = nil
        currentStream = nil
        closeSocket()
        isConnected = false
    }

    private var currentStream: AsyncStream<TypelessQuotaSnapshot>?

    // MARK: - 主循环

    private func runLoop() async {
        var backoff = reconnectBaseSeconds
        while !Task.isCancelled {
            do {
                try await connect()
                isConnected = true
                lastFailureDescription = nil
                backoff = reconnectBaseSeconds
                try await listen()
            } catch {
                isConnected = false
                if Task.isCancelled { break }
                lastFailureDescription = (error as? TypelessCDPError)?.errorDescription
                    ?? error.localizedDescription
                closeSocket()
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 30)
            }
        }
        isConnected = false
        closeSocket()
    }

    private func connect() async throws {
        closeSocket()
        _ = try await fetchVersion()
        let targets = try await fetchTargets()
        // 监听场景优先 hub：额度刷新基本都发生在主窗口里；浮条只在没有主窗口时兜底。
        let selected = targets.first { $0.pageRole == "hub" }
            ?? TypelessQuotaBridge.preferredTarget(in: targets)
        guard let target = selected else {
            throw TypelessCDPError.noRendererPage(port)
        }
        connectedTargetID = target.id
        guard let url = URL(string: target.webSocketDebuggerURL) else {
            throw TypelessCDPError.websocketFailed("非法 URL")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let localSession = URLSession(configuration: configuration)
        let task = localSession.webSocketTask(with: url)
        task.resume()
        session = localSession
        socket = task
        _ = try await waitForResponse(sending: "Network.enable", ["maxPostDataSize": 0])
    }

    /// 收事件直到连接断开 / 任务取消。
    private func listen() async throws {
        while !Task.isCancelled {
            let message = try await receiveMessage()
            if let method = message["method"] as? String {
                try await handleEvent(method: method, params: message["params"] as? [String: Any] ?? [:])
            }
        }
    }

    /// 目标页变化（hub 出现 / 消失）时主动重连。
    private func refreshTargetIfNeeded() async {
        guard socket != nil, let current = connectedTargetID else { return }
        guard let targets = try? await fetchTargets() else { return }
        let desired = targets.first { $0.pageRole == "hub" }?.id
            ?? TypelessQuotaBridge.preferredTarget(in: targets)?.id
        guard let desired, desired != current else { return }
        // 关掉当前连接，让 runLoop 的 catch 分支重连并重新选页。
        socket?.cancel(with: .goingAway, reason: nil)
    }

    private func handleEvent(method: String, params: [String: Any]) async throws {
        guard method == "Network.responseReceived" else { return }
        guard let response = params["response"] as? [String: Any],
              let url = response["url"] as? String,
              url.contains("/user/usage_stats"),
              (response["status"] as? Int ?? 0) == 200,
              let requestID = params["requestId"] as? String
        else { return }

        // 取 body 也是一次命令；期间如果又来一条 usage_stats 事件，
        // 不要递归去取第二条 body（会越套越深），交给下一轮刷新。
        guard !isFetchingBody else { return }
        isFetchingBody = true
        defer { isFetchingBody = false }

        guard let bodyMessage = try? await waitForResponse(
            sending: "Network.getResponseBody",
            ["requestId": requestID]
        ),
            let body = (bodyMessage["result"] as? [String: Any])?["body"] as? String,
            // 来源标注成 CDP 直读：虽然是「旁听」App 自己的响应，
            // 但它的签名/TLS 都来自 App 渲染进程，与主动直读同一条链路。
            let snapshot = TypelessQuotaBridge.decodeUsageStatsBody(body, source: .cdpBridge)
        else { return }
        continuation?.yield(snapshot)
    }

    // MARK: - HTTP 发现

    private func fetchVersion() async throws -> [String: Any] {
        let data = try await fetchData(TypelessQuotaBridge.versionURL(port: port))
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TypelessCDPError.commandFailed("版本响应不是 JSON")
        }
        let userAgent = (object["User-Agent"] as? String) ?? ""
        if !userAgent.contains("Typeless") && !userAgent.contains("Electron") {
            throw TypelessCDPError.notTypeless(port)
        }
        return object
    }

    private func fetchTargets() async throws -> [TypelessQuotaBridge.CDPTarget] {
        let data = try await fetchData(TypelessQuotaBridge.listURL(port: port))
        return TypelessQuotaBridge.decodeTargets(data)
    }

    private func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw TypelessCDPError.portClosed(port)
            }
            return data
        } catch let error as TypelessCDPError {
            throw error
        } catch {
            throw TypelessCDPError.portClosed(port)
        }
    }

    // MARK: - JSON-RPC

    private func waitForResponse(sending method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = try await send(method, params)
        return try await waitForResponse(id: id)
    }

    private func send(_ method: String, _ params: [String: Any]) async throws -> Int {
        guard let socket else { throw TypelessCDPError.websocketFailed("尚未连接") }
        let id = nextCommandID
        nextCommandID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TypelessCDPError.commandFailed("命令序列化失败")
        }
        try await socket.send(.string(text))
        return id
    }

    private func waitForResponse(id: Int) async throws -> [String: Any] {
        while true {
            let message = try await receiveMessage()
            if let method = message["method"] as? String {
                // 事件可能夹在等待过程中（比如第二条 usage_stats）。顺手处理，别丢。
                try await handleEvent(method: method, params: message["params"] as? [String: Any] ?? [:])
                continue
            }
            guard let responseID = message["id"] as? Int else { continue }
            guard responseID == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String) ?? "未知 CDP 错误"
                throw TypelessCDPError.commandFailed(TypelessQuotaBridge.redactSecrets(in: text))
            }
            return message
        }
    }

    private func receiveMessage() async throws -> [String: Any] {
        guard let socket else { throw TypelessCDPError.websocketFailed("尚未连接") }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await withWatcherTimeout(seconds: receiveTimeout) {
                try await socket.receive()
            }
        } catch {
            throw TypelessCDPError.timeout(receiveTimeout)
        }
        let text: String
        switch message {
        case .string(let value): text = value
        case .data(let data): text = String(decoding: data, as: UTF8.self)
        @unknown default: throw TypelessCDPError.commandFailed("未知消息类型")
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw TypelessCDPError.commandFailed("消息不是 JSON 对象")
        }
        return object
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
    }
}

/// 与 `TypelessCDPQuotaReader` 里的同名工具分开命名，避免同模块冲突。
private func withWatcherTimeout<T: Sendable>(
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
