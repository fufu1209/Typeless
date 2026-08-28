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

    // MARK: - 看门狗排程

    /// 单轮休眠上限（秒）。
    ///
    /// 到点会重新计算下一次周界，所以设成 1 小时**不等于**「每小时复活一次」，
    /// 只是每小时重新校准一次排程 —— 没跨周时复活逻辑什么都不会做。
    ///
    /// 这么设是为了让下面这些情况都能自愈，而不是卡到下一周：
    /// 用户在设置里切换周期时区、笔记本跨时区出差、夏令时切换、系统时钟被 NTP 校正。
    /// 曾经是一路睡到周一，结果改了时区要等整整一周才生效。
    public static let watchdogMaxSleepSeconds: TimeInterval = 3_600
    /// 单轮休眠下限（秒），避免边界抖动时空转打满 CPU。
    public static let watchdogMinSleepSeconds: TimeInterval = 60

    /// 看门狗这一轮该睡多久：睡到下个周界，再夹到 [下限, 上限]。
    /// +2 秒余量是为了避开「刚好卡在 00:00:00」的边界抖动。
    public static func watchdogSleepSeconds(
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        lastResetAt: Date? = nil,
        calendar: Calendar = .current
    ) -> TimeInterval {
        let wait = secondsUntilReset(now: now, mode: mode, lastResetAt: lastResetAt, calendar: calendar)
        return min(max(wait + 2, watchdogMinSleepSeconds), watchdogMaxSleepSeconds)
    }

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

    // MARK: - 倒计时文案

    /// 人类可读倒计时。≥1 天显示「X 天 Y 小时」，≥1 小时显示「X 小时 Y 分」，否则「X 分」。
    /// 目标时间已过或为 0 时返回「即将」。
    public static func countdownText(from now: Date = Date(), to target: Date) -> String {
        let seconds = max(0, target.timeIntervalSince(now))
        let totalMinutes = Int(seconds / 60)
        if totalMinutes <= 0 { return "即将" }

        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days) 天 \(hours) 小时"
        }
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        return "\(minutes) 分"
    }

    /// 账号「下次可用」展示文案。UI 直接绑定这个，避免各处自己拼字符串造成口径不一致。
    /// - 已耗尽：显示到下次刷新的倒计时 + 刷新时点说明。
    /// - 余额 > 0 且可用：显示「立即可用」。
    /// - 暂停：显示「已暂停，需手动恢复」。
    public static func nextAvailabilityText(
        for account: AccountQuotaSnapshot,
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        calendar: Calendar = .current
    ) -> String {
        if account.status == .paused {
            return "已暂停，需手动恢复"
        }
        if account.remainingCharacters > 0 && (account.status == .available || account.status == .nearlySpent) {
            return "立即可用"
        }

        switch mode {
        case .calendarWeek:
            guard let reset = nextCalendarWeekReset(now: now, calendar: calendar) else {
                return "刷新时间计算失败"
            }
            return "\(countdownText(from: now, to: reset))后（周一 00:00）"
        case .rollingWeek:
            let reset = account.lastResetAt.addingTimeInterval(weekSeconds)
            return "\(countdownText(from: now, to: reset))后（注册满 7 天）"
        }
    }

    /// 下次刷新的绝对时间点，UI 用来做定时刷新 / 状态栏展示。
    public static func nextResetDate(
        for account: AccountQuotaSnapshot,
        now: Date = Date(),
        mode: QuotaCycleMode = .calendarWeek,
        calendar: Calendar = .current
    ) -> Date? {
        switch mode {
        case .calendarWeek:
            return nextCalendarWeekReset(now: now, calendar: calendar)
        case .rollingWeek:
            return account.lastResetAt.addingTimeInterval(weekSeconds)
        }
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

// MARK: - 周期口径观测（v2.5.6）
//
// 背景：`/user/usage_stats` 只返回 `week_word_usage_value / week_word_usage_limit`，
// **不返回任何重置时间戳**；免费账号的 `userData.current_period_end` 也是 null。
// 也就是说「额度到底是『周一 00:00 刷新』还是『用尽后滚动 7 天』」这件事，
// 服务端没告诉我们，之前一直是按「周额度 = 服务端按自然周分桶」推断的。
//
// 正确做法不是继续猜，而是**观测**：额度数值下降的那一刻就是一次真实重置。
// 把每次下降的时间点记下来，看它们落在周一 00:00 还是散落在七天里，答案自然浮现。

public extension QuotaCycleEngine {

    /// 一次额度采样。
    struct UsageSample: Equatable, Sendable {
        public let at: Date
        public let usedCharacters: Int

        public init(at: Date, usedCharacters: Int) {
            self.at = at
            self.usedCharacters = usedCharacters
        }
    }

    /// 观测到的重置时刻（额度数值显著下降）。
    struct ObservedReset: Equatable, Sendable {
        public let at: Date
        public let from: Int
        public let to: Int

        public init(at: Date, from: Int, to: Int) {
            self.at = at
            self.from = from
            self.to = to
        }
    }

    /// 从一串采样里找出重置时刻。
    ///
    /// - Parameter dropThreshold: 下降幅度超过该值才算重置。默认 50，
    ///   用来滤掉「同一周内正常波动」和个别识别结果回退造成的微小抖动。
    /// - Note: 采样必须按时间升序传入。
    static func observedResetInstants(
        in samples: [UsageSample],
        dropThreshold: Int = 50
    ) -> [ObservedReset] {
        guard samples.count > 1 else { return [] }
        var result: [ObservedReset] = []
        for i in 1..<samples.count {
            let previous = samples[i - 1]
            let current = samples[i]
            if previous.usedCharacters - current.usedCharacters > dropThreshold {
                result.append(ObservedReset(
                    at: current.at,
                    from: previous.usedCharacters,
                    to: current.usedCharacters
                ))
            }
        }
        return result
    }

    /// 观测结论：目前还没观测到任何重置时返回 `.insufficient`。
    enum CycleInference: Equatable, Sendable {
        /// 还没观测到足够的重置，结论未定。UI 不该把倒计时说成确定时间。
        case insufficient(observations: Int)
        /// 所有观测到的重置都落在周一 00:00 附近 → 自然周。
        case calendarWeek(observations: Int)
        /// 重置散落在七天里、与周界无关 → 滚动 7 天。
        case rollingWeek(observations: Int)
        /// 有的在周界、有的不在 —— 口径可能变了，或数据有噪声，需要人工看。
        case inconsistent(observations: Int)

        public var observationCount: Int {
            switch self {
            case .insufficient(let n), .calendarWeek(let n), .rollingWeek(let n), .inconsistent(let n):
                return n
            }
        }
    }

    /// 判断某个时刻距离最近的周一 00:00 有多远（秒）。
    /// 用来判定「这次重置是不是卡在周界上」。
    static func secondsFromWeeklyBoundary(_ date: Date, calendar: Calendar) -> TimeInterval {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        guard let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) else {
            return .greatestFiniteMagnitude
        }
        let thisMonday = cal.startOfDay(for: monday)
        let nextMonday = cal.date(byAdding: .day, value: 7, to: thisMonday) ?? thisMonday
        let previousMonday = cal.date(byAdding: .day, value: -7, to: thisMonday) ?? thisMonday
        return min(
            abs(date.timeIntervalSince(thisMonday)),
            abs(date.timeIntervalSince(nextMonday)),
            abs(date.timeIntervalSince(previousMonday))
        )
    }

    /// 从观测到的重置时刻反推周期口径。
    ///
    /// - Parameter toleranceSeconds: 判定「落在周界上」的容差。默认 1 小时 ——
    ///   客户端轮询有间隔（守护最快 20 秒一轮，但用户可能几小时才开一次 App），
    ///   观测时刻天然滞后于真实重置时刻，容差太小会把自然周误判成滚动。
    static func inferCycleMode(
        fromResets resets: [ObservedReset],
        calendar: Calendar,
        toleranceSeconds: TimeInterval = 3_600
    ) -> CycleInference {
        guard !resets.isEmpty else { return .insufficient(observations: 0) }
        let onBoundary = resets.filter {
            secondsFromWeeklyBoundary($0.at, calendar: calendar) <= toleranceSeconds
        }
        if onBoundary.count == resets.count { return .calendarWeek(observations: resets.count) }
        if onBoundary.isEmpty { return .rollingWeek(observations: resets.count) }
        return .inconsistent(observations: resets.count)
    }

    /// 给 UI 的口径说明。观测不足时必须说实话，不能把推断包装成确定结论。
    static func cycleConfidenceText(_ inference: CycleInference) -> String {
        switch inference {
        case .insufficient(let n):
            return "周期口径待确认（已观测 \(n) 次额度刷新）"
        case .calendarWeek(let n):
            return "已确认按自然周刷新（周一的 00:00），依据 \(n) 次实测"
        case .rollingWeek(let n):
            return "已确认为滚动 7 天刷新，依据 \(n) 次实测"
        case .inconsistent(let n):
            return "刷新时刻不规律（\(n) 次实测有落在周一的也有不落的），建议人工核一下"
        }
    }
}
