import SwiftUI
import TypelessSwitchboardCore

// MARK: - Tab 5：自检与排障
//
// 端口自原 `InspectorView` 的「连接设置」里的自检/权限部分 + 「状态」整段。
// 这一页只回答一个问题：**哪里坏了，以及把能证明坏在哪的材料交出去。**

struct DiagnosticsTabView: View {
    @EnvironmentObject private var store: SwitchboardStore

    @State private var isCheckingTypeless = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeading(
                    title: "自检排障",
                    subtitle: "先跑一键自检确认环境，再把日志、环境、设备、token 报告复制出来定位问题。",
                    symbolName: SwitchboardTab.diagnostics.symbolName
                )

                checkCard

                if !store.diagnostics.isEmpty {
                    SettingsCard(title: "自检结果", symbolName: "list.bullet.clipboard", footnote: footnote1) {
                        VStack(spacing: 8) {
                            ForEach(store.diagnostics) { item in
                                DiagnosticRow(item: item)
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    reportCard
                    statusCard
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: 自检动作

    private var checkCard: some View {
        SettingsCard(title: "运行自检", symbolName: "checklist.checked") {
            HStack(spacing: 8) {
                Button {
                    isCheckingTypeless = true
                    Task {
                        await store.runSetupDiagnostics(apiKey: KeychainStore.readAPIKey())
                        isCheckingTypeless = false
                    }
                } label: {
                    Label(isCheckingTypeless ? "自检中" : "一键自检", systemImage: "checklist.checked")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCheckingTypeless)

                Button {
                    isCheckingTypeless = true
                    Task {
                        await store.checkTypelessEntry()
                        isCheckingTypeless = false
                    }
                } label: {
                    Label(isCheckingTypeless ? "检查中" : "检查入口", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingTypeless)
            }

            HStack(spacing: 8) {
                Menu {
                    ForEach(
                        MacPermissionChecklist.recommendedItems.filter { $0.settingsPaneIdentifier != nil },
                        id: \.title
                    ) { item in
                        Button(item.title) {
                            if let pane = item.settingsPaneIdentifier {
                                store.openMacPermissionSettings(pane)
                            }
                        }
                    }
                } label: {
                    Label("打开权限设置", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    store.copyMacPermissionChecklist()
                } label: {
                    Label("复制权限清单", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

        }
    }

    // MARK: 报告与快照

    private var reportCard: some View {
        SettingsCard(title: "排障材料", symbolName: "shippingbox", footnote: footnote2) {
            Button {
                store.copyTroubleshootingBundle()
            } label: {
                Label("复制完整排障包", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                Button {
                    store.copyTypelessEnvironmentReport()
                } label: {
                    Label("复制 Typeless 环境", systemImage: "terminal")
                }

                Button {
                    store.copyDeviceInfoReport()
                } label: {
                    Label("复制设备信息", systemImage: "desktopcomputer")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.captureLoginSnapshotManifest()
                } label: {
                    Label("生成登录态快照", systemImage: "camera.metering.matrix")
                }

                Button {
                    store.copyLatestLoginSnapshotManifest()
                } label: {
                    Label("复制快照", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)

            Button {
                store.copyTokenAuditReport()
            } label: {
                Label("复制 token 报告", systemImage: "key.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

        }
    }

    // MARK: 状态 / 最近自动化

    private var statusCard: some View {
        SettingsCard(title: "状态", symbolName: "info.circle") {
            Text(store.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            NoteLine(text: "账号数据保存在本机 Application Support，MoeMail 密钥保存在 macOS 钥匙串。")

            HStack(spacing: 8) {
                Button {
                    store.openDataFolder()
                } label: {
                    Label("打开数据", systemImage: "folder")
                }

                Button {
                    store.copyDataPath()
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)

            if let result = store.state.lastAutomationResult {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("最近自动换号", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))

                    Text(result.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.status == .completed ? .green : .orange)

                    ScrollView {
                        Text(result.markdown)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.markdown, forType: .string)
                        store.statusMessage = "已复制最近自动换号结果"
                    } label: {
                        Label("复制自动化结果", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.openLastAutomationBrowserSession()
                    } label: {
                        Label("打开新账号会话", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!result.canOpenBrowserSession)

                    Button {
                        Task { _ = await store.retryLastAutomation() }
                    } label: {
                        Label(
                            store.isRunningAutomaticReplacement ? "重试中" : "重试最近自动化",
                            systemImage: "arrow.clockwise.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!result.canRetry || store.isRunningAutomaticReplacement)
                }
            }
        }
    }

    private var footnote1: String {
        "本工具自用，权限建议全部授予：自动化、辅助功能、全磁盘访问都会影响账号切换是否成功。"
    }

    private var footnote2: String {
        "排障包只含脱敏后的路径、状态与错误信息，不含钥匙串里的密码。"
    }

}
