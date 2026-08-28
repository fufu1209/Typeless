import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct QuotaSummaryView: View {
    @EnvironmentObject private var store: SwitchboardStore

    private var totalRemaining: Int {
        store.state.accounts.reduce(0) { $0 + $1.remainingCharacters }
    }

    private var availableCount: Int {
        store.state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
    }

    private var pendingCount: Int {
        store.state.accounts.filter { $0.effectiveReviewState == .pending }.count
    }

    private var exhaustedCount: Int {
        store.state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }.count
    }

    private var pausedCount: Int {
        store.state.accounts.filter { $0.status == .paused || $0.effectiveReviewState == .rejected }.count
    }

    /// v2.5.3：全池统一的下一次额度刷新时间（Typeless 官方按自然周，周一 00:00 本地时区）。
    /// 用尽的号数 > 0 时才展示，避免额度充足时噪音。
    private var nextRefreshText: String? {
        guard exhaustedCount > 0 else { return nil }
        guard let reset = QuotaCycleEngine.nextCalendarWeekReset(now: Date()) else { return nil }
        return QuotaCycleEngine.countdownText(from: Date(), to: reset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("可用账号", systemImage: "person.crop.circle.badge.checkmark")
                Spacer()
                Text("\(availableCount)")
                    .font(.title3.weight(.semibold))
            }
            HStack {
                Label("剩余额度", systemImage: "textformat.size")
                Spacer()
                Text("\(totalRemaining)")
                    .font(.title3.weight(.semibold))
            }
            if let nextRefreshText {
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.questionmark")
                        .imageScale(.small)
                    Text("用尽的号 \(nextRefreshText)后恢复")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Typeless 官方按自然周计额度，每周一 00:00（本地时区）刷新")
            }
            Divider()
            HStack(spacing: 8) {
                SummaryPill(title: "待确认", value: pendingCount, color: .orange)
                SummaryPill(title: "用完", value: exhaustedCount, color: .red)
                SummaryPill(title: "暂停", value: pausedCount, color: .secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SummaryPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
            Text("\(value)")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
