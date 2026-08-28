import SwiftUI
import TypelessSwitchboardCore

// MARK: - Tab 2：智能换号
//
// 端口自原 `LegacyContentView.sidebar` 尾部的三个换号大按钮（AppMain.swift 5986-6037）
// + `InspectorView.checklistPanel`（AppMain.swift 7041-7075，含 checklistBinding 7254-7262）。
// 这一页只回答一个问题：**现在点什么能把额度续上。**
//
// 阈值 / 热备 / 「池空时自动注册新号」在「额度守护」tab（QuotaGuardTabView.policyCard），
// 这里不再重复；「连接设置」「账号池工具」「MoeMail」「邮箱域名」「状态」属于其它 tab。

struct RotateTabView: View {
    @EnvironmentObject private var store: SwitchboardStore
    @Binding var selectedAccountID: UUID?
    @Binding var apiKey: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeading(
                    title: SwitchboardTab.rotate.title,
                    subtitle: "额度见底时点一下就换；切号前照着清单核对一遍。",
                    symbolName: SwitchboardTab.rotate.symbolName
                )

                actionsCard
                checklistCard
                priorityCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: 换号动作

    private var actionsCard: some View {
        SettingsCard(title: "换号动作", symbolName: "bolt.horizontal.circle.fill", footnote: actionFootnote) {
            if let account = selectedAccount {
                InfoLine(
                    label: "当前选中",
                    value: "\(account.email) · 本周剩余 \(account.remainingCharacters) / \(account.monthlyLimit)",
                    color: account.remainingCharacters > 0 ? .primary : .orange
                )
                // v2.5.3：换号决策最关心的是「这个号什么时候能再用」，之前完全没显示。
                InfoLine(
                    label: "下次可用",
                    value: account.nextAvailabilityText,
                    color: account.nextAvailabilityText == "立即可用" ? .primary : .orange
                )
            } else {
                InfoLine(label: "当前选中", value: "未选择账号", color: .orange)
            }

            Button {
                Task {
                    selectedAccountID = await store.runSmartSwitch(
                        apiKey: apiKey,
                        domain: store.state.settings.domains.first ?? "",
                        expiryTime: 0,
                        from: selectedAccountID,
                        forceSwitch: true
                    )
                }
            } label: {
                Label(
                    store.isSwitchBusy ? "换号进行中…" : "智能换号（一点就换）",
                    systemImage: "bolt.horizontal.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(store.isSwitchBusy)

            Button {
                selectedAccountID = store.prepareSwitch(from: selectedAccountID)
            } label: {
                Label("准备切换（打开页面兜底）", systemImage: "forward.end.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isSwitchBusy)

            Button {
                Task {
                    selectedAccountID = await store.runOneClickAutomaticReplacement(
                        apiKey: apiKey,
                        domain: store.state.settings.domains.first ?? "",
                        expiryTime: 0,
                        from: selectedAccountID,
                        interactive: true
                    )
                }
            } label: {
                Label(
                    store.isRunningAutomaticReplacement ? "注册换号中" : "强制全自动注册新号",
                    systemImage: "wand.and.stars.inverse"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(store.isSwitchBusy || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: 切换清单

    private var checklistCard: some View {
        SettingsCard(title: "切换清单", symbolName: "checklist", footnote: checklistFootnote) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    store.resetChecklist()
                } label: {
                    Label("重置清单", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("重置清单")
            }

            ForEach(store.state.settings.checklist.indices, id: \.self) { index in
                Toggle(isOn: checklistBinding(index: index, keyPath: \.isDone)) {
                    Text(store.state.settings.checklist[index].title)
                        .font(.callout)
                        .foregroundStyle(store.state.settings.checklist[index].isRequired ? .primary : .secondary)
                }
            }

            if let next = store.nextAvailableAccountID() {
                Button {
                    selectedAccountID = next
                    store.resetChecklist()
                } label: {
                    Label("选择下一个可用账号", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    // MARK: 选号优先级说明

    private var priorityCard: some View {
        SettingsCard(title: "换号优先级", symbolName: "arrow.up.arrow.down", footnote: priorityFootnote) {
            NoteLine(
                text: "1. 已复活的号：跨过周一 00:00 且本周用尽的号优先切回，已用字数少的排在前面。",
                color: .primary,
                lineLimit: 2
            )
            NoteLine(
                text: "2. 静默就绪且余额最多的号：已确认、带静默会话、余额 > 0 的号，按剩余额度从多到少取。",
                color: .primary,
                lineLimit: 3
            )
            NoteLine(
                text: "3. 两个池子都空：不硬切，改走「强制全自动注册新号」补一个新号进来。",
                color: .primary,
                lineLimit: 2
            )
        }
    }

    // MARK: 辅助

    private var selectedAccount: Account? {
        guard let selectedAccountID else { return nil }
        return store.state.accounts.first { $0.id == selectedAccountID }
    }

    private func checklistBinding<Value>(index: Int, keyPath: WritableKeyPath<SwitchTask, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.settings.checklist[index][keyPath: keyPath] },
            set: { newValue in
                store.state.settings.checklist[index][keyPath: keyPath] = newValue
                store.save()
            }
        )
    }

    private var actionFootnote: String {
        "智能换号：优先在账号池内静默注入会话，没有可注入会话时自动降级为全自动注册。准备切换：只把当前号标记为已用完并打开目标号页面兜底，不改登录态。"
    }

    private var checklistFootnote: String {
        "粗体为必做项。切号前逐项打勾，点「选择下一个可用账号」会自动选中下一个并清空清单。"
    }

    private var priorityFootnote: String {
        "口径取自 QuotaCycleEngine.pickNext：复活号 > 静默就绪池（余额降序）> nil。周度默认按自然周（周一 00:00 本地时区）判定复活。"
    }
}
