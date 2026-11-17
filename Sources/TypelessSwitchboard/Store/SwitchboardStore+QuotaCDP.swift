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

    /// 让 Typeless 以调试端口重启（用户主动点击时才调用）。
    ///
    /// 为什么必须重启：`--remote-debugging-port` 只在进程启动时生效，
    /// 已经跑着的 Typeless 不会凭空长出 DevTools 端口。
    func restartTypelessWithQuotaDebugPort() async -> String {
        guard let appPath = typelessAppPath() else {
            return "未找到 /Applications/Typeless.app"
        }
        let quitLog = await terminateInstalledTypelessApp()
        // 给 Electron 一点收尾时间（它要 flush 会话文件，否则下一次启动可能读到半份缓存）。
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        launchTypelessInBackground(activate: false, quotaDebugPort: cdpQuotaPort)
        var lines = [quitLog]
        lines.append("已用 --remote-debugging-port=\(cdpQuotaPort) 重新拉起 \(appPath)")
        // 等端口起来（最多 12 秒），让用户点完就能看到结果。
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await isQuotaDebugPortReachable() {
                lines.append("调试端口已就绪：http://127.0.0.1:\(cdpQuotaPort)/json/version")
                return lines.joined(separator: "\n")
            }
        }
        lines.append("等了 12 秒仍未连上端口 —— 可能是新版本改了启动参数，或端口 \(cdpQuotaPort) 被占用")
        return lines.joined(separator: "\n")
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
