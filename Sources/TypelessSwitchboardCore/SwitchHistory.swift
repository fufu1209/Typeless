import Foundation

// MARK: - v2.8.0：换号历史（运营看板的数据底座）
//
// 为什么现在才做：v2.8.0 之前「额度读到没有」本身就是个黑盒，换号是否成功只能翻
// daemon 日志（一行一条、没结构）。CDP 直读把额度变成可信数字之后，
// 「过去 7 天换了几次、成功率多少、一次要多久」才有意义 —— 这是判断
// 「该不该扩池子 / 阈值调对了没有」的唯一硬数据。
//
// 设计约束：
//   * 只记**结果与耗时**，不记 token / 密码 / payload；
//   * 上限 200 条，落盘在 store.json（随备份一起走）；
//   * 统计是纯函数，可被 checks 直接覆盖。

/// 换号由谁触发。
public enum SwitchTrigger: String, Codable, Equatable, Sendable, CaseIterable {
    /// 额度守护巡检自动触发。
    case automatic
    /// 额度长期读不到时的降级强制轮换。
    case degradedForced
    /// 用户点「智能换号 / 选择下一个账号」。
    case manual
    /// 全自动注册新号并切换。
    case registration

    public var displayName: String {
        switch self {
        case .automatic: return "自动巡检"
        case .degradedForced: return "降级轮换"
        case .manual: return "手动"
        case .registration: return "自动注册"
        }
    }
}

/// 一次换号尝试的结果。
public struct SwitchHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var fromEmail: String?
    public var toEmail: String?
    public var trigger: SwitchTrigger
    public var succeeded: Bool
    /// 从开始注入到「确认桌面端已读入新会话」的秒数（失败时为已耗时）。
    public var durationSeconds: Double
    public var note: String

    public init(
        id: UUID = UUID(),
        at: Date = Date(),
        fromEmail: String? = nil,
        toEmail: String? = nil,
        trigger: SwitchTrigger,
        succeeded: Bool,
        durationSeconds: Double,
        note: String = ""
    ) {
        self.id = id
        self.at = at
        self.fromEmail = fromEmail
        self.toEmail = toEmail
        self.trigger = trigger
        self.succeeded = succeeded
        self.durationSeconds = durationSeconds
        self.note = note
    }
}

/// 近 N 天统计。纯函数，不做 IO。
public struct SwitchHistorySummary: Equatable, Sendable {
    public var windowDays: Int
    public var total: Int
    public var succeeded: Int
    public var failed: Int
    public var averageSeconds: Double
    public var medianSeconds: Double
    public var byTrigger: [SwitchTrigger: Int]

    public var successRate: Double {
        total == 0 ? 0 : Double(succeeded) / Double(total)
    }

    public init(
        windowDays: Int,
        total: Int,
        succeeded: Int,
        failed: Int,
        averageSeconds: Double,
        medianSeconds: Double,
        byTrigger: [SwitchTrigger: Int]
    ) {
        self.windowDays = windowDays
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.averageSeconds = averageSeconds
        self.medianSeconds = medianSeconds
        self.byTrigger = byTrigger
    }
}

public enum SwitchHistory {
    /// 落盘上限。够看「最近几个月」，又不至于把 store.json 撑大。
    public static let maximumEntries = 200

    /// 追加一条并按时间裁剪（新的在前）。
    public static func appending(_ entry: SwitchHistoryEntry, to history: [SwitchHistoryEntry]) -> [SwitchHistoryEntry] {
        var next = history
        next.append(entry)
        // 按时间倒序（新的在前）。排序而不是无脑 insert(0)：旧版本/导入的
        // store.json 里顺序未必可靠，UI 列表与「最近一次」都依赖这个顺序。
        next.sort { $0.at > $1.at }
        if next.count > maximumEntries {
            next = Array(next.prefix(maximumEntries))
        }
        return next
    }

    /// 近 `windowDays` 天的统计。
    public static func summarize(
        _ history: [SwitchHistoryEntry],
        now: Date = Date(),
        windowDays: Int = 7
    ) -> SwitchHistorySummary {
        let window = max(windowDays, 1)
        let cutoff = now.addingTimeInterval(-Double(window) * 86_400)
        let entries = history.filter { $0.at >= cutoff }

        let durations = entries.map { max($0.durationSeconds, 0) }.sorted()
        let average: Double
        let median: Double
        if durations.isEmpty {
            average = 0
            median = 0
        } else {
            average = durations.reduce(0, +) / Double(durations.count)
            median = durations.count % 2 == 1
                ? durations[durations.count / 2]
                : (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2
        }

        var byTrigger: [SwitchTrigger: Int] = [:]
        for entry in entries {
            byTrigger[entry.trigger, default: 0] += 1
        }

        return SwitchHistorySummary(
            windowDays: window,
            total: entries.count,
            succeeded: entries.filter(\.succeeded).count,
            failed: entries.filter { !$0.succeeded }.count,
            averageSeconds: average,
            medianSeconds: median,
            byTrigger: byTrigger
        )
    }

    /// 一行摘要，给菜单栏 / 侧栏用。
    public static func summaryLine(_ summary: SwitchHistorySummary) -> String {
        guard summary.total > 0 else {
            return "近 \(summary.windowDays) 天还没有换号记录"
        }
        let rate = Int((summary.successRate * 100).rounded())
        let seconds = String(format: "%.1f", summary.medianSeconds)
        return "近 \(summary.windowDays) 天换号 \(summary.total) 次"
            + "（成功 \(summary.succeeded) / 失败 \(summary.failed)，成功率 \(rate)%）"
            + " · 中位耗时 \(seconds)s"
    }

    /// CSV 导出（Excel / Numbers 可直接开）。时间用 ISO8601，邮箱按原样。
    public static func csv(_ history: [SwitchHistoryEntry]) -> String {
        var lines = ["时间,触发方式,结果,耗时(秒),原账号,新账号,备注"]
        let formatter = ISO8601DateFormatter()
        for entry in history {
            let fields = [
                formatter.string(from: entry.at),
                entry.trigger.displayName,
                entry.succeeded ? "成功" : "失败",
                String(format: "%.1f", entry.durationSeconds),
                entry.fromEmail ?? "",
                entry.toEmail ?? "",
                entry.note
            ]
            lines.append(fields.map(csvEscape).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    /// CSV 字段转义：含逗号/引号/换行时用双引号包起来，内部引号翻倍。
    static func csvEscape(_ field: String) -> String {
        let needsQuoting = field.contains(",") || field.contains("\"") || field.contains("\n")
        guard needsQuoting else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
