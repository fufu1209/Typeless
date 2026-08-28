import SwiftUI
import TypelessSwitchboardCore

// TODO(agent): 端口自 AppMain.swift 的 InspectorView「连接设置」「MoeMail 邮箱」「邮箱域名」三段。
struct RegistrationTabView: View {
    @Binding var apiKey: String
    @Binding var selectedAccountID: UUID?

    var body: some View {
        TabHeading(
            title: SwitchboardTab.registration.title,
            subtitle: SwitchboardTab.registration.subtitle,
            symbolName: SwitchboardTab.registration.symbolName
        )
    }
}
