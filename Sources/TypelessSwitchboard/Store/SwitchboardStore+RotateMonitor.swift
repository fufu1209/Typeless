import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func startRotateMonitor(kickImmediately: Bool = false) {
        if rotateMonitorTask != nil {
            if kickImmediately {
                // 已在跑：额外触发一轮，不拆掉现有循环。
                Task { [weak self] in
                    _ = await self?.performAutoRotateCheck()
                }
            }
            return
        }
        let threshold = SmartSwitchPolicy.normalizeThreshold(state.settings.autoRotateRemainingThreshold)
        autoRotateMonitorStatus = kickImmediately
            ? "无感守护运行中：立即巡检…"
            : "无感守护运行中：约 \(SmartSwitchPolicy.defaultStartupDelaySeconds) 秒后首次读额度（阈值 \(threshold)）"
        rotateMonitorTask = Task { [weak self] in
            if !kickImmediately {
                do {
                    try await Task.sleep(nanoseconds: SmartSwitchPolicy.defaultStartupDelaySeconds * 1_000_000_000)
                } catch {
                    return
                }
            }

            while !Task.isCancelled {
                guard let self = self else { break }
                if self.state.settings.isAutoRotateEnabled {
                    _ = await self.performAutoRotateCheck()
                } else {
                    break
                }

                let delay = SmartSwitchPolicy.nextCheckDelaySeconds(
                    remaining: self.lastKnownRemainingForInterval,
                    threshold: self.state.settings.autoRotateRemainingThreshold,
                    intervalMinutes: self.state.settings.autoRotateCheckIntervalMinutes
                )
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } catch {
                    break
                }
            }
            await MainActor.run {
                self?.autoRotateMonitorStatus = self?.state.settings.isAutoRotateEnabled == true
                    ? "无感守护已暂停（可点菜单「立即巡检额度」恢复）"
                    : "无感守护已关闭"
            }
        }
    }

    func stopRotateMonitor() {
        rotateMonitorTask?.cancel()
        rotateMonitorTask = nil
        if !state.settings.isAutoRotateEnabled {
            autoRotateMonitorStatus = "无感守护已关闭"
        }
    }

    /// 休眠唤醒 / 用户点菜单时调用：确保守护循环在跑，并立刻同步一轮额度。
    func resumeRotateMonitorAfterWakeOrManualKick() {
        guard state.settings.isAutoRotateEnabled else {
            autoRotateMonitorStatus = "无感守护已关闭"
            return
        }
        if rotateMonitorTask == nil {
            startRotateMonitor(kickImmediately: true)
        } else {
            Task { [weak self] in
                _ = await self?.performAutoRotateCheck()
            }
        }
    }

    /// 用户主入口：点一下即可。优先池内静默切换，没有可注入会话时再全自动注册。

    func performAutoRotateCheck(apiKey: String? = nil) async -> UUID? {
        guard !isAutoRotateCheckInFlight else {
            autoRotateMonitorStatus = "巡检进行中（跳过重叠触发）"
            return nil
        }
        guard !isRunningAutomaticReplacement, !isRunningSmartSwitch else {
            autoRotateMonitorStatus = "换号进行中，本轮巡检跳过"
            return nil
        }

        isAutoRotateCheckInFlight = true
        defer { isAutoRotateCheckInFlight = false }

        lastAutoRotateCheckAt = Date()
        autoRotateMonitorStatus = "正在同步额度…"

        // v2.6.8：apiKey 为 nil 时按运行模式解析。边车优先（两种模式都一样，
        // 边车就是同一个值的镜像，读它没有授权面）；只有边车为空时 GUI 才走
        // 钥匙串（首跑装 Key 之前条目不存在，秒返回空串，不会卡）。
        let key = (apiKey ?? resolveAPIKeyForCurrentMode()).trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = state.settings.domains.first ?? ""
        let allowCreate = state.settings.autoCreateWhenPoolEmpty && !key.isEmpty

        let syncedID = await syncActiveAppSessionAndQuota()
        if lastSyncHitDeviceUserLimit {
            lastAutoRotateDecisionReason = "检测到设备登录用户数超限，跳过静默切换并全自动重置设备身份"
            guard allowCreate else {
                autoRotateMonitorStatus = "巡检完成：设备用户数超限，但未允许自动创建新号"
                statusMessage = "设备登录用户数已超限；请配置 MoeMail API Key 并开启「池空时自动注册新号」"
                return nil
            }
            if isRunningAutomaticReplacement || isRunningSmartSwitch {
                autoRotateMonitorStatus = "巡检完成：设备超限但其它换号进行中"
                return nil
            }
            // v2.6.9：设备超限的重置+注册同样受退避约束 —— 这条路径失败时
            // （MoeMail 不可用、注册被拒）旧逻辑会每分钟重烧一次地址。
            if isAutoRegistrationCoolingDown {
                let hint = autoRegistrationCooldownStatus
                autoRotateMonitorStatus = "巡检完成：设备超限待重置 · \(hint)"
                return nil
            }
            autoRotateMonitorStatus = "设备用户数超限，自动重置设备并注册中…"
            isRunningSmartSwitch = true
            defer { isRunningSmartSwitch = false }
            let newID = await runOneClickAutomaticReplacement(
                apiKey: key,
                domain: domain,
                expiryTime: 0,
                from: syncedID
            )
            noteAutoRegistrationAttempt(success: newID != nil)
            autoRotateMonitorStatus = newID != nil ? "守护中：已因设备超限完成重置换号" : "巡检完成：设备超限后的自动注册失败"
            return newID
        }

        guard let currentID = syncedID else {
            lastAutoRotateDecisionReason = "无法读取官方 App 登录态，本轮巡检跳过"
            autoRotateMonitorStatus = "巡检完成：未读到登录态（请保持 Typeless 已登录）"
            return nil
        }
        guard let currentIndex = accountIndex(id: currentID) else {
            autoRotateMonitorStatus = "巡检完成：账号未入库"
            return nil
        }

        liveAccountEmail = state.accounts[currentIndex].email

        // 本周额度 API 未成功时的处置。
        //
        // v2.6.7 起区分「偶发失败」与「持续失效」，不再一律跳过换号决策：
        //
        //   偶发失败（数据还不太陈旧）→ 继续保守跳过。一两次网络抖动就换号，
        //     等于用陈旧数字做决策，正是 v2.6.0 要避免的。
        //
        //   持续失效（距上次成功同步 ≥ 10 分钟）→ 降级用**本地缓存估算**继续决策。
        //     旧逻辑在这里 `return`，而 API 一旦长期不可用，自动换号就永久停摆：
        //     本机实测 2026-10-14 起 Typeless 服务端对 /user/usage_stats 上线
        //     JA3/TLS 指纹白名单（HTTP 418 / ja3_tls_code），到 10-24 已停摆 11 天、
        //     3182 条「跳过换号决策」，用户额度用完只能手动点「智能换号」。
        //
        //     判据用**时间**而非失败次数：守护是 launchd 拉起的单次进程
        //     （--daemon-check 跑完就退），内存计数每次重启归零，永远攒不到阈值；
        //     而 lastQuotaSyncAt 是持久化字段，天然跨进程累积。
        //
        // ⚠️ 降级口径必须保守：本地 remaining 是上次成功同步的快照，此后的真实
        //    消耗没有记录 ⇒ 会**高估**剩余。所以阈值按 quotaDegradedThresholdMultiplier
        //    放大，宁可早换，不可该换不换。
        var degradedEstimate = false
        if !lastQuotaSyncFresh {
            // 客户端指纹被拒是「本地无解、必须升级 App」的状态，与网络问题分开报，
            // 不能靠降级掩盖 —— 降级只会让用户以为还在自动保护中。
            if lastSyncHitClientNotSupported {
                lastAutoRotateDecisionReason = "Typeless 已拒绝本客户端（客户端指纹过期），自动换号停摆：请升级 Typeless Switchboard"
                autoRotateMonitorStatus = "⚠️ 自动换号已停摆：Typeless 拒绝本客户端指纹，需要新版本 App 适配"
                return currentID
            }
            // v2.7.5：官方额度 API 被墙时，先尝试读屏取 Typeless 界面上的活额度。
            // 读到就用它当剩余字数、走正常阈值决策（<200 可精准触发）；读不到再降级到时间轮换。
            if let screenRemaining = await readTypelessOnScreenQuota() {
                // remainingCharacters 是只读计算属性（max(monthlyLimit - usedCharacters, 0)），
                // 要注入读屏得到的活剩余，只能改写 usedCharacters，保持 monthlyLimit 不变。
                let acct = state.accounts[currentIndex]
                state.accounts[currentIndex].usedCharacters = max(acct.monthlyLimit - screenRemaining, 0)
                liveRemainingCharacters = screenRemaining
                lastAutoRotateDecisionReason = "额度取 Typeless 界面（API 被墙·读屏兜底），剩余 \(screenRemaining)"
            } else if isQuotaDataStaleBeyondDegradeThreshold {
                degradedEstimate = true
                isQuotaAPIDegraded = true
                let staleMinutes = lastQuotaSyncAt.map { Int(Date().timeIntervalSince($0) / 60) } ?? -1
                quotaDegradedReason = "官方额度 API 已 \(staleMinutes) 分钟未返回新鲜数值，降级用本地缓存估算驱动换号（阈值已放大）"
                lastAutoRotateDecisionReason = quotaDegradedReason
            } else {
                lastAutoRotateDecisionReason = "本周额度 API 未刷新成功，跳过换号决策（避免陈旧数字）"
                autoRotateMonitorStatus = "巡检完成：\(weeklyQuotaSummaryLine)；本轮不换号"
                return currentID
            }
        }

        let remaining = state.accounts[currentIndex].remainingCharacters
        lastKnownRemainingForInterval = remaining
        liveRemainingCharacters = remaining

        let baseThreshold = SmartSwitchPolicy.normalizeThreshold(state.settings.autoRotateRemainingThreshold)
        let threshold = degradedEstimate
            ? max(baseThreshold * SwitchboardStore.quotaDegradedThresholdMultiplier, baseThreshold)
            : baseThreshold
        let candidates = smartSwitchCandidates(excluding: currentID)

        // v2.7.1：降级模式（额度 API 长期不可用，现在是常态）下，冻结的 remaining 永远 ≥ 阈值，
        // 常规 decide 必走 .none。改为：池内有新鲜备用号且冷却已过，则强制轮换过去，
        // 让用户不卡在已耗尽号上（与手动「智能换号」等价）。
        var decision: SmartSwitchDecision
        if degradedEstimate, let forced = makeForcedRotationDecision(candidates: candidates) {
            decision = forced
            lastAutoRotateDecisionReason = forced.reason
        } else {
            decision = SmartSwitchPolicy.decide(
                currentRemaining: remaining,
                threshold: threshold,
                forceSwitch: false,
                candidates: candidates,
                allowFullAutomaticReplacement: allowCreate
            )
        }
        lastAutoRotateDecisionReason = decision.reason

        var resultID: UUID? = currentID

        switch decision.path {
        case .none:
            // 额度 ≥ 阈值：只监控、不换号；同时后台补热备，保证真到阈值时能秒切。
            autoRotateMonitorStatus = SmartSwitchPolicy.monitorIdleStatus(remaining: remaining, threshold: threshold)
                + " · \(weeklyQuotaSummaryLine)"
                + (degradedEstimate ? " · ⚠️ 估算模式（官方额度 API 不可用，阈值为正常 \(SwitchboardStore.quotaDegradedThresholdMultiplier) 倍）" : "")
            if allowCreate {
                await ensureHotSpareIfNeeded(apiKey: key, domain: domain, respectCooldown: true)
            }

        case .silentPoolSwitch:
            guard let targetID = decision.targetAccountID else {
                autoRotateMonitorStatus = "巡检完成：决策缺少目标账号"
                break
            }
            if isRunningAutomaticReplacement || isRunningSmartSwitch {
                autoRotateMonitorStatus = "巡检完成：其它换号进行中，跳过静默切换"
                break
            }
            autoRotateMonitorStatus = "剩余 \(remaining) < \(threshold)，正在静默换号（含设备身份轮换）…"
            let success = await switchActiveAccountSilently(
                to: targetID,
                markPreviousExhausted: currentID,
                activateTypeless: false
            )
            if success {
                statusMessage = "无感换号完成 → \(decision.targetEmail ?? "")"
                autoRotateMonitorStatus = "守护中：已静默切换并轮换设备身份，继续监测"
                resultID = targetID
                if allowCreate {
                    await ensureHotSpareIfNeeded(apiKey: key, domain: domain, respectCooldown: true)
                }
            } else if allowCreate {
                // v2.6.9：注册退避。失败后不立刻重试，否则守护每分钟烧一个
                // MoeMail 地址 + 一轮 Playwright（用户明确要求别过度占资源）。
                if isAutoRegistrationCoolingDown {
                    let hint = autoRegistrationCooldownStatus
                    statusMessage = "静默切换失败（\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))）；\(hint)"
                    autoRotateMonitorStatus = "巡检完成：静默切换失败 · \(hint)"
                    break
                }
                autoRotateMonitorStatus = SmartSwitchPolicy.isDeviceUserLimitError(lastSilentSwitchFailureReason)
                    ? "静默命中设备限制，自动注册中…"
                    : "静默失败，自动注册中…"
                isRunningSmartSwitch = true
                defer { isRunningSmartSwitch = false }
                let newID = await runOneClickAutomaticReplacement(
                    apiKey: key,
                    domain: domain,
                    expiryTime: 0,
                    from: currentID
                )
                noteAutoRegistrationAttempt(success: newID != nil)
                autoRotateMonitorStatus = newID != nil ? "守护中：已注册并切换" : "巡检完成：自动注册失败"
                resultID = newID ?? currentID
            } else {
                statusMessage = "自动静默换号失败：\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))；请配置 MoeMail API Key 或手动补号"
                autoRotateMonitorStatus = "巡检完成：静默切换失败"
            }

        case .fullAutomaticReplacement:
            // v2.6.9：同上，注册退避。
            if isAutoRegistrationCoolingDown {
                let hint = autoRegistrationCooldownStatus
                autoRotateMonitorStatus = "巡检完成：待自动注册 · \(hint)"
                break
            }
            autoRotateMonitorStatus = "剩余 \(remaining) < \(threshold) 且无备用会话，自动注册中…"
            isRunningSmartSwitch = true
            defer { isRunningSmartSwitch = false }
            let newID = await runOneClickAutomaticReplacement(
                apiKey: key,
                domain: domain,
                expiryTime: 0,
                from: currentID
            )
            noteAutoRegistrationAttempt(success: newID != nil)
            autoRotateMonitorStatus = (newID != nil && newID != currentID)
                ? "守护中：已注册并切换"
                : "巡检完成：自动注册未完成"
            resultID = newID ?? currentID
            if allowCreate, newID != nil {
                await ensureHotSpareIfNeeded(apiKey: key, domain: domain, respectCooldown: true)
            }
        }

        return resultID
    }

    /// 后台补齐热备：额度充足时静默注册 1 个可注入会话的备用号，不切换当前使用号。
    ///
    /// - Parameter respectCooldown: 自治路径（额度巡检）传 true —— 注册失败后退避中
    ///   就跳过，不重复烧 MoeMail 地址；用户主动发起的路径传 false，立即执行。
    func ensureHotSpareIfNeeded(
        apiKey: String,
        domain: String,
        respectCooldown: Bool = false
    ) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isRunningAutomaticReplacement else { return }
        if respectCooldown, isAutoRegistrationCoolingDown { return }

        let target = SmartSwitchPolicy.normalizeHotSpareTarget(state.settings.hotSpareTargetCount)
        guard target > 0 else { return }

        let activeID = liveAccountEmail.isEmpty
            ? nil
            : state.accounts.first { $0.email.lowercased() == liveAccountEmail.lowercased() }?.id
        let candidates = smartSwitchCandidates(excluding: activeID)
        guard SmartSwitchPolicy.needsHotSpare(candidates: candidates, target: target) else { return }

        autoRotateMonitorStatus = "守护中：补齐热备账号…"
        // 热备只走 Playwright 独立 profile，不碰桌面登录态。
        let spareID = await runOneClickAutomaticReplacement(
            apiKey: apiKey,
            domain: domain,
            expiryTime: 0,
            from: nil,
            preserveCurrentAccount: true
        )
        noteAutoRegistrationAttempt(success: spareID != nil)
        if let spareID, let index = accountIndex(id: spareID) {
            let hasPayload = !(state.accounts[index].rawUserDataPayload?.isEmpty ?? true)
            autoRotateMonitorStatus = hasPayload
                ? "守护中：热备已就绪（\(state.accounts[index].email)）"
                : "守护中：热备已注册但会话缓存未固化（下次可再同步）"
        } else {
            autoRotateMonitorStatus = "守护中：热备补齐未完成（下次巡检再试）"
        }
    }

    func runSmartSwitch(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        from currentID: UUID?,
        forceSwitch: Bool = true
    ) async -> UUID? {
        guard !isRunningSmartSwitch, !isRunningAutomaticReplacement else {
            statusMessage = "换号正在进行中，请稍候"
            return currentID
        }

        isRunningSmartSwitch = true
        defer { isRunningSmartSwitch = false }

        statusMessage = forceSwitch ? "正在智能换号…" : "正在根据额度自动换号…"
        let syncedID = await syncActiveAppSessionAndQuota()
        // 设备用户数超限：静默池切换只会复用旧 deviceId，直接走全自动 resetDevice。
        if lastSyncHitDeviceUserLimit {
            lastAutoRotateDecisionReason = "检测到设备登录用户数超限，跳过静默切换并全自动重置设备身份"
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "设备登录用户数已超限，且未配置 MoeMail API Key，无法自动注册新号。请配置后重试，或手动全自动换号。"
                return currentID
            }
            statusMessage = "设备登录用户数已超限，正在重置设备身份并全自动注册换号…"
            return await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: expiryTime,
                from: syncedID ?? currentID,
                interactive: forceSwitch
            )
        }

        let resolvedCurrentID = syncedID ?? currentID
        let currentRemaining: Int? = {
            guard let id = resolvedCurrentID, let index = accountIndex(id: id) else { return nil }
            return state.accounts[index].remainingCharacters
        }()
        if let currentRemaining {
            lastKnownRemainingForInterval = currentRemaining
            liveRemainingCharacters = currentRemaining
        }

        let candidates = smartSwitchCandidates(excluding: resolvedCurrentID)
        let decision = SmartSwitchPolicy.decide(
            currentRemaining: currentRemaining,
            threshold: state.settings.autoRotateRemainingThreshold,
            forceSwitch: forceSwitch,
            candidates: candidates,
            allowFullAutomaticReplacement: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        lastAutoRotateDecisionReason = decision.reason

        switch decision.path {
        case .none:
            statusMessage = decision.reason
            return resolvedCurrentID

        case .silentPoolSwitch:
            guard let targetID = decision.targetAccountID else {
                statusMessage = "智能换号决策异常：缺少目标账号"
                return resolvedCurrentID
            }
            if isRunningAutomaticReplacement {
                statusMessage = "全自动换号进行中，智能换号已跳过"
                return resolvedCurrentID
            }
            statusMessage = decision.reason
            let success = await switchActiveAccountSilently(
                to: targetID,
                markPreviousExhausted: resolvedCurrentID,
                activateTypeless: forceSwitch
            )
            if success {
                statusMessage = "已静默切换到「\(decision.targetEmail ?? "")」（已轮换设备身份）"
                // 换走当前号后补热备，用户无感。
                Task { await self.ensureHotSpareIfNeeded(apiKey: apiKey, domain: domain) }
                return targetID
            }
            if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                statusMessage = "静默切换失败：\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))；且未配置 MoeMail API Key，无法自动注册新号"
                return resolvedCurrentID
            }
            let limitHint = SmartSwitchPolicy.isDeviceUserLimitError(lastSilentSwitchFailureReason)
                || lastSyncHitDeviceUserLimit
            statusMessage = limitHint
                ? "静默切换命中设备用户数限制，正在降级为全自动重置设备并注册换号…"
                : "静默切换失败，正在降级为全自动注册换号…"
            return await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: expiryTime,
                from: resolvedCurrentID,
                interactive: forceSwitch
            )

        case .fullAutomaticReplacement:
            statusMessage = decision.reason
            return await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: expiryTime,
                from: resolvedCurrentID,
                interactive: forceSwitch
            )
        }
    }

    /// 降级模式下「额度 API 长期不可用」时的强制轮换决策。
    ///
    /// 背景：Typeless 给 `/user/usage_stats` 上了 Cloudflare 指纹白名单，Node / curl_cffi /
    /// Playwright 等**所有外部客户端**都被拦（HTTP 418 / ja3_tls_code），只有官方 App 自己的
    /// 浏览器上下文能过；而官方 App 不落盘周额度、二进制启动器还拒绝 `--remote-debugging-port`，
    /// 所以「外部主动读额度」这条路彻底走不通 —— `quotaFresh` 永远为 false，lastQuotaSyncAt 也
    /// 永远不更新 ⇒ 一直停在降级分支。
    ///
    /// 老逻辑在降级分支里仍用「最后一次成功同步的冻结 remaining」做决策，冻结值不会递减 ⇒
    /// 永远 ≥ 阈值 ⇒ 永不换号，用户额度用完只能手动点「智能换号」。
    ///
    /// 这里改为：池内有「可静默注入会话」的新鲜号、且距上次强制轮换算起已超冷却，就轮换过去
    /// （与手动「智能换号」等价），保证用户**永远不会卡在已耗尽的号上**。冷却避免守护每分钟烧一轮。
    static let quotaDegradedForceRotationCooldownMinutes = 90.0

    func makeForcedRotationDecision(candidates: [SmartSwitchCandidate]) -> SmartSwitchDecision? {
        let eligible = candidates.filter { $0.hasSilentSessionPayload }
        guard !eligible.isEmpty else { return nil }
        let cooldown = Self.quotaDegradedForceRotationCooldownMinutes * 60
        if let last = state.lastForcedRotationAt, Date().timeIntervalSince(last) < cooldown {
            return nil
        }
        let best = eligible.max(by: { $0.remainingCharacters < $1.remainingCharacters })
        state.lastForcedRotationAt = Date()
        return SmartSwitchDecision(
            path: .silentPoolSwitch,
            targetAccountID: best?.id,
            targetEmail: best?.email,
            reason: "额度 API 长期不可用（Typeless 已封锁所有外部客户端）：轮换到池内新鲜号「\(best?.email ?? "")」（冷却 \(Int(Self.quotaDegradedForceRotationCooldownMinutes)) 分钟后再次轮换）"
        )
    }

    func smartSwitchCandidates(excluding currentID: UUID?) -> [SmartSwitchCandidate] {
        state.accounts.compactMap { account in
            guard account.id != currentID else { return nil }
            guard account.isUsable, account.remainingCharacters > 0 else { return nil }
            return SmartSwitchCandidate(
                id: account.id,
                email: account.email.ifEmpty(account.name),
                remainingCharacters: account.remainingCharacters,
                hasSilentSessionPayload: account.isSilentlySwitchable
            )
        }
    }

}
