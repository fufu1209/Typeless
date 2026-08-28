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
            let snapshot = AccountQuotaSnapshot(
                id: account.id,
                email: account.email,
                status: Self.snapshotStatus(from: account.status),
                reviewState: Self.snapshotReviewState(from: account.effectiveReviewState),
                usedCharacters: account.usedCharacters,
                monthlyLimit: account.monthlyLimit,
                lastResetAt: account.lastResetAt,
                createdAt: account.createdAt,
                hasSilentSessionPayload: !(account.rawUserDataPayload?.isEmpty ?? true)
            )
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

    static func snapshotStatus(from status: AccountStatus) -> AccountQuotaSnapshot.Status {
        switch status {
        case .available: return .available
        case .nearlySpent: return .nearlySpent
        case .exhausted: return .exhausted
        case .paused: return .paused
        }
    }

    static func snapshotReviewState(from state: ReviewState) -> AccountQuotaSnapshot.ReviewState {
        switch state {
        case .pending: return .pending
        case .approved: return .approved
        case .rejected: return .rejected
        }
    }

    /// v2.1.0 接线：候选池生成前先复活已过期账号，再走原 SmartSwitchPolicy 决策。
    /// 这样 `smartSwitchCandidates` 会自然把复活号纳入静默池，无需改 decide() 内部逻辑。
    func smartSwitchCandidatesAfterRevival(excluding currentID: UUID?) -> [SmartSwitchCandidate] {
        _ = reviveExpiredAccountsIfNeeded()
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
