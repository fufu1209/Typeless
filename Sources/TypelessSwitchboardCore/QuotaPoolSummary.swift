import Foundation

// MARK: - QuotaPoolSummary
//
// 「可用账号 / 剩余额度」这两个界面数字的口径。
//
// 以前的实现是 `accounts.reduce(0) { $0 + $1.remainingCharacters }` ——
// **全池无条件求和**，连「根本没有静默会话、换不过去」的账号也算进去。
// 于是界面报 79,866，而真正能换过去用的只有 73,866，多算了两个账号的 4,000 字
// （2026-09-30 实测）。
//
// 这类偏差危险的地方不在于数字大小，而在于它**恰好落在「还能用多久」的判断上**：
// 用户看到 79,866 会以为还有余量，实际可能已经换不动了。
//
// 现在的口径与选号逻辑（`QuotaCycleEngine` 的「静默就绪」池）**对齐**：
// 界面上的数字必须等于工具真会做的事。

/// 参与汇总的单个账号快照。只带汇总需要的三个事实，便于纯函数测试。
public struct QuotaPoolEntry: Equatable, Sendable {
    /// 本周剩余额度（`monthlyLimit - usedCharacters`，已夹到 0）。
    public let remainingCharacters: Int
    /// 是否带静默会话（`rawUserDataPayload` 非空）。
    /// 没有它就只能重新注册/登录，额度**换不过去**。
    public let hasSilentSessionPayload: Bool
    /// 是否已确认、未被暂停（对应 `Account.isUsable`）。
    public let isSelectable: Bool

    public init(remainingCharacters: Int, hasSilentSessionPayload: Bool, isSelectable: Bool) {
        self.remainingCharacters = remainingCharacters
        self.hasSilentSessionPayload = hasSilentSessionPayload
        self.isSelectable = isSelectable
    }
}

/// 账号池额度的汇总结果。
public enum QuotaPoolSummary {

    public struct Result: Equatable, Sendable {
        /// 真能换过去的账号数。
        public let switchableCount: Int
        /// 真能换过去的账号的剩余额度合计。
        public let switchableRemaining: Int
        /// 「看起来可用、其实没静默会话」的账号数（被排除的部分）。
        public let sessionlessCount: Int
        /// 被排除掉的那部分额度合计，用于在界面上解释差额。
        public let sessionlessRemaining: Int

        public init(switchableCount: Int, switchableRemaining: Int,
                    sessionlessCount: Int, sessionlessRemaining: Int) {
            self.switchableCount = switchableCount
            self.switchableRemaining = switchableRemaining
            self.sessionlessCount = sessionlessCount
            self.sessionlessRemaining = sessionlessRemaining
        }

        public static let empty = Result(
            switchableCount: 0, switchableRemaining: 0,
            sessionlessCount: 0, sessionlessRemaining: 0
        )
    }

    /// 汇总账号池。
    ///
    /// - `switchable`：已确认未暂停 + 带静默会话 + 还有额度（与选号口径一致）。
    /// - `sessionless`：已确认未暂停 + 还有额度，但**没有**静默会话 ——
    ///   这部分额度是虚的（换不过去），单独统计出来好让界面把差额讲清楚。
    ///
    /// 暂停 / 待确认 / 额度为 0 的账号两边都不计入：前两类不是「换不过去」而是
    /// 「用户没让它上」，第三类本来就没有余量。
    public static func make(from entries: [QuotaPoolEntry]) -> Result {
        var switchableCount = 0
        var switchableRemaining = 0
        var sessionlessCount = 0
        var sessionlessRemaining = 0

        for entry in entries {
            guard entry.isSelectable, entry.remainingCharacters > 0 else { continue }
            if entry.hasSilentSessionPayload {
                switchableCount += 1
                switchableRemaining += entry.remainingCharacters
            } else {
                sessionlessCount += 1
                sessionlessRemaining += entry.remainingCharacters
            }
        }

        return Result(
            switchableCount: switchableCount,
            switchableRemaining: switchableRemaining,
            sessionlessCount: sessionlessCount,
            sessionlessRemaining: sessionlessRemaining
        )
    }
}
