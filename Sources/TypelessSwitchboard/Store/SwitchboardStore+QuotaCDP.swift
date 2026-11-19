import SwiftUI
import AppKit
import TypelessSwitchboardCore

// MARK: - v2.8.0：额度直读（CDP）接线
//
// 这个文件只做三件事：
//   1. 把「读一次额度」包装成 store 的方法；
//   2. 把读到的数字写进当前账号（含来源标注、观测采样、降级状态复位）；
//   3. 提供「让 Typeless 以调试端口重启」「自检直读」两个人工入口。
//
// 设计约束：
//   * **绝不因为直读失败而改变原有行为** —— 失败就返回 nil，调用方照旧走
//     官方 API / 读屏 / 缓存降级。
//   * **绝不在日志里写令牌** —— 探针只回传 email / user_id / 额度字段，
//     任何原始报文都要先过 `TypelessQuotaBridge.redactSecrets`。
//   * 直读只覆盖「当前登录账号」。池里其它账号的额度仍然只能靠切换后读，
//     或由 `scripts/audit-account-pool.js` 逐号验证（那条路同样受 JA3 限制）。

extension SwitchboardStore {

    /// 当前设置的调试端口。
    var cdpQuotaPort: Int {
        TypelessQuotaBridge.normalizePort(state.settings.cdpQuotaPort)
    }

    /// 直读开关。
    var isCDPQuotaEnabled: Bool {
        state.settings.isCDPQuotaEnabled
    }

    /// 读一次额度。失败返回 nil，并把原因写进 `lastCDPQuotaFailure`。
    func readQuotaViaCDPBridge() async -> TypelessQuotaSnapshot? {
        guard isCDPQuotaEnabled else {
            // 关闭是用户的选择，不是失败 —— 不要把它写进失败原因，
            // 否则「额度守护」卡片会一直挂一条红的「直读未成功」。
            lastCDPQuotaFailure = ""
            return nil
        }
        let reader = TypelessCDPQuotaReader(port: cdpQuotaPort)
        let snapshot = await reader.readQuota()
        if let snapshot {
            lastCDPQuotaFailure = ""
            lastQuotaSource = snapshot.source
            return snapshot
        }
        lastCDPQuotaFailure = await reader.lastFailureDescription ?? "未知原因"
        return nil
    }

    /// 把一次读数落到账号上：找账号（找不到就补一条）→ 写 used/limit → 复位降级状态。
    ///
    /// 返回落到的账号 ID；没有可用身份信息时返回 nil（不猜、不硬塞给当前号）。
    @discardableResult
    func applyQuotaSnapshotToMatchingAccount(_ snapshot: TypelessQuotaSnapshot) -> UUID? {
        guard let email = snapshot.email?.nilIfBlank else { return nil }

        var index = state.accounts.firstIndex { $0.email.lowercased() == email.lowercased() }
        if index == nil {
            var account = Account.blank(settings: state.settings)
            account.email = email
            account.name = email
            account.notes = "由额度直读自动收录（\(snapshot.source.displayName)）"
            state.accounts.append(account)
            index = state.accounts.count - 1
        }
        guard let index else { return nil }

        recordQuotaUsageObservation(
            accountID: state.accounts[index].id,
            email: email,
            usedCharacters: snapshot.usedCharacters
        )

        state.accounts[index].usedCharacters = snapshot.usedCharacters
        state.accounts[index].monthlyLimit = max(snapshot.weeklyLimit, 1)
        // 注意：不要用 `QuotaTier` 覆写 `role` —— `role` 存的是**服务端原值**
        //（free / pro_trial / pro），是账号池与官方 App 对齐的事实字段；
        // QuotaTier 是从额度上限**反推**出来的视图，只用于徽章。

        lastQuotaUsedCharacters = snapshot.usedCharacters
        lastQuotaMonthlyLimit = max(snapshot.weeklyLimit, 1)
        lastQuotaSyncAt = snapshot.capturedAt
        lastQuotaSyncFresh = true
        lastQuotaSource = snapshot.source
        lastSyncHitClientNotSupported = false
        noteQuotaAPISuccess()

        liveRemainingCharacters = snapshot.remainingCharacters
        liveAccountEmail = email

        let tier = QuotaTier.badgeText(
            weeklyLimit: snapshot.weeklyLimit,
            createdAt: state.accounts[index].createdAt,
            now: snapshot.capturedAt
        )
        state.accounts[index].notes = [
            "本周额度：已用 \(snapshot.usedCharacters)/\(snapshot.weeklyLimit)，剩余 \(snapshot.remainingCharacters)",
            tier,
            "\(snapshot.source.displayName) \(Self.shortClock(snapshot.capturedAt))"
        ].compactMap { $0 }.joined(separator: " · ")

        syncStatusMessage = "本周额度已直读「\(email)」：\(snapshot.summary)"
        statusMessage = syncStatusMessage
        save()
        return state.accounts[index].id
    }

    /// 自检入口：返回一段可复制的诊断文本（不写账号、不改状态）。
    func diagnoseCDPQuotaBridge() async -> String {
        guard isCDPQuotaEnabled else {
            return "额度直读已关闭：请在「额度守护」页打开「额度直读（CDP）」"
        }
        let reader = TypelessCDPQuotaReader(port: cdpQuotaPort)
        let text = await reader.diagnose()
        lastCDPQuotaFailure = text.contains("直读正常") ? "" : text
        return text
    }

    /// Typeless 桌面端是否在运行（用 bundle id / 名称双判）。
    func typelessIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "now.typeless.desktop" || $0.localizedName == "Typeless"
        }
    }

    /// 桌面端当前是否**真的有登录态**。
    ///
    /// 判据两条：`user-data.json` 存在（加密会话本体），且 `app-storage.json` 的
    /// `userData` 非空（Typeless 启动后自己回填的投影）。只看文件存在不够 ——
    /// 注册失败会把内容清空但文件可能还在。
    func isDesktopSessionPresent() -> Bool {
        let userData = typelessUserDataDir().appendingPathComponent("user-data.json")
        guard FileManager.default.fileExists(atPath: userData.path) else { return false }
        guard let data = try? Data(contentsOf: typelessStorageURL()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projected = object["userData"] as? String
        else { return false }
        return !projected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 恢复桌面登录态（v2.9.0）。
    ///
    /// 场景：注册失败 / 手动误删 / 切换后桌面端变未登录。挑一个**令牌未死**、
    /// 剩余额度最多的账号，把 payload 写回去并重启（不重置设备）。
    /// `force = false` 时只在「确实没有登录态」时才动手。
    func repairDesktopLogin(preferredEmail: String? = nil, force: Bool = false) async -> String {
        if !force, isDesktopSessionPresent() {
            return "Typeless 当前已有登录态，无需修复"
        }
        // 先读一次当前会话（只在本地解密，不发请求）：能读出来就优先恢复「同一个号」，
        // 而不是因为别的号剩余额度更多就把用户换走。
        _ = await syncActiveAppSessionAndQuotaNode(localOnly: true)

        let candidates = state.accounts.filter { $0.isSilentlySwitchable }
        let target: Account? = {
            if let preferredEmail,
               let match = candidates.first(where: { $0.email.caseInsensitiveCompare(preferredEmail) == .orderedSame }) {
                return match
            }
            // 优先恢复「用户刚才在用的号」，而不是简单挑额度最多的 —— 换号是有成本的。
            if let live = liveAccountEmail.nilIfBlank,
               let match = candidates.first(where: { $0.email.caseInsensitiveCompare(live) == .orderedSame }) {
                return match
            }
            if let previousID = state.lastAutomationResult?.previousAccountID,
               let match = candidates.first(where: { $0.id == previousID }) {
                return match
            }
            return candidates.sorted {
                if $0.remainingCharacters == $1.remainingCharacters {
                    return $0.createdAt > $1.createdAt
                }
                return $0.remainingCharacters > $1.remainingCharacters
            }.first
        }()
        guard let target, let payload = target.rawUserDataPayload, !payload.isEmpty else {
            return "没有可恢复的会话：账号池里没有「刷新令牌仍有效」的账号，请手动登录一次或注册新号"
        }

        let restored = await reinjectSessionPayload(
            payload,
            activateTypeless: true,
            resetDeviceIdentity: false
        )
        guard restored else {
            return "恢复「\(target.email)」会话失败：\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))"
        }
        // 等待调试端口真正起来再读额度。
        //
        // v2.9.0 实测：CLI 里 `reinjectSessionPayload` 只是**提交**了 openApplication，
        // 紧接着 exit(0) 会把启动请求一起带走 —— 打印「已恢复」但 Typeless 根本没起来。
        // 现在必须等到端口可连（同时证明渲染进程已就绪）才算完成。
        guard await waitForQuotaDebugPort(timeout: 15) else {
            return "已写入「\(target.email)」的会话，但 15 秒内没等到 Typeless 起来（调试端口未就绪）"
        }
        // 端口可连不代表渲染页面已经建好（floating-bar 通常晚 1–3 秒）。
        // 再给最多 10 秒逐次重试，避免「明明能读，却报没读到」。
        for _ in 0..<10 {
            if let snapshot = await readQuotaViaCDPBridge() {
                _ = applyQuotaSnapshotToMatchingAccount(snapshot)
                return "已恢复「\(target.email)」并读到额度：\(snapshot.summary)"
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return "已恢复「\(target.email)」的会话；额度暂未读到（刚启动，稍后会自动重试）"
    }

    /// 是否需要「自动修桥」：直读开着、Typeless 在跑、端口不在、且 10 分钟内没修过。
    ///
    /// 只在额度数据已经陈旧（>=10 分钟）时才会被调用 —— 正常抖动不重启 App。
    func shouldRepairQuotaBridge() async -> Bool {
        guard isCDPQuotaEnabled, typelessIsRunning() else { return false }
        // 换号/注册进行中时绝不重启 Typeless —— 那会把正在注入的会话打断。
        guard !isSwitchBusy else { return false }
        if await isQuotaDebugPortReachable() { return false }
        if let last = state.lastCDPBridgeRepairAt, Date().timeIntervalSince(last) < 600 {
            return false
        }
        return true
    }

    /// 让 Typeless 以调试端口重启（用户主动点击 / 额度未知时的自动修复）。
    ///
    /// 为什么必须重启：`--remote-debugging-port` 只在进程启动时生效，
    /// 已经跑着的 Typeless 不会凭空长出 DevTools 端口。
    func restartTypelessWithQuotaDebugPort() async -> String {
        guard !isSwitchBusy else {
            return "换号/同步进行中，跳过带端口重启"
        }
        guard let appPath = typelessAppPath() else {
            return "未找到 /Applications/Typeless.app"
        }
        // 先记时间再动手：即使重启失败，也要让下一次修复至少等 10 分钟，
        // 否则「修不好 → 每分钟重启一次」会变成新的灾难。
        state.lastCDPBridgeRepairAt = Date()
        save()
        let quitLog = await terminateInstalledTypelessApp()
        // 给 Electron 一点收尾时间（它要 flush 会话文件，否则下一次启动可能读到半份缓存）。
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        launchTypelessInBackground(activate: false, quotaDebugPort: cdpQuotaPort)
        var lines = [quitLog]
        lines.append("已用 --remote-debugging-port=\(cdpQuotaPort) 重新拉起 \(appPath)")
        // 等端口起来（最多 15 秒），让用户点完就能看到结果。
        if await waitForQuotaDebugPort(timeout: 15) {
            lines.append("调试端口已就绪：http://127.0.0.1:\(cdpQuotaPort)/json/version")
            return lines.joined(separator: "\n")
        }
        lines.append("等了 15 秒仍未连上端口 —— 可能是新版本改了启动参数，或端口 \(cdpQuotaPort) 被占用")
        return lines.joined(separator: "\n")
    }

    /// 等调试端口就绪（最多 `timeout` 秒）。返回 true 表示端口可连且是 Typeless。
    func waitForQuotaDebugPort(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 1))
        while Date() < deadline {
            if await isQuotaDebugPortReachable() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 端口上是不是 Typeless 的 DevTools。
    func isQuotaDebugPortReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(cdpQuotaPort)/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userAgent = object["User-Agent"] as? String
        else { return false }
        return userAgent.contains("Typeless") || userAgent.contains("Electron")
    }
}

// MARK: - v2.8.0：实时额度监听（CDP 事件）
//
// 轮询负责「我不知道，去问一次」；监听负责「App 自己刷新时，我立刻知道」。
// 两者互补：监听断了不影响轮询，轮询慢也不影响监听。

extension SwitchboardStore {

    /// GUI 启动 / 打开直读开关时调用。非 GUI（daemon）不常驻监听。
    func startLiveQuotaWatcherIfNeeded() {
        guard runMode == .gui, state.settings.isCDPQuotaEnabled else { return }
        guard liveQuotaWatcherTask == nil else { return }

        let watcher = TypelessQuotaLiveWatcher(port: cdpQuotaPort)
        liveQuotaWatcher = watcher
        liveQuotaWatcherTask = Task { [weak self] in
            let stream = await watcher.start()
            for await snapshot in stream {
                guard let self else { break }
                self.ingestLiveQuotaSnapshot(snapshot)
            }
        }
        appendDaemonLog(
            remaining: liveRemainingCharacters,
            email: liveAccountEmail,
            reason: "额度实时监听已启动（端口 \(cdpQuotaPort)）",
            resultID: nil
        )
    }

    func stopLiveQuotaWatcher(reason: String = "停止") {
        liveQuotaWatcherTask?.cancel()
        liveQuotaWatcherTask = nil
        if let watcher = liveQuotaWatcher {
            Task { await watcher.stop() }
        }
        liveQuotaWatcher = nil
        appendDaemonLog(
            remaining: liveRemainingCharacters,
            email: liveAccountEmail,
            reason: "额度实时监听已\(reason)",
            resultID: nil
        )
    }

    /// 开关 / 端口变化后调用：把监听器状态调整到与设置一致。
    func applyLiveQuotaWatcherState() {
        stopLiveQuotaWatcher(reason: "重启（设置变更）")
        startLiveQuotaWatcherIfNeeded()
    }

    /// 收到一条「旁听来的」额度快照。
    ///
    /// 与轮询的区别：这里的事件可能来自 App 自己刚完成的一次刷新，
    /// 所以**不能**用旧的 capturedAt 覆盖更新鲜的轮询结果。
    func ingestLiveQuotaSnapshot(_ snapshot: TypelessQuotaSnapshot) {
        if let last = lastQuotaSyncAt, snapshot.capturedAt < last {
            return
        }
        var snapshot = snapshot
        if snapshot.email == nil {
            snapshot.email = liveAccountEmail.nilIfBlank
        }

        let changed = snapshot.usedCharacters != lastQuotaUsedCharacters
            || snapshot.weeklyLimit != lastQuotaMonthlyLimit

        lastQuotaSyncAt = snapshot.capturedAt
        lastQuotaSyncFresh = true
        lastQuotaSource = .cdpBridge
        lastCDPQuotaFailure = ""
        liveRemainingCharacters = snapshot.remainingCharacters
        liveQuotaEventCount += 1
        lastLiveQuotaEventAt = snapshot.capturedAt

        guard changed else { return }
        _ = applyQuotaSnapshotToMatchingAccount(snapshot)
    }
}
