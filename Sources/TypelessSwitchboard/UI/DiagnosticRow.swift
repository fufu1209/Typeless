import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct DiagnosticRow: View {
    let item: DiagnosticItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.level.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(item.level.title)
                        .font(.caption)
                        .foregroundStyle(item.level.color)
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
