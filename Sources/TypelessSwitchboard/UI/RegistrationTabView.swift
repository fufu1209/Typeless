import SwiftUI
import TypelessSwitchboardCore

// MARK: - Tab 4：注册与邮箱
//
// 端口自原 `InspectorView` 的三个面板：
// - 「连接设置」（AppMain.swift 6618-6717），剔除已归到「自检排障」的自检/权限/诊断列表；
// - 「MoeMail 邮箱」（AppMain.swift 6912-7039）；
// - 「邮箱域名」（AppMain.swift 7077-7113）。
// 这一页只回答一个问题：**新号从哪里来（MoeMail 邮箱 + 批量注册）。**

struct RegistrationTabView: View {
    @EnvironmentObject private var store: SwitchboardStore
    @Binding var apiKey: String
    @Binding var selectedAccountID: UUID?

    @State private var newDomain = ""
    @State private var isRefreshing = false
    @State private var isLoadingEmails = false
    @State private var isGeneratingEmail = false
    @State private var isCreatingRegistration = false
    @State private var isLoadingMessages = false
    @State private var generatedName = "typeless"
    @State private var generatedDomain = ""
    @State private var generatedExpiry = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TabHeading(
                    title: SwitchboardTab.registration.title,
                    subtitle: "配好 MoeMail 密钥与域名，读取或生成邮箱，一键创建待注册的候选账号。",
                    symbolName: SwitchboardTab.registration.symbolName
                )

                HStack(alignment: .top, spacing: 14) {
                    connectionCard
                    domainsCard
                }

                moeMailCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: 连接设置（密钥 / 入口 / 地址）

    private var connectionCard: some View {
        SettingsCard(title: "连接设置", symbolName: "gearshape", footnote: footnote1) {
            TextField("Typeless 入口", text: settingsBinding(\.typelessLoginURL))
                .textFieldStyle(.roundedBorder)
            TextField("MoeMail 地址", text: settingsBinding(\.moeMailBaseURL))
                .textFieldStyle(.roundedBorder)
            SecureField("MoeMail API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button {
                    store.openInstalledTypelessApp()
                } label: {
                    Label("打开 App", systemImage: "macwindow")
                }

                Button {
                    store.openTypelessOfficialWebsite()
                } label: {
                    Label("打开官网", systemImage: "safari")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    KeychainStore.saveAPIKey(apiKey)
                    store.statusMessage = "API Key 已保存到钥匙串"
                } label: {
                    Label("保存密钥", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    isRefreshing = true
                    Task {
                        await store.refreshMoeMailConfig(apiKey: apiKey)
                        isRefreshing = false
                    }
                } label: {
                    Label(isRefreshing ? "同步中" : "同步域名", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isRefreshing)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            NoteLine(text: "自检、权限设置与诊断结果已移到「自检排障」tab，这里只负责连得上。")
        }
    }

    // MARK: 邮箱域名

    private var domainsCard: some View {
        SettingsCard(title: "邮箱域名", symbolName: "at", footnote: footnote2) {
            HStack(spacing: 8) {
                TextField("添加域名", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if !store.state.settings.domains.contains(trimmed) {
                        store.state.settings.domains.append(trimmed)
                        store.state.settings.domains.sort()
                        store.save()
                    }
                    newDomain = ""
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], spacing: 8) {
                ForEach(store.state.settings.domains, id: \.self) { domain in
                    Text(domain)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }

    // MARK: MoeMail 邮箱

    private var moeMailCard: some View {
        SettingsCard(title: "MoeMail 邮箱", symbolName: "mail.stack", footnote: footnote3) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                    TextField("邮箱前缀", text: $generatedName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("域名")
                    Picker("域名", selection: $generatedDomain) {
                        ForEach(store.state.settings.domains, id: \.self) { domain in
                            Text(domain).tag(domain)
                        }
                    }
                }
                GridRow {
                    Text("有效期")
                    Picker("有效期", selection: $generatedExpiry) {
                        Text("永久").tag(0)
                        Text("1 小时").tag(3_600_000)
                        Text("1 天").tag(86_400_000)
                        Text("7 天").tag(604_800_000)
                    }
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button {
                    isLoadingEmails = true
                    Task {
                        await store.loadMoeMailEmails(apiKey: apiKey)
                        isLoadingEmails = false
                    }
                } label: {
                    Label(isLoadingEmails ? "读取中" : "读取列表", systemImage: "tray.and.arrow.down")
                }
                .disabled(isLoadingEmails)

                Button {
                    isGeneratingEmail = true
                    Task {
                        if let email = await store.generateMoeMailEmail(
                            apiKey: apiKey,
                            name: generatedName,
                            domain: generatedDomain,
                            expiryTime: generatedExpiry
                        ) {
                            selectedAccountID = store.importMoeMailEmail(email)
                        }
                        isGeneratingEmail = false
                    }
                } label: {
                    Label(isGeneratingEmail ? "生成中" : "生成并导入", systemImage: "plus.circle")
                }
                .disabled(isGeneratingEmail || generatedDomain.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                isCreatingRegistration = true
                Task {
                    if let id = await store.createMoeMailRegistrationCandidate(
                        apiKey: apiKey,
                        domain: generatedDomain,
                        expiryTime: generatedExpiry
                    ) {
                        selectedAccountID = id
                    }
                    isCreatingRegistration = false
                }
            } label: {
                Label(
                    isCreatingRegistration ? "创建中" : "创建注册候选账号",
                    systemImage: "person.crop.circle.badge.plus"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isCreatingRegistration || generatedDomain.isEmpty)

            Divider()

            Button {
                guard let index = store.accountIndex(id: selectedAccountID) else { return }
                let account = store.state.accounts[index]
                isLoadingMessages = true
                Task {
                    await store.loadMessages(for: account, apiKey: apiKey)
                    isLoadingMessages = false
                }
            } label: {
                Label(isLoadingMessages ? "读取中" : "读取当前账号邮件", systemImage: "envelope.badge")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoadingMessages || selectedAccount?.moeMailEmailID == nil)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if store.moeMailEmails.isEmpty {
                        Text("读取 MoeMail 后，可以把已有邮箱导入账号池。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(store.moeMailEmails.prefix(8)) { email in
                            MoeMailEmailRow(email: email) {
                                selectedAccountID = store.importMoeMailEmail(email)
                            }
                        }
                    }

                    if !store.moeMailMessages.isEmpty {
                        Divider()
                        ForEach(store.moeMailMessages.prefix(5)) { message in
                            MoeMailMessageRow(message: message)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
        }
        .onAppear {
            if generatedDomain.isEmpty {
                generatedDomain = store.state.settings.domains.first ?? ""
            }
        }
    }

    // MARK: 支撑

    private var selectedAccount: Account? {
        guard let index = store.accountIndex(id: selectedAccountID) else { return nil }
        return store.state.accounts[index]
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
        "密钥存在 macOS 钥匙串，不写进账号数据文件；改完地址或入口记得点一次「同步域名」拉取可用域名。"
    }

    private var footnote2: String {
        "域名用于生成邮箱与候选账号的后缀，同步域名会从 MoeMail 服务拉取可用列表。"
    }

    private var footnote3: String {
        "「创建注册候选账号」会用随机档案生成邮箱、写入钥匙串强密码，并把账号放进兜底确认队列等待注册核验。"
    }

}
