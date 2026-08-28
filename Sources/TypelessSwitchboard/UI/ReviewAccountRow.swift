import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct ReviewAccountRow: View {
    let account: Account
    let onSelect: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email.isEmpty ? account.name : account.email)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text((account.typelessUsername ?? account.domain).ifEmpty(account.domain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button {
                    onApprove()
                } label: {
                    Label("确认", systemImage: "checkmark")
                }

                Button {
                    onReject()
                } label: {
                    Label("退回", systemImage: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
