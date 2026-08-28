import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct AccountDetailView: View {
    @Binding var account: Account
    let onSave: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var store: SwitchboardStore
    @State private var showingDeleteConfirmation = false
    @State private var generatedPassword = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                complianceNotice
                quotaPanel
                editorPanel
                registrationPanel
                actionPanel
            }
            .padding(24)
        }
        .confirmationDialog("删除这个账号？", isPresented: $showingDeleteConfirmation) {
            Button("删除", role: .destructive, action: onDelete)
            Button("取消", role: .cancel) { }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(account.name.isEmpty ? "未命名账号" : account.name)
                    .font(.largeTitle.weight(.semibold))
                Text(account.email.isEmpty ? "还没有填写邮箱" : account.email)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Picker("状态", selection: binding(\.status)) {
                    ForEach(AccountStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)

                Label(account.effectiveReviewState.title, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(account.effectiveReviewState.color)
            }
        }
    }

    private var complianceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.blue)
            Text("这个工具支持自动创建邮箱、浏览器注册、验证码轮询和结果桥接；一键换号会按 typeless-toolkit resetDevice 重置本机设备身份，清理桌面端/Chrome 旧登录态，并把成功账号直接自动确认。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var quotaPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("本月额度", systemImage: "gauge.with.dots.needle.50percent")
                    .font(.headline)
                Spacer()
                Text("剩余 \(account.remainingCharacters) 字")
                    .font(.headline)
            }

            ProgressView(value: account.usageRatio)
                .tint(account.status.color)

            HStack(spacing: 12) {
                NumberField(title: "已用字数", value: binding(\.usedCharacters))
                NumberField(title: "每月额度", value: binding(\.monthlyLimit))
            }

            HStack(spacing: 8) {
                Button {
                    account.usedCharacters = account.monthlyLimit
                    account.status = .exhausted
                    onSave()
                } label: {
                    Label("标记已用完", systemImage: "xmark.circle")
                }

                Button {
                    account.usedCharacters = 0
                    account.status = .available
                    account.lastResetAt = Date()
                    onSave()
                } label: {
                    Label("本月重置", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }

    private var editorPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("账号资料", systemImage: "person.text.rectangle")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("名称")
                    TextField("例如：主力账号", text: binding(\.name))
                }
                GridRow {
                    Text("邮箱")
                    TextField("name@example.com", text: binding(\.email))
                }
                GridRow {
                    Text("MoeMail ID")
                    TextField("邮箱 ID，可从 MoeMail 导入", text: optionalStringBinding(\.moeMailEmailID))
                }
                GridRow {
                    Text("登录名")
                    TextField("Typeless 用户名或显示名", text: optionalStringBinding(\.typelessUsername))
                }
                GridRow {
                    Text("密码提示")
                    TextField("不要保存明文密码", text: optionalStringBinding(\.passwordHint))
                }
                GridRow {
                    Text("域名")
                    Picker("域名", selection: binding(\.domain)) {
                        ForEach(store.state.settings.domains, id: \.self) { domain in
                            Text(domain).tag(domain)
                        }
                    }
                }
                GridRow {
                    Text("角色")
                    TextField("平民 / 骑士 / 其他", text: binding(\.role))
                }
                GridRow {
                    Text("Typeless")
                    TextField("登录页地址", text: binding(\.typelessURL))
                }
                GridRow {
                    Text("邮箱入口")
                    TextField("邮箱或收件箱地址", text: binding(\.inboxURL))
                }
                GridRow {
                    Text("备注")
                    TextField("手动记录用途、到期时间或注意事项", text: binding(\.notes), axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
            }
            .font(.callout)
        }
        .panelStyle()
    }

    private var registrationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("注册助手 / 兜底", systemImage: "person.badge.plus")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("邮箱")
                        .foregroundStyle(.secondary)
                    Text(account.email.isEmpty ? "未填写" : account.email)
                        .lineLimit(1)
                }
                GridRow {
                    Text("用户名")
                        .foregroundStyle(.secondary)
                    Text((account.typelessUsername ?? account.name).isEmpty ? "未填写" : (account.typelessUsername ?? account.name))
                        .lineLimit(1)
                }
                GridRow {
                    Text("强密码")
                        .foregroundStyle(.secondary)
                    SecureField("先生成，再复制", text: $generatedPassword)
                }
            }
            .font(.callout)

            HStack(spacing: 8) {
                Button {
                    let profile = AccountProfileGenerator.make(domain: account.domain.ifEmpty(store.state.settings.domains.first ?? "example.com"))
                    account.name = profile.displayName
                    account.typelessUsername = profile.username
                    account.email = profile.email
                    account.domain = profile.domain
                    account.status = .available
                    account.usedCharacters = 0
                    generatedPassword = profile.password
                    copy(profile.password, message: "已生成候选资料，并复制强密码")
                    onSave()
                } label: {
                    Label("生成候选资料", systemImage: "sparkles")
                }

                Button {
                    generatedPassword = PasswordGenerator.make()
                    copy(generatedPassword, message: "已生成并复制强密码")
                } label: {
                    Label("生成密码", systemImage: "key.horizontal")
                }

                Button {
                    copy(account.email, message: "已复制邮箱")
                } label: {
                    Label("复制邮箱", systemImage: "at")
                }
                .disabled(account.email.isEmpty)

                Button {
                    let value = (account.typelessUsername ?? account.name).trimmingCharacters(in: .whitespacesAndNewlines)
                    copy(value, message: "已复制用户名")
                } label: {
                    Label("复制用户名", systemImage: "person.text.rectangle")
                }
                .disabled((account.typelessUsername ?? account.name).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    open(account.typelessURL)
                } label: {
                    Label("打开注册页", systemImage: "safari")
                }

                Button {
                    store.copyRegistrationPreparationPlan(for: account.id)
                } label: {
                    Label("复制准备包", systemImage: "doc.text")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    open(account.inboxURL)
                } label: {
                    Label("打开邮箱", systemImage: "envelope")
                }

                Button {
                    account.usedCharacters = 0
                    account.status = .available
                    account.reviewState = .approved
                    account.reviewedAt = Date()
                    if account.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        account.notes = "已由兜底完成注册核验"
                    }
                    onSave()
                    store.statusMessage = "已记录兜底核验完成"
                } label: {
                    Label("记录完成", systemImage: "checkmark.circle")
                }

                Button {
                    account.reviewState = .rejected
                    account.status = .paused
                    onSave()
                    store.statusMessage = "已退回当前候选账号"
                } label: {
                    Label("退回", systemImage: "xmark.circle")
                }
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("切换操作", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            HStack(spacing: 10) {
                Button {
                    open(account.typelessURL)
                } label: {
                    Label("打开 Typeless", systemImage: "safari")
                }

                Button {
                    open(account.inboxURL)
                } label: {
                    Label("打开邮箱", systemImage: "envelope.open")
                }

                Button {
                    copy(account.email, message: "已复制邮箱")
                } label: {
                    Label("复制邮箱", systemImage: "doc.on.doc")
                }
                .disabled(account.email.isEmpty)

                Button {
                    store.copySwitchSummary(for: account.id)
                } label: {
                    Label("复制摘要", systemImage: "list.clipboard")
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Account, Value>) -> Binding<Value> {
        Binding(
            get: { account[keyPath: keyPath] },
            set: { newValue in
                account[keyPath: keyPath] = newValue
                onSave()
            }
        )
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<Account, String?>) -> Binding<String> {
        Binding(
            get: { account[keyPath: keyPath] ?? "" },
            set: { newValue in
                account[keyPath: keyPath] = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue
                onSave()
            }
        )
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            store.statusMessage = "无法打开地址"
            return
        }
        store.statusMessage = "已打开浏览器"
    }

    private func copy(_ value: String, message: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        store.statusMessage = message
    }
}


private struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.28), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}

private extension View {
    func panelStyle() -> some View {
        modifier(PanelStyle())
    }
}
