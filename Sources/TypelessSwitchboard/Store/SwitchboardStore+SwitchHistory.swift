import SwiftUI
import AppKit
import TypelessSwitchboardCore

// MARK: - v2.8.0：换号历史（运营看板）
//
// 记录入口只有两个（都在 Core 里定义模型）：
//   * `switchActiveAccountSilently` —— 池内静默切换（自动巡检 / 手动 / 降级轮换）；
//   * `runOneClickAutomaticReplacement` —— 全自动注册换号（热备注册不记）。
//
// 只记**结果与耗时**：从「开始注入」到「确认桌面端读入新会话」的真实秒数，
// 正是用户能感知的「换号要等多久」。这些数据是调阈值、判断该不该扩池子的依据。

extension SwitchboardStore {

    var switchHistoryEntries: [SwitchHistoryEntry] {
        state.switchHistory ?? []
    }

    /// 记一条换号历史。失败也记 —— 「多久失败一次」比「成功了几次」更能说明池子健康度。
    func recordSwitchHistory(
        trigger: SwitchTrigger,
        fromID: UUID?,
        toID: UUID?,
        succeeded: Bool,
        startedAt: Date,
        note: String? = nil
    ) {
        let fromEmail = fromID.flatMap { id in
            accountIndex(id: id).map { state.accounts[$0].email }
        }
        let toEmail = toID.flatMap { id in
            accountIndex(id: id).map { state.accounts[$0].email }
        }
        let duration = max(Date().timeIntervalSince(startedAt), 0)
        let resolvedNote = note ?? (succeeded ? "" : lastSilentSwitchFailureReason)

        let entry = SwitchHistoryEntry(
            fromEmail: fromEmail,
            toEmail: toEmail,
            trigger: trigger,
            succeeded: succeeded,
            durationSeconds: duration,
            note: String(resolvedNote.prefix(160))
        )
        state.switchHistory = SwitchHistory.appending(entry, to: state.switchHistory ?? [])
        save()
    }

    func switchHistorySummary(days: Int = 7) -> SwitchHistorySummary {
        SwitchHistory.summarize(switchHistoryEntries, now: Date(), windowDays: days)
    }

    /// 复制 CSV 到剪贴板（与其它「复制…」按钮同一套交互）。
    @discardableResult
    func copySwitchHistoryCSV() -> String {
        let csv = SwitchHistory.csv(switchHistoryEntries)
        copyToClipboard(csv)
        statusMessage = switchHistoryEntries.isEmpty
            ? "换号历史为空，已复制表头"
            : "已复制 \(switchHistoryEntries.count) 条换号历史（CSV）"
        return csv
    }

    func clearSwitchHistory() {
        state.switchHistory = []
        save()
        statusMessage = "已清空换号历史"
    }
}
