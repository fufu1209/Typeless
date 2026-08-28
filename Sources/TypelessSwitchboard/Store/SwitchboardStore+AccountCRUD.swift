import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
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

    // MARK: - v2.5.2 完整配置包导入导出

    /// 把"换 Mac 也能立刻用"所需的所有非隐私数据写到 ~/Downloads。
    /// - 不导出 keychain 内容（API Key / 账号强密码 / 设备凭据）
    /// - 不导出 token 摘要、浏览器快照
    /// - 文件名带时间戳，格式 JSON，按 schemaVersion 校验
    /// - 成功时返回写入的文件 URL，失败返回 nil 并设置 statusMessage
    @discardableResult
    func exportFullBundle() -> URL? {
        let bundle = makeBundle(kind: .full)
        return writeBundle(bundle)
    }

    /// 脱敏导出：邮箱变 `demo[N]@example.com`、notes 清空。
    /// 适合发 GitHub / 分享给同事 / 备份后归档。
    @discardableResult
    func exportPublicBundle() -> URL? {
        let sanitized = ConfigurationBundleIO.sanitize(makeBundle(kind: .full))
        return writeBundle(sanitized)
    }

    /// 从 JSON 文件导入。返回新增的账号数（已存在的邮箱会被跳过）。
    /// - 校验 schemaVersion，失败返回 -1
    /// - 按邮箱去重（已有则不重复添加）
    /// - 导入后自动 save()
    @discardableResult
    func importFullBundle(from url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else {
            statusMessage = "导入失败：无法读取文件"
            return -1
        }
        guard let bundle = ConfigurationBundleIO.parse(data) else {
            statusMessage = "导入失败：schema 不匹配（期望 v\(ConfigurationBundleIO.currentSchemaVersion)）"
            return -1
        }
        var added = 0
        var skipped = 0
        let existingEmails = Set(state.accounts.map { $0.email.lowercased() })
        for acc in bundle.accounts {
            if existingEmails.contains(acc.email.lowercased()) {
                skipped += 1
                continue
            }
            // 注意：导入的账号 password 为空，需要在新设备上重新生成
            // typelessUsername 也可能为空（公开版脱敏后）
            var imported = Account.blank(settings: state.settings)
            imported.name = acc.name
            imported.email = acc.email
            imported.domain = acc.domain.isEmpty ? accountDomain(of: acc.email) : acc.domain
            imported.role = acc.role
            imported.typelessUsername = acc.typelessUsername
            imported.notes = acc.notes
            imported.createdAt = acc.createdAt
            imported.status = AccountStatus(rawValue: acc.status) ?? .available
            state.accounts.append(imported)
            added += 1
        }
        // 合并设置（不覆盖已有非默认值）
        if bundle.settings.autoRotateRemainingThreshold != SmartSwitchPolicy.defaultRemainingThreshold {
            state.settings.autoRotateRemainingThreshold = bundle.settings.autoRotateRemainingThreshold
        }
        if bundle.settings.autoRotateCheckIntervalMinutes != SmartSwitchPolicy.defaultCheckIntervalMinutes {
            state.settings.autoRotateCheckIntervalMinutes = bundle.settings.autoRotateCheckIntervalMinutes
        }
        state.settings.hotSpareTargetCount = bundle.settings.hotSpareTarget
        save()
        statusMessage = "导入完成：新增 \(added) 个账号，跳过 \(skipped) 个重复"
        return added
    }

    private func makeBundle(kind: ConfigurationBundle.Kind) -> ConfigurationBundle {
        let accounts = state.accounts.map { acc in
            ConfigurationBundleAccount(
                name: acc.name,
                email: acc.email,
                domain: acc.domain,
                role: acc.role,
                typelessUsername: acc.typelessUsername,
                notes: acc.notes,
                createdAt: acc.createdAt,
                status: acc.status.rawValue
            )
        }
        let settings = BundleSettings(
            autoRotateRemainingThreshold: state.settings.autoRotateRemainingThreshold,
            autoRotateCheckIntervalMinutes: state.settings.autoRotateCheckIntervalMinutes,
            keepRunningInBackground: state.settings.keepRunningInBackground,
            hotSpareTarget: state.settings.hotSpareTargetCount,
            moeMailBaseURL: state.settings.moeMailBaseURL,
            allowFullAutomaticReplacement: state.settings.autoCreateWhenPoolEmpty
        )
        return ConfigurationBundle(
            schemaVersion: ConfigurationBundleIO.currentSchemaVersion,
            appVersion: appVersionString(),
            exportedAt: Date(),
            kind: kind,
            accounts: accounts,
            settings: settings
        )
    }

    private func writeBundle(_ bundle: ConfigurationBundle) -> URL? {
        let encoder = ConfigurationBundleIO.encoder
        guard let data = try? encoder.encode(bundle) else {
            statusMessage = "导出失败：编码错误"
            return nil
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let kindLabel = bundle.kind == .full ? "full" : "public"
        let stamp = isoTimestampForFilename()
        let outURL = downloads.appendingPathComponent(
            "TypelessSwitchboard-bundle-\(kindLabel)-\(stamp).json"
        )
        do {
            try data.write(to: outURL, options: .atomic)
            statusMessage = "已导出到 \(outURL.path)"
            return outURL
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
            return nil
        }
    }

    private func accountDomain(of email: String) -> String {
        if let at = email.firstIndex(of: "@") {
            return String(email[email.index(after: at)...])
        }
        return ""
    }

    private func isoTimestampForFilename() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }

    private func appVersionString() -> String {
        // 打进 .app 时以 Info.plist 为准（它会带上构建号）；
        // 裸二进制（CLI 导出 / daemon 巡检）读不到 Info.plist，
        // 回落到 Core 的 AppVersion —— 不再有第二处硬编码跟着漂移。
        if let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !s.isEmpty {
            return s
        }
        return AppVersion.short
    }
}
