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
        let revivedSnapshot = performWeeklyRevivalIfNeeded(reason: "额度同步")
        if !revivedSnapshot.isEmpty {
            syncStatusMessage = "已复活 \(revivedSnapshot.count) 个账号（本周额度刷新）：\(revivedSnapshot.joined(separator: "、"))"
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
                        // v2.5.6：官方接口不返回重置时间戳，所以「周一刷新」还是
                        // 「滚动 7 天」只能靠实测。每次同步都记一笔采样，
                        // 额度数值下降那一刻就是一次真实重置，记进日志供事后判定。
                        recordQuotaUsageObservation(
                            accountID: state.accounts[i].id,
                            email: email,
                            usedCharacters: used
                        )
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

// MARK: - 周期口径实测（v2.5.6）
//
// 官方 `/user/usage_stats` 只给 `week_word_usage_value / week_word_usage_limit`，
// **不给重置时间戳**；免费账号的 `current_period_end` 也是 null。
// 所以「额度到底是周一刷新还是滚动 7 天」服务端没说，以前是按「周额度 = 自然周分桶」推断。
//
// 现在改成实测：每次拿到新鲜额度就记一笔采样，数值显著下降即记为一次重置，
// 把时刻写进日志。攒够样本后 `QuotaCycleEngine.inferCycleMode` 自动给出结论，
// 不用再靠人猜，也不用等用户报障。

extension SwitchboardStore {

    /// 记一笔额度采样；若相对上一笔显著下降，判定为一次真实重置并落日志。
    func recordQuotaUsageObservation(accountID: UUID, email: String, usedCharacters: Int) {
        let previous = quotaUsageSamples[accountID]
        quotaUsageSamples[accountID] = usedCharacters

        guard let previous, previous - usedCharacters > 50 else { return }

        // 观测到了重置 —— 这是判定周期口径的唯一硬证据，必须记清楚。
        let now = Date()
        quotaObservedResets.append(
            QuotaCycleEngine.ObservedReset(at: now, from: previous, to: usedCharacters)
        )
        // 同时落盘：观测要跨周才攒得够（判定口径至少要看两三次重置），
        // 只放内存的话 App 一重启就清零，永远攒不到样本。
        let record = QuotaCycleObservationStore.Record(
            at: now, from: previous, to: usedCharacters, email: email
        )
        quotaObservationRecords = QuotaCycleObservationStore.append(record, to: quotaObservationFileURL())
        let stamp = ISO8601DateFormatter().string(from: now)
        let calendar = QuotaCycleClock.shared.calendar
        let distance = QuotaCycleEngine.secondsFromWeeklyBoundary(now, calendar: calendar)
        let onBoundary = distance <= 3_600
        let line = "额度重置实测：\(email) \(previous) → \(usedCharacters) @ \(stamp)"
            + " | 距最近周一 00:00 \(Int(distance / 60)) 分钟 → "
            + (onBoundary ? "落在周界上（支持自然周口径）" : "不在周界上（支持滚动 7 天口径）")
        // 同时进守护日志和引导日志所在目录，方便一处翻。
        appendDaemonLog(remaining: nil, email: email, reason: line, resultID: nil)
    }

    /// 观测记录落盘位置。与 store.json 同目录，备份/迁移时一起带走。
    func quotaObservationFileURL() -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("quota-cycle-observations.json")
    }

    /// 启动时把历史观测读回来。
    ///
    /// 顺序很重要：必须先读盘再开始采样，否则本轮同步会拿到「上一笔 = 无」
    /// 而漏判一次重置 —— 恰好跨周重启的用户就少了最关键的那条证据。
    func loadQuotaCycleObservations() {
        let records = QuotaCycleObservationStore.load(from: quotaObservationFileURL())
        quotaObservationRecords = records
        quotaObservedResets = QuotaCycleObservationStore.resets(from: records)
    }

    /// 当前已观测到的重置次数（UI 用来显示「口径待确认 / 已确认」）。
    var observedQuotaResetCount: Int {
        quotaObservedResets.count
    }

    /// 按已观测到的重置给出的周期口径结论。还没观测到时是「未定」。
    func quotaCycleInference() -> QuotaCycleEngine.CycleInference {
        QuotaCycleEngine.inferCycleMode(
            fromResets: quotaObservedResets,
            calendar: QuotaCycleClock.shared.calendar
        )
    }
}
