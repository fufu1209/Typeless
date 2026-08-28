import Foundation

// MARK: - QuotaCycleEngine
//
// 真实价值：Typeless 官方返回的是「周额度」（`week_word_usage_value` / `week_word_usage_limit`，
// 见 `scripts/extract-active-session.js:155`），但 v1.x 整条数据链都当月管，
// 导致周一恢复的账号会被闲置到下月初，约 3/4 额度被错杀，进而触发不必要的注册、
// 「设备登录用户数超限」等连锁故障。
//
// 本文件给出可单测的周期 / 复活 / 选号三件套，与 main.swift 里的 Account 完全解耦。
// 调用方把 Account 转成 `AccountQuotaSnapshot` 喂进来即可。

/// 周期模式：默认按 ISO 周（周一 00:00 本地时区），备选 rolling 7 天。
public enum QuotaCycleMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// 按 ISO 日历周：周一 00:00（本地时区）刷新。绝大多数用户适用。
    case calendarWeek
    /// 从 `lastResetAt` 起 7×24h 滚动。账号若改成「注册后 7 天」也能用。
    case rollingWeek
}

/// QuotaCycleEngine 用的最小快照。不依赖 main.swift 里的 Account 类型。
public struct AccountQuotaSnapshot: Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case available
        case nearlySpent
        case exhausted
        case paused
    }

    public enum ReviewState: String, Codable, Equatable, Sendable {
        case pending
        case approved
        case rejected
    }

    public let id: UUID
    public let email: String
    public let status: Status
    public let reviewState: ReviewState
    public let usedCharacters: Int
    public let monthlyLimit: Int
    public let lastResetAt: Date
    public let createdAt: Date
    public let hasSilentSessionPayload: Bool

    public init(
        id: UUID,
        email: String,
        status: Status,
        reviewState: ReviewState,
        usedCharacters: Int,
        monthlyLimit: Int,
        lastResetAt: Date,
        createdAt: Date,
        hasSilentSessionPayload: Bool
    ) {
        self.id = id
        self.email = email
        self.status = status
        self.reviewState = reviewState
        self.usedCharacters = usedCharacters
        self.monthlyLimit = monthlyLimit
        self.lastResetAt = lastResetAt
        self.createdAt = createdAt
        self.hasSilentSessionPayload = hasSilentSessionPayload
    }

    public var remainingCharacters: Int {
        max(monthlyLimit - usedCharacters, 0)
    }

    public var usageRatio: Double {
        guard monthlyLimit > 0 else { return 0 }
        return min(Double(usedCharacters) / Double(monthlyLimit), 1)
    }

    public var isApproved: Bool { reviewState == .approved }

    public var isExhausted: Bool {
        // 严格基于显式 status：.paused 是用户主动决定，不应被自动复活。
        status == .exhausted
    }
}

/// 周度复活 + 选号三件套。所有方法都是纯函数，便于单测。
public enum QuotaCycleEngine {
    /// Typeless 单账号周额度上限（与 `extract-active-session.js` 默认返回值对齐）。
    public static let defaultWeeklyLimit = 8000
    public static let weekSeconds: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - 距离下次刷新

    /// 距离下一个额度刷新还有几天（向上取整，最小 0）。
    /// - `now`: 当前时间（默认 Date()）。
    /// - `mode`: 周期模式。
    /// - `lastResetAt`: 上次重置时间；仅 `rollingWeek` 必填。
    public static func daysUntilReset(
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        lastResetAt: Date? = nil,
        calendar: Calendar = .current
    ) -> Int {
        let seconds = secondsUntilReset(now: now, mode: mode, lastResetAt: lastResetAt, calendar: calendar)
        return max(0, Int(ceil(seconds / 86_400.0)))
    }

    /// 距离下次刷新的秒数。
    public static func secondsUntilReset(
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        lastResetAt: Date? = nil,
        calendar: Calendar = .current
    ) -> TimeInterval {
        switch mode {
        case .rollingWeek:
            guard let lastResetAt else { return 0 }
            return max(0, lastResetAt.addingTimeInterval(weekSeconds).timeIntervalSince(now))
        case .calendarWeek:
            guard let nextReset = nextCalendarWeekReset(now: now, calendar: calendar) else { return 0 }
            return max(0, nextReset.timeIntervalSince(now))
        }
    }

    /// 下一个 ISO 周刷新时间（本周一 00:00 / 下周一 00:00）。
    public static func nextCalendarWeekReset(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        // 找到「本周一 00:00」；如果 now 还在本周一 00:00 之前才用，否则推到下周一。
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        guard let monday = cal.date(from: comps) else { return nil }
        let candidate = cal.startOfDay(for: monday)
        if candidate > now {
            return candidate
        }
        return cal.date(byAdding: .day, value: 7, to: candidate)
    }

    // MARK: - 复活判定

    /// 账号是否应该从 `.exhausted` 复活成 `.available`。
    /// - `account.isExhausted` 为 true；
    /// - 且距上次 reset 已跨过周期边界（calendarWeek 模式：跨 ISO 周；
    ///   rollingWeek 模式：≥ 7 天）。
    public static func shouldRevive(
        account: AccountQuotaSnapshot,
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        calendar: Calendar = .current
    ) -> Bool {
        guard account.isApproved, account.isExhausted else { return false }
        switch mode {
        case .rollingWeek:
            return now.timeIntervalSince(account.lastResetAt) >= weekSeconds
        case .calendarWeek:
            return hasCrossedWeeklyBoundary(now: now, since: account.lastResetAt, calendar: calendar)
        }
    }

    /// 是否已跨过至少一个完整的 ISO 周（周一 00:00 本地时区为分界）。
    public static func hasCrossedWeeklyBoundary(
        now: Date,
        since: Date,
        calendar: Calendar = .current
    ) -> Bool {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let nowWeek = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let sinceWeek = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: since)
        guard let nw = nowWeek.yearForWeekOfYear, let sw = sinceWeek.yearForWeekOfYear,
              let nww = nowWeek.weekOfYear, let sww = sinceWeek.weekOfYear else {
            return false
        }
        // ISO 周用 (year, week) 复合 key 区分跨年。
        if nw != sw { return true }
        return nww > sww
    }

    /// 把一批 .exhausted 账号过滤出「本周该复活」的部分，按 usedCharacters 升序。
    public static func revivedAccounts(
        in accounts: [AccountQuotaSnapshot],
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        calendar: Calendar = .current
    ) -> [AccountQuotaSnapshot] {
        accounts
            .filter { shouldRevive(account: $0, now: now, mode: mode, calendar: calendar) }
            .sorted { a, b in
                if a.usedCharacters != b.usedCharacters { return a.usedCharacters < b.usedCharacters }
                return a.email.localizedCaseInsensitiveCompare(b.email) == .orderedAscending
            }
    }

    // MARK: - 选下一目标

    /// 选号优先级：
    /// 1. 复活号（最高优先；按 usedCharacters 升序）
    /// 2. 静默就绪 + approved + 余额 > 0（按余额降序）
    /// 3. 返回 nil（应走全自动注册新号）
    public static func pickNext(
        among accounts: [AccountQuotaSnapshot],
        excluding currentID: UUID? = nil,
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        calendar: Calendar = .current
    ) -> AccountQuotaSnapshot? {
        // 1. 复活优先（即便 currentID 也要返回——切换回原号是核心价值）
        if let revived = revivedAccounts(in: accounts, now: now, mode: mode, calendar: calendar).first {
            return revived
        }

        // 2. 静默就绪池
        let silentReady = accounts
            .filter { $0.id != currentID }
            .filter {
                $0.isApproved &&
                ($0.status == .available || $0.status == .nearlySpent) &&
                $0.hasSilentSessionPayload &&
                $0.remainingCharacters > 0
            }
            .sorted { a, b in
                if a.remainingCharacters != b.remainingCharacters {
                    return a.remainingCharacters > b.remainingCharacters
                }
                return a.email.localizedCaseInsensitiveCompare(b.email) == .orderedAscending
            }
        return silentReady.first
    }

    // MARK: - 摘要

    /// 给 UI 展示的周期摘要，例如：
    /// "本周已用 6133/8000 · 还剩 1,867 · 距离刷新还有 3 天（周一 00:00）"
    public static func summary(
        for account: AccountQuotaSnapshot,
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        calendar: Calendar = .current
    ) -> String {
        let days = daysUntilReset(now: now, mode: mode, lastResetAt: account.lastResetAt, calendar: calendar)
        let boundaryLabel: String
        switch mode {
        case .calendarWeek:
            boundaryLabel = "周一 00:00"
        case .rollingWeek:
            boundaryLabel = "上次 reset 后 7 天"
        }
        return "本周已用 \(account.usedCharacters)/\(account.monthlyLimit) · 还剩 \(account.remainingCharacters) · 距离刷新还有 \(days) 天（\(boundaryLabel)）"
    }
}

// MARK: - Convenience bridges
//
// 1) `Snapshot` 工厂：调用方传 `Account` 完整数据进来即可生成快照。
//    这里不直接 import Account（Account 在 main.swift / App target 里），只给出
//    一组基础类型参数，调用方自己组装。

public extension AccountQuotaSnapshot {
    /// 复活后的「干净」快照：状态翻回 .available、已用归零、lastResetAt 推到 now。
    /// 调用方负责把生成结果落回主 store 并 save()。
    static func revive(
        from snapshot: AccountQuotaSnapshot,
        now: Date = Date(),
        weeklyLimit: Int = QuotaCycleEngine.defaultWeeklyLimit
    ) -> AccountQuotaSnapshot {
        AccountQuotaSnapshot(
            id: snapshot.id,
            email: snapshot.email,
            status: .available,
            reviewState: snapshot.reviewState,
            usedCharacters: 0,
            monthlyLimit: snapshot.monthlyLimit > 0 ? snapshot.monthlyLimit : weeklyLimit,
            lastResetAt: now,
            createdAt: snapshot.createdAt,
            hasSilentSessionPayload: snapshot.hasSilentSessionPayload
        )
    }
}
