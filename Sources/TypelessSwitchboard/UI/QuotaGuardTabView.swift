import SwiftUI
import TypelessSwitchboardCore

// MARK: - Tab 3：额度守护（开机 LaunchAgent 自动巡检）
//
// 端口自原 `ContentView.sidebar` 的「额度守护（推荐开机插件，不必常驻本 App）」整段。
// 这一页只回答一个问题：**我不开着这个 App 时，额度还有没有人看着。**

struct QuotaGuardTabView: View {
    @EnvironmentObject private var store: SwitchboardStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeading(
                    title: "额度守护",
                    subtitle: "装一个开机 LaunchAgent，登录后按间隔巡检额度，不必常驻本 App。",
                    symbolName: SwitchboardTab.quotaGuard.symbolName
                )

                HStack(alignment: .top, spacing: 14) {
                    agentCard
                    policyCard
                }

                weeklyCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: 插件本身

    private var agentCard: some View {
        SettingsCard(title: "开机插件", symbolName: "power", footnote: footnote1) {
            InfoLine(
                label: "状态",
                value: store.launchAgentStatusMessage,
                color: QuotaGuardLaunchAgent.isInstalled ? .green : .secondary
            )

            HStack(spacing: 8) {
                Button {
                    _ = store.installQuotaGuardLaunchAgent()
                } label: {
                    Label("安装/更新开机插件", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)

                Button {
                    _ = store.uninstallQuotaGuardLaunchAgent()
                } label: {
                    Label("卸载", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!QuotaGuardLaunchAgent.isInstalled)

                Button {
                    Task { await store.runQuotaGuardOnceFromUI() }
                } label: {
                    Label("立刻巡检一次", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isSwitchBusy)
            }

            Toggle("打开本 App 时循环监控（可选）", isOn: settingsBinding(\.isAutoRotateEnabled))
                .toggleStyle(.checkbox)
                .font(.caption)

            Toggle("关窗后继续挂菜单栏（可选）", isOn: settingsBinding(\.keepRunningInBackground))
                .toggleStyle(.checkbox)
                .font(.caption)

        }
    }

    // MARK: 自动换号的触发口径

    private var policyCard: some View {
        SettingsCard(title: "换号触发条件", symbolName: "gauge.medium", footnote: footnote2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("本周剩余 <")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "阈值",
                    value: Binding(
                        get: { store.state.settings.autoRotateRemainingThreshold },
                        set: { newValue in
                            store.state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.normalizeThreshold(newValue)
                            store.save()
                        }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                Text("字就换号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("常备热备账号")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "热备",
                    value: Binding(
                        get: { store.state.settings.hotSpareTargetCount },
                        set: { newValue in
                            store.state.settings.hotSpareTargetCount = SmartSwitchPolicy.normalizeHotSpareTarget(newValue)
                            store.save()
                        }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                Text("个")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Toggle("池空时自动注册新号", isOn: settingsBinding(\.autoCreateWhenPoolEmpty))
                .toggleStyle(.checkbox)
                .font(.caption)

            if let remaining = store.liveRemainingCharacters, store.lastQuotaSyncFresh {
                let threshold = SmartSwitchPolicy.normalizeThreshold(store.state.settings.autoRotateRemainingThreshold)
                let emailSuffix = store.liveAccountEmail.isEmpty ? "" : " · \(store.liveAccountEmail)"
                let line = remaining >= threshold
                    ? "本周剩余 \(remaining) ≥ 阈值 \(threshold)：只监控，不换号\(emailSuffix)"
                    : "本周剩余 \(remaining) < 阈值 \(threshold)：将自动换号\(emailSuffix)"
                NoteLine(
                    text: line,
                    color: remaining >= threshold ? .secondary : .orange,
                    lineLimit: 2
                )
            } else if !store.lastQuotaSyncFresh {
                NoteLine(
                    text: "本周额度未刷新成功时不会自动换号（避免陈旧数字误触发）",
                    color: .orange,
                    lineLimit: 2
                )
            }

            NoteLine(text: store.autoRotateMonitorStatus, color: .secondary, lineLimit: 4)

            if !store.lastAutoRotateDecisionReason.isEmpty {
                NoteLine(text: store.lastAutoRotateDecisionReason, color: Color(nsColor: .tertiaryLabelColor), lineLimit: 3)
            }

        }
    }

    // MARK: 本周额度总览

    private var weeklyCard: some View {
        SettingsCard(title: "本周额度", symbolName: "calendar.badge.clock") {
            QuotaSummaryView()

            NoteLine(
                text: store.weeklyQuotaSummaryLine,
                color: store.lastQuotaSyncFresh ? .secondary : .orange,
                lineLimit: 3
            )

            if let accountLoadError = store.accountLoadError {
                NoteLine(text: accountLoadError, color: .red, lineLimit: 5)
            }

            Button {
                Task {
                    _ = await store.syncActiveAppSessionAndQuota()
                }
            } label: {
                Label("同步官方 App 登录与额度", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isSyncingSession)
        }
    }

    private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.settings[keyPath: keyPath] },
            set: { newValue in
                store.state.settings[keyPath: keyPath] = newValue
                store.save()
            }
        )
    }

    private var footnote1: String {
        "插件启动 \(QuotaGuardLaunchAgentPlanner.daemonFlag)，单次巡检后退出；轮询间隔由 launchd 控制，低于 \(QuotaGuardLaunchAgentPlanner.minimumIntervalSeconds) 秒会被 launchd 拒绝加载。"
    }

    private var footnote2: String {
        "口径：Typeless 本周周额度（week_word_usage）。插件定时读官方接口；仅本周剩余 < 阈值（默认 200）且数字新鲜才自动换号。近阈值会加速到约 20 秒一轮。日志在 Application Support/TypelessSwitchboard/Logs/。"
    }

}
