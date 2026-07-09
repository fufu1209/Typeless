import SwiftUI
import AppKit
import ApplicationServices
import Security
import Darwin
import TypelessSwitchboardCore

private let defaultDomains = [
    "8888891.xyz",
    "xiefucai1209.com",
    "fucai.edu.kg",
    "fucaixie.xyz",
    "cnmlgb.de",
    "zhooo.amyjaneofficial.ccwu.ccorg",
    "coolkid.icu",
    "zhooo.ggff.net",
    "coolkidsa.ggff.net",
    "20030416.xyz",
    "amyjaneofficial.ccwu.cc"
]

private let typelessOfficialURL = "https://www.typeless.com/"
private let typelessDefaultLoginURL = "https://www.typeless.com/login"
private let oldTypelessLoginURL = "https://app.typeless.com"
private let typelessCredentialTarget = "now.typeless.desktop.deviceIdentifier"
private let typelessCredentialAccount = "now.typeless.desktop.security.auth_key"
private let typelessLegacyCredentialTarget = "Typeless.deviceIdentifier"
private let typelessAutomationPasswordEnvironmentKey = "TYPELESS_AUTOMATION_PASSWORD"
private let typelessAppQuitGraceSeconds: TimeInterval = 2.5
private let chromeSessionJavaScriptDelaySeconds = 1

enum AccountStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case available
    case nearlySpent
    case exhausted
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .available: "可用"
        case .nearlySpent: "快用完"
        case .exhausted: "本月已用完"
        case .paused: "暂停"
        }
    }

    var color: Color {
        switch self {
        case .available: .green
        case .nearlySpent: .orange
        case .exhausted: .red
        case .paused: .secondary
        }
    }
}

enum ReviewState: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case approved
    case rejected

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: "待兜底确认"
        case .approved: "已确认"
        case .rejected: "已退回"
        }
    }

    var color: Color {
        switch self {
        case .pending: .orange
        case .approved: .green
        case .rejected: .red
        }
    }
}

enum AccountListFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case pending
    case exhausted
    case paused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .available: "可用"
        case .pending: "待确认"
        case .exhausted: "用完"
        case .paused: "暂停"
        }
    }
}

struct Account: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var moeMailEmailID: String?
    var typelessUsername: String?
    var passwordHint: String?
    var reviewState: ReviewState?
    var reviewedAt: Date?
    var name: String
    var email: String
    var domain: String
    var role: String
    var monthlyLimit: Int
    var usedCharacters: Int
    var status: AccountStatus
    var typelessURL: String
    var inboxURL: String
    var notes: String
    var createdAt: Date
    var lastResetAt: Date

    var remainingCharacters: Int {
        max(monthlyLimit - usedCharacters, 0)
    }

    var usageRatio: Double {
        guard monthlyLimit > 0 else { return 0 }
        return min(Double(usedCharacters) / Double(monthlyLimit), 1)
    }

    var isUsable: Bool {
        (status == .available || status == .nearlySpent) && (reviewState ?? .approved) == .approved
    }

    var effectiveReviewState: ReviewState {
        reviewState ?? .approved
    }

    static func blank(settings: AppSettings) -> Account {
        Account(
            id: UUID(),
            moeMailEmailID: nil,
            typelessUsername: nil,
            passwordHint: nil,
            reviewState: .approved,
            reviewedAt: Date(),
            name: "新账号",
            email: "",
            domain: settings.domains.first ?? "",
            role: "平民",
            monthlyLimit: 8000,
            usedCharacters: 0,
            status: .available,
            typelessURL: settings.typelessLoginURL,
            inboxURL: settings.moeMailBaseURL,
            notes: "",
            createdAt: Date(),
            lastResetAt: Date()
        )
    }
}

struct MoeMailEmail: Identifiable, Equatable {
    var id: String
    var address: String
    var name: String
    var domain: String
    var expiresAt: Date?
    var rawSummary: String

    var displayName: String {
        if !name.isEmpty { return name }
        return address.isEmpty ? id : address
    }
}

struct MoeMailMessage: Identifiable, Equatable {
    var id: String
    var subject: String
    var sender: String
    var receivedAt: String
    var preview: String
}

enum DiagnosticLevel: String {
    case ok
    case warning
    case error

    var title: String {
        switch self {
        case .ok: "正常"
        case .warning: "注意"
        case .error: "需要处理"
        }
    }

    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

struct DiagnosticItem: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var detail: String
    var level: DiagnosticLevel
}

struct AppSettings: Codable, Equatable, Sendable {
    var typelessLoginURL: String
    var moeMailBaseURL: String
    var domains: [String]
    var checklist: [SwitchTask]

    static let defaults = AppSettings(
        typelessLoginURL: typelessDefaultLoginURL,
        moeMailBaseURL: "https://mail.8888891.xyz",
        domains: defaultDomains,
        checklist: [
            SwitchTask(title: "确认当前账号本月额度已经用完", isRequired: true),
            SwitchTask(title: "在 Typeless 内正常退出当前账号", isRequired: true),
            SwitchTask(title: "选择下一个仍有额度的账号", isRequired: true),
            SwitchTask(title: "自动轮询对应邮箱验证码，必要时手动兜底", isRequired: true),
            SwitchTask(title: "登录完成后更新本工具里的已用字数", isRequired: false)
        ]
    )
}

struct SwitchTask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isRequired: Bool
    var isDone: Bool

    init(id: UUID = UUID(), title: String, isRequired: Bool, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isRequired = isRequired
        self.isDone = isDone
    }
}

struct PersistedState: Codable, Equatable, Sendable {
    var accounts: [Account]
    var settings: AppSettings
    var tokenSummaries: [TokenSummary]?
    var loginSnapshots: [LoginSnapshotManifest]?
    var registrationPlans: [RegistrationPreparationPlan]?
    var deviceReport: DeviceInfoReport?
    var lastAutomationResult: RegistrationAutomationResult?

    static let empty = PersistedState(
        accounts: [],
        settings: .defaults,
        tokenSummaries: [],
        loginSnapshots: [],
        registrationPlans: [],
        deviceReport: nil,
        lastAutomationResult: nil
    )
}

@MainActor
final class SwitchboardStore: ObservableObject {
    @Published var state: PersistedState
    @Published var statusMessage = "本地数据已准备好"
    @Published var moeMailEmails: [MoeMailEmail] = []
    @Published var moeMailMessages: [MoeMailMessage] = []
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var isRunningAutomaticReplacement = false

    private let fileURL: URL

    var dataFileURL: URL {
        fileURL
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        self.fileURL = folder.appendingPathComponent("store.json")

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.appDecoder.decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = .empty
        }
        migrateDefaultsIfNeeded()
    }

    private func migrateDefaultsIfNeeded() {
        if state.settings.typelessLoginURL == oldTypelessLoginURL ||
            state.settings.typelessLoginURL == typelessOfficialURL {
            state.settings.typelessLoginURL = typelessDefaultLoginURL
        }
        for index in state.settings.checklist.indices {
            if state.settings.checklist[index].title == "打开对应邮箱，手动处理必要验证码" {
                state.settings.checklist[index].title = "自动轮询对应邮箱验证码，必要时手动兜底"
            }
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.appEncoder.encode(state)
            try data.write(to: fileURL, options: [.atomic])
            statusMessage = "已保存到本机"
        } catch {
            statusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func addAccount() -> UUID {
        let account = Account.blank(settings: state.settings)
        state.accounts.append(account)
        save()
        return account.id
    }

    func importMoeMailEmail(_ email: MoeMailEmail) -> UUID {
        if let index = state.accounts.firstIndex(where: { $0.email == email.address && !email.address.isEmpty }) {
            state.accounts[index].moeMailEmailID = email.id
            state.accounts[index].domain = email.domain
            state.accounts[index].inboxURL = state.settings.moeMailBaseURL
            save()
            return state.accounts[index].id
        }

        var account = Account.blank(settings: state.settings)
        account.moeMailEmailID = email.id
        account.name = email.displayName
        account.email = email.address
        account.domain = email.domain
        account.inboxURL = state.settings.moeMailBaseURL
        account.notes = "从 MoeMail 导入"
        account.reviewState = .approved
        account.reviewedAt = Date()
        state.accounts.append(account)
        save()
        return account.id
    }

    func deleteAccount(id: UUID) {
        state.accounts.removeAll { $0.id == id }
        save()
    }

    func accountIndex(id: UUID?) -> Int? {
        guard let id else { return nil }
        return state.accounts.firstIndex { $0.id == id }
    }

    func nextAvailableAccountID() -> UUID? {
        nextAvailableAccountID(excluding: nil)
    }

    func nextAvailableAccountID(excluding excludedID: UUID?) -> UUID? {
        state.accounts
            .filter { $0.id != excludedID }
            .filter { $0.isUsable && $0.remainingCharacters > 0 }
            .sorted {
                if $0.remainingCharacters == $1.remainingCharacters {
                    return $0.createdAt < $1.createdAt
                }
                return $0.remainingCharacters > $1.remainingCharacters
            }
            .first?
            .id
    }

    func lastCompletedAutomationAccountID() -> UUID? {
        guard state.lastAutomationResult?.status == .completed else { return nil }
        return state.lastAutomationResult?.accountID
    }

    func pendingReviewAccountIDs() -> [UUID] {
        state.accounts
            .filter { $0.effectiveReviewState == .pending }
            .map(\.id)
    }

    func approveAccount(id: UUID) {
        guard let index = accountIndex(id: id) else { return }
        state.accounts[index].reviewState = .approved
        state.accounts[index].reviewedAt = Date()
        state.accounts[index].status = .available
        if state.accounts[index].notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            state.accounts[index].notes == "候选账号，等待兜底注册核验" {
            state.accounts[index].notes = "已由兜底确认，可用于正常切换"
        }
        save()
        statusMessage = "已确认账号：\(state.accounts[index].email)"
    }

    func rejectAccount(id: UUID) {
        guard let index = accountIndex(id: id) else { return }
        state.accounts[index].reviewState = .rejected
        state.accounts[index].status = .paused
        save()
        statusMessage = "已退回账号：\(state.accounts[index].email)"
    }

    func prepareSwitch(from currentID: UUID?) -> UUID? {
        guard let nextID = nextAvailableAccountID(excluding: currentID),
              let nextIndex = accountIndex(id: nextID) else {
            statusMessage = "没有其它可用账号；当前账号状态未改变。请先导入已有账号或处理兜底确认账号。"
            return nil
        }

        if let currentIndex = accountIndex(id: currentID) {
            state.accounts[currentIndex].status = .exhausted
            state.accounts[currentIndex].usedCharacters = state.accounts[currentIndex].monthlyLimit
        }

        let account = state.accounts[nextIndex]
        copyToClipboard(account.email)
        openInstalledTypelessApp()
        openURL(account.typelessURL)
        openURL(account.inboxURL)
        for index in state.settings.checklist.indices {
            state.settings.checklist[index].isDone = false
        }
        save()
        statusMessage = "已准备切换：\(account.email.isEmpty ? account.name : account.email)"
        return nextID
    }

    func generateCandidateAccounts(count: Int, domain: String) {
        let resolvedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty(state.settings.domains.first ?? "example.com")
        for _ in 0..<max(count, 1) {
            let profile = AccountProfileGenerator.make(domain: resolvedDomain)
            var account = Account.blank(settings: state.settings)
            account.name = profile.displayName
            account.typelessUsername = profile.username
            account.email = profile.email
            account.domain = profile.domain
            account.passwordHint = "强密码已生成，请放入密码管理器"
            account.reviewState = .pending
            account.reviewedAt = nil
            account.status = .paused
            account.notes = "候选账号，等待兜底注册核验"
            state.accounts.append(account)
        }
        save()
        statusMessage = "已生成 \(max(count, 1)) 个候选账号"
    }

    func exportAccountsToClipboard() {
        do {
            let data = try JSONEncoder.appEncoder.encode(state)
            if let text = String(data: data, encoding: .utf8) {
                copyToClipboard(text)
                statusMessage = "已复制账号备份 JSON"
            }
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func importAccountsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            statusMessage = "剪贴板没有可导入的 JSON"
            return
        }

        do {
            let imported = try JSONDecoder.appDecoder.decode(PersistedState.self, from: data)
            state = imported
            save()
            statusMessage = "已从剪贴板导入账号备份"
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func importToolkitAccountsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            statusMessage = "剪贴板没有 typeless-toolkit accounts.json"
            return
        }

        do {
            let root = try JSONSerialization.jsonObject(with: data)
            let rawAccounts: [[String: Any]]
            if let array = root as? [[String: Any]] {
                rawAccounts = array
            } else if let dict = root as? [String: Any],
                      let array = (dict["accounts"] ?? dict["data"]) as? [[String: Any]] {
                rawAccounts = array
            } else {
                statusMessage = "无法识别 toolkit 账号 JSON"
                return
            }

            if state.tokenSummaries == nil { state.tokenSummaries = [] }
            var importedCount = 0
            var tokenCount = 0

            for raw in rawAccounts {
                let imported = ToolkitAccountImporter.importableAccount(from: raw, existingDomains: state.settings.domains)
                let item = imported.account

                var account = Account.blank(settings: state.settings)
                account.name = item.name
                account.email = item.email
                account.domain = item.domain.ifEmpty(state.settings.domains.first ?? "")
                account.role = item.role
                account.typelessUsername = item.typelessUsername
                account.status = .paused
                account.reviewState = .pending
                account.reviewedAt = nil
                account.notes = item.notes

                if let index = state.accounts.firstIndex(where: { !$0.email.isEmpty && $0.email == item.email }) {
                    account.id = state.accounts[index].id
                    account.createdAt = state.accounts[index].createdAt
                    state.accounts[index] = account
                } else {
                    state.accounts.append(account)
                }

                if let summary = imported.tokenSummary {
                    state.tokenSummaries?.removeAll { $0.accountEmail == summary.accountEmail }
                    state.tokenSummaries?.append(summary)
                    tokenCount += 1
                }
                importedCount += 1
            }

            save()
            statusMessage = "已导入 \(importedCount) 个 toolkit 账号；记录 \(tokenCount) 条 token 指纹"
        } catch {
            statusMessage = "toolkit 账号导入失败：\(error.localizedDescription)"
        }
    }

    func exportAccountsCSVToClipboard() {
        let headers = [
            "name", "email", "domain", "role", "monthly_limit", "used_characters",
            "status", "review_state", "moemail_id", "typeless_username", "notes"
        ]
        let rows = state.accounts.map { account in
            [
                account.name,
                account.email,
                account.domain,
                account.role,
                String(account.monthlyLimit),
                String(account.usedCharacters),
                account.status.rawValue,
                account.effectiveReviewState.rawValue,
                account.moeMailEmailID ?? "",
                account.typelessUsername ?? "",
                account.notes
            ]
        }
        let csv = ([headers] + rows)
            .map { $0.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n")
        copyToClipboard(csv)
        statusMessage = "已复制账号表格 CSV"
    }

    func copySwitchSummary(for id: UUID?) {
        guard let index = accountIndex(id: id) else {
            statusMessage = "没有选中账号"
            return
        }
        let account = state.accounts[index]
        let lines = [
            "账号：\(account.name)",
            "邮箱：\(account.email)",
            "用户名：\(account.typelessUsername ?? "")",
            "域名：\(account.domain)",
            "额度：剩余 \(account.remainingCharacters) / \(account.monthlyLimit)",
            "状态：\(account.status.title)，\(account.effectiveReviewState.title)",
            "Typeless：\(account.typelessURL)",
            "邮箱入口：\(account.inboxURL)",
            "备注：\(account.notes)"
        ]
        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制当前账号摘要"
    }

    func copyAccountPoolAuditToClipboard() {
        let duplicates = Dictionary(grouping: state.accounts.filter { !$0.email.isEmpty }, by: { $0.email.lowercased() })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        let missingEmail = state.accounts.filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }
        let exhausted = state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }
        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }
        let lowQuota = available
            .filter { $0.monthlyLimit > 0 && Double($0.remainingCharacters) / Double($0.monthlyLimit) <= 0.15 }
            .sorted { $0.remainingCharacters < $1.remainingCharacters }

        var lines = [
            "Typeless Switchboard 账号池体检",
            "总账号：\(state.accounts.count)",
            "可用账号：\(available.count)",
            "待兜底确认：\(pending.count)",
            "本月已用完：\(exhausted.count)",
            "重复邮箱：\(duplicates.count)",
            "未填写邮箱：\(missingEmail.count)",
            ""
        ]

        if !duplicates.isEmpty {
            lines.append("重复邮箱")
            lines += duplicates.map { "- \($0)" }
            lines.append("")
        }

        if !missingEmail.isEmpty {
            lines.append("未填写邮箱")
            lines += missingEmail.map { "- \($0.name)" }
            lines.append("")
        }

        if !pending.isEmpty {
            lines.append("待兜底确认")
            lines += pending.map { "- \($0.email.ifEmpty($0.name))" }
            lines.append("")
        }

        if !lowQuota.isEmpty {
            lines.append("剩余额度低于 15%")
            lines += lowQuota.map { "- \($0.email.ifEmpty($0.name))：\($0.remainingCharacters) / \($0.monthlyLimit)" }
            lines.append("")
        }

        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制账号池体检报告"
    }

    func copyTypelessEnvironmentReport() {
        let appPath = typelessAppPath() ?? "未找到"
        let executablePath = typelessExecutablePath() ?? "未找到"
        let userData = typelessUserDataDir()
        let cache = typelessDeviceCacheDir()
        let lines = [
            "Typeless macOS 环境报告",
            "App Bundle：\(appPath)",
            "可执行文件：\(executablePath)",
            "登录态目录：\(userData.path) \(FileManager.default.fileExists(atPath: userData.path) ? "✅" : "⚠️ 不存在")",
            "设备缓存目录：\(cache.path) \(FileManager.default.fileExists(atPath: cache.path) ? "✅" : "⚠️ 不存在")",
            "设备凭据 Service：\(typelessCredentialTarget)",
            "设备凭据 Account：\(typelessCredentialAccount)",
            "兼容旧凭据名：\(typelessLegacyCredentialTarget)",
            "复制报告本身只读；一键换号会按 typeless-toolkit resetDevice 逻辑重置设备 ID，并隔离 Typeless 桌面登录态和工具浏览器登录态。"
        ]
        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制 Typeless 环境报告"
    }

    func copyTokenAuditReport() {
        let summaries = state.tokenSummaries ?? []
        var lines = [
            "Typeless token 指纹报告",
            "记录数量：\(summaries.count)",
            "说明：这里只保存 sha256 指纹和字段名，不保存 token 明文。",
            ""
        ]

        if summaries.isEmpty {
            lines.append("还没有导入带 token 字段的 toolkit 账号。")
        } else {
            lines += summaries
                .sorted { $0.importedAt > $1.importedAt }
                .map { summary in
                    [
                        "- 账号：\(summary.accountEmail.ifEmpty("未填写邮箱"))",
                        "  access：\(summary.accessTokenFingerprint ?? "未发现")",
                        "  refresh：\(summary.refreshTokenFingerprint ?? "未发现")",
                        "  字段：\(summary.discoveredKeys.joined(separator: ", "))",
                        "  时间：\(summary.importedAt)"
                    ].joined(separator: "\n")
                }
        }

        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制 token 指纹报告"
    }

    func captureLoginSnapshotManifest() {
        let source = typelessUserDataDir()
        guard FileManager.default.fileExists(atPath: source.path) else {
            statusMessage = "登录态目录不存在，无法生成快照清单"
            return
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var files: [SnapshotFile] = []

        while let url = enumerator?.nextObject() as? URL, files.count < 500 {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(source.path + "/")
                ? String(url.path.dropFirst(source.path.count + 1))
                : url.lastPathComponent
            files.append(SnapshotFile(
                path: relative,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? Date()
            ))
        }

        let manifest = LoginSnapshotManifest.make(
            sourcePath: source.path,
            files: files,
            includeSensitiveContents: false
        )
        if state.loginSnapshots == nil { state.loginSnapshots = [] }
        state.loginSnapshots?.insert(manifest, at: 0)
        save()
        copyToClipboard(manifest.markdown)
        statusMessage = "已生成登录态快照清单：\(files.count) 个文件"
    }

    func copyLatestLoginSnapshotManifest() {
        guard let manifest = state.loginSnapshots?.first else {
            statusMessage = "还没有登录态快照清单"
            return
        }
        copyToClipboard(manifest.markdown)
        statusMessage = "已复制最近一次登录态快照清单"
    }

    func copyDeviceInfoReport() {
        let report = DeviceInfoReport.make(
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelIdentifier: macModelIdentifier(),
            appPath: typelessAppPath() ?? "未找到",
            loginDataPath: typelessUserDataDir().path,
            cachePath: typelessDeviceCacheDir().path
        )
        state.deviceReport = report
        save()
        copyToClipboard(report.markdown)
        statusMessage = "已复制设备信息报告"
    }

    func copyRegistrationPreparationPlan(for id: UUID?) {
        guard let index = accountIndex(id: id) else {
            statusMessage = "没有选中账号"
            return
        }

        let account = state.accounts[index]
        let candidate = RegistrationCandidate(
            displayName: account.name,
            username: (account.typelessUsername ?? account.name).ifEmpty(account.email.components(separatedBy: "@").first ?? account.name),
            email: account.email,
            domain: account.domain,
            passwordHint: account.passwordHint ?? "请使用密码管理器里的强密码"
        )
        let plan = RegistrationPreparationPlan.make(candidate: candidate, typelessURL: account.typelessURL)
        if state.registrationPlans == nil { state.registrationPlans = [] }
        state.registrationPlans?.insert(plan, at: 0)
        save()
        copyToClipboard(plan.markdown)
        statusMessage = "已复制注册准备包"
    }

    func copyTroubleshootingBundle() {
        let appPath = typelessAppPath() ?? "未找到"
        let executablePath = typelessExecutablePath() ?? "未找到"
        let userData = typelessUserDataDir()
        let cache = typelessDeviceCacheDir()

        let total = state.accounts.count
        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }.count
        let exhausted = state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }.count
        let missingEmail = state.accounts.filter { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count

        var lines = [
            "Typeless Switchboard 排障包",
            "生成时间：\(Date())",
            "",
            "【Typeless】",
            "入口：\(state.settings.typelessLoginURL)",
            "App Bundle：\(appPath)",
            "可执行文件：\(executablePath)",
            "登录态目录：\(userData.path) \(FileManager.default.fileExists(atPath: userData.path) ? "✅" : "⚠️ 不存在")",
            "设备缓存目录：\(cache.path) \(FileManager.default.fileExists(atPath: cache.path) ? "✅" : "⚠️ 不存在")",
            "",
            "【MoeMail】",
            "地址：\(state.settings.moeMailBaseURL)",
            "域名数量：\(state.settings.domains.count)",
            "邮箱列表缓存：\(moeMailEmails.count)",
            "邮件列表缓存：\(moeMailMessages.count)",
            "",
            "【账号池】",
            "总账号：\(total)",
            "可切换账号：\(available)",
            "待兜底确认账号：\(pending)",
            "本月已用完：\(exhausted)",
            "未填写邮箱：\(missingEmail)",
            "",
            "【最近自检】"
        ]

        if diagnostics.isEmpty {
            lines.append("还没有运行一键自检")
        } else {
            lines += diagnostics.map { "- [\($0.level.title)] \($0.title)：\($0.detail)" }
        }

        lines += [
            "",
            "说明：此排障包不包含 MoeMail API Key、不包含密码、不包含验证码。",
            "当前工具支持浏览器自动注册、验证码轮询和结果桥接；一键换号会按 typeless-toolkit resetDevice 逻辑重置本机设备身份，并隔离 Typeless 桌面登录态和工具浏览器登录态。"
        ]

        copyToClipboard(lines.joined(separator: "\n"))
        statusMessage = "已复制完整排障包"
    }

    private func macModelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return "未知"
        }
        var model = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
            return "未知"
        }
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func openTypelessOfficialWebsite() {
        openURL(typelessOfficialURL)
        statusMessage = "已打开 Typeless 官网"
    }

    func openInstalledTypelessApp() {
        if let path = typelessAppPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            statusMessage = "已打开本机 Typeless App"
            return
        }

        openURL(typelessOfficialURL)
        statusMessage = "未找到本机 Typeless App，已打开官网"
    }

    private func typelessAppPath() -> String? {
        let candidates = [
            "/Applications/Typeless.app",
            "\(NSHomeDirectory())/Applications/Typeless.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func typelessExecutablePath() -> String? {
        let candidates = [
            "/Applications/Typeless.app/Contents/MacOS/Typeless",
            "\(NSHomeDirectory())/Applications/Typeless.app/Contents/MacOS/Typeless"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func firstExistingAppSupportPath(_ names: [String]) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in names {
            let url = appSupport.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return appSupport.appendingPathComponent(names.first ?? "Typeless")
    }

    private func typelessUserDataDir() -> URL {
        firstExistingAppSupportPath(["Typeless.exe", "Typeless"])
    }

    private func typelessDeviceCacheDir() -> URL {
        let candidates = typelessDeviceCacheDirectories()
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    private func typelessDeviceCacheDirectories() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates = [
            appSupport.appendingPathComponent("now.typeless.desktop", isDirectory: true),
            appSupport.appendingPathComponent("Typeless/Cache", isDirectory: true),
            appSupport.appendingPathComponent("Typeless.exe/Cache", isDirectory: true),
            appSupport.appendingPathComponent("Typeless", isDirectory: true),
            appSupport.appendingPathComponent("Typeless.exe", isDirectory: true)
        ]
        return candidates.reduce(into: [URL]()) { result, url in
            if !result.contains(where: { $0.path == url.path }) {
                result.append(url)
            }
        }
    }

    func checkTypelessEntry() async {
        guard let url = URL(string: state.settings.typelessLoginURL) else {
            statusMessage = "Typeless 入口地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<400).contains(code) {
                statusMessage = "Typeless 入口可访问：HTTP \(code)"
            } else {
                statusMessage = "Typeless 入口返回 HTTP \(code)，建议打开官网或本机 App"
            }
        } catch {
            statusMessage = "Typeless 入口检查失败：\(error.localizedDescription)"
        }
    }

    func runSetupDiagnostics(apiKey: String) async {
        var results: [DiagnosticItem] = []

        let appExists = typelessAppPath() != nil
        results.append(DiagnosticItem(
            title: "Typeless App",
            detail: appExists ? "已找到本机 Typeless App" : "未找到本机 App，会改用官网入口",
            level: appExists ? .ok : .warning
        ))
        appendMacPermissionDiagnostics(to: &results)

        if let url = URL(string: state.settings.typelessLoginURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                results.append(DiagnosticItem(
                    title: "Typeless 入口",
                    detail: (200..<400).contains(code) ? "入口可访问，HTTP \(code)" : "入口返回 HTTP \(code)，建议打开官网或本机 App",
                    level: (200..<400).contains(code) ? .ok : .warning
                ))
            } catch {
                results.append(DiagnosticItem(
                    title: "Typeless 入口",
                    detail: "入口检查失败：\(error.localizedDescription)",
                    level: .error
                ))
            }
        } else {
            results.append(DiagnosticItem(title: "Typeless 入口", detail: "入口地址格式无效", level: .error))
        }

        if URL(string: state.settings.moeMailBaseURL) == nil {
            results.append(DiagnosticItem(title: "MoeMail 地址", detail: "MoeMail 地址格式无效", level: .error))
        } else if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(DiagnosticItem(title: "MoeMail API Key", detail: "未填写 API Key，无法读取邮箱和邮件", level: .warning))
        } else {
            do {
                guard let url = moeMailURL(path: "/api/config") else {
                    throw NSError(domain: "MoeMail", code: -1, userInfo: [NSLocalizedDescriptionKey: "MoeMail 地址无效"])
                }
                let data = try await moeMailRequest(url: url, apiKey: apiKey)
                let domains = extractDomains(from: data)
                results.append(DiagnosticItem(
                    title: "MoeMail 配置",
                    detail: domains.isEmpty ? "API 可连通，但没有识别到域名" : "API 可连通，识别到 \(domains.count) 个域名",
                    level: domains.isEmpty ? .warning : .ok
                ))
            } catch {
                results.append(DiagnosticItem(title: "MoeMail 配置", detail: "连接失败：\(error.localizedDescription)", level: .error))
            }
        }

        let nodeCheck = await automationCommandVersion(command: "node", versionArgument: "--version")
        results.append(DiagnosticItem(
            title: "Node.js 自动化",
            detail: nodeCheck.isEmpty ? "未检测到 node；全自动浏览器注册会降级为脚本和手动兜底" : "已检测到 node：\(nodeCheck)",
            level: nodeCheck.isEmpty ? .warning : .ok
        ))

        let npmCheck = await automationCommandVersion(command: "npm", versionArgument: "--version")
        results.append(DiagnosticItem(
            title: "npm / Playwright",
            detail: npmCheck.isEmpty ? "未检测到 npm；无法自动安装/运行 Playwright" : "已检测到 npm：\(npmCheck)，准备预热 Playwright 运行时",
            level: npmCheck.isEmpty ? .warning : .ok
        ))

        if !nodeCheck.isEmpty && !npmCheck.isEmpty {
            let runtime = await prepareAutomationRuntime()
            results.append(DiagnosticItem(
                title: "Playwright 运行时",
                detail: runtime.message,
                level: runtime.success ? .ok : .warning
            ))
        }

        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }.count
        results.append(DiagnosticItem(
            title: "可切换账号",
            detail: available > 0 ? "有 \(available) 个已确认可用账号" : "没有已确认可用账号，需要先导入账号或处理兜底确认账号",
            level: available > 0 ? .ok : .warning
        ))

        if pending > 0 {
            results.append(DiagnosticItem(title: "待兜底确认账号", detail: "\(pending) 个候选账号等待兜底确认", level: .warning))
        }

        diagnostics = results
        let errors = results.filter { $0.level == .error }.count
        let warnings = results.filter { $0.level == .warning }.count
        statusMessage = errors > 0 ? "自检完成：\(errors) 个问题需要处理" : "自检完成：\(warnings) 个注意项"
    }

    private func appendMacPermissionDiagnostics(to results: inout [DiagnosticItem]) {
        let accessibilityTrusted = AXIsProcessTrusted()
        results.append(DiagnosticItem(
            title: "电脑权限：辅助功能",
            detail: accessibilityTrusted
                ? "已允许辅助功能控制；可自动点击 Chrome 弹窗、System Events 弹窗和 Typeless 交接。"
                : "需要在系统设置 → 隐私与安全性 → 辅助功能中允许 TypelessSwitchboard，才能自动点击 Chrome 的“打开 Typeless.app”弹窗。",
            level: accessibilityTrusted ? .ok : .warning
        ))

        let chromeProbe = Self.runAppleEventsProbe(#"tell application "Google Chrome" to get version"#)
        let systemEventsProbe = Self.runAppleEventsProbe(#"tell application "System Events" to count processes"#)
        let automationOK = chromeProbe.success && systemEventsProbe.success
        results.append(DiagnosticItem(
            title: "电脑权限：自动化",
            detail: automationOK
                ? "Apple Events 已可控制 Google Chrome 和 System Events。"
                : "需要在系统设置 → 隐私与安全性 → 自动化（Privacy_Automation）允许 TypelessSwitchboard 控制 Google Chrome 和 System Events。Chrome：\(chromeProbe.message)；System Events：\(systemEventsProbe.message)",
            level: automationOK ? .ok : .warning
        ))

        if let externalProtocolItem = MacPermissionChecklist.recommendedItems.first(where: { $0.title.contains("Google Chrome 外部协议") }) {
            results.append(DiagnosticItem(
                title: "电脑权限：Chrome 外部协议",
                detail: externalProtocolItem.detail,
                level: .warning
            ))
        }

        let typelessPermissionTitles = ["麦克风", "输入监听", "屏幕录制"]
        let typelessPermissionDetails = MacPermissionChecklist.recommendedItems
            .filter { item in typelessPermissionTitles.contains { item.title.contains($0) } }
            .map(\.detail)
            .joined(separator: " ")
        results.append(DiagnosticItem(
            title: "Typeless 权限：麦克风 / 输入监听 / 屏幕录制",
            detail: typelessPermissionDetails.ifEmpty("给 Typeless.app 打开麦克风、输入监听和屏幕录制权限，切到新账号后才能直接录音、快捷键唤起和显示浮窗。"),
            level: .warning
        ))
    }

    private func preflightMacPermissionsBeforeAutomaticReplacement(log: inout [String]) -> Bool {
        log.append("开始注册前权限预检：先触发/检查辅助功能、自动化、Chrome 外部协议和 Typeless 常用权限")

        let promptOptions = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(promptOptions)
        let chromeProbe = Self.runAppleEventsProbe(#"tell application "Google Chrome" to get version"#)
        let systemEventsProbe = Self.runAppleEventsProbe(#"tell application "System Events" to count processes"#)
        let automationOK = chromeProbe.success && systemEventsProbe.success

        if accessibilityTrusted {
            log.append("权限预检通过：辅助功能 Accessibility 已允许")
        } else {
            log.append("权限预检未通过：辅助功能 Accessibility 未允许；已在创建 MoeMail 邮箱前打开系统设置，避免中途卡在弹窗")
            openMacPermissionSettings("Privacy_Accessibility")
        }

        if automationOK {
            log.append("权限预检通过：自动化 Apple Events 已可控制 Google Chrome 和 System Events")
        } else {
            log.append("权限预检未通过：自动化 Apple Events 未完全允许；Chrome：\(chromeProbe.message)；System Events：\(systemEventsProbe.message)")
            openMacPermissionSettings("Privacy_Automation")
        }

        if accessibilityTrusted && automationOK {
            log.append("权限预检完成：可以继续创建邮箱、清理环境和注册新账号")
            return true
        }

        copyToClipboard(MacPermissionChecklist.markdown)
        statusMessage = "一键换号已在注册前暂停：请先给 TypelessSwitchboard 打开辅助功能/自动化权限；权限清单已复制，设置好后再点一次。"
        return false
    }

    func copyMacPermissionChecklist() {
        copyToClipboard(MacPermissionChecklist.markdown)
        statusMessage = "已复制 macOS 权限清单"
    }

    func openMacPermissionSettings(_ settingsPaneIdentifier: String) {
        let raw = "x-apple.systempreferences:com.apple.preference.security?\(settingsPaneIdentifier)"
        guard let url = URL(string: raw) else {
            statusMessage = "权限设置入口无效：\(settingsPaneIdentifier)"
            return
        }
        NSWorkspace.shared.open(url)
        statusMessage = "已打开系统设置：\(settingsPaneIdentifier)"
    }

    func openDataFolder() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
            statusMessage = "已打开本地数据文件夹"
        } catch {
            statusMessage = "打开数据文件夹失败：\(error.localizedDescription)"
        }
    }

    func copyDataPath() {
        copyToClipboard(fileURL.path)
        statusMessage = "已复制本地数据路径"
    }

    func importAccountsCSVFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "剪贴板没有可导入的 CSV"
            return
        }

        let rows = parseCSV(text)
        guard let header = rows.first else {
            statusMessage = "CSV 内容为空"
            return
        }

        let keys = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element.lowercased(), $0.offset) })
        var importedCount = 0

        for row in rows.dropFirst() {
            let email = csvValue(row, keys: keys, name: "email")
            guard !email.isEmpty else { continue }

            let domain = csvValue(row, keys: keys, name: "domain")
                .ifEmpty(email.components(separatedBy: "@").last ?? state.settings.domains.first ?? "")
            let status = AccountStatus(rawValue: csvValue(row, keys: keys, name: "status")) ?? .paused
            let reviewState = ReviewState(rawValue: csvValue(row, keys: keys, name: "review_state")) ?? .pending

            var account = Account.blank(settings: state.settings)
            account.name = csvValue(row, keys: keys, name: "name").ifEmpty(email.components(separatedBy: "@").first ?? "导入账号")
            account.email = email
            account.domain = domain
            account.role = csvValue(row, keys: keys, name: "role").ifEmpty("平民")
            account.monthlyLimit = Int(csvValue(row, keys: keys, name: "monthly_limit")) ?? 8000
            account.usedCharacters = Int(csvValue(row, keys: keys, name: "used_characters")) ?? 0
            account.status = status
            account.reviewState = reviewState
            account.reviewedAt = reviewState == .approved ? Date() : nil
            account.moeMailEmailID = csvValue(row, keys: keys, name: "moemail_id").nilIfEmpty
            account.typelessUsername = csvValue(row, keys: keys, name: "typeless_username").nilIfEmpty
            account.notes = csvValue(row, keys: keys, name: "notes")

            if let index = state.accounts.firstIndex(where: { $0.email == email }) {
                account.id = state.accounts[index].id
                account.createdAt = state.accounts[index].createdAt
                state.accounts[index] = account
            } else {
                state.accounts.append(account)
            }
            importedCount += 1
        }

        save()
        statusMessage = "已导入 \(importedCount) 个 CSV 账号"
    }

    func resetMonthlyQuotaForApprovedAccounts() {
        var count = 0
        for index in state.accounts.indices where state.accounts[index].effectiveReviewState == .approved {
            state.accounts[index].usedCharacters = 0
            state.accounts[index].status = .available
            state.accounts[index].lastResetAt = Date()
            count += 1
        }
        save()
        statusMessage = "已重置 \(count) 个已确认账号的本月额度"
    }

    func resetChecklist() {
        for index in state.settings.checklist.indices {
            state.settings.checklist[index].isDone = false
        }
        save()
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToClipboard(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func csvValue(_ row: [String], keys: [String: Int], name: String) -> String {
        guard let index = keys[name], row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolkitString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return ""
    }

    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n" && !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    func refreshMoeMailConfig(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return
        }
        guard let base = URL(string: state.settings.moeMailBaseURL),
              let url = URL(string: "/api/config", relativeTo: base) else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                statusMessage = "MoeMail 配置读取失败：HTTP \(status)"
                return
            }

            let discovered = extractDomains(from: data)
            if discovered.isEmpty {
                statusMessage = "MoeMail 已连通，但没有识别到新域名"
            } else {
                var merged = state.settings.domains
                for domain in discovered where !merged.contains(domain) {
                    merged.append(domain)
                }
                state.settings.domains = merged
                save()
                statusMessage = "已同步 \(discovered.count) 个域名"
            }
        } catch {
            statusMessage = "MoeMail 连接失败：\(error.localizedDescription)"
        }
    }

    func loadMoeMailEmails(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return
        }
        guard let url = moeMailURL(path: "/api/emails") else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        do {
            let data = try await moeMailRequest(url: url, apiKey: apiKey)
            let emails = parseMoeMailEmails(from: data)
            moeMailEmails = emails
            statusMessage = emails.isEmpty ? "没有读取到邮箱" : "已读取 \(emails.count) 个邮箱"
        } catch {
            statusMessage = "邮箱列表读取失败：\(error.localizedDescription)"
        }
    }

    func generateMoeMailEmail(apiKey: String, name: String, domain: String, expiryTime: Int) async -> MoeMailEmail? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return nil
        }
        guard let url = moeMailURL(path: "/api/emails/generate") else {
            statusMessage = "MoeMail 地址无效"
            return nil
        }

        let payload: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "typeless" : name,
            "expiryTime": expiryTime,
            "domain": domain
        ]

        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await moeMailRequest(url: url, apiKey: apiKey, method: "POST", body: body)
            let emails = parseMoeMailEmails(from: data)
            if let email = emails.first {
                if !moeMailEmails.contains(where: { $0.id == email.id }) {
                    moeMailEmails.insert(email, at: 0)
                }
                statusMessage = "已生成邮箱：\(email.address)"
                return email
            }

            await loadMoeMailEmails(apiKey: apiKey)
            statusMessage = "已请求生成邮箱，请在列表中确认"
            return nil
        } catch {
            statusMessage = "生成邮箱失败：\(error.localizedDescription)"
            return nil
        }
    }

    func createMoeMailRegistrationCandidate(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        copyPasswordToClipboard: Bool = true
    ) async -> UUID? {
        let resolvedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty(state.settings.domains.first ?? "example.com")
        let profile = AccountProfileGenerator.make(domain: resolvedDomain)
        let localPart = profile.email.components(separatedBy: "@").first ?? profile.username

        guard let email = await generateMoeMailEmail(
            apiKey: apiKey,
            name: localPart,
            domain: resolvedDomain,
            expiryTime: expiryTime
        ) else {
            return nil
        }

        var account = Account.blank(settings: state.settings)
        account.moeMailEmailID = email.id
        account.name = profile.displayName
        account.typelessUsername = profile.username
        account.email = email.address.ifEmpty(profile.email)
        account.domain = email.domain.ifEmpty(resolvedDomain)
        account.passwordHint = "强密码已保存到 macOS Keychain"
        account.reviewState = .pending
        account.reviewedAt = nil
        account.status = .paused
        account.usedCharacters = 0
        account.inboxURL = state.settings.moeMailBaseURL
        account.notes = "MoeMail 已生成；等待兜底完成 Typeless 注册与邮箱验证码核验"

        if let index = state.accounts.firstIndex(where: { !$0.email.isEmpty && $0.email == account.email }) {
            account.id = state.accounts[index].id
            account.createdAt = state.accounts[index].createdAt
            state.accounts[index] = account
        } else {
            state.accounts.insert(account, at: 0)
        }

        KeychainStore.saveAccountPassword(profile.password, accountID: account.id)

        let candidate = RegistrationCandidate(
            displayName: account.name,
            username: account.typelessUsername ?? profile.username,
            email: account.email,
            domain: account.domain,
            passwordHint: "强密码已保存到 macOS Keychain"
        )
        let plan = RegistrationPreparationPlan.make(candidate: candidate, typelessURL: account.typelessURL)
        if state.registrationPlans == nil { state.registrationPlans = [] }
        state.registrationPlans?.insert(plan, at: 0)

        if copyPasswordToClipboard {
            copyToClipboard(profile.password)
        }
        save()
        statusMessage = copyPasswordToClipboard
            ? "已创建注册候选账号，强密码已保存到 Keychain 并复制：\(account.email)"
            : "已创建注册候选账号，强密码已保存到 Keychain：\(account.email)"
        return account.id
    }

    func runOneClickAutomaticReplacement(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        from currentID: UUID?
    ) async -> UUID? {
        guard !isRunningAutomaticReplacement else {
            statusMessage = "全自动换号正在运行中"
            return nil
        }

        isRunningAutomaticReplacement = true
        defer { isRunningAutomaticReplacement = false }

        var log: [String] = ["开始全自动一键换号"]
        let previousAccount = currentID
            .flatMap { id in accountIndex(id: id).map { state.accounts[$0] } }
        var previousAccountEmailForResult = previousAccount?.email

        guard preflightMacPermissionsBeforeAutomaticReplacement(log: &log) else {
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountID: nil,
                accountEmail: "",
                username: "",
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            return currentID
        }

        statusMessage = "正在准备 Node/npm/Playwright 自动化运行环境..."
        let runtime = await prepareAutomationRuntime()
        guard runtime.success else {
            log.append(runtime.message)
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountEmail: "",
                username: "",
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            statusMessage = "自动化运行环境未准备好，未创建新账号：\(runtime.message)"
            return nil
        }
        log.append(runtime.message)
        let staleChromePromptLog = resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement()
        log.append(contentsOf: staleChromePromptLog)
        let staleChromeTabsLog = closePersonalChromeTypelessTabsBeforeReplacement()
        log.append(contentsOf: staleChromeTabsLog)
        let desktopPreparationLog = prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement()
        log.append(contentsOf: desktopPreparationLog)
        let browserSessionPreparationLog = prepareRetainedTypelessBrowserSessionsForAutomaticReplacement()
        log.append(contentsOf: browserSessionPreparationLog)
        let chromePreparationLog = preparePersonalChromeTypelessWebSessionForAutomaticReplacement()
        log.append(contentsOf: chromePreparationLog)
        statusMessage = "正在创建新的 MoeMail 邮箱和 Typeless 注册资料..."

        guard let newID = await createMoeMailRegistrationCandidate(
            apiKey: apiKey,
            domain: domain,
            expiryTime: expiryTime,
            copyPasswordToClipboard: false
        ), let index = accountIndex(id: newID) else {
            log.append("创建新候选账号失败；一键自动流程不会兜底打开邮箱页或切到旧账号")
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountID: nil,
                accountEmail: "",
                username: "",
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            statusMessage = "创建新 MoeMail 邮箱失败，未打开邮箱页，旧账号未改变"
            return currentID
        }

        var account = state.accounts[index]
        let password = KeychainStore.readAccountPassword(accountID: account.id)
        guard !password.isEmpty else {
            log.append("Keychain 中没有读取到账户密码")
            state.lastAutomationResult = RegistrationAutomationResult(
                previousAccountID: previousAccount?.id,
                previousAccountEmail: previousAccount?.email,
                accountID: account.id,
                accountEmail: account.email,
                username: account.typelessUsername ?? account.name,
                status: .failed,
                verificationCode: nil,
                scriptPath: nil,
                passwordStoredInKeychain: false,
                log: log
            )
            save()
            return nil
        }

        log.append("新邮箱已创建：\(account.email)")
        log.append("强密码已保存到 Keychain")

        let verificationCodeFileURL = makeVerificationCodeBridgeFileURL(account: account)
        let automationResultFileURL = makeAutomationResultBridgeFileURL(account: account)
        try? FileManager.default.removeItem(at: verificationCodeFileURL)
        try? FileManager.default.removeItem(at: automationResultFileURL)

        let firstScriptURL = writeRegistrationAutomationScript(
            account: account,
            password: password,
            verificationCode: nil,
            verificationCodeFileURL: verificationCodeFileURL,
            automationResultFileURL: automationResultFileURL
        )
        var automationTask: Task<(success: Bool, message: String), Never>?
        if let firstScriptURL {
            log.append("已生成注册自动化脚本：\(firstScriptURL.path)")
            log.append("网页登录态将保留在固定浏览器目录：\(makeBrowserProfileDirectoryURL(account: account).path)")
            statusMessage = "正在尝试自动打开并填写 Typeless 注册页..."
            automationTask = Task { await runPlaywrightScript(firstScriptURL, password: password) }
            log.append("Playwright 脚本已启动并等待验证码文件：\(verificationCodeFileURL.path)")
        } else {
            log.append("注册自动化脚本生成失败")
        }

        log.append("注册阶段后台运行：不自动弹出邮箱页或注册页")

        statusMessage = "正在轮询 MoeMail 验证码..."
        let verificationCode = await pollVerificationCode(
            for: account,
            apiKey: apiKey,
            attempts: RegistrationAutomationTiming.moeMailPollingAttempts,
            delaySeconds: RegistrationAutomationTiming.moeMailPollingDelaySeconds
        )
        if let verificationCode {
            log.append("已提取验证码：\(verificationCode)")
            copyToClipboard(verificationCode)
            writeVerificationCode(verificationCode, to: verificationCodeFileURL)
            log.append("已写入验证码桥接文件，浏览器脚本会继续提交")
        } else {
            log.append("暂未从 MoeMail 邮件中提取到验证码，已打开邮箱并保留账号资料")
            writeVerificationCode("NO_CODE", to: verificationCodeFileURL)
            copyToClipboard(account.email)
        }

        if let automationTask {
            let runResult = await automationTask.value
            log.append(runResult.message)
        }
        let browserResult = readAutomationResult(from: automationResultFileURL)
        if let browserResult {
            log.append("浏览器结果：\(browserResult.summary)")
            if previousAccountEmailForResult?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
               let detected = browserResult.detectedPreviousAccountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detected.isEmpty {
                previousAccountEmailForResult = detected
                log.append("自动检测到旧账号：\(detected)")
            }
            if browserResult.isLikelyRegistrationComplete {
                log.append("浏览器结果判定：注册大概率完成")
            } else {
                log.append("浏览器结果判定：仍可能停留在注册/验证/错误页面，需要兜底确认")
            }
        } else {
            log.append("未读取到浏览器结果文件，保留脚本和账号资料供兜底")
        }

        let automationComplete = RegistrationAutomationCompletionPolicy.isComplete(
            verificationCode: verificationCode,
            browserResult: browserResult
        )

        if automationComplete,
           let currentIndex = accountIndex(id: currentID),
           state.accounts[currentIndex].id != account.id {
            state.accounts[currentIndex].status = .exhausted
            state.accounts[currentIndex].usedCharacters = state.accounts[currentIndex].monthlyLimit
            state.accounts[currentIndex].notes = "已由全自动一键换号替换为：\(account.email)"
        }

        if let refreshedIndex = accountIndex(id: account.id) {
            state.accounts[refreshedIndex].passwordHint = "强密码已保存到 macOS Keychain"
            if automationComplete {
                state.accounts[refreshedIndex].reviewState = .approved
                state.accounts[refreshedIndex].reviewedAt = Date()
                state.accounts[refreshedIndex].status = .available
                state.accounts[refreshedIndex].usedCharacters = 0
                state.accounts[refreshedIndex].notes = "自动换号已提取验证码，浏览器结果判定注册完成，可用于切换"
            } else {
                state.accounts[refreshedIndex].reviewState = .pending
                state.accounts[refreshedIndex].reviewedAt = nil
                state.accounts[refreshedIndex].status = .paused
                state.accounts[refreshedIndex].notes = verificationCode == nil
                    ? "自动换号已创建账号资料；验证码暂未提取，等待兜底确认"
                    : "自动换号已提取验证码并尝试提交；浏览器结果未证明注册完成，等待兜底确认"
            }
            account = state.accounts[refreshedIndex]
        }

        let browserProfileURL = makeBrowserProfileDirectoryURL(account: account)
        if automationComplete {
            log.append(contentsOf: syncPersonalChromeTypelessWebSession(
                account: account,
                profileDirectoryPath: browserProfileURL.path
            ))
            log.append(handoffRetainedTypelessProfileToDesktopOnce(profileDirectoryPath: browserProfileURL.path, expectedEmail: account.email))
            log.append("新账号浏览器会话已保留：\(browserProfileURL.path)；未自动打开额外浏览器，需要排查时再点“打开新账号会话”")
            log.append(contentsOf: completeTypelessDesktopOnboardingIfPresent(expectedEmail: account.email, timeoutSeconds: 120))
        }

        copyToClipboard(automationComplete ? account.email : (verificationCode ?? account.email))
        for index in state.settings.checklist.indices {
            state.settings.checklist[index].isDone = false
        }

        let status: RegistrationAutomationStatus = automationComplete ? .completed : .needsAttention
        state.lastAutomationResult = RegistrationAutomationResult(
            previousAccountID: previousAccount?.id,
            previousAccountEmail: previousAccountEmailForResult,
            accountID: account.id,
            accountEmail: account.email,
            username: account.typelessUsername ?? account.name,
            status: status,
            verificationCode: verificationCode,
            scriptPath: firstScriptURL?.path,
            verificationCodeFilePath: verificationCodeFileURL.path,
            browserResultFilePath: automationResultFileURL.path,
            browserProfileDirectoryPath: browserProfileURL.path,
            passwordStoredInKeychain: true,
            log: log
        )
        save()
        statusMessage = automationComplete
            ? "全自动换号已完成，已同步 Google Chrome / Typeless 桌面端并复制新邮箱：\(account.email)"
            : "自动换号已推进到兜底确认阶段；旧账号未标记用完：\(account.email)"
        return automationComplete ? account.id : currentID
    }

    func runCommandLineAutomaticReplacementIfRequested() async -> Bool {
        let arguments = CommandLine.arguments
        guard let countIndex = arguments.firstIndex(of: "--auto-switch-count") else {
            return false
        }

        let requestedCount = arguments.indices.contains(countIndex + 1)
            ? (Int(arguments[countIndex + 1]) ?? 1)
            : 1
        let count = min(max(requestedCount, 1), 5)
        let domain = commandLineValue(for: "--auto-switch-domain", in: arguments)
            .ifEmpty(state.settings.domains.first ?? "8888891.xyz")
        let apiKey = KeychainStore.readAPIKey()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fputs("TypelessSwitchboard CLI: MoeMail API Key missing in Keychain\n", stderr)
            return true
        }

        print("TypelessSwitchboard CLI: starting \(count) automatic replacement run(s), domain=\(domain)")
        for runIndex in 1...count {
            let fromID = lastCompletedAutomationAccountID()
            let startedAt = Date()
            let resultID = await runOneClickAutomaticReplacement(
                apiKey: apiKey,
                domain: domain,
                expiryTime: 0,
                from: fromID
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            let result = state.lastAutomationResult
            print("TypelessSwitchboard CLI: run \(runIndex)/\(count) resultID=\(resultID?.uuidString ?? "nil") status=\(result?.status.rawValue ?? "none") account=\(result?.accountEmail ?? "") elapsed=\(String(format: "%.1f", elapsed))s")
            if result?.status != .completed {
                print("TypelessSwitchboard CLI: stopping because run \(runIndex) did not complete")
                break
            }
        }
        save()
        return true
    }

    private func commandLineValue(for flag: String, in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return ""
        }
        return arguments[index + 1]
    }

    func retryLastAutomation() async -> UUID? {
        guard !isRunningAutomaticReplacement else {
            statusMessage = "自动化正在运行中"
            return nil
        }
        guard let last = state.lastAutomationResult, last.canRetry else {
            statusMessage = "没有可重试的最近自动化结果"
            return nil
        }
        guard let accountID = last.accountID,
              let accountIndex = accountIndex(id: accountID) else {
            statusMessage = "最近自动化对应账号不存在"
            return nil
        }
        guard let scriptPath = last.scriptPath,
              FileManager.default.fileExists(atPath: scriptPath) else {
            statusMessage = "最近自动化脚本不存在，无法重试"
            return nil
        }

        let account = state.accounts[accountIndex]
        let password = KeychainStore.readAccountPassword(accountID: accountID)
        guard !password.isEmpty else {
            statusMessage = "Keychain 中没有这个账号的密码，无法重试"
            return nil
        }

        isRunningAutomaticReplacement = true
        defer { isRunningAutomaticReplacement = false }

        var log = last.log
        log.append("开始重试最近自动化")

        if let code = last.verificationCode,
           let codePath = last.verificationCodeFilePath,
           !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writeVerificationCode(code, to: URL(fileURLWithPath: codePath))
            log.append("已重新写入验证码桥接文件：\(codePath)")
        }

        if let resultPath = last.browserResultFilePath {
            try? FileManager.default.removeItem(atPath: resultPath)
        }

        statusMessage = "正在重试最近自动化：\(account.email)"
        let runResult = await runPlaywrightScript(URL(fileURLWithPath: scriptPath), password: password)
        log.append(runResult.message)

        let browserResult = last.browserResultFilePath
            .map { URL(fileURLWithPath: $0) }
            .flatMap(readAutomationResult)
        if let browserResult {
            log.append("重试浏览器结果：\(browserResult.summary)")
        } else {
            log.append("重试后仍未读取到浏览器结果")
        }

        let automationComplete = RegistrationAutomationCompletionPolicy.isComplete(
            verificationCode: last.verificationCode,
            browserResult: browserResult
        )
        if let refreshedIndex = self.accountIndex(id: accountID) {
            if automationComplete {
                state.accounts[refreshedIndex].reviewState = .approved
                state.accounts[refreshedIndex].reviewedAt = Date()
                state.accounts[refreshedIndex].status = .available
                state.accounts[refreshedIndex].usedCharacters = 0
                state.accounts[refreshedIndex].notes = "重试自动化后浏览器结果判定注册完成，可用于切换"
            } else {
                state.accounts[refreshedIndex].reviewState = .pending
                state.accounts[refreshedIndex].status = .paused
                state.accounts[refreshedIndex].notes = "重试自动化后仍未证明注册完成，等待兜底确认"
            }
        }

        let status: RegistrationAutomationStatus = automationComplete ? .completed : .needsAttention
        state.lastAutomationResult = RegistrationAutomationResult(
            previousAccountID: last.previousAccountID,
            previousAccountEmail: last.previousAccountEmail,
            accountID: accountID,
            accountEmail: account.email,
            username: account.typelessUsername ?? account.name,
            status: status,
            verificationCode: last.verificationCode,
            scriptPath: last.scriptPath,
            verificationCodeFilePath: last.verificationCodeFilePath,
            browserResultFilePath: last.browserResultFilePath,
            browserProfileDirectoryPath: last.browserProfileDirectoryPath,
            passwordStoredInKeychain: true,
            log: log
        )
        save()
        statusMessage = automationComplete
            ? "最近自动化重试完成：\(account.email)"
            : "最近自动化已重试，仍需要兜底确认：\(account.email)"
        return automationComplete ? accountID : nil
    }

    func loadMessages(for account: Account, apiKey: String) async {
        guard let emailID = account.moeMailEmailID, !emailID.isEmpty else {
            statusMessage = "这个账号还没有关联 MoeMail 邮箱 ID"
            return
        }
        guard let url = moeMailURL(path: "/api/emails/\(emailID)") else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        do {
            let data = try await moeMailRequest(url: url, apiKey: apiKey)
            moeMailMessages = parseMoeMailMessages(from: data)
            statusMessage = moeMailMessages.isEmpty ? "没有读取到邮件" : "已读取 \(moeMailMessages.count) 封邮件"
        } catch {
            statusMessage = "邮件列表读取失败：\(error.localizedDescription)"
        }
    }

    private func pollVerificationCode(for account: Account, apiKey: String, attempts: Int, delaySeconds: UInt64) async -> String? {
        let totalAttempts = max(attempts, 1)
        for attempt in 1...totalAttempts {
            await loadMessages(for: account, apiKey: apiKey)
            if let code = verificationCode(from: moeMailMessages) {
                return code
            }
            statusMessage = "正在等待验证码邮件（\(attempt)/\(totalAttempts)）..."
            guard attempt < totalAttempts else { continue }
            let scheduledDelay = RegistrationAutomationTiming.moeMailPollingDelaySeconds(afterAttempt: attempt) ?? delaySeconds
            try? await Task.sleep(nanoseconds: scheduledDelay * 1_000_000_000)
        }
        return nil
    }

    private func automationCommandVersion(command: String, versionArgument: String) async -> String {
        await Task.detached(priority: .utility) {
            let result = SwitchboardStore.runProcess(arguments: [command, versionArgument], environment: SwitchboardStore.automationEnvironment())
            guard result.status == 0 else { return "" }
            return result.output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }

    private func prepareAutomationRuntime() async -> (success: Bool, message: String) {
        let folder = automationDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.ensureAutomationPackageManifest(in: folder)
        } catch {
            return (false, "自动化目录准备失败：\(error.localizedDescription)")
        }

        return await Task.detached(priority: .utility) {
            let node = SwitchboardStore.runProcess(
                arguments: ["node", "--version"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard node.status == 0 else {
                return (false, "未检测到 node：\(node.output.ifEmpty("退出码 \(node.status)"))")
            }

            let npm = SwitchboardStore.runProcess(
                arguments: ["npm", "--version"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard npm.status == 0 else {
                return (false, "未检测到 npm：\(npm.output.ifEmpty("退出码 \(npm.status)"))")
            }

            let nodeVersion = node.output.components(separatedBy: .newlines).first ?? "node"
            let npmVersion = npm.output.components(separatedBy: .newlines).first ?? "npm"
            if SwitchboardStore.isAutomationRuntimeCached(in: folder) {
                return (true, "自动化运行环境已缓存，跳过 npm install / playwright install：\(nodeVersion)，npm \(npmVersion)")
            }

            let installPackage = SwitchboardStore.runProcess(
                arguments: ["npm", "install", "--silent", "--no-audit", "--no-fund", "playwright"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 90
            )
            guard installPackage.status == 0 else {
                return (false, "Playwright 包准备失败：\(installPackage.output.ifEmpty("退出码 \(installPackage.status)"))")
            }

            let installBrowser = SwitchboardStore.runProcess(
                arguments: ["npm", "exec", "--", "playwright", "install", "chromium"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 120
            )
            guard installBrowser.status == 0 else {
                return (false, "Playwright Chromium 准备失败：\(installBrowser.output.ifEmpty("退出码 \(installBrowser.status)"))")
            }

            SwitchboardStore.markAutomationRuntimeReady(in: folder)
            return (true, "自动化运行环境已准备：\(nodeVersion)，npm \(npmVersion)")
        }.value
    }

    private func verificationCode(from messages: [MoeMailMessage]) -> String? {
        for message in messages {
            let fields = [message.subject, message.sender, message.receivedAt, message.preview]
            if let code = VerificationCodeExtractor.extract(from: fields) {
                return code
            }
        }
        return nil
    }

    private func makeVerificationCodeBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-code-\(safeEmail)-\(account.id.uuidString).txt")
    }

    private func makeAutomationResultBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-result-\(safeEmail)-\(account.id.uuidString).json")
    }

    private func makeBrowserProfileDirectoryURL(account: Account) -> URL {
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return retainedTypelessBrowserProfileRootURL()
            .appendingPathComponent("\(safeEmail)-\(account.id.uuidString)", isDirectory: true)
    }

    private func retainedTypelessBrowserProfileRootURL() -> URL {
        automationDirectoryURL()
            .appendingPathComponent("BrowserProfiles", isDirectory: true)
    }

    private func automationDirectoryURL() -> URL {
        dataFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Automation", isDirectory: true)
    }

    private func writeVerificationCode(_ code: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "写入验证码桥接文件失败：\(error.localizedDescription)"
        }
    }

    private func writeRegistrationAutomationScript(
        account: Account,
        password: String,
        verificationCode: String?,
        verificationCodeFileURL: URL?,
        automationResultFileURL: URL?
    ) -> URL? {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeEmail = account.email
                .replacingOccurrences(of: "@", with: "_at_")
                .replacingOccurrences(of: ".", with: "_")
            let scriptURL = folder.appendingPathComponent("typeless-register-\(safeEmail)-\(Date().timeIntervalSince1970).js")
            let input = BrowserRegistrationAutomationInput(
                registrationURL: account.typelessURL,
                email: account.email,
                username: account.typelessUsername ?? account.name,
                password: password,
                verificationCode: verificationCode,
                verificationCodeFilePath: verificationCodeFileURL?.path,
                automationResultFilePath: automationResultFileURL?.path,
                browserProfileDirectoryPath: makeBrowserProfileDirectoryURL(account: account).path,
                clearBrowserProfileBeforeRun: true,
                passwordEnvironmentVariable: typelessAutomationPasswordEnvironmentKey,
                headless: true
            )
            try BrowserAutomationScriptBuilder
                .makeRegistrationScript(input: input)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            return scriptURL
        } catch {
            statusMessage = "写入自动化脚本失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func readAutomationResult(from url: URL) -> BrowserAutomationResultPayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserAutomationResultPayload.self, from: data)
    }

    private func prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement() -> [String] {
        var log: [String] = []
        log.append(terminateInstalledTypelessApp())

        let backupRoot = automationDirectoryURL()
            .appendingPathComponent("DesktopSessionBackups", isDirectory: true)
            .appendingPathComponent(Self.safeTimestamp(), isDirectory: true)

        log.append(contentsOf: resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: backupRoot))

        for source in typelessDesktopSessionDataDirectories() {
            guard FileManager.default.fileExists(atPath: source.path) else {
                log.append("桌面登录态目录不存在，跳过：\(source.path)")
                continue
            }

            do {
                try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                let destination = backupRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                log.append("已隔离旧桌面登录态：\(source.path) → \(destination.path)")
            } catch {
                log.append("隔离旧桌面登录态失败：\(source.path)：\(error.localizedDescription)")
            }
        }

        return log
    }

    private func resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: URL) -> [String] {
        var log: [String] = []

        log.append(contentsOf: deleteTypelessDeviceCredentialsFromKeychain())

        for cacheDirectory in typelessDeviceCacheDirectories() {
            let deviceCache = cacheDirectory.appendingPathComponent("device.cache")
            if FileManager.default.fileExists(atPath: deviceCache.path) {
                do {
                    try FileManager.default.removeItem(at: deviceCache)
                    log.append("已删除 Typeless 设备缓存 device.cache：\(deviceCache.path)")
                } catch {
                    log.append("删除 Typeless 设备缓存失败：\(deviceCache.path)：\(error.localizedDescription)")
                }
            }
        }

        for dataDirectory in typelessDesktopSessionDataDirectories() {
            let userData = dataDirectory.appendingPathComponent("user-data.json")
            if FileManager.default.fileExists(atPath: userData.path) {
                do {
                    try FileManager.default.removeItem(at: userData)
                    log.append("已删除 Typeless 加密登录凭证 user-data.json：\(userData.path)")
                } catch {
                    log.append("删除 Typeless 加密登录凭证失败：\(userData.path)：\(error.localizedDescription)")
                }
            }

            let storage = dataDirectory.appendingPathComponent("app-storage.json")
            if FileManager.default.fileExists(atPath: storage.path) {
                do {
                    try clearTypelessAppStorageForDeviceReset(storage)
                    log.append("已清理 Typeless app-storage.json 的 userData / quotaUsage：\(storage.path)")
                } catch {
                    log.append("清理 Typeless app-storage.json 失败：\(storage.path)：\(error.localizedDescription)")
                }
            }

            for subdirectory in ["Local Storage", "Network", "Cookies", "Session Storage"] {
                let url = dataDirectory.appendingPathComponent(subdirectory, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    do {
                        try FileManager.default.removeItem(at: url)
                        log.append("已清理 Typeless Electron 残留目录 \(subdirectory)：\(url.path)")
                    } catch {
                        log.append("清理 Typeless Electron 残留目录失败 \(subdirectory)：\(error.localizedDescription)")
                    }
                }
            }
        }

        if log.isEmpty {
            log.append("未发现 Typeless 设备身份残留；继续隔离桌面登录态")
        } else {
            log.append("已按 typeless-toolkit resetDevice 逻辑重置本机 Typeless 设备身份")
        }
        _ = backupRoot
        return log
    }

    private func deleteTypelessDeviceCredentialsFromKeychain() -> [String] {
        var log: [String] = []
        let candidates: [(service: String, account: String?)] = [
            (typelessCredentialTarget, typelessCredentialAccount),
            (typelessLegacyCredentialTarget, nil)
        ]

        for candidate in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service
            ]
            if let account = candidate.account {
                query[kSecAttrAccount as String] = account
            }
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                if let account = candidate.account {
                    log.append("已删除 Typeless 设备 Keychain 凭据：service=\(candidate.service), account=\(account)")
                } else {
                    log.append("已删除 Typeless 旧设备 Keychain 凭据：service=\(candidate.service)")
                }
            } else if status != errSecItemNotFound {
                if deleteTypelessDeviceCredentialWithSecurityCLI(service: candidate.service, account: candidate.account) {
                    log.append("已通过 security delete-generic-password 删除 Typeless 设备 Keychain 凭据：service=\(candidate.service)")
                } else {
                    log.append("删除 Typeless 设备 Keychain 凭据失败：service=\(candidate.service)，状态 \(status)")
                }
            }

            let labelQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrLabel as String: candidate.service
            ]
            let labelStatus = SecItemDelete(labelQuery as CFDictionary)
            if labelStatus == errSecSuccess {
                log.append("已删除 Typeless 设备 Keychain 标签凭据：label=\(candidate.service)")
            } else if labelStatus != errSecItemNotFound {
                if deleteTypelessDeviceCredentialWithSecurityCLI(label: candidate.service) {
                    log.append("已通过 security delete-generic-password 删除 Typeless 设备 Keychain 标签凭据：label=\(candidate.service)")
                } else {
                    log.append("删除 Typeless 设备 Keychain 标签凭据失败：label=\(candidate.service)，状态 \(labelStatus)")
                }
            }
        }

        if log.isEmpty {
            log.append("未发现 Typeless 设备 Keychain 凭据")
        }
        return log
    }

    private func deleteTypelessDeviceCredentialWithSecurityCLI(service: String, account: String?) -> Bool {
        var arguments = ["security", "delete-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        let result = SwitchboardStore.runProcess(
            arguments: arguments,
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }

    private func deleteTypelessDeviceCredentialWithSecurityCLI(label: String) -> Bool {
        let result = SwitchboardStore.runProcess(
            arguments: ["security", "delete-generic-password", "-l", label],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }

    private func clearTypelessAppStorageForDeviceReset(_ storageURL: URL) throws {
        guard let data = try? Data(contentsOf: storageURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        object["userData"] = [:]
        object.removeValue(forKey: "quotaUsage")
        if object.keys.contains("session") {
            object["session"] = NSNull()
        }
        if object.keys.contains("currentRoute") {
            object["currentRoute"] = NSNull()
        }

        let patchedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patchedData.write(to: storageURL, options: .atomic)
    }

    private func prepareRetainedTypelessBrowserSessionsForAutomaticReplacement() -> [String] {
        var log: [String] = []
        log.append(terminateRetainedTypelessBrowserSessions())

        let source = retainedTypelessBrowserProfileRootURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            log.append("旧网页登录态目录不存在，跳过：\(source.path)")
            return log
        }

        let backupRoot = automationDirectoryURL()
            .appendingPathComponent("BrowserSessionBackups", isDirectory: true)
            .appendingPathComponent(Self.safeTimestamp(), isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
            let destination = backupRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            log.append("已隔离旧网页登录态：\(source.path) → \(destination.path)")
        } catch {
            log.append("隔离旧网页登录态失败：\(source.path)：\(error.localizedDescription)")
        }

        return log
    }

    private func resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement() -> [String] {
        let result = approveChromeTypelessAppPrompt()
        let output = result.output.ifEmpty("退出码 \(result.status)")
        if result.status == 0,
           output.localizedCaseInsensitiveContains("approved") {
            return ["已先处理 Google Chrome 遗留的 Typeless.app 弹窗，并尝试勾选“始终允许 www.typeless.com”"]
        }
        if result.status == 0,
           output.localizedCaseInsensitiveContains("not found") {
            return ["未发现 Google Chrome 遗留的 Typeless.app 弹窗，继续清理环境"]
        }
        return ["处理 Google Chrome 遗留 Typeless.app 弹窗未完成：\(output)；继续清理环境"]
    }

    private func closePersonalChromeTypelessTabsBeforeReplacement() -> [String] {
        let script = """
        tell application "Google Chrome"
          set closedCount to 0
          if (count of windows) = 0 then return "closed 0 typeless tabs"
          repeat with chromeWindow in windows
            set tabCount to count of tabs of chromeWindow
            repeat with tabIndex from tabCount to 1 by -1
              try
                set chromeTab to tab tabIndex of chromeWindow
                if (URL of chromeTab contains "typeless.com") then
                  close chromeTab
                  set closedCount to closedCount + 1
                end if
              end try
            end repeat
          end repeat
          return "closed " & closedCount & " typeless tabs"
        end tell
        """
        let result = runInlineAppleScript(
            script,
            label: "close-personal-chrome-typeless-tabs",
            timeoutSeconds: 10
        )
        if result.status == 0 {
            return ["已关闭 Google Chrome 里的旧 Typeless 标签：\(result.output.ifEmpty("closed 0 typeless tabs"))"]
        }
        return ["关闭 Google Chrome 旧 Typeless 标签失败：\(result.output.ifEmpty("退出码 \(result.status)"))"]
    }

    private func preparePersonalChromeTypelessWebSessionForAutomaticReplacement() -> [String] {
        let clearScript = """
        (async () => {
          try { localStorage.clear(); } catch (error) {}
          try { sessionStorage.clear(); } catch (error) {}
          try {
            document.cookie.split(';').forEach(cookie => {
              const name = cookie.split('=')[0].trim();
              if (!name) return;
              const domains = ['', 'www.typeless.com', '.typeless.com'];
              const paths = ['/', '/login', '/login/app/success'];
              for (const domain of domains) {
                for (const path of paths) {
                  document.cookie = name + '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0; path=' + path + (domain ? '; domain=' + domain : '');
                }
              }
            });
          } catch (error) {}
          try {
            if (window.indexedDB && indexedDB.databases) {
              const databases = await indexedDB.databases();
              for (const database of databases) {
                if (database.name) indexedDB.deleteDatabase(database.name);
              }
            }
          } catch (error) {}
          try {
            if (window.caches) {
              const keys = await caches.keys();
              for (const key of keys) await caches.delete(key);
            }
          } catch (error) {}
          location.href = 'https://www.typeless.com/login';
          'cleared typeless chrome session';
        })();
        """

        let result = runJavaScriptInPersonalChrome(
            clearScript,
            label: "clear-personal-chrome-typeless-session",
            targetURL: typelessDefaultLoginURL,
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        return result.status == 0
            ? ["已清理 Google Chrome 里的 Typeless 网页旧账号会话"]
            : ["清理 Google Chrome 里的 Typeless 网页旧账号会话失败：\(result.output.ifEmpty("退出码 \(result.status)"))"]
    }

    private func syncPersonalChromeTypelessWebSession(account: Account, profileDirectoryPath: String) -> [String] {
        guard let tokenInfo = extractTypelessTokenInfo(fromBrowserProfile: profileDirectoryPath, expectedEmail: account.email) else {
            return ["未能从新账号浏览器 profile 提取 Typeless 登录态，跳过同步 Google Chrome"]
        }

        let syncScript = """
        try { localStorage.clear(); } catch (error) {}
        try { sessionStorage.clear(); } catch (error) {}
        localStorage.setItem('MAXAI_CLIENT__FEATURES__AUTH__TOKEN_INFO', \(Self.javaScriptStringLiteral(tokenInfo)));
        location.href = 'https://www.typeless.com/login/app/success';
        'synced typeless chrome session';
        """

        let syncResult = runJavaScriptInPersonalChrome(
            syncScript,
            label: "sync-personal-chrome-typeless-session",
            targetURL: "https://www.typeless.com/login",
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        guard syncResult.status == 0 else {
            return ["同步新账号到 Google Chrome 失败：\(syncResult.output.ifEmpty("退出码 \(syncResult.status)"))"]
        }

        let openDesktopScript = """
        const button = Array.from(document.querySelectorAll('button, [role="button"]')).find(element => {
          const text = (element.innerText || '').toLowerCase();
          return text.includes('open the desktop app') || text.includes('打开桌面应用');
        });
        if (button) {
          button.click();
          'clicked desktop handoff';
        } else {
          'desktop handoff button not found';
        }
        """
        _ = runJavaScriptInPersonalChrome(
            openDesktopScript,
            label: "open-typeless-desktop-from-personal-chrome",
            targetURL: "https://www.typeless.com/login/app/success",
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        _ = approveChromeTypelessAppPrompt()

        return ["已把 Google Chrome 的 Typeless 网页会话切到新账号：\(account.email)"]
    }

    private func handoffRetainedTypelessProfileToDesktopOnce(profileDirectoryPath: String, expectedEmail: String) -> String {
        if let tokenInfo = extractTypelessTokenInfo(fromBrowserProfile: profileDirectoryPath, expectedEmail: expectedEmail),
           let authURL = makeTypelessDesktopAuthURL(fromTokenInfo: tokenInfo) {
            forceLaunchTypelessBeforeAuthProtocol()
            let firstOpen = openTypelessAuthProtocol(authURL)
            Thread.sleep(forTimeInterval: 2.0)
            let secondOpen = openTypelessAuthProtocol(authURL)
            if firstOpen || secondOpen {
                return "已用完整 access_token / refresh_token / user_id 后台触发 Typeless 桌面端登录协议"
            }
        }

        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let scriptURL = folder.appendingPathComponent("typeless-desktop-handoff-\(Date().timeIntervalSince1970).js")
            try makeDesktopHandoffScript(profileDirectoryPath: profileDirectoryPath)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            let result = SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 45
            )
            if result.status == 0 {
                return "已后台触发新账号 Typeless 桌面端 handoff：\(result.output.ifEmpty("无输出"))"
            }
            return "后台触发 Typeless 桌面端 handoff 未完成：\(result.output.ifEmpty("退出码 \(result.status)"))"
        } catch {
            return "后台触发 Typeless 桌面端 handoff 失败：\(error.localizedDescription)"
        }
    }

    private func forceLaunchTypelessBeforeAuthProtocol() {
        if let path = typelessAppPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            Thread.sleep(forTimeInterval: 6.0)
        }
    }

    private func openTypelessAuthProtocol(_ authURL: String) -> Bool {
        let result = SwitchboardStore.runProcess(
            arguments: ["open", authURL],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 15
        )
        return result.status == 0
    }

    private func makeTypelessDesktopAuthURL(fromTokenInfo tokenInfo: String) -> String? {
        guard let data = tokenInfo.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["accessToken"] as? String,
              let refreshToken = object["refreshToken"] as? String,
              let userID = object["userId"] as? String,
              let email = object["email"] as? String else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "typeless"
        components.host = "auth"
        components.path = "/google/success"
        components.queryItems = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "user_id", value: userID),
            URLQueryItem(name: "client_user_id", value: "")
        ]
        return components.url?.absoluteString
    }

    private func makeDesktopHandoffScript(profileDirectoryPath: String) -> String {
        let profile = Self.javaScriptStringLiteral(profileDirectoryPath)
        return """
        const { chromium } = require('playwright');
        const { execFileSync } = require('child_process');

        const browserProfileDirectoryPath = \(profile);
        const targetURL = 'https://www.typeless.com/login/app/success';
        let openedProtocolURL = '';

        function openExternalTypelessProtocolURL(url) {
          if (!url || !url.startsWith('typeless://')) return false;
          if (openedProtocolURL) return true;
          openedProtocolURL = url;
          execFileSync('/usr/bin/open', [url], { stdio: 'ignore' });
          return true;
        }

        async function clickDesktopHandoff(page) {
          const selectors = [
            'button:has-text("Open the desktop app")',
            '[role="button"]:has-text("Open the desktop app")',
            'button:has-text("打开桌面应用")',
            '[role="button"]:has-text("打开桌面应用")'
          ];
          for (const selector of selectors) {
            const locator = page.locator(selector).first();
            try {
              if (await locator.isVisible({ timeout: 2500 })) {
                await locator.click({ timeout: 2500 });
                return selector;
              }
            } catch (error) {}
          }
          const directProtocolURL = await page.evaluate(() => {
            const urls = [];
            document.querySelectorAll('a[href], button, [role="button"]').forEach(element => {
              const href = element.getAttribute && element.getAttribute('href');
              if (href) urls.push(href);
              const dataset = element.dataset || {};
              Object.values(dataset).forEach(value => { if (typeof value === 'string') urls.push(value); });
              const onclick = element.getAttribute && element.getAttribute('onclick');
              if (onclick) urls.push(onclick);
            });
            const match = urls.join('\\n').match(/typeless:\\/\\/[^\\s"'<>]+/i);
            return match ? match[0] : '';
          }).catch(() => '');
          if (directProtocolURL) {
            openExternalTypelessProtocolURL(directProtocolURL);
            return 'direct typeless:// URL';
          }
          return '';
        }

        (async () => {
          const context = await chromium.launchPersistentContext(browserProfileDirectoryPath, { headless: true });
          const page = context.pages()[0] || await context.newPage();
          page.on('request', request => {
            try { openExternalTypelessProtocolURL(request.url()); } catch (error) {}
          });
          await page.goto(targetURL, { waitUntil: 'domcontentloaded', timeout: 20000 }).catch(() => {});
          await page.waitForLoadState('domcontentloaded', { timeout: 10000 }).catch(() => {});
          await page.waitForTimeout(1200);
          const clicked = await clickDesktopHandoff(page);
          await page.waitForTimeout(3500);
          await context.close();
          if (openedProtocolURL) {
            console.log('opened typeless:// desktop handoff via ' + (clicked || 'request') + ': ' + openedProtocolURL.slice(0, 120));
          } else {
            console.log('desktop handoff button/protocol not found at ' + page.url() + ' title=' + await page.title().catch(() => ''));
          }
        })().catch(error => {
          console.error(error.stack || error.message || String(error));
          process.exit(1);
        });
        """
    }

    private func completeTypelessDesktopOnboardingIfPresent(expectedEmail: String, timeoutSeconds: TimeInterval = 60) -> [String] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let typelessFolder = appSupport.appendingPathComponent("Typeless", isDirectory: true)
        let storageURL = typelessFolder.appendingPathComponent("app-storage.json")
        let onboardingURL = typelessFolder.appendingPathComponent("app-onboarding.json")

        let readiness = waitForTypelessDesktopStorage(
            storageURL: storageURL,
            onboardingURL: onboardingURL,
            expectedEmail: expectedEmail,
            timeoutSeconds: timeoutSeconds
        )
        if let email = readiness.email {
            guard email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                return ["桌面 App 当前账号不是新邮箱（检测到 \(email)），暂不改新手引导"]
            }
        } else {
            return ["尚未检测到桌面 App 新账号登录态，暂不改新手引导"]
        }

        do {
            logOutAndStopTypelessForOnboardingPatch()
            try writeTypelessOnboardingCompletion(to: onboardingURL)
            try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
            if let path = typelessAppPath() {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                enforceTypelessDesktopOnboardingPatchAfterRelaunch(
                    storageURL: storageURL,
                    onboardingURL: onboardingURL,
                    expectedEmail: expectedEmail
                )
            }
            return ["已跳过/完成 Typeless 桌面端新手引导"]
        } catch {
            return ["跳过 Typeless 新手引导失败：\(error.localizedDescription)"]
        }
    }

    private func writeTypelessOnboardingCompletion(to onboardingURL: URL) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: onboardingURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }
        object["isCompleted"] = true
        object["step"] = 99
        object["setUpStep"] = 99
        object["tryItStep"] = 99
        object["tryItPlaygroundStep"] = 99
        object["onboardingStep"] = NSNull()
        object["onboardingMaxReachedStep"] = NSNull()
        object["onboardingAutoLanguageDetection"] = true
        object["onboardingCompletedFloatingBarStart"] = true
        object["onboardingCompletedFloatingBarRelease"] = true
        object["onboardingHomePageClickAppToShowFloatingBar"] = []
        object["onboardingTryItPlaygroundIsCompleted"] = true
        object["onboardingMaxTryItPlaygroundStepValue"] = 99
        object["onboardingShortcutCalloutDismissedStep"] = 99
        object["pressToStopDictationOnboardingShown"] = [
            "voice_transcript_release": true,
            "voice_transcript": true,
            "voice_command": true,
            "voice_translation": true
        ]
        object["translationModeFeatureAlertOnboarding"] = [
            "dictationCount": 99,
            "shown": true
        ]
        if var translation = object["translationModeFeatureOnboarding"] as? [String: Any] {
            if var settingDot = translation["settingDot"] as? [String: Any] {
                settingDot["dismissed"] = true
                translation["settingDot"] = settingDot
            }
            if var newTags = translation["newTags"] as? [String: Any] {
                newTags["dismissed"] = true
                translation["newTags"] = newTags
            }
            object["translationModeFeatureOnboarding"] = translation
        }
        if var appDownload = object["appDownloadButtonOnboarding"] as? [String: Any] {
            appDownload["dismissed"] = true
            object["appDownloadButtonOnboarding"] = appDownload
        }
        if var shortcut = object["shortcutChangeFeatureOnboarding"] as? [String: Any] {
            if var settingDot = shortcut["settingDot"] as? [String: Any] {
                settingDot["dismissed"] = true
                shortcut["settingDot"] = settingDot
            }
            if var newTags = shortcut["newTags"] as? [String: Any] {
                newTags["dismissed"] = true
                shortcut["newTags"] = newTags
            }
            object["shortcutChangeFeatureOnboarding"] = shortcut
        }
        object["__ONBOARDING_UPGRADE_NOTICE"] = true

        try FileManager.default.createDirectory(at: onboardingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: onboardingURL, options: .atomic)
    }

    private func writeTypelessStorageOnboardingCompletion(to storageURL: URL, expectedEmail: String) throws {
        guard let data = try? Data(contentsOf: storageURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var userData = object["userData"] as? [String: Any] else {
            throw NSError(
                domain: "TypelessOnboardingPatch",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 Typeless 桌面端 app-storage.json 里的 userData"]
            )
        }

        guard let email = userData["email"] as? String,
              email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
            let actualEmail = (userData["email"] as? String) ?? "未知"
            throw NSError(
                domain: "TypelessOnboardingPatch",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "app-storage.json 账号不匹配：\(actualEmail)"]
            )
        }

        userData["is_new_user"] = false

        var onboarding = userData["onboarding"] as? [String: Any] ?? [:]
        for platform in ["ios", "android", "macos", "windows"] {
            var platformState = onboarding[platform] as? [String: Any] ?? [:]
            platformState["completed"] = true
            onboarding[platform] = platformState
        }
        userData["onboarding"] = onboarding

        object["userData"] = userData
        if object.keys.contains("currentRoute") {
            object["currentRoute"] = NSNull()
        }

        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let patchedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patchedData.write(to: storageURL, options: .atomic)
    }

    private func enforceTypelessDesktopOnboardingPatchAfterRelaunch(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String
    ) {
        for delay in [1.0, 3.0, 6.0, 12.0, 24.0, 60.0] {
            Thread.sleep(forTimeInterval: delay)
            guard let email = readTypelessDesktopEmail(from: storageURL),
                  email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                continue
            }
            try? writeTypelessOnboardingCompletion(to: onboardingURL)
            try? writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
        }
    }

    private func waitForTypelessDesktopStorage(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String,
        timeoutSeconds: TimeInterval
    ) -> (email: String?, onboardingExists: Bool) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastEmail: String?
        var onboardingExists = FileManager.default.fileExists(atPath: onboardingURL.path)

        repeat {
            if let email = readTypelessDesktopEmail(from: storageURL) {
                lastEmail = email
                onboardingExists = FileManager.default.fileExists(atPath: onboardingURL.path)
                if email.caseInsensitiveCompare(expectedEmail) == .orderedSame {
                    return (email, onboardingExists)
                }
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return (lastEmail, onboardingExists)
    }

    private func readTypelessDesktopEmail(from storageURL: URL) -> String? {
        guard let data = try? Data(contentsOf: storageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = object["userData"] as? [String: Any],
              let email = userData["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return email
    }

    private func logOutAndStopTypelessForOnboardingPatch() {
        _ = terminateInstalledTypelessApp()
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func terminateInstalledTypelessApp() -> String {
        let running = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier == "now.typeless.desktop" ||
                app.localizedName == "Typeless" ||
                app.bundleURL?.path == typelessAppPath()
        }

        guard !running.isEmpty else {
            return "本机 Typeless App 未运行，无需退出"
        }

        for app in running {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(typelessAppQuitGraceSeconds)
        while Date() < deadline {
            let stillRunning = NSWorkspace.shared.runningApplications.contains { app in
                app.bundleIdentifier == "now.typeless.desktop" ||
                    app.localizedName == "Typeless" ||
                    app.bundleURL?.path == typelessAppPath()
            }
            if !stillRunning {
                return "已正常退出本机 Typeless App"
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }

        let forced = SwitchboardStore.runProcess(
            arguments: ["pkill", "-f", "Typeless.app/Contents"],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 5
        )
        return forced.status == 0
            ? "已强制退出残留 Typeless App 进程"
            : "已请求退出 Typeless App；未发现可强制结束的残留进程"
    }

    private func terminateRetainedTypelessBrowserSessions() -> String {
        guard FileManager.default.fileExists(atPath: retainedTypelessBrowserProfileRootURL().path) else {
            return "旧网页登录态 profile 根目录不存在，无需关闭浏览器窗口"
        }

        let running = SwitchboardStore.runProcess(
            arguments: ["pgrep", "-f", retainedTypelessBrowserProfileRootURL().path],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 5
        )
        guard running.status == 0 else {
            return "未发现旧网页登录浏览器窗口"
        }

        let forced = SwitchboardStore.runProcess(
            arguments: ["pkill", "-f", retainedTypelessBrowserProfileRootURL().path],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 5
        )
        return forced.status == 0
            ? "已关闭旧网页登录浏览器窗口"
            : "尝试关闭旧网页登录浏览器窗口失败：\(forced.output.ifEmpty("退出码 \(forced.status)"))"
    }

    private func typelessDesktopSessionDataDirectories() -> [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let candidates = [
            appSupport.appendingPathComponent("Typeless", isDirectory: true),
            appSupport.appendingPathComponent("Typeless.exe", isDirectory: true),
            appSupport.appendingPathComponent("now.typeless.desktop", isDirectory: true)
        ]
        return candidates.reduce(into: [URL]()) { result, url in
            if !result.contains(where: { $0.path == url.path }) {
                result.append(url)
            }
        }
    }

    private nonisolated static func safeTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func runInlineAppleScript(
        _ appleScript: String,
        label: String,
        timeoutSeconds: TimeInterval
    ) -> (status: Int32, output: String) {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).applescript")
            try appleScript.write(to: url, atomically: true, encoding: .utf8)
            return SwitchboardStore.runProcess(
                arguments: ["osascript", url.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func runJavaScriptInPersonalChrome(
        _ javaScript: String,
        label: String,
        targetURL: String,
        delayBeforeJavaScriptSeconds: Int,
        timeoutSeconds: TimeInterval
    ) -> (status: Int32, output: String) {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let javaScriptURL = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).js")
            let appleScriptURL = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).applescript")
            try javaScript.write(to: javaScriptURL, atomically: true, encoding: .utf8)

            let appleScript = """
            tell application "Google Chrome"
              activate
              if (count of windows) = 0 then
                make new window
              end if
              set targetTab to missing value
              repeat with chromeWindow in windows
                repeat with chromeTab in tabs of chromeWindow
                  try
                    if (URL of chromeTab contains "typeless.com") then
                      set targetTab to chromeTab
                      exit repeat
                    end if
                  end try
                end repeat
                if targetTab is not missing value then exit repeat
              end repeat
              if targetTab is missing value then
                set targetTab to make new tab at end of tabs of window 1 with properties {URL:\(Self.appleScriptStringLiteral(targetURL))}
              else
                set URL of targetTab to \(Self.appleScriptStringLiteral(targetURL))
              end if
              delay \(delayBeforeJavaScriptSeconds)
              set javaScriptSource to read POSIX file \(Self.appleScriptStringLiteral(javaScriptURL.path))
              execute targetTab javascript javaScriptSource
            end tell
            """
            try appleScript.write(to: appleScriptURL, atomically: true, encoding: .utf8)
            return SwitchboardStore.runProcess(
                arguments: ["osascript", appleScriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func approveChromeTypelessAppPrompt() -> (status: Int32, output: String) {
        let script = """
        -- Handles Chrome external-protocol prompt:
        -- AXCheckBox / “始终允许 www.typeless.com ...” / “Always allow ...”
        on clickFirstCheckbox(containerElement)
          tell application "System Events"
            try
              if (count of checkboxes of containerElement) > 0 then
                set targetCheckbox to checkbox 1 of containerElement
                try
                  if (value of targetCheckbox as integer) is 0 then click targetCheckbox
                on error
                  click targetCheckbox
                end try
                return true
              end if
            end try
            try
              repeat with childGroup in groups of containerElement
                if my clickFirstCheckbox(childGroup) then return true
              end repeat
            end try
          end tell
          return false
        end clickFirstCheckbox

        on clickNamedOpenButton(containerElement)
          tell application "System Events"
            set buttonNames to {"打开Typeless.app", "打开 Typeless.app", "Open Typeless.app", "打开桌面应用", "Open the desktop app"}
            repeat with buttonName in buttonNames
              try
                click button (buttonName as text) of containerElement
                return true
              end try
            end repeat
            try
              repeat with childButton in buttons of containerElement
                set buttonText to ""
                try
                  set buttonText to (name of childButton as text)
                end try
                if buttonText contains "Typeless.app" or buttonText contains "打开" or buttonText contains "Open" then
                  click childButton
                  return true
                end if
              end repeat
            end try
            try
              repeat with childGroup in groups of containerElement
                if my clickNamedOpenButton(childGroup) then return true
              end repeat
            end try
          end tell
          return false
        end clickNamedOpenButton

        on chromeHasTypelessSuccessTab()
          tell application "Google Chrome"
            try
              repeat with chromeWindow in windows
                repeat with chromeTab in tabs of chromeWindow
                  try
                    if (URL of chromeTab contains "typeless.com/login/app/success") then
                      set active tab index of chromeWindow to (index of chromeTab)
                      set index of chromeWindow to 1
                      return true
                    end if
                  end try
                end repeat
              end repeat
            end try
          end tell
          return false
        end chromeHasTypelessSuccessTab

        on chromeSuccessPageShowsDesktopButton()
          tell application "Google Chrome"
            try
              if (count of windows) = 0 then return false
              if (URL of active tab of front window contains "typeless.com/login/app/success") then
                set pageText to execute active tab of front window javascript "document.body.innerText || ''"
                if pageText contains "打开桌面应用" or pageText contains "Open the desktop app" then
                  return true
                end if
              end if
            end try
          end tell
          return false
        end chromeSuccessPageShowsDesktopButton

        on clickDesktopButtonInPage()
          tell application "Google Chrome"
            try
              if (count of windows) = 0 then return false
              if (URL of active tab of front window contains "typeless.com/login/app/success") then
                execute active tab of front window javascript "Array.from(document.querySelectorAll('button,[role=button]')).find(e => /打开桌面应用|Open the desktop app/i.test(e.innerText||''))?.click();"
                return true
              end if
            end try
          end tell
          return false
        end clickDesktopButtonInPage

        tell application "Google Chrome"
          activate
        end tell
        delay 0.2

        set hadSuccessTab to chromeHasTypelessSuccessTab()
        set pageHadDesktopButton to chromeSuccessPageShowsDesktopButton()
        if pageHadDesktopButton then
          clickDesktopButtonInPage()
          delay 0.5
        end if
        set maxAttempts to 2
        if pageHadDesktopButton then set maxAttempts to 4

        tell application "System Events"
          if exists process "Google Chrome" then
            tell process "Google Chrome"
              repeat with attempt from 1 to maxAttempts
                repeat with chromeWindow in windows
                  set checkboxClicked to my clickFirstCheckbox(chromeWindow)
                  if my clickNamedOpenButton(chromeWindow) then
                    if checkboxClicked then
                      return "approved chrome typeless prompt with always allow"
                    end if
                    return "approved chrome typeless prompt"
                  end if
                end repeat
                if attempt is 1 and hadSuccessTab and pageHadDesktopButton then
                  -- Give Chrome a short moment to render the external-protocol modal.
                  delay 0.5
                else
                  delay 0.2
                end if
              end repeat
              if hadSuccessTab and pageHadDesktopButton then
                -- Conservative keyboard fallback only after a known Typeless success page click.
                try
                  key code 48 using {shift down}
                  key code 48 using {shift down}
                  key code 49
                  key code 48
                  key code 48
                  key code 49
                  return "approved chrome typeless prompt by keyboard fallback"
                end try
              end if
            end tell
          end if
        end tell
        return "chrome typeless prompt not found"
        """

        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("approve-chrome-typeless-prompt-\(Date().timeIntervalSince1970).applescript")
            try script.write(to: url, atomically: true, encoding: .utf8)
            return SwitchboardStore.runProcess(
                arguments: ["osascript", url.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 10
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func extractTypelessTokenInfo(fromBrowserProfile profileDirectoryPath: String, expectedEmail: String) -> String? {
        let levelDBURL = URL(fileURLWithPath: profileDirectoryPath)
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Local Storage", isDirectory: true)
            .appendingPathComponent("leveldb", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: levelDBURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        let escapedEmail = NSRegularExpression.escapedPattern(for: expectedEmail)
        let pattern = #"\{"accessToken":"[^"]+","refreshToken":"[^"]+","userId":"[^"]+","email":""# + escapedEmail + #""\}"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for case let fileURL as URL in enumerator {
            guard !fileURL.hasDirectoryPath,
                  let data = try? Data(contentsOf: fileURL),
                  let contents = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8),
                  let regex else { continue }
            let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
            guard let match = regex.firstMatch(in: contents, range: range),
                  let swiftRange = Range(match.range, in: contents) else { continue }
            let tokenInfo = String(contents[swiftRange])
            if tokenInfo.contains("MAXAI_CLIENT__FEATURES__AUTH__TOKEN_INFO") {
                return tokenInfo
            }
            return tokenInfo
        }
        return nil
    }

    private nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    private nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    func openLastAutomationBrowserSession() {
        guard let result = state.lastAutomationResult,
              let profilePath = result.browserProfileDirectoryPath,
              result.canOpenBrowserSession else {
            statusMessage = "最近自动化没有可打开的浏览器登录态目录"
            return
        }
        let targetURL = accountForLastAutomationResult()?.typelessURL ?? state.settings.typelessLoginURL
        statusMessage = openRetainedBrowserSession(profileDirectoryPath: profilePath, targetURL: targetURL)
    }

    private func accountForLastAutomationResult() -> Account? {
        guard let accountID = state.lastAutomationResult?.accountID,
              let index = accountIndex(id: accountID) else {
            return nil
        }
        return state.accounts[index]
    }

    private func openRetainedBrowserSession(profileDirectoryPath: String, targetURL: String) -> String {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: profileDirectoryPath),
                withIntermediateDirectories: true
            )

            let scriptURL = folder.appendingPathComponent("typeless-open-retained-session-\(Date().timeIntervalSince1970).js")
            let script = BrowserAutomationScriptBuilder.makeOpenSessionScript(input: BrowserSessionAutomationInput(
                targetURL: targetURL,
                browserProfileDirectoryPath: profileDirectoryPath,
                headless: false
            ))
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)

            let syntaxCheck = SwitchboardStore.runProcess(
                arguments: ["node", "--check", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard syntaxCheck.status == 0 else {
                return "新账号浏览器会话脚本语法检查失败：\(syntaxCheck.output.ifEmpty("退出码 \(syntaxCheck.status)"))"
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", scriptURL.path]
            process.environment = SwitchboardStore.automationEnvironment()
            process.currentDirectoryURL = folder
            try process.run()
            return "已打开新账号浏览器会话：\(targetURL)"
        } catch {
            return "打开新账号浏览器会话失败：\(error.localizedDescription)"
        }
    }

    private func runPlaywrightScript(_ scriptURL: URL, password: String) async -> (success: Bool, message: String) {
        await Task.detached(priority: .utility) {
            let syntaxCheck = SwitchboardStore.runProcess(
                arguments: ["node", "--check", scriptURL.path],
                environment: SwitchboardStore.automationEnvironment()
            )
            guard syntaxCheck.status == 0 else {
                return (false, "Playwright 脚本语法检查失败：\(syntaxCheck.output.ifEmpty("退出码 \(syntaxCheck.status)"))")
            }

            let scriptFolder = scriptURL.deletingLastPathComponent()
            try? SwitchboardStore.ensureAutomationPackageManifest(in: scriptFolder)

            if !SwitchboardStore.isAutomationRuntimeCached(in: scriptFolder) {
                let installPackage = SwitchboardStore.runProcess(
                    arguments: ["npm", "install", "--silent", "--no-audit", "--no-fund", "playwright"],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: scriptFolder,
                    timeoutSeconds: 90
                )
                guard installPackage.status == 0 else {
                    return (false, "Playwright 包安装失败或超时，已保留脚本可重试：\(installPackage.output.ifEmpty("退出码 \(installPackage.status)"))")
                }

                let installBrowser = SwitchboardStore.runProcess(
                    arguments: ["npm", "exec", "--", "playwright", "install", "chromium"],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: scriptFolder,
                    timeoutSeconds: 120
                )
                guard installBrowser.status == 0 else {
                    return (false, "Playwright Chromium 准备失败或超时，已保留脚本可重试：\(installBrowser.output.ifEmpty("退出码 \(installBrowser.status)"))")
                }
                SwitchboardStore.markAutomationRuntimeReady(in: scriptFolder)
            }

            var environment = SwitchboardStore.automationEnvironment()
            environment[typelessAutomationPasswordEnvironmentKey] = password
            let run = SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path],
                environment: environment,
                currentDirectory: scriptFolder,
                timeoutSeconds: 180
            )
            if run.status == 0 {
                return (true, "Playwright 自动化已执行：\(run.output.ifEmpty("无输出"))")
            }
            return (false, "Playwright 自动化未完成，已保留脚本可重试：\(run.output.ifEmpty("退出码 \(run.status)"))")
        }.value
    }

    private nonisolated static func automationEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let additions = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = environment["PATH"] ?? ""
        let merged = (additions + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            .joined(separator: ":")
        environment["PATH"] = merged
        return environment
    }

    private nonisolated static func ensureAutomationPackageManifest(in folder: URL) throws {
        let packageFile = folder.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: packageFile.path) {
            try "{\"private\":true}".write(to: packageFile, atomically: true, encoding: .utf8)
        }
    }

    private nonisolated static func automationRuntimeReadyMarkerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".typeless-playwright-runtime-ready.json")
    }

    private nonisolated static func isAutomationRuntimeCached(in folder: URL) -> Bool {
        let packageFile = folder
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
            .appendingPathComponent("package.json")
        let markerFile = automationRuntimeReadyMarkerURL(in: folder)
        return FileManager.default.fileExists(atPath: packageFile.path) &&
            FileManager.default.fileExists(atPath: markerFile.path) &&
            isPlaywrightChromiumExecutableAvailable(in: folder)
    }

    private nonisolated static func isPlaywrightChromiumExecutableAvailable(in folder: URL) -> Bool {
        let probeScript = """
        const fs = require('fs');
        const { chromium } = require('playwright');
        const executablePath = chromium.executablePath();
        if (!executablePath || !fs.existsSync(executablePath)) {
          console.error('missing chromium executable: ' + executablePath);
          process.exit(2);
        }
        console.log(executablePath);
        """
        let result = runProcess(
            arguments: ["node", "-e", probeScript],
            environment: automationEnvironment(),
            currentDirectory: folder,
            timeoutSeconds: 15
        )
        return result.status == 0
    }

    private nonisolated static func markAutomationRuntimeReady(in folder: URL) {
        let marker = automationRuntimeReadyMarkerURL(in: folder)
        let payload = [
            "readyAt": ISO8601DateFormatter().string(from: Date()),
            "package": "playwright",
            "browser": "chromium"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: marker, options: .atomic)
        }
    }

    private nonisolated static func runAppleEventsProbe(_ appleScript: String) -> (success: Bool, message: String) {
        let result = runProcess(
            arguments: ["osascript", "-e", appleScript],
            environment: automationEnvironment(),
            timeoutSeconds: 8
        )
        if result.status == 0 {
            return (true, result.output.ifEmpty("OK"))
        }
        if result.output.contains("-1743") || result.output.localizedCaseInsensitiveContains("not authorized") {
            return (false, "未授权")
        }
        return (false, result.output.ifEmpty("退出码 \(result.status)"))
    }

    private nonisolated static func runProcess(
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 60
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                group.leave()
            }
            if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                process.terminate()
                return (-2, "命令超时：\(arguments.joined(separator: " "))")
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (
                process.terminationStatus,
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func moeMailURL(path: String) -> URL? {
        guard let base = URL(string: state.settings.moeMailBaseURL) else { return nil }
        return URL(string: path, relativeTo: base)
    }

    private func moeMailRequest(url: URL, apiKey: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")
        if let body {
            request.httpBody = body
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(
                domain: "MoeMail",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]
            )
        }
        return data
    }

    private func parseMoeMailEmails(from data: Data) -> [MoeMailEmail] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let dictionaries = collectDictionaries(from: json)

        let emails = dictionaries.compactMap { dictionary -> MoeMailEmail? in
            let address = stringValue(dictionary, keys: ["email", "address", "mail", "emailAddress"])
            let id = stringValue(dictionary, keys: ["id", "_id", "emailId", "emailID", "uuid"])
            guard !address.isEmpty || !id.isEmpty else { return nil }

            let resolvedAddress = address
            let domain = stringValue(dictionary, keys: ["domain", "mailDomain"])
                .ifEmpty(resolvedAddress.components(separatedBy: "@").last ?? "")
            let name = stringValue(dictionary, keys: ["name", "username", "label"])
                .ifEmpty(resolvedAddress.components(separatedBy: "@").first ?? "")
            let resolvedID = id.ifEmpty(resolvedAddress)

            return MoeMailEmail(
                id: resolvedID,
                address: resolvedAddress,
                name: name,
                domain: domain,
                expiresAt: nil,
                rawSummary: summarize(dictionary)
            )
        }

        return Array(Dictionary(grouping: emails, by: \.id).compactMap { $0.value.first })
            .sorted { $0.address < $1.address }
    }

    private func parseMoeMailMessages(from data: Data) -> [MoeMailMessage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return collectDictionaries(from: json).compactMap { dictionary -> MoeMailMessage? in
            let id = stringValue(dictionary, keys: ["id", "_id", "messageId", "messageID", "uuid"])
            let subject = stringValue(dictionary, keys: ["subject", "title"]).ifEmpty("无主题")
            let sender = stringValue(dictionary, keys: ["from", "sender", "fromAddress"])
            let receivedAt = stringValue(dictionary, keys: ["createdAt", "receivedAt", "date", "time"])
            let preview = stringValue(dictionary, keys: ["preview", "text", "body", "content"])
            guard !id.isEmpty || !sender.isEmpty || subject != "无主题" else { return nil }
            return MoeMailMessage(
                id: id.ifEmpty(UUID().uuidString),
                subject: subject,
                sender: sender,
                receivedAt: receivedAt,
                preview: preview
            )
        }
    }

    private func collectDictionaries(from object: Any) -> [[String: Any]] {
        var result: [[String: Any]] = []

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                result.append(dictionary)
                dictionary.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }

        walk(object)
        return result
    }

    private func stringValue(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] {
                if let string = value as? String {
                    return string.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
        }
        return ""
    }

    private func summarize(_ dictionary: [String: Any]) -> String {
        dictionary
            .prefix(4)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "  ")
    }

    private func extractDomains(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var values: [String] = []

        func walk(_ object: Any) {
            if let string = object as? String {
                if looksLikeDomain(string) {
                    values.append(string)
                }
            } else if let array = object as? [Any] {
                array.forEach(walk)
            } else if let dictionary = object as? [String: Any] {
                dictionary.values.forEach(walk)
            }
        }

        walk(json)
        return Array(Set(values)).sorted()
    }

    private func looksLikeDomain(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("."),
              !trimmed.contains(" "),
              !trimmed.contains("@"),
              !trimmed.hasPrefix("http") else {
            return false
        }
        return trimmed.range(of: #"^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}

private extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum KeychainStore {
    private static let service = "local.typeless.switchboard"
    private static let account = "moemail-api-key"
    private static let accountPasswordPrefix = "typeless-account-password-"

    static func readAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveAPIKey(_ value: String) {
        save(value, account: account)
    }

    static func readAccountPassword(accountID: UUID) -> String {
        read(account: accountPasswordPrefix + accountID.uuidString)
    }

    static func saveAccountPassword(_ value: String, accountID: UUID) {
        save(value, account: accountPasswordPrefix + accountID.uuidString)
    }

    private static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            SecItemAdd(createQuery as CFDictionary, nil)
        }
    }
}

@main
struct TypelessSwitchboardApp: App {
    @StateObject private var store = SwitchboardStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: SwitchboardStore
    @State private var selectedID: UUID?
    @State private var apiKey = KeychainStore.readAPIKey()
    @State private var searchText = ""
    @State private var listFilter: AccountListFilter = .all
    @State private var commandLineAutomationStarted = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 304)

            Divider()

            detailArea
                .frame(minWidth: 500)

            Divider()

            InspectorView(apiKey: $apiKey, selectedID: $selectedID)
                .frame(width: 360)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fontDesign(.rounded)
        .onAppear {
            if selectedID == nil {
                selectedID = store.state.accounts.first?.id
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "switch.2")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Typeless Switchboard")
                        .font(.title2.weight(.semibold))
                    Text("MoeMail 注册与账号切换")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 18)

            QuotaSummaryView()
                .padding(.horizontal, 14)

            VStack(spacing: 8) {
                TextField("搜索账号、邮箱或域名", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("筛选", selection: $listFilter) {
                    ForEach(AccountListFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 14)

            List(selection: $selectedID) {
                ForEach(filteredAccounts) { account in
                    AccountRow(account: account)
                        .tag(account.id)
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 8) {
                Button {
                    selectedID = store.addAccount()
                } label: {
                    Label("新增", systemImage: "plus")
                }

                Button {
                    selectedID = store.nextAvailableAccountID()
                } label: {
                    Label("下一个", systemImage: "arrow.right.circle")
                }
                .disabled(store.nextAvailableAccountID() == nil)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 18)

            Button {
                selectedID = store.prepareSwitch(from: selectedID)
            } label: {
                Label("准备切换", systemImage: "forward.end.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.nextAvailableAccountID() == nil)
            .padding(.horizontal, 18)

            Button {
                Task {
                    selectedID = await store.runOneClickAutomaticReplacement(
                        apiKey: apiKey,
                        domain: store.state.settings.domains.first ?? "",
                        expiryTime: 0,
                        from: selectedID
                    )
                }
            } label: {
                Label(
                    store.isRunningAutomaticReplacement ? "自动换号中" : "全自动一键换号",
                    systemImage: "wand.and.stars.inverse"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(store.isRunningAutomaticReplacement || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

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

    @ViewBuilder
    private var detailArea: some View {
        if let index = store.accountIndex(id: selectedID) {
            AccountDetailView(
                account: accountBinding(index: index),
                onSave: store.save,
                onDelete: {
                    let deletedID = store.state.accounts[index].id
                    store.deleteAccount(id: deletedID)
                    selectedID = store.state.accounts.first?.id
                }
            )
        } else {
            EmptyStateView {
                selectedID = store.addAccount()
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
}

struct QuotaSummaryView: View {
    @EnvironmentObject private var store: SwitchboardStore

    private var totalRemaining: Int {
        store.state.accounts.reduce(0) { $0 + $1.remainingCharacters }
    }

    private var availableCount: Int {
        store.state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
    }

    private var pendingCount: Int {
        store.state.accounts.filter { $0.effectiveReviewState == .pending }.count
    }

    private var exhaustedCount: Int {
        store.state.accounts.filter { $0.status == .exhausted || $0.remainingCharacters == 0 }.count
    }

    private var pausedCount: Int {
        store.state.accounts.filter { $0.status == .paused || $0.effectiveReviewState == .rejected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("可用账号", systemImage: "person.crop.circle.badge.checkmark")
                Spacer()
                Text("\(availableCount)")
                    .font(.title3.weight(.semibold))
            }
            HStack {
                Label("剩余额度", systemImage: "textformat.size")
                Spacer()
                Text("\(totalRemaining)")
                    .font(.title3.weight(.semibold))
            }
            Divider()
            HStack(spacing: 8) {
                SummaryPill(title: "待确认", value: pendingCount, color: .orange)
                SummaryPill(title: "用完", value: exhaustedCount, color: .red)
                SummaryPill(title: "暂停", value: pausedCount, color: .secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct SummaryPill: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
            Text("\(value)")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.name.isEmpty ? "未命名账号" : account.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Circle()
                    .fill(account.status.color)
                    .frame(width: 8, height: 8)
            }

            Text(account.email.isEmpty ? account.domain : account.email)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ProgressView(value: account.usageRatio)
                .tint(account.status.color)

            HStack(spacing: 6) {
                Text("剩余 \(account.remainingCharacters) / \(account.monthlyLimit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(account.status.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(account.status.color.opacity(0.14))
                    .foregroundStyle(account.status.color)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                if account.effectiveReviewState != .approved {
                    Text(account.effectiveReviewState.title)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(account.effectiveReviewState.color.opacity(0.14))
                        .foregroundStyle(account.effectiveReviewState.color)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
        .padding(.vertical, 5)
    }
}

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

struct InspectorView: View {
    @EnvironmentObject private var store: SwitchboardStore
    @Binding var apiKey: String
    @Binding var selectedID: UUID?

    @State private var newDomain = ""
    @State private var isRefreshing = false
    @State private var isLoadingEmails = false
    @State private var isGeneratingEmail = false
    @State private var isCreatingRegistration = false
    @State private var isLoadingMessages = false
    @State private var isCheckingTypeless = false
    @State private var generatedName = "typeless"
    @State private var generatedDomain = defaultDomains.first ?? ""
    @State private var generatedExpiry = 0
    @State private var candidateCount = 5

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsPanel
                accountPoolPanel
                reviewQueuePanel
                moeMailPanel
                checklistPanel
                domainsPanel
                statusPanel
            }
            .padding(18)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("连接设置", systemImage: "gearshape")
                .font(.headline)

            TextField("Typeless 入口", text: settingsBinding(\.typelessLoginURL))
            TextField("MoeMail 地址", text: settingsBinding(\.moeMailBaseURL))
            SecureField("MoeMail API Key", text: $apiKey)

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

                Button {
                    isCheckingTypeless = true
                    Task {
                        await store.checkTypelessEntry()
                        isCheckingTypeless = false
                    }
                } label: {
                    Label(isCheckingTypeless ? "检查中" : "检查入口", systemImage: "network")
                }
                .disabled(isCheckingTypeless)
            }
            .buttonStyle(.bordered)

            Button {
                isCheckingTypeless = true
                Task {
                    await store.runSetupDiagnostics(apiKey: apiKey)
                    isCheckingTypeless = false
                }
            } label: {
                Label(isCheckingTypeless ? "自检中" : "一键自检", systemImage: "checklist.checked")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCheckingTypeless)

            HStack(spacing: 8) {
                Menu {
                    ForEach(MacPermissionChecklist.recommendedItems.filter { $0.settingsPaneIdentifier != nil }, id: \.title) { item in
                        Button(item.title) {
                            if let pane = item.settingsPaneIdentifier {
                                store.openMacPermissionSettings(pane)
                            }
                        }
                    }
                } label: {
                    Label("打开权限设置", systemImage: "lock.shield")
                }

                Button {
                    store.copyMacPermissionChecklist()
                } label: {
                    Label("复制权限清单", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    KeychainStore.saveAPIKey(apiKey)
                    store.statusMessage = "API Key 已保存到钥匙串"
                } label: {
                    Label("保存密钥", systemImage: "key")
                }

                Button {
                    isRefreshing = true
                    Task {
                        await store.refreshMoeMailConfig(apiKey: apiKey)
                        isRefreshing = false
                    }
                } label: {
                    Label(isRefreshing ? "同步中" : "同步域名", systemImage: "arrow.down.circle")
                }
                .disabled(isRefreshing)
            }
            .buttonStyle(.bordered)

            if !store.diagnostics.isEmpty {
                VStack(spacing: 8) {
                    ForEach(store.diagnostics) { item in
                        DiagnosticRow(item: item)
                    }
                }
            }
        }
        .panelStyle()
    }

    private var accountPoolPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("账号池工具", systemImage: "tray.full")
                .font(.headline)

            Stepper(value: $candidateCount, in: 1...30) {
                Text("候选账号数量：\(candidateCount)")
                    .font(.callout)
            }

            Picker("候选域名", selection: $generatedDomain) {
                ForEach(store.state.settings.domains, id: \.self) { domain in
                    Text(domain).tag(domain)
                }
            }

            HStack(spacing: 8) {
                Button {
                    store.generateCandidateAccounts(count: candidateCount, domain: generatedDomain)
                } label: {
                    Label("批量生成", systemImage: "sparkles")
                }

                Button {
                    selectedID = store.prepareSwitch(from: selectedID)
                } label: {
                    Label("准备切换", systemImage: "forward.end.circle")
                }
                .disabled(store.nextAvailableAccountID() == nil)
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    selectedID = await store.runOneClickAutomaticReplacement(
                        apiKey: apiKey,
                        domain: generatedDomain,
                        expiryTime: generatedExpiry,
                        from: selectedID
                    )
                }
            } label: {
                Label(
                    store.isRunningAutomaticReplacement ? "自动创建和切换中" : "全自动一键换新账号",
                    systemImage: "wand.and.stars"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(
                store.isRunningAutomaticReplacement ||
                apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                generatedDomain.isEmpty
            )

            HStack(spacing: 8) {
                Button {
                    store.exportAccountsToClipboard()
                } label: {
                    Label("复制 JSON", systemImage: "doc.on.doc")
                }

                Button {
                    store.importAccountsFromClipboard()
                    selectedID = store.state.accounts.first?.id
                } label: {
                    Label("恢复 JSON", systemImage: "arrow.down.doc")
                }
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                Button {
                    store.exportAccountsCSVToClipboard()
                } label: {
                    Label("复制 CSV", systemImage: "tablecells")
                }

                Button {
                    store.importAccountsCSVFromClipboard()
                    selectedID = store.state.accounts.first?.id
                } label: {
                    Label("导入 CSV", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.bordered)

            Button {
                store.importToolkitAccountsFromClipboard()
                selectedID = store.state.accounts.first?.id
            } label: {
                Label("导入 toolkit 账号", systemImage: "square.stack.3d.down.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.copyAccountPoolAuditToClipboard()
            } label: {
                Label("复制体检报告", systemImage: "stethoscope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.resetMonthlyQuotaForApprovedAccounts()
            } label: {
                Label("月初重置已确认账号", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .panelStyle()
        .onAppear {
            if generatedDomain.isEmpty {
                generatedDomain = store.state.settings.domains.first ?? ""
            }
        }
    }

    private var reviewQueuePanel: some View {
        let pendingIDs = store.pendingReviewAccountIDs()
        return VStack(alignment: .leading, spacing: 12) {
            if pendingIDs.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Label("全自动换号确认状态", systemImage: "bolt.badge.checkmark")
                            .font(.headline)
                        Text(store.state.lastAutomationResult?.status == .completed
                             ? "最近一次一键换号已自动确认成功账号，不需要再点“确认/退回”。"
                             : "当前没有待兜底确认账号；只有自动化无法证明注册完成时，才会出现兜底队列。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack {
                    Label("兜底确认队列", systemImage: "checkmark.seal")
                        .font(.headline)
                    Spacer()
                    Text("\(pendingIDs.count)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                Text("这里仅显示自动化没有证明完成的候选账号；正常一键换号成功后会直接进入已确认可用池。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    ForEach(pendingIDs.prefix(8), id: \.self) { id in
                        if let index = store.accountIndex(id: id) {
                            ReviewAccountRow(
                                account: store.state.accounts[index],
                                onSelect: { selectedID = id },
                                onApprove: {
                                    store.approveAccount(id: id)
                                    selectedID = id
                                },
                                onReject: { store.rejectAccount(id: id) }
                            )
                        }
                    }
                }
            }
        }
        .panelStyle()
    }

    private var moeMailPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("MoeMail 邮箱", systemImage: "mail.stack")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("名称")
                    TextField("邮箱前缀", text: $generatedName)
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
                            selectedID = store.importMoeMailEmail(email)
                        }
                        isGeneratingEmail = false
                    }
                } label: {
                    Label(isGeneratingEmail ? "生成中" : "生成并导入", systemImage: "plus.circle")
                }
                .disabled(isGeneratingEmail || generatedDomain.isEmpty)
            }
            .buttonStyle(.bordered)

            Button {
                isCreatingRegistration = true
                Task {
                    if let id = await store.createMoeMailRegistrationCandidate(
                        apiKey: apiKey,
                        domain: generatedDomain,
                        expiryTime: generatedExpiry
                    ) {
                        selectedID = id
                    }
                    isCreatingRegistration = false
                }
            } label: {
                Label(isCreatingRegistration ? "创建中" : "创建注册候选账号", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isCreatingRegistration || generatedDomain.isEmpty)

            if store.moeMailEmails.isEmpty {
                Text("读取 MoeMail 后，可以把已有邮箱导入账号池。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.moeMailEmails.prefix(8)) { email in
                        MoeMailEmailRow(email: email) {
                            selectedID = store.importMoeMailEmail(email)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    guard let index = store.accountIndex(id: selectedID) else { return }
                    let account = store.state.accounts[index]
                    isLoadingMessages = true
                    Task {
                        await store.loadMessages(for: account, apiKey: apiKey)
                        isLoadingMessages = false
                    }
                } label: {
                    Label(isLoadingMessages ? "读取中" : "读取当前账号邮件", systemImage: "envelope.badge")
                }
                .disabled(isLoadingMessages || selectedAccount?.moeMailEmailID == nil)
            }
            .buttonStyle(.bordered)

            if !store.moeMailMessages.isEmpty {
                VStack(spacing: 8) {
                    ForEach(store.moeMailMessages.prefix(5)) { message in
                        MoeMailMessageRow(message: message)
                    }
                }
            }
        }
        .panelStyle()
        .onAppear {
            if generatedDomain.isEmpty {
                generatedDomain = store.state.settings.domains.first ?? ""
            }
        }
    }

    private var checklistPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("切换清单", systemImage: "checklist")
                    .font(.headline)
                Spacer()
                Button {
                    store.resetChecklist()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
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
                    selectedID = next
                    store.resetChecklist()
                } label: {
                    Label("选择下一个可用账号", systemImage: "arrow.right.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .panelStyle()
    }

    private var domainsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("邮箱域名", systemImage: "at")
                .font(.headline)

            HStack {
                TextField("添加域名", text: $newDomain)
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
        .panelStyle()
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("状态", systemImage: "info.circle")
                .font(.headline)
            Text(store.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("账号数据保存在本机 Application Support，MoeMail 密钥保存在 macOS 钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let result = store.state.lastAutomationResult {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("最近自动换号", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                    Text(result.status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(result.status == .completed ? .green : .orange)
                    Text(result.markdown)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(12)
                        .textSelection(.enabled)
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
                        Task {
                            if let id = await store.retryLastAutomation() {
                                selectedID = id
                            }
                        }
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

            Button {
                store.copyTypelessEnvironmentReport()
            } label: {
                Label("复制 Typeless 环境", systemImage: "terminal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                store.copyDeviceInfoReport()
            } label: {
                Label("复制设备信息", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity)
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

            Button {
                store.copyTroubleshootingBundle()
            } label: {
                Label("复制完整排障包", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .panelStyle()
    }

    private var selectedAccount: Account? {
        guard let index = store.accountIndex(id: selectedID) else { return nil }
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

    private func checklistBinding<Value>(index: Int, keyPath: WritableKeyPath<SwitchTask, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.settings.checklist[index][keyPath: keyPath] },
            set: { newValue in
                store.state.settings.checklist[index][keyPath: keyPath] = newValue
                store.save()
            }
        )
    }
}

struct MoeMailEmailRow: View {
    let email: MoeMailEmail
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(email.address.isEmpty ? email.displayName : email.address)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(email.domain.isEmpty ? email.id : email.domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onImport()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("导入账号池")
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct ReviewAccountRow: View {
    let account: Account
    let onSelect: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.email.isEmpty ? account.name : account.email)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text((account.typelessUsername ?? account.domain).ifEmpty(account.domain))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button {
                    onApprove()
                } label: {
                    Label("确认", systemImage: "checkmark")
                }

                Button {
                    onReject()
                } label: {
                    Label("退回", systemImage: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct DiagnosticRow: View {
    let item: DiagnosticItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(item.level.color)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(item.level.title)
                        .font(.caption)
                        .foregroundStyle(item.level.color)
                }
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct MoeMailMessageRow: View {
    let message: MoeMailMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.subject)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if !message.receivedAt.isEmpty {
                    Text(message.receivedAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !message.sender.isEmpty {
                Text(message.sender)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !message.preview.isEmpty {
                Text(message.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct EmptyStateView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("还没有账号")
                .font(.title2.weight(.semibold))
            Text("先添加你已经拥有并有权使用的账号，再用这里记录额度和切换状态。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                onCreate()
            } label: {
                Label("添加账号", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct NumberField: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: $value, formatter: NumberFormatter.integer)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private extension NumberFormatter {
    static var integer: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.minimum = 0
        return formatter
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct GeneratedAccountProfile {
    var displayName: String
    var username: String
    var email: String
    var domain: String
    var password: String
}

enum AccountProfileGenerator {
    private static let adjectives = [
        "clear", "swift", "bright", "quiet", "fresh", "lucky", "solid", "rapid",
        "neat", "smart", "calm", "prime", "true", "bold", "clean", "sharp"
    ]
    private static let nouns = [
        "note", "draft", "paper", "cursor", "field", "page", "signal", "orbit",
        "marker", "line", "pixel", "folder", "writer", "memo", "frame", "script"
    ]

    static func make(domain: String) -> GeneratedAccountProfile {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).ifEmpty("example.com")
        let adjective = adjectives.randomElement() ?? "clear"
        let noun = nouns.randomElement() ?? "note"
        let suffix = String(Int.random(in: 100_000...999_999))
        let username = "\(adjective)_\(noun)_\(suffix)"
        let email = "\(adjective).\(noun).\(suffix)@\(normalizedDomain)"

        return GeneratedAccountProfile(
            displayName: "\(adjective.capitalized) \(noun.capitalized)",
            username: username,
            email: email,
            domain: normalizedDomain,
            password: PasswordGenerator.make()
        )
    }
}

enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let digits = Array("23456789")
    private static let symbols = Array("!@#$%*+=?")

    static func make(length: Int = 20) -> String {
        let required = [
            lowercase.randomElement() ?? "a",
            uppercase.randomElement() ?? "A",
            digits.randomElement() ?? "2",
            symbols.randomElement() ?? "!"
        ]
        let all = lowercase + uppercase + digits + symbols
        let rest = (0..<max(length - required.count, 0)).map { _ in
            all.randomElement() ?? "x"
        }
        return String((required + rest).shuffled())
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
