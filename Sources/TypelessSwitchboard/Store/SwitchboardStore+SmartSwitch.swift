import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {



    func reviveExpiredAccountsIfNeeded(now: Date = Date()) -> [String] {
        let mode = QuotaCycleMode.calendarWeek
        let calendar = Calendar.current
        var revivedEmails: [String] = []
        let now = now
        for index in state.accounts.indices {
            let account = state.accounts[index]
            // v2.5.3：桥接收敛到 Account.quotaSnapshot，避免与 UI 的周期口径分叉。
            let snapshot = account.quotaSnapshot
            guard QuotaCycleEngine.shouldRevive(account: snapshot, now: now, mode: mode, calendar: calendar) else { continue }
            state.accounts[index].status = .available
            state.accounts[index].usedCharacters = 0
            state.accounts[index].lastResetAt = now
            let displayEmail = account.email.ifEmpty(account.name)
            revivedEmails.append(displayEmail)
        }
        if !revivedEmails.isEmpty {
            save()
        }
        return revivedEmails
    }

    // MARK: - v2.5.4 周额度周期看门狗

    /// 独立于「无感守护」开关的周额度复活看门狗。
    ///
    /// 为什么必须独立：`reviveExpiredAccountsIfNeeded` 原来只挂在
    /// `syncActiveAppSessionAndQuota` 里，而同步依赖 node 脚本和 Typeless 登录态，
    /// 且巡检循环受 `isAutoRotateEnabled` 控制。关掉守护、或整个周末没开 App，
    /// 周一 00:00 之后的复活就不会发生，账号被白白闲置一整周。
    ///
    /// 看门狗做两件事：
    /// 1. 启动立刻复活一次（覆盖「周末没开 App」）；
    /// 2. 精确睡到下一个周一 00:00 再复活，然后重新排程（覆盖「App 一直开着跨过周界」）。
    func startQuotaCycleWatchdogIfNeeded() {
        guard quotaCycleWatchdogTask == nil else { return }
        quotaCycleWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                await MainActor.run { self.performWeeklyRevivalIfNeeded(reason: "周期看门狗") }

                // 睡到下一个周一 00:00（+2 秒余量避开边界抖动），上限 7 天防呆。
                let waitSeconds = QuotaCycleEngine.secondsUntilReset(
                    now: Date(),
                    mode: .calendarWeek,
                    calendar: .current
                )
                let clamped = min(max(waitSeconds + 2, 60), QuotaCycleEngine.weekSeconds)
                do {
                    try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                } catch {
                    break
                }
            }
        }
    }

    func stopQuotaCycleWatchdog() {
        quotaCycleWatchdogTask?.cancel()
        quotaCycleWatchdogTask = nil
    }

    /// 复活并把结果同步到 UI 状态。所有入口（启动 / 看门狗 / 同步 / 手动）都走这里，
    /// 保证「复活了哪些号」只有一种记录方式，不会出现 UI 与日志说法不一致。
    @discardableResult
    func performWeeklyRevivalIfNeeded(reason: String) -> [String] {
        let revived = reviveExpiredAccountsIfNeeded()
        guard !revived.isEmpty else { return [] }
        lastWeeklyRevivalAt = Date()
        lastWeeklyRevivalEmails = revived
        statusMessage = "本周额度已刷新，自动复活 \(revived.count) 个账号（\(reason)）：\(revived.joined(separator: "、"))"
        return revived
    }

    /// v2.1.0 接线：候选池生成前先复活已过期账号，再走原 SmartSwitchPolicy 决策。
    /// 这样 `smartSwitchCandidates` 会自然把复活号纳入静默池，无需改 decide() 内部逻辑。
    func smartSwitchCandidatesAfterRevival(excluding currentID: UUID?) -> [SmartSwitchCandidate] {
        _ = performWeeklyRevivalIfNeeded(reason: "换号决策")
        return smartSwitchCandidates(excluding: currentID)
    }

    func switchActiveAccountSilently(
        to accountID: UUID,
        markPreviousExhausted previousID: UUID? = nil,
        activateTypeless: Bool = false
    ) async -> Bool {
        lastSilentSwitchFailureReason = ""
        lastSyncHitDeviceUserLimit = false

        guard let index = accountIndex(id: accountID) else {
            lastSilentSwitchFailureReason = "目标账号不存在"
            return false
        }
        let targetAccount = state.accounts[index]
        guard let payload = targetAccount.rawUserDataPayload, !payload.isEmpty else {
            lastSilentSwitchFailureReason = "目标账号缺少可注入的桌面会话缓存"
            return false
        }

        // 静默换号也必须轮换设备身份，否则同一 deviceId 会不断挂新 user，最终触发服务端设备用户数上限。
        let injectOK = await reinjectSessionPayload(
            payload,
            activateTypeless: activateTypeless,
            resetDeviceIdentity: true
        )
        guard injectOK else {
            if lastSilentSwitchFailureReason.isEmpty {
                lastSilentSwitchFailureReason = "写入桌面会话或重置设备身份失败"
            }
            return false
        }

        var verified = false
        for attempt in 0..<SmartSwitchPolicy.silentSwitchVerifyAttempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: SmartSwitchPolicy.silentSwitchVerifyDelaySeconds * 1_000_000_000)
            }
            if lastSyncHitDeviceUserLimit {
                lastSilentSwitchFailureReason = "设备登录用户数已超限，静默会话不可用"
                return false
            }
            // 验证只需要本地解密出的当前桌面账号，无需每次请求官方额度 API。
            if let synced = await syncActiveAppSessionAndQuota(localOnly: true),
               let syncedIndex = accountIndex(id: synced),
               state.accounts[syncedIndex].email.lowercased() == targetAccount.email.lowercased() {
                liveAccountEmail = state.accounts[syncedIndex].email
                liveRemainingCharacters = state.accounts[syncedIndex].remainingCharacters
                lastKnownRemainingForInterval = liveRemainingCharacters
                verified = true
                break
            }
            if lastSyncHitDeviceUserLimit {
                lastSilentSwitchFailureReason = syncStatusMessage.ifEmpty("设备登录用户数已超限，静默会话不可用")
                return false
            }
        }

        guard verified else {
            if lastSilentSwitchFailureReason.isEmpty {
                lastSilentSwitchFailureReason = lastSyncHitDeviceUserLimit
                    ? "设备登录用户数已超限，静默会话不可用"
                    : "静默注入后未能确认目标账号「\(targetAccount.email)」已生效"
            }
            return false
        }

        // 本地校验已确认切到目标号：补一次完整同步刷新本周额度数字（失败不影响已确认结果）。
        _ = await syncActiveAppSessionAndQuota()

        if let previousID,
           let previousIndex = accountIndex(id: previousID),
           previousID != accountID {
            state.accounts[previousIndex].status = .exhausted
            state.accounts[previousIndex].usedCharacters = state.accounts[previousIndex].monthlyLimit
            state.accounts[previousIndex].notes = "已由无感换号切换到：\(targetAccount.email.ifEmpty(targetAccount.name))"
        }

        for idx in state.settings.checklist.indices {
            state.settings.checklist[idx].isDone = false
        }

        // v2.5.3 兜底：若拉起后桌面端仍被判为新用户（例如 Typeless 启动时重写了 storage），
        // 这里不打断用户（不退出重启），只把文件补写成最终态，保证下次启动不会再弹引导。
        if typelessDesktopIsNewUser() {
            let backfill = writeTypelessDesktopOnboardingFiles(
                storageURL: typelessStorageURL(),
                onboardingURL: typelessOnboardingURL(),
                expectedEmail: nil
            )
            appendOnboardingPatchLog("无感换号后补写引导标记：\(backfill.joined(separator: "；"))")
        }

        liveAccountEmail = targetAccount.email
        if liveRemainingCharacters == nil {
            liveRemainingCharacters = targetAccount.remainingCharacters
        }
        save()
        return true
    }

    /// 退出 Typeless →（可选）重置设备身份 → 写入加密会话 → 后台重开（默认不抢前台）。
    /// - Parameter resetDeviceIdentity: 静默换号应传 true，避免同一 deviceId 挂过多账号触发服务端限制。
    func reinjectSessionPayload(
        _ payload: String,
        activateTypeless: Bool,
        resetDeviceIdentity: Bool = true
    ) async -> Bool {
        _ = await terminateInstalledTypelessApp()

        if resetDeviceIdentity {
            let backupRoot = automationDirectoryURL()
                .appendingPathComponent("DesktopSessionBackups", isDirectory: true)
                .appendingPathComponent("silent-\(Self.safeTimestamp())", isDirectory: true)
            let resetLog = resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: backupRoot)
            // 设备重置会删掉 user-data.json；紧接着用目标会话 payload 重新写入。
            if resetLog.contains(where: { $0.contains("失败") && !$0.contains("未发现") }) {
                lastSilentSwitchFailureReason = resetLog.first { $0.contains("失败") } ?? "设备身份重置失败"
                // 仍继续尝试写入会话，但保留失败原因供上层降级。
            }
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        let scriptURL = folder.appendingPathComponent("write-active-session.js")

        let result = await Task.detached(priority: .userInitiated) {
            return SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path, payload],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 10
            )
        }.value

        guard result.status == 0 else {
            lastSilentSwitchFailureReason = "写入桌面会话失败：\(result.output.ifEmpty("退出码 \(result.status)"))"
            return false
        }

        // 确保 Typeless 数据目录存在，避免设备缓存被清后 Electron 冷启动路径异常。
        for directory in typelessDesktopSessionDataDirectories() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // v2.5.3：无感换号的关键一步。
        // 会话缓存刚写入时 userData.is_new_user=true，若直接拉起 Typeless，
        // 它冷启动读盘就会判定为新用户并弹出新手引导 —— 这就是「换号后又要走新手引导」的根因。
        // 这里在**拉起之前**把引导完成标记写死，Typeless 第一次读盘即是非新用户，全程无感。
        let patchLog = writeTypelessDesktopOnboardingFiles(
            storageURL: typelessStorageURL(),
            onboardingURL: typelessOnboardingURL(),
            expectedEmail: nil
        )
        if patchLog.contains(where: { $0.contains("失败") }) {
            appendOnboardingPatchLog("无感换号写引导标记异常：\(patchLog.joined(separator: "；"))")
        }

        launchTypelessInBackground(activate: activateTypeless)
        // 给 Electron 一点时间读入新会话并生成新的 device.cache。
        try? await Task.sleep(nanoseconds: SmartSwitchPolicy.silentInjectSettleSeconds * 1_000_000_000)
        return true
    }

    func launchTypelessInBackground(activate: Bool) {
        guard let path = typelessAppPath() else {
            if activate { openInstalledTypelessApp() }
            return
        }
        let url = URL(fileURLWithPath: path)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
