import SwiftUI
import TypelessSwitchboardCore

// MARK: - 根容器：5 个 tab 取代原来的「侧边栏塞 20+ 控件 + 右侧嵌套 DisclosureGroup」
//
// 布局取舍：
// - 顶部一条**常驻状态带**（额度摘要 + 错误横幅 + 一键换号），不管切到哪个 tab 都能看到
//   最关键的「额度还有没有 / 现在用的哪个号」；
// - 下面 TabView 承载 5 个功能面，每个 tab 内部用 NavigationStack + 统一卡片排版；
// - 原来右侧 360px 的 InspectorView 拆散后按语义归位到对应 tab，不再有深层折叠。

struct RootView: View {
    @EnvironmentObject private var store: SwitchboardStore

    @State private var selection: SwitchboardTab = .pool
    @State private var selectedAccountID: UUID?
    @State private var apiKey = KeychainStore.readAPIKey()
    @State private var commandLineAutomationStarted = false

    var body: some View {
        VStack(spacing: 0) {
            GlobalStatusBar(selectedAccountID: $selectedAccountID)

            Divider()

            TabView(selection: $selection) {
                PoolTabView(selectedAccountID: $selectedAccountID)
                    .tabItem { tabLabel(for: .pool) }
                    .tag(SwitchboardTab.pool)

                RotateTabView(selectedAccountID: $selectedAccountID, apiKey: $apiKey)
                    .tabItem { tabLabel(for: .rotate) }
                    .tag(SwitchboardTab.rotate)

                QuotaGuardTabView()
                    .tabItem { tabLabel(for: .quotaGuard) }
                    .tag(SwitchboardTab.quotaGuard)

                RegistrationTabView(apiKey: $apiKey, selectedAccountID: $selectedAccountID)
                    .tabItem { tabLabel(for: .registration) }
                    .tag(SwitchboardTab.registration)

                DiagnosticsTabView()
                    .tabItem { tabLabel(for: .diagnostics) }
                    .tag(SwitchboardTab.diagnostics)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fontDesign(.rounded)
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = store.state.accounts.first?.id
            }
        }
        .task {
            guard !commandLineAutomationStarted else { return }
            commandLineAutomationStarted = true
            if await store.runCommandLineAutomaticReplacementIfRequested() {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func tabLabel(for tab: SwitchboardTab) -> some View {
        Label(tab.title, systemImage: tab.symbolName)
    }
}

// MARK: - 常驻状态带

/// 无论切到哪个 tab 都显示的三件事：本周额度、当前隐患、一键换号。
private struct GlobalStatusBar: View {
    @EnvironmentObject private var store: SwitchboardStore
    @Binding var selectedAccountID: UUID?

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "switch.2")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            Text("Typeless Switchboard")
                .font(.headline)

            Divider()
                .frame(height: 22)

            QuotaSummaryView()

            Spacer(minLength: 8)

            if store.diagnostics.contains(where: { $0.level == .error }) {
                Label("环境依赖或权限缺失", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .help("部分功能受限，请到「自检排障」运行一键自检")
            }

            if store.isSyncingSession {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("同步官方 App 登录与额度中...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await store.runQuotaGuardOnceFromUI() }
            } label: {
                Label("立刻巡检一次", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isSwitchBusy)

            Button {
                Task {
                    selectedAccountID = await store.runSmartSwitch(
                        apiKey: KeychainStore.readAPIKey(),
                        domain: store.state.settings.domains.first ?? "",
                        expiryTime: 0,
                        from: selectedAccountID,
                        forceSwitch: true
                    )
                }
            } label: {
                Label(store.isSwitchBusy ? "换号进行中…" : "智能换号", systemImage: "bolt.horizontal.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.purple)
            .disabled(store.isSwitchBusy)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
