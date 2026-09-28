import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct AccountRow: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name.isEmpty ? "未命名账号" : account.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(account.status.color)
                    .frame(width: 8, height: 8)
            }

            Text(account.email.isEmpty ? account.domain : account.email)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ProgressView(value: account.usageRatio)
                .tint(account.status.color)

            HStack(spacing: 6) {
                Text("本周剩余 \(account.remainingCharacters) / \(account.monthlyLimit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                // v2.6.0：新注册账号自带 3 天 Pro 试用（周额度 23333，免费档只有 2000）。
                // 光看「23333 / 23333」看不出所以然，标出档位与剩余天数才知道该优先用谁。
                if let badge = account.tierBadgeText {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16))
                        .foregroundStyle(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Spacer()

                Text(account.status.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(account.status.color.opacity(0.14))
                    .foregroundStyle(account.status.color)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                if account.effectiveReviewState != .approved {
                    Text(account.effectiveReviewState.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(account.effectiveReviewState.color.opacity(0.14))
                        .foregroundStyle(account.effectiveReviewState.color)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }

            // v2.5.3：QuotaCycleEngine 的周期能力早就有了，但 UI 从未接线，
            // 导致「下次可用」一直是空白。这里接上。
            HStack(spacing: 4) {
                Image(systemName: account.nextAvailabilityText == "立即可用" ? "checkmark.clock" : "clock.badge.questionmark")
                    .imageScale(.small)
                Text(account.nextAvailabilityText == "立即可用"
                     ? "下次可用：立即可用"
                     : "下次可用：\(account.nextAvailabilityText)")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(account.nextAvailabilityText == "立即可用" ? Color.green : Color.secondary)
        }
        .padding(.vertical, 5)
    }
}
