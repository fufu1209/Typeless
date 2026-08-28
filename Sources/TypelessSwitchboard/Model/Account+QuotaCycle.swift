import Foundation
import TypelessSwitchboardCore

// MARK: - Account → AccountQuotaSnapshot 桥接
//
// v2.5.3：QuotaCycleEngine 早在 v2.1.0 就提供了 daysUntilReset / secondsUntilReset /
// nextCalendarWeekReset，但整个 UI 从未调用过它们，导致账号行/详情里「下次可用」永远是空的。
// 这里补上唯一桥接点，UI 只准从这里取周期信息，避免口径再次分叉。

extension Account {

    /// 转成 Core 引擎能吃的快照。这是 App 层账号模型与 Core 周期引擎之间**唯一**的转换入口。
    var quotaSnapshot: AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            id: id,
            email: email,
            status: Self.snapshotStatus(from: status),
            reviewState: Self.snapshotReviewState(from: effectiveReviewState),
            usedCharacters: usedCharacters,
            monthlyLimit: monthlyLimit,
            lastResetAt: lastResetAt,
            createdAt: createdAt,
            hasSilentSessionPayload: hasSilentSessionPayload
        )
    }

    /// 已固化桌面会话缓存 —— 无感换号的前提。
    var hasSilentSessionPayload: Bool {
        !(rawUserDataPayload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 「下次可用」文案。已可用显示「立即可用」，用尽显示到周一 00:00 的倒计时。
    ///
    /// 日历统一取自 `QuotaCycleClock`：与复活判定、看门狗排程共用同一个口径，
    /// 否则用户在设置里改了时区后会出现「倒计时归零了但还没复活」。
    var nextAvailabilityText: String {
        QuotaCycleEngine.nextAvailabilityText(
            for: quotaSnapshot,
            calendar: QuotaCycleClock.shared.calendar
        )
    }

    /// 下次额度刷新的绝对时间点（周一 00:00，按设置里的时区）。
    var nextResetDate: Date? {
        QuotaCycleEngine.nextResetDate(
            for: quotaSnapshot,
            calendar: QuotaCycleClock.shared.calendar
        )
    }

    /// 周期摘要，例如「本周已用 6133/8000 · 还剩 1,867 · 距离刷新还有 3 天（周一 00:00）」。
    var quotaCycleSummary: String {
        QuotaCycleEngine.summary(
            for: quotaSnapshot,
            calendar: QuotaCycleClock.shared.calendar
        )
    }

    /// 剩余额度是否低于阈值（口径与自动轮换完全一致，避免 UI 与守护进程判定不一致）。
    func isQuotaLow(threshold: Int) -> Bool {
        SmartSwitchPolicy.isQuotaLow(remaining: remainingCharacters, threshold: threshold)
    }

    // MARK: - 枚举桥接（供 snapshot 与 Store 共用，保持单一事实来源）

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
}
