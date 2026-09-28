import Foundation

/// Typeless 的账号档位。
///
/// 服务端用 `role` 区分档位（`pro_trial` / `free`），但 `role` 只有把桌面端
/// **切到该账号**才能从 `app-storage.json` 读到。而 `/user/usage_stats` 会直接下发
/// 周额度（`week_word_usage_limit`），**每个账号拿自己的 token 就能问，不必换号** ——
/// 所以这里从额度反推档位，用于在账号列表里一眼看出「哪个号额度肥」。
///
/// 实测（2026-09-29）：
///   - 新注册账号 `role = pro_trial`，`insert_time` → `exp_time` **恰好 3 天**，
///     期间 `week_word_usage_limit = 23333`；
///   - 3 天后降为 `role = free`，周额度 2000（2026 年 9 月前是 8000）。
///
/// 两个新注册账号的本地 `createdAt` 与「服务端 `insert_time` + 3 天」吻合到
/// 21 秒以内，所以试用到期时间可以用 `createdAt + 3 天` 在本地推算，无需换号。
public enum QuotaTier: String, Sendable, CaseIterable {
    /// 新注册赠送的 3 天 Pro 试用档。
    case proTrial
    /// 免费档。
    case free
    /// 未知额度（官方改了数字）—— 原样显示，不硬猜。
    case unknown

    /// Pro 试用档的周额度（服务端下发值）。
    public static let proTrialWeeklyLimit = 23333
    /// Pro 试用时长。
    public static let proTrialDurationDays = 3
    /// 免费档的旧周额度（2026-09 之前）。
    public static let legacyFreeWeeklyLimit = 8000

    /// 一天的秒数。抽出来是为了让测试能构造确定的时刻。
    public static let secondsPerDay: TimeInterval = 86_400

    /// 从服务端下发的周额度反推档位。
    public static func from(weeklyLimit: Int) -> QuotaTier {
        switch weeklyLimit {
        case proTrialWeeklyLimit: return .proTrial
        case QuotaCycleEngine.defaultWeeklyLimit, legacyFreeWeeklyLimit: return .free
        default: return .unknown
        }
    }

    public var isProTrial: Bool { self == .proTrial }

    /// Pro 试用的到期时刻。非试用档返回 nil。
    public static func trialEndsAt(createdAt: Date, weeklyLimit: Int) -> Date? {
        guard from(weeklyLimit: weeklyLimit).isProTrial else { return nil }
        return createdAt.addingTimeInterval(TimeInterval(proTrialDurationDays) * secondsPerDay)
    }

    /// Pro 试用剩余天数（不足一天算 1 天；已到期为 0）。非试用档返回 nil。
    public static func trialDaysRemaining(createdAt: Date, weeklyLimit: Int, now: Date) -> Int? {
        guard let endsAt = trialEndsAt(createdAt: createdAt, weeklyLimit: weeklyLimit) else {
            return nil
        }
        let seconds = endsAt.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int(ceil(seconds / secondsPerDay))
    }

    /// 账号列表上的档位徽章文案。免费档是常态，返回 nil 以免列表被噪音塞满。
    public static func badgeText(weeklyLimit: Int, createdAt: Date, now: Date) -> String? {
        switch from(weeklyLimit: weeklyLimit) {
        case .proTrial:
            guard let days = trialDaysRemaining(createdAt: createdAt, weeklyLimit: weeklyLimit, now: now) else {
                return "Pro 试用"
            }
            return days > 0 ? "Pro 试用 · 剩 \(days) 天" : "Pro 试用 · 今日到期"
        case .free:
            return nil
        case .unknown:
            return "额度 \(weeklyLimit)"
        }
    }
}
