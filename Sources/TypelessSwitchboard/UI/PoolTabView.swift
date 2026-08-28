import SwiftUI
import UniformTypeIdentifiers
import TypelessSwitchboardCore

// MARK: - Tab 1：账号池
//
// 端口自 `AppMain.swift`：
// - `LegacyContentView.sidebar`：搜索 TextField + 筛选 Picker（5782-5791）、
//   `List(selection:)` + `AccountRow`（5794-5799）、「新增」「下一个」（5802-5815）；
// - `LegacyContentView.filteredAccounts`（6043-6073）、`detailArea`（6076-6092）、
//   `accountBinding(index:)`（6094-6102）；
// - `InspectorView.accountPoolPanel` 的 9 个工具按钮（6719-6859），
//   去掉了属于「智能换号」tab 的两个换号按钮；
// - `InspectorView.reviewQueuePanel`（6861-6910）。
//
// 这一页只回答一个问题：**我手上有哪些账号，它们各自是什么状态。**

struct PoolTabView: View {
    @Binding var selectedAccountID: UUID?

    @EnvironmentObject private var store: SwitchboardStore

    @State private var searchText = ""
    @State private var listFilter: AccountListFilter = .all
    @State private var candidateCount = 5
    @State private var generatedDomain = ""
    @State private var isShowingBundleImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeading(
                    title: SwitchboardTab.pool.title,
                    subtitle: SwitchboardTab.pool.subtitle,
                    symbolName: SwitchboardTab.pool.symbolName
                )

                HStack(alignment: .top, spacing: 14) {
                    listPane
                    detailPane
                }
                .frame(height: 470)

                toolsCard
                reviewQueueCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: 左：账号列表（搜索 + 筛选 + 选中）

    private var listPane: some View {
        SettingsCard(
            title: "账号列表",
            symbolName: "list.bullet.rectangle",
            footnote: listFootnote
        ) {
            TextField("搜索账号、邮箱或域名", text: $searchText)
                .textFieldStyle(.roundedBorder)

            Picker("筛选", selection: $listFilter) {
                ForEach(AccountListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()

            List(selection: $selectedAccountID) {
                ForEach(filteredAccounts) { account in
                    AccountRow(account: account)
                        .tag(account.id)
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            HStack(spacing: 8) {
                Button {
                    selectedAccountID = store.addAccount()
                } label: {
                    Label("新增", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    selectedAccountID = store.nextAvailableAccountID()
                } label: {
                    Label("下一个", systemImage: "arrow.right.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(store.nextAvailableAccountID() == nil)
            }
            .buttonStyle(.bordered)
        }
        .frame(width: 320)
    }

    private var listFootnote: String {
        "共 \(store.state.accounts.count) 个账号，当前筛选显示 \(filteredAccounts.count) 个。"
    }

    // MARK: 右：选中账号详情

    private var detailPane: some View {
        detailArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var detailArea: some View {
        if let index = store.accountIndex(id: selectedAccountID) {
            AccountDetailView(
                account: accountBinding(index: index),
                onSave: store.save,
                onDelete: {
                    let deletedID = store.state.accounts[index].id
                    store.deleteAccount(id: deletedID)
                    selectedAccountID = store.state.accounts.first?.id
                }
            )
        } else {
            EmptyStateView {
                selectedAccountID = store.addAccount()
            }
        }
    }

    private func accountBinding(index: Int) -> Binding<Account> {
        Binding(
            get: { store.state.accounts[index] },
            set: { newValue in
                store.state.accounts[index] = newValue
                store.save()
            }
        )
    }

    // MARK: 搜索 + 筛选（原样来自 LegacyContentView.filteredAccounts）

    private var filteredAccounts: [Account] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.state.accounts.filter { account in
            let matchesFilter: Bool
            switch listFilter {
            case .all:
                matchesFilter = true
            case .available:
                matchesFilter = account.isUsable && account.remainingCharacters > 0
            case .pending:
                matchesFilter = account.effectiveReviewState == .pending
            case .exhausted:
                matchesFilter = account.status == .exhausted || account.remainingCharacters == 0
            case .paused:
                matchesFilter = account.status == .paused || account.effectiveReviewState == .rejected
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }

            let haystack = [
                account.name,
                account.email,
                account.domain,
                account.role,
                account.typelessUsername ?? "",
                account.notes
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    // MARK: 账号池工具（端口自 InspectorView.accountPoolPanel）

    private var toolsCard: some View {
        SettingsCard(
            title: "账号池工具",
            symbolName: "tray.full",
            footnote: "生成、备份、导入、体检。换号与注册动作已分别移到「智能换号」「注册与邮箱」两页。"
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Stepper(value: $candidateCount, in: 1...30) {
                    Text("候选账号数量：\(candidateCount)")
                        .font(.callout)
                }

                Picker("候选域名", selection: $generatedDomain) {
                    ForEach(store.state.settings.domains, id: \.self) { domain in
                        Text(domain).tag(domain)
                    }
                }
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Button {
                    store.generateCandidateAccounts(count: candidateCount, domain: generatedDomain)
                } label: {
                    Label("批量生成", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    selectedAccountID = store.prepareSwitch(from: selectedAccountID)
                } label: {
                    Label("准备切换", systemImage: "forward.end.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(store.nextAvailableAccountID() == nil || store.isSwitchBusy)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.exportAccountsToClipboard()
                } label: {
                    Label("复制 JSON", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    store.importAccountsFromClipboard()
                    selectedAccountID = store.state.accounts.first?.id
                } label: {
                    Label("恢复 JSON", systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.exportAccountsCSVToClipboard()
                } label: {
                    Label("复制 CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    store.importAccountsCSVFromClipboard()
                    selectedAccountID = store.state.accounts.first?.id
                } label: {
                    Label("导入 CSV", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            Button {
                store.importToolkitAccountsFromClipboard()
                selectedAccountID = store.state.accounts.first?.id
            } label: {
                Label("导入 toolkit 账号", systemImage: "square.stack.3d.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.copyAccountPoolAuditToClipboard()
                } label: {
                    Label("复制体检报告", systemImage: "stethoscope")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    store.resetMonthlyQuotaForApprovedAccounts()
                } label: {
                    Label("月初重置已确认账号", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            // v2.5.2：完整配置包导入导出（换 Mac / 分享 / 备份）
            HStack(spacing: 8) {
                Button {
                    _ = store.exportFullBundle()
                } label: {
                    Label("导出完整配置包", systemImage: "archivebox")
                        .frame(maxWidth: .infinity)
                }
                .help("导出账号池 + 设置到 ~/Downloads（不含 keychain）")

                Button {
                    _ = store.exportPublicBundle()
                } label: {
                    Label("导出脱敏包（可分享）", systemImage: "archivebox.fill")
                        .frame(maxWidth: .infinity)
                }
                .help("邮箱替换为占位、备注清空，可发 GitHub / 分享给同事")

                Button {
                    isShowingBundleImporter = true
                } label: {
                    Label("导入配置包", systemImage: "square.and.arrow.down.on.square")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)

            if !store.statusMessage.isEmpty {
                NoteLine(text: store.statusMessage, lineLimit: 4)
            }
        }
        .onAppear {
            if generatedDomain.isEmpty {
                generatedDomain = store.state.settings.domains.first ?? ""
            }
        }
        .fileImporter(
            isPresented: $isShowingBundleImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let needsScope = url.startAccessingSecurityScopedResource()
                    defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
                    _ = store.importFullBundle(from: url)
                }
            case .failure(let error):
                store.statusMessage = "导入失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: 兜底确认队列（端口自 InspectorView.reviewQueuePanel）

    private var reviewQueueCard: some View {
        let pendingIDs = store.pendingReviewAccountIDs()
        return SettingsCard(
            title: pendingIDs.isEmpty ? "全自动换号确认状态" : "兜底确认队列",
            symbolName: pendingIDs.isEmpty ? "bolt.badge.checkmark" : "checkmark.seal",
            footnote: "确认后的账号进入可用池，退回的账号不再参与自动换号。"
        ) {
            if pendingIDs.isEmpty {
                NoteLine(
                    text: store.state.lastAutomationResult?.status == .completed
                        ? "最近一次一键换号已自动确认成功账号，不需要再点“确认/退回”。"
                        : "当前没有待兜底确认账号；只有自动化无法证明注册完成时，才会出现兜底队列。",
                    lineLimit: 3
                )
            } else {
                InfoLine(label: "待确认", value: "\(pendingIDs.count) 个", color: .orange)

                NoteLine(
                    text: "这里仅显示自动化没有证明完成的候选账号；正常一键换号成功后会直接进入已确认可用池。",
                    lineLimit: 3
                )

                ForEach(Array(pendingIDs.prefix(8)), id: \.self) { id in
                    if let index = store.accountIndex(id: id) {
                        ReviewAccountRow(
                            account: store.state.accounts[index],
                            onSelect: { selectedAccountID = id },
                            onApprove: {
                                store.approveAccount(id: id)
                                selectedAccountID = id
                            },
                            onReject: { store.rejectAccount(id: id) }
                        )
                    }
                }
            }
        }
    }
}
