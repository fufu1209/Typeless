import SwiftUI
import TypelessSwitchboardCore

// MARK: - Tab 3：额度守护（开机 LaunchAgent 自动巡检）
//
// 端口自原 `ContentView.sidebar` 的「额度守护（推荐开机插件，不必常驻本 App）」整段。
// 这一页只回答一个问题：**我不开着这个 App 时，额度还有没有人看着。**

struct QuotaGuardTabView: View {
    @EnvironmentObject private var store: SwitchboardStore
    /// v2.8.0：「自检直读」「带端口重启」的输出，贴在这里方便复制。
    @State private var cdpDiagnostics = ""
    @State private var isCDPProbing = false

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
                cdpCard
                historyCard
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
                color: QuotaGuardLaunchAgent.isLoaded
                    ? .green
                    : (QuotaGuardLaunchAgent.isInstalled ? .orange : .secondary)
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
                Label("同步登录态与本周额度（直读优先）", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isSyncingSession)

            Divider()

            // v2.5.5：额度按「周一 00:00」刷新，这个 00:00 相对哪个时区决定复活时刻。
            // 系统时区与本人实际所在时区不一致时（系统 +0700 / 人在深圳 +0800）
            // 倒计时会整体偏移一小时，这里允许显式锁定。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("刷新时区")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { store.state.settings.quotaCycleTimeZoneIdentifier },
                    set: { store.setQuotaCycleTimeZoneIdentifier($0) }
                )) {
                    Text("跟随系统（\(TimeZone.current.identifier)）").tag("")
                    Text("中国标准时间 UTC+8").tag("Asia/Shanghai")
                    Text("印度支那 UTC+7").tag("Asia/Bangkok")
                    Text("协调世界时 UTC").tag("UTC")
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 240)
                Spacer()
            }

            NoteLine(text: quotaCycleFootnote, color: .secondary, lineLimit: 3)

            // v2.5.6：官方接口不返回重置时间戳，「周一刷新」目前仍是**推断**。
            // 观测到真实重置后这里会自动变成「已确认」并给出依据次数。
            // 确认之前，不许把推断包装成确定结论给用户。
            let inference = store.quotaCycleInference()
            if case .insufficient = inference {
                NoteLine(
                    text: "\(QuotaCycleEngine.cycleConfidenceText(inference))。目前按自然周（周一 00:00）排程；一旦实测到额度重置，会自动校准口径。",
                    color: .orange,
                    lineLimit: 3
                )
            } else {
                NoteLine(text: QuotaCycleEngine.cycleConfidenceText(inference), color: .secondary, lineLimit: 2)
            }
        }
    }

    // MARK: 额度直读（v2.8.0）

    /// 额度直读卡片。
    ///
    /// 为什么值得单独一张卡：官方接口现在同时被「客户端签名」和「JA3/TLS 指纹」
    /// 两道门挡着，node / curl 一律 418；读屏 OCR 又依赖屏幕录制权限和窗口可见性。
    /// CDP 直读是唯一「不要权限、不看窗口、拿到服务端原值」的链路，但它的前提
    /// （Typeless 带调试端口启动）必须让用户看得见、按得到。
    private var cdpCard: some View {
        SettingsCard(title: "额度直读（CDP）", symbolName: "bolt.horizontal.circle", footnote: cdpFootnote) {
            Toggle("启用额度直读（推荐）", isOn: settingsBinding(\.isCDPQuotaEnabled))
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: store.state.settings.isCDPQuotaEnabled) { _ in
                    store.applyLiveQuotaWatcherState()
                }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("调试端口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "端口",
                    value: Binding(
                        get: { store.state.settings.cdpQuotaPort },
                        set: { newValue in
                            store.state.settings.cdpQuotaPort = TypelessQuotaBridge.normalizePort(newValue)
                            store.save()
                        }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
                .onSubmit { store.applyLiveQuotaWatcherState() }
                Spacer()
                if let source = store.lastQuotaSource {
                    Text("最近来源：\(source.displayName)")
                        .font(.caption)
                        .foregroundStyle(source.isLive ? .green : .orange)
                }
            }

            if !store.liveAccountEmail.isEmpty {
                InfoLine(label: "当前账号", value: store.liveAccountEmail, color: .secondary)
            }
            if let synced = store.lastQuotaSyncAt {
                let age = Date().timeIntervalSince(synced)
                InfoLine(
                    label: "额度年龄",
                    value: Self.relativeAge(synced),
                    color: age > 600 ? .orange : .secondary
                )
            }
            if let repaired = store.state.lastCDPBridgeRepairAt {
                InfoLine(label: "最近自动修桥", value: Self.relativeAge(repaired), color: .secondary)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        isCDPProbing = true
                        cdpDiagnostics = await store.diagnoseCDPQuotaBridge()
                        isCDPProbing = false
                    }
                } label: {
                    Label("自检直读", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCDPProbing)

                Button {
                    Task {
                        isCDPProbing = true
                        cdpDiagnostics = await store.restartTypelessWithQuotaDebugPort()
                        isCDPProbing = false
                    }
                } label: {
                    Label("带端口重启 Typeless", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)
                .disabled(isCDPProbing)
            }

            Button {
                Task {
                    isCDPProbing = true
                    if let snapshot = await store.readQuotaViaCDPBridge() {
                        store.applyQuotaSnapshotToMatchingAccount(snapshot)
                        cdpDiagnostics = "直读成功：\(snapshot.summary)；页面客户端 \(snapshot.clientChunk ?? "未知")"
                    } else {
                        cdpDiagnostics = "直读失败：\(store.lastCDPQuotaFailure)"
                    }
                    isCDPProbing = false
                }
            } label: {
                Label("立即直读一次额度", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isCDPProbing)

            if store.isCDPQuotaEnabled {
                if let lastEvent = store.lastLiveQuotaEventAt {
                    NoteLine(
                        text: "实时监听：已旁听 \(store.liveQuotaEventCount) 次额度刷新（最近 \(Self.historyClock(lastEvent))）",
                        color: .secondary,
                        lineLimit: 2
                    )
                } else {
                    NoteLine(
                        text: "实时监听已启动：Typeless 自己刷新额度时会自动同步（不额外发请求）",
                        color: .secondary,
                        lineLimit: 2
                    )
                }
            }

            if !store.lastCDPQuotaFailure.isEmpty {
                NoteLine(text: "直读未成功：\(store.lastCDPQuotaFailure)", color: .orange, lineLimit: 4)
            }
            if !cdpDiagnostics.isEmpty {
                NoteLine(text: cdpDiagnostics, color: .secondary, lineLimit: 6)
            }
            NoteLine(text: store.weeklyQuotaSummaryLine, color: .secondary, lineLimit: 3)
        }
    }

    // MARK: 换号历史（v2.8.0）

    /// 换号历史卡片。
    ///
    /// 只回答三个问题：**换了几次 / 成功率多少 / 一次要等多久**。
    /// 这三个数字决定「阈值调对了没有」和「池子该不该扩」——比看 daemon 日志快得多。
    private var historyCard: some View {
        SettingsCard(title: "换号历史（近 7 天）", symbolName: "clock.arrow.circlepath", footnote: historyFootnote) {
            let summary = store.switchHistorySummary()
            let entries = store.switchHistoryEntries

            NoteLine(text: SwitchHistory.summaryLine(summary), color: summary.failed > 0 ? .orange : .secondary, lineLimit: 3)

            if entries.isEmpty {
                NoteLine(text: "还没有换号记录。成功/失败/耗时会在每次换号后自动记一条。", color: .secondary, lineLimit: 2)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entries.prefix(8)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(entry.succeeded ? .green : .red)
                                .font(.caption)
                            Text(Self.historyClock(entry.at))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(entry.trigger.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.toEmail ?? "—")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1fs", entry.durationSeconds))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    _ = store.copySwitchHistoryCSV()
                } label: {
                    Label("复制 CSV", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    store.clearSwitchHistory()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(entries.isEmpty)
            }
        }
    }

    private var historyFootnote: String {
        "每次换号（自动巡检 / 手动 / 降级轮换 / 自动注册）都会记一条结果与耗时；热备注册不切换账号，不记。只保留最近 \(SwitchHistory.maximumEntries) 条，不含令牌或会话内容。"
    }

    /// 「多久以前」的人话表述，给额度年龄/修桥时间用。
    private static func relativeAge(_ date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }

    private static func historyClock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private var cdpFootnote: String {
        "直读走 Typeless 自己渲染进程里的 API 客户端：签名、Cookie、TLS 指纹都是官方的，所以不会被 JA3 墙挡。前提是 Typeless 以 --remote-debugging-port=\(store.cdpQuotaPort) 启动（「带端口重启」会帮你做一次）。端口只监听 127.0.0.1。"
    }

    /// 下次刷新的绝对时刻 + 到点会发生什么。用户最关心的就是「多久能回到满额度」。
    private var quotaCycleFootnote: String {
        let calendar = QuotaCycleClock.shared.calendar
        guard let reset = QuotaCycleEngine.nextCalendarWeekReset(calendar: calendar) else {
            return "下次刷新时间计算失败"
        }
        let formatter = DateFormatter()
        formatter.timeZone = QuotaCycleClock.shared.timeZone
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEEE HH:mm z"
        let countdown = QuotaCycleEngine.countdownText(to: reset)
        let count = store.state.accounts.count
        let perAccount = store.lastQuotaMonthlyLimit ?? QuotaCycleEngine.defaultWeeklyLimit
        let poolNote = count > 0 ? "，池内 \(count) 个账号同时回到各 \(perAccount) 字" : ""
        return "下次刷新 \(formatter.string(from: reset))（还有 \(countdown)）\(poolNote)。到点不需要开着本 App，看门狗会按同一时刻自动复活。"
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
        "口径：Typeless 本周周额度（week_word_usage）。插件优先用 CDP 直读 App 渲染进程里的真实数值；直读不可用时退回读屏 OCR / 本地缓存估算。仅本周剩余 < 阈值（默认 \(SmartSwitchPolicy.defaultRemainingThreshold)）且数字新鲜才自动换号。近阈值会加速到约 20 秒一轮。日志在 Application Support/TypelessSwitchboard/Logs/。"
    }

}
