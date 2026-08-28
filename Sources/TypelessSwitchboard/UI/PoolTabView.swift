import SwiftUI
import TypelessSwitchboardCore

// TODO(agent): 端口自 AppMain.swift 的 LegacyContentView.sidebar 列表段
// + InspectorView 的「账号池工具」「兜底确认队列」两段。
struct PoolTabView: View {
    @Binding var selectedAccountID: UUID?

    var body: some View {
        TabHeading(
            title: SwitchboardTab.pool.title,
            subtitle: SwitchboardTab.pool.subtitle,
            symbolName: SwitchboardTab.pool.symbolName
        )
    }
}
