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

        let key = (apiKey ?? KeychainStore.readAPIKey()).trimmingCharacters(in: .whitespacesAndNewlines)
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
            autoRotateMonitorStatus = "设备用户数超限，自动重置设备并注册中…"
            isRunningSmartSwitch = true
            defer { isRunningSmartSwitch = false }
            let newID = await runOneClickAutomaticReplacement(
                apiKey: key,
                domain: domain,
                expiryTime: 0,
                from: syncedID
            )
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
        // 本周额度 API 未成功时：只展示缓存，绝不据此自动换号（避免陈旧数字误触发）。
        if !lastQuotaSyncFresh {
            lastAutoRotateDecisionReason = "本周额度 API 未刷新成功，跳过换号决策（避免陈旧数字）"
            autoRotateMonitorStatus = "巡检完成：\(weeklyQuotaSummaryLine)；本轮不换号"
            return currentID
        }

        let remaining = state.accounts[currentIndex].remainingCharacters
        lastKnownRemainingForInterval = remaining
        liveRemainingCharacters = remaining

        let threshold = SmartSwitchPolicy.normalizeThreshold(state.settings.autoRotateRemainingThreshold)
        let candidates = smartSwitchCandidates(excluding: currentID)
        let decision = SmartSwitchPolicy.decide(
            currentRemaining: remaining,
            threshold: threshold,
            forceSwitch: false,
            candidates: candidates,
            allowFullAutomaticReplacement: allowCreate
        )
        lastAutoRotateDecisionReason = decision.reason

        var resultID: UUID? = currentID

        switch decision.path {
        case .none:
            // 额度 ≥ 阈值：只监控、不换号；同时后台补热备，保证真到阈值时能秒切。
            autoRotateMonitorStatus = SmartSwitchPolicy.monitorIdleStatus(remaining: remaining, threshold: threshold)
                + " · \(weeklyQuotaSummaryLine)"
            if allowCreate {
                await ensureHotSpareIfNeeded(apiKey: key, domain: domain)
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
                    await ensureHotSpareIfNeeded(apiKey: key, domain: domain)
                }
            } else if allowCreate {
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
                autoRotateMonitorStatus = newID != nil ? "守护中：已注册并切换" : "巡检完成：自动注册失败"
                resultID = newID ?? currentID
            } else {
                statusMessage = "自动静默换号失败：\(lastSilentSwitchFailureReason.ifEmpty("未知原因"))；请配置 MoeMail API Key 或手动补号"
                autoRotateMonitorStatus = "巡检完成：静默切换失败"
            }

        case .fullAutomaticReplacement:
            autoRotateMonitorStatus = "剩余 \(remaining) < \(threshold) 且无备用会话，自动注册中…"
            isRunningSmartSwitch = true
            defer { isRunningSmartSwitch = false }
            let newID = await runOneClickAutomaticReplacement(
                apiKey: key,
                domain: domain,
                expiryTime: 0,
                from: currentID
            )
            autoRotateMonitorStatus = (newID != nil && newID != currentID)
                ? "守护中：已注册并切换"
                : "巡检完成：自动注册未完成"
            resultID = newID ?? currentID
            if allowCreate, newID != nil {
                await ensureHotSpareIfNeeded(apiKey: key, domain: domain)
            }
        }

        return resultID
    }

    /// 后台补齐热备：额度充足时静默注册 1 个可注入会话的备用号，不切换当前使用号。
    func ensureHotSpareIfNeeded(apiKey: String, domain: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !isRunningAutomaticReplacement else { return }

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

    @discardableResult

    func smartSwitchCandidates(excluding currentID: UUID?) -> [SmartSwitchCandidate] {
        state.accounts.compactMap { account in
            guard account.id != currentID else { return nil }
            guard account.isUsable, account.remainingCharacters > 0 else { return nil }
            let payload = account.rawUserDataPayload?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SmartSwitchCandidate(
                id: account.id,
                email: account.email.ifEmpty(account.name),
                remainingCharacters: account.remainingCharacters,
                hasSilentSessionPayload: !payload.isEmpty
            )
        }
    }

}
