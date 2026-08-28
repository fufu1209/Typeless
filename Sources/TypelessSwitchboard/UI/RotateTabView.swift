import SwiftUI
import TypelessSwitchboardCore

// TODO(agent): 端口自 AppMain.swift 的 LegacyContentView.sidebar 换号段
// + InspectorView 的「切换清单」段。
struct RotateTabView: View {
    @Binding var selectedAccountID: UUID?
    @Binding var apiKey: String

    var body: some View {
        TabHeading(
            title: SwitchboardTab.rotate.title,
            subtitle: SwitchboardTab.rotate.subtitle,
            symbolName: SwitchboardTab.rotate.symbolName
        )
    }
}
