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
                Text("剩余 \(account.remainingCharacters) / \(account.monthlyLimit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
        }
        .padding(.vertical, 5)
    }
}
