import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func syncActiveAppSessionAndQuota(localOnly: Bool = false) async -> UUID? {
        isSyncingSession = true
        lastSyncHitDeviceUserLimit = false
        if !localOnly {
            // 只有完整同步才清空「新鲜额度」标记；本地校验不动该标记，避免误判额度陈旧。
            lastQuotaSyncFresh = false
        }
        // v2.1.0 接线：每次同步都让 QuotaCycleEngine 先把过期的 .exhausted 账号翻成 .available。
        // 周一 00:00 之后第一次同步就会触发「账号一复活」，避免额度错杀。
        let revivedSnapshot = reviveExpiredAccountsIfNeeded()
        if !revivedSnapshot.isEmpty {
            syncStatusMessage = "已复活 \(revivedSnapshot.count) 个账号（本周额度刷新）：\(revivedSnapshot.joined(separator: "、"))"
            statusMessage = syncStatusMessage
        }
        syncStatusMessage = localOnly
            ? "正在本地校验 Typeless 登录态..."
            : "正在读取本地 Typeless 登录状态并向云端同步本周额度..."
        statusMessage = syncStatusMessage
        statusMessage = syncStatusMessage
        
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        let scriptURL = folder.appendingPathComponent("extract-active-session.js")

        var arguments = ["node", scriptURL.path]
        if localOnly {
            arguments.append("--local-only")
        }
        
        let result = await Task.detached(priority: .userInitiated) {
            return SwitchboardStore.runProcess(
                arguments: arguments,
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
        }.value
        
        isSyncingSession = false
        
        guard result.status == 0 else {
            syncStatusMessage = "同步进程失败：\(result.output)"
            statusMessage = syncStatusMessage
            noteDeviceUserLimitIfPresent(in: result.output)
            return nil
        }
        
        guard let data = result.output.data(using: .utf8) else {
            syncStatusMessage = "读取进程输出失败"
            statusMessage = syncStatusMessage
            return nil
        }
        
        struct ActiveSessionResult: Codable {
            let success: Bool
            let email: String?
            let userId: String?
            let usedCharacters: Int?
            let monthlyLimit: Int?
            let info: String?
            let error: String?
            let errorCode: String?
            let rawJson: String?
        }
        
        do {
            let res = try JSONDecoder().decode(ActiveSessionResult.self, from: data)
            if !res.success {
                syncStatusMessage = "同步失败：\(res.error ?? "未知错误")"
                statusMessage = syncStatusMessage
                noteDeviceUserLimitIfPresent(in: res.error)
                noteDeviceUserLimitIfPresent(in: res.errorCode)
                return nil
            }
            
            guard let email = res.email else {
                syncStatusMessage = "解密成功但未找到邮箱"
                statusMessage = syncStatusMessage
                return nil
            }

            if res.errorCode == "DEVICE_USER_LIMIT" || SmartSwitchPolicy.isDeviceUserLimitError(res.error) {
                lastSyncHitDeviceUserLimit = true
            }

            // 只有官方 usage_stats 给出本周 used/limit 才算「新鲜额度」；否则不得据此判定充足。
            let quotaFresh = res.error == nil
                && res.usedCharacters != nil
                && res.monthlyLimit != nil
                && !lastSyncHitDeviceUserLimit
            
            var matchedID: UUID? = nil
            for i in 0..<state.accounts.count {
                if state.accounts[i].email.lowercased() == email.lowercased() {
                    matchedID = state.accounts[i].id
                    if quotaFresh, let used = res.usedCharacters, let limit = res.monthlyLimit {
                        state.accounts[i].usedCharacters = used
                        state.accounts[i].monthlyLimit = max(limit, 1)
                        lastQuotaUsedCharacters = used
                        lastQuotaMonthlyLimit = max(limit, 1)
                        lastQuotaSyncAt = Date()
                        lastQuotaSyncFresh = true
                        liveRemainingCharacters = state.accounts[i].remainingCharacters
                        liveAccountEmail = state.accounts[i].email
                        let remaining = state.accounts[i].remainingCharacters
                        state.accounts[i].notes = "本周额度：已用 \(used)/\(limit)，剩余 \(remaining) · 官方同步 \(Self.shortClock(Date()))"
                    } else if let info = res.info, res.error == nil, !localOnly {
                        state.accounts[i].notes = "已同步：\(info)"
                    }
                    // 额度 API 正常时才刷新静默会话缓存；设备超限/API 错误时保留旧 payload。
                    if res.error == nil, let rawJson = res.rawJson, !rawJson.isEmpty {
                        state.accounts[i].rawUserDataPayload = rawJson
                    }
                    break
                }
            }
            
            if let matchedID = matchedID {
                if let errorMsg = res.error {
                    if lastSyncHitDeviceUserLimit {
                        syncStatusMessage = "已读到账号「\(email)」，但设备登录用户数已超限：\(errorMsg)"
                    } else {
                        // 登录态在，但本周额度 API 失败：保留旧 used/limit，明确标陈旧。
                        lastQuotaSyncFresh = false
                        syncStatusMessage = "已读到账号「\(email)」，但本周额度 API 失败（数字可能陈旧）：\(errorMsg)"
                    }
                } else if quotaFresh {
                    let used = lastQuotaUsedCharacters ?? 0
                    let limit = lastQuotaMonthlyLimit ?? 8000
                    let remaining = liveRemainingCharacters ?? max(limit - used, 0)
                    syncStatusMessage = "本周额度已更新「\(email)」：已用 \(used)/\(limit)，剩余 \(remaining)"
                } else if localOnly {
                    syncStatusMessage = "本地校验：当前桌面会话账号「\(email)」"
                } else {
                    lastQuotaSyncFresh = false
                    syncStatusMessage = "已读到账号「\(email)」，但未拿到完整本周额度字段"
                }
                save()
                statusMessage = syncStatusMessage
                // 设备超限时桌面会话不可信：返回 nil，让上层优先走 resetDevice + 全自动换号。
                if lastSyncHitDeviceUserLimit {
                    return nil
                }
                // API 失败时仍返回账号 ID，供 UI 显示邮箱；换号决策见 performAutoRotateCheck（非新鲜则不换）。
                return matchedID
            } else {
                // 新建账号
                var newAcc = Account.blank(settings: state.settings)
                newAcc.email = email
                if quotaFresh {
                    newAcc.usedCharacters = res.usedCharacters ?? 0
                    newAcc.monthlyLimit = res.monthlyLimit ?? 8000
                    lastQuotaUsedCharacters = newAcc.usedCharacters
                    lastQuotaMonthlyLimit = newAcc.monthlyLimit
                    lastQuotaSyncAt = Date()
                    lastQuotaSyncFresh = true
                    liveRemainingCharacters = newAcc.remainingCharacters
                    liveAccountEmail = email
                    newAcc.notes = "本周额度：已用 \(newAcc.usedCharacters)/\(newAcc.monthlyLimit)，剩余 \(newAcc.remainingCharacters) · 官方同步 \(Self.shortClock(Date()))"
                } else {
                    newAcc.usedCharacters = res.usedCharacters ?? 0
                    newAcc.monthlyLimit = res.monthlyLimit ?? 8000
                    newAcc.notes = "从官方 App 自动导入（本周额度待刷新）"
                    if !localOnly {
                        lastQuotaSyncFresh = false
                    }
                }
                if res.error == nil {
                    newAcc.rawUserDataPayload = res.rawJson
                }
                state.accounts.append(newAcc)
                save()
                if lastSyncHitDeviceUserLimit {
                    syncStatusMessage = "发现账号「\(email)」，但设备登录用户数已超限，未采用当前桌面会话"
                    statusMessage = syncStatusMessage
                    return nil
                }
                if !quotaFresh, res.error != nil {
                    syncStatusMessage = "发现账号「\(email)」，但本周额度 API 失败，暂不据此换号"
                } else {
                    syncStatusMessage = "发现新账号「\(email)」，已自动导入"
                }
                statusMessage = syncStatusMessage
                return newAcc.id
            }
            
        } catch {
            syncStatusMessage = "解析同步结果失败：\(error.localizedDescription)"
            statusMessage = syncStatusMessage
            noteDeviceUserLimitIfPresent(in: result.output)
            return nil
        }
    }

    func noteDeviceUserLimitIfPresent(in message: String?) {
        if SmartSwitchPolicy.isDeviceUserLimitError(message) {
            lastSyncHitDeviceUserLimit = true
        }
    }

    nonisolated static func shortClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 侧栏/日志用的本周额度摘要。
    var weeklyQuotaSummaryLine: String {
        let used = lastQuotaUsedCharacters
        let limit = lastQuotaMonthlyLimit
        let remaining = liveRemainingCharacters
        let clock = lastQuotaSyncAt.map(Self.shortClock) ?? "—"
        if let used, let limit, let remaining {
            let freshness = lastQuotaSyncFresh ? "新鲜" : "可能陈旧"
            return "本周：已用 \(used)/\(limit)，剩余 \(remaining) · \(freshness) · \(clock)"
        }
        if let remaining {
            return "本周剩余约 \(remaining)（待官方刷新）· \(clock)"
        }
        return lastQuotaSyncFresh ? "本周额度已同步 · \(clock)" : "本周额度尚未成功同步"
    }



    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.appEncoder.encode(state)
            if data != lastSavedStateData {
                try data.write(to: fileURL, options: [.atomic])
                lastSavedStateData = data
            }
            
            if state.settings.isAutoRotateEnabled {
                startRotateMonitor()
            } else {
                stopRotateMonitor()
            }
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 智能换号 / 账号池自动轮切与额度监控

    /// 启动或重启无感守护循环。`kickImmediately` 用于休眠唤醒 / 菜单「立即巡检」后的续跑。
}
