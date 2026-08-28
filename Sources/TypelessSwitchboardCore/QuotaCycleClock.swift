import Foundation

// MARK: - QuotaCycleClock
//
// 周期日历的**单一事实来源**。
//
// 为什么需要它：Typeless 的额度是「周一 00:00 刷新」，而「周一 00:00」是相对某个时区而言的。
// 引擎里所有周期计算都用 `Calendar`，时区不同结果就不同。之前 UI 倒计时、复活判定、
// 看门狗排程各自拿 `Calendar.current`，一旦系统时区与用户实际所在时区不一致
// （例如系统停在 Asia/Bangkok +0700、人实际在深圳 +0800），
// 倒计时就会整体偏移一小时，出现「倒计时归零了但还没复活」。
//
// 这里给一个进程级共享的日历：
// - 默认跟随系统（与改造前行为完全一致，不影响既有测试）；
// - 用户在设置里指定时区后，UI 倒计时 / 复活判定 / 看门狗排程三处同时生效，不会分叉。
//
// 用 `.iso8601` 而不是 `.current`：ISO 8601 日历天然以周一为一周之始、
// 且首周最少 4 天，正好是额度周期要的口径，不随系统 locale 漂移。

public final class QuotaCycleClock: @unchecked Sendable {
    public static let shared = QuotaCycleClock()

    private let lock = NSLock()
    private var timeZoneOverride: TimeZone?

    private init() {}

    /// 覆盖时区。传 `nil` 恢复「跟随系统」。
    public func setTimeZone(_ timeZone: TimeZone?) {
        lock.lock()
        defer { lock.unlock() }
        timeZoneOverride = timeZone
    }

    /// 按标识符覆盖时区。传 `nil` 或空串表示跟随系统；标识符非法时保持原状并返回 false。
    @discardableResult
    public func setTimeZone(identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else {
            setTimeZone(nil)
            return true
        }
        guard let timeZone = TimeZone(identifier: identifier) else { return false }
        setTimeZone(timeZone)
        return true
    }

    /// 当前生效的时区（覆盖值，或系统时区）。
    public var timeZone: TimeZone {
        lock.lock()
        defer { lock.unlock() }
        return timeZoneOverride ?? .current
    }

    /// 当前生效的周期日历。
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }
}
