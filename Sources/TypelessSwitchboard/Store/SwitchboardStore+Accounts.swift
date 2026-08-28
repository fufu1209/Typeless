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

    func macModelIdentifier() -> String {
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

    func typelessAppPath() -> String? {
        let candidates = [
            "/Applications/Typeless.app",
            "\(NSHomeDirectory())/Applications/Typeless.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func typelessExecutablePath() -> String? {
        let candidates = [
            "/Applications/Typeless.app/Contents/MacOS/Typeless",
            "\(NSHomeDirectory())/Applications/Typeless.app/Contents/MacOS/Typeless"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func firstExistingAppSupportPath(_ names: [String]) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in names {
            let url = appSupport.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return appSupport.appendingPathComponent(names.first ?? "Typeless")
    }

    func typelessUserDataDir() -> URL {
        firstExistingAppSupportPath(["Typeless.exe", "Typeless"])
    }

    func typelessDeviceCacheDir() -> URL {
        let candidates = typelessDeviceCacheDirectories()
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
    }

    func typelessDeviceCacheDirectories() -> [URL] {
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


    func refreshPermissionCacheIfNeeded(force: Bool = false, probeAppleEvents: Bool = true) {
        if !force,
           let last = lastPermissionProbeAt,
           Date().timeIntervalSince(last) < permissionProbeCacheTTL,
           cachedAccessibilityTrusted != nil {
            return
        }

        // 只做静默检查，绝不调用 AXIsProcessTrustedWithOptions(prompt:true)。
        // prompt:true 会在未授权/签名变化时反复弹出“想使用辅助功能”。
        cachedAccessibilityTrusted = AXIsProcessTrusted()

        if probeAppleEvents {
            // Apple Events 探测也可能弹“自动化”授权；后台路径默认跳过，仅自检/手动时探测。
            let chromeProbe = Self.runAppleEventsProbe(#"tell application "Google Chrome" to get version"#)
            let systemEventsProbe = Self.runAppleEventsProbe(#"tell application "System Events" to count processes"#)
            cachedAutomationOK = chromeProbe.success && systemEventsProbe.success
            cachedAutomationDetail = "Chrome：\(chromeProbe.message)；System Events：\(systemEventsProbe.message)"
        } else if cachedAutomationOK == nil {
            cachedAutomationOK = true
            cachedAutomationDetail = "后台路径跳过 Apple Events 探测，避免重复弹窗"
        }

        lastPermissionProbeAt = Date()
    }

    func appendMacPermissionDiagnostics(to results: inout [DiagnosticItem]) {
        refreshPermissionCacheIfNeeded(force: true, probeAppleEvents: true)
        let accessibilityTrusted = cachedAccessibilityTrusted == true
        results.append(DiagnosticItem(
            title: "电脑权限：辅助功能",
            detail: accessibilityTrusted
                ? "已允许辅助功能控制；可自动点击 Chrome 弹窗、System Events 弹窗和 Typeless 交接。"
                : "需要在系统设置 → 隐私与安全性 → 辅助功能中允许 TypelessSwitchboard，才能自动点击 Chrome 的“打开 Typeless.app”弹窗。请只开一次；工具不会反复弹授权窗。",
            level: accessibilityTrusted ? .ok : .warning
        ))

        let automationOK = cachedAutomationOK == true
        results.append(DiagnosticItem(
            title: "电脑权限：自动化",
            detail: automationOK
                ? "Apple Events 已可控制 Google Chrome 和 System Events。"
                : "需要在系统设置 → 隐私与安全性 → 自动化（Privacy_Automation）允许 TypelessSwitchboard 控制 Google Chrome 和 System Events。\(cachedAutomationDetail)",
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

    /// 注册前权限预检：只静默检查，绝不反复弹系统授权窗。
    /// - Parameter interactive: 用户手动点换号时为 true，允许整次会话最多打开一次系统设置。
    func preflightMacPermissionsBeforeAutomaticReplacement(
        log: inout [String],
        interactive: Bool = false
    ) -> Bool {
        log.append("开始注册前权限预检：静默检查辅助功能与自动化（不弹系统授权窗）")

        // 后台热备/巡检：只用缓存 + 静默 AX 检查，不探测 Apple Events，避免连环弹窗。
        refreshPermissionCacheIfNeeded(force: interactive, probeAppleEvents: interactive)

        let accessibilityTrusted = cachedAccessibilityTrusted == true
        let automationOK = cachedAutomationOK != false

        if accessibilityTrusted {
            log.append("权限预检通过：辅助功能 Accessibility 已允许")
        } else {
            log.append("权限预警：辅助功能 Accessibility 未允许；Playwright 注册可继续，自动点 Chrome 弹窗可能受限")
            if interactive {
                openMacPermissionSettingsOnce("Privacy_Accessibility")
            }
        }

        if automationOK {
            log.append("权限预检通过：自动化 Apple Events 状态可用或已跳过探测")
        } else {
            log.append("权限预警：自动化 Apple Events 可能未完全允许。\(cachedAutomationDetail)")
            if interactive {
                openMacPermissionSettingsOnce("Privacy_Automation")
            }
        }

        // 不再因权限缺失硬暂停：反复 hard-fail + 后台重试会导致用户一直看到授权/设置弹窗。
        // Playwright 注册本身不依赖辅助功能；缺权限时最多降级自动点弹窗能力。
        if !accessibilityTrusted || !automationOK {
            log.append("权限未齐也继续执行；请在系统设置里一次性允许后，重建签名的 App 也只需再开一次")
            if interactive {
                statusMessage = "权限未齐：已继续换号；辅助功能/自动化请在系统设置里一次性打开"
            }
        } else {
            log.append("权限预检完成：继续执行创建邮箱、清理环境和自动换号逻辑")
        }
        return true
    }

    func copyMacPermissionChecklist() {
        copyToClipboard(MacPermissionChecklist.markdown)
        statusMessage = "已复制 macOS 权限清单"
    }

    /// 用户主动点 UI 时打开系统设置；自动流程整次会话最多打开一次。
    func openMacPermissionSettings(_ settingsPaneIdentifier: String) {
        openMacPermissionSettingsOnce(settingsPaneIdentifier, force: true)
    }

    func openMacPermissionSettingsOnce(_ settingsPaneIdentifier: String, force: Bool = false) {
        if !force, didAutoOpenPermissionSettingsThisSession {
            return
        }
        if !force {
            didAutoOpenPermissionSettingsThisSession = true
        }

        // 优先用现代 System Settings URL，减少旧路径反复拉起。
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(settingsPaneIdentifier)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsPaneIdentifier)"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                statusMessage = "已打开系统设置：\(settingsPaneIdentifier)（只需允许一次）"
                return
            }
        }
        statusMessage = "权限设置入口无效：\(settingsPaneIdentifier)"
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

    func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    func csvValue(_ row: [String], keys: [String: Int], name: String) -> String {
        guard let index = keys[name], row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toolkitString(_ dictionary: [String: Any], keys: [String]) -> String {
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

    func parseCSV(_ text: String) -> [[String]] {
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
        from currentID: UUID?,
        preserveCurrentAccount: Bool = false,
        interactive: Bool = false
    ) async -> UUID? {
        guard !isRunningAutomaticReplacement else {
            statusMessage = "全自动换号正在运行中"
            return nil
        }

        isRunningAutomaticReplacement = true
        defer { isRunningAutomaticReplacement = false }

        var log: [String] = [
            preserveCurrentAccount ? "开始热备注册（不切换当前使用号）" : "开始全自动一键换号"
        ]
        let previousAccount = currentID
            .flatMap { id in accountIndex(id: id).map { state.accounts[$0] } }
        var previousAccountEmailForResult = previousAccount?.email

        // 热备/后台：interactive=false，绝不弹辅助功能授权窗、不反复打开系统设置。
        guard preflightMacPermissionsBeforeAutomaticReplacement(
            log: &log,
            interactive: interactive && !preserveCurrentAccount
        ) else {
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

        if preserveCurrentAccount {
            // 热备：只在独立 Playwright profile 里注册，绝不碰当前桌面/Chrome 登录态。
            log.append("热备模式：跳过桌面/Chrome 清理与 handoff，避免打断当前使用")
        } else {
            let staleChromePromptLog = await resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement()
            log.append(contentsOf: staleChromePromptLog)
            let staleChromeTabsLog = await closePersonalChromeTypelessTabsBeforeReplacement()
            log.append(contentsOf: staleChromeTabsLog)
            let desktopPreparationLog = await prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement()
            log.append(contentsOf: desktopPreparationLog)
            let browserSessionPreparationLog = await prepareRetainedTypelessBrowserSessionsForAutomaticReplacement()
            log.append(contentsOf: browserSessionPreparationLog)
            let chromePreparationLog = await preparePersonalChromeTypelessWebSessionForAutomaticReplacement()
            log.append(contentsOf: chromePreparationLog)
        }
        statusMessage = preserveCurrentAccount
            ? "正在后台注册热备账号…"
            : "正在创建新的 MoeMail 邮箱和 Typeless 注册资料..."

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
           !preserveCurrentAccount,
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
                state.accounts[refreshedIndex].notes = preserveCurrentAccount
                    ? "热备账号：已注册完成，等待无感静默切换"
                    : "自动换号已提取验证码，浏览器结果判定注册完成，可用于切换"
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
            // 优先从浏览器 profile 抽出 token，写成可静默注入的桌面会话 payload。
            if let tokenInfo = extractTypelessTokenInfo(
                fromBrowserProfile: browserProfileURL.path,
                expectedEmail: account.email
            ),
               let desktopPayload = SmartSwitchPolicy.desktopUserDataPayload(fromBrowserTokenInfo: tokenInfo),
               let refreshedIndex = accountIndex(id: account.id) {
                state.accounts[refreshedIndex].rawUserDataPayload = desktopPayload
                account = state.accounts[refreshedIndex]
                log.append("已从浏览器 profile 固化静默会话缓存，可供下次无感换号秒切")
            }

            if !preserveCurrentAccount {
                log.append(contentsOf: await syncPersonalChromeTypelessWebSession(
                    account: account,
                    profileDirectoryPath: browserProfileURL.path
                ))
                log.append(await handoffRetainedTypelessProfileToDesktopOnce(
                    profileDirectoryPath: browserProfileURL.path,
                    expectedEmail: account.email
                ))
                log.append("新账号浏览器会话已保留：\(browserProfileURL.path)；未自动打开额外浏览器，需要排查时再点“打开新账号会话”")
                log.append(contentsOf: await completeTypelessDesktopOnboardingIfPresent(
                    expectedEmail: account.email,
                    timeoutSeconds: 120
                ))
            } else {
                log.append("热备模式：已保留浏览器 profile，未切换当前桌面/Chrome 使用号")
            }
        }

        if !preserveCurrentAccount {
            copyToClipboard(automationComplete ? account.email : (verificationCode ?? account.email))
            for index in state.settings.checklist.indices {
                state.settings.checklist[index].isDone = false
            }
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
        if automationComplete, !preserveCurrentAccount {
            // 先用本地解密快速确认桌面已切到新号并固化会话缓存，避免每轮验证都请求官方额度 API。
            var matchedNewAccount = false
            for attempt in 0..<SmartSwitchPolicy.sessionCaptureRetryAttempts {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: SmartSwitchPolicy.sessionCaptureRetryDelaySeconds * 1_000_000_000)
                }
                if let synced = await syncActiveAppSessionAndQuota(localOnly: true),
                   let syncedIndex = accountIndex(id: synced) {
                    let email = state.accounts[syncedIndex].email.lowercased()
                    if email == account.email.lowercased() {
                        matchedNewAccount = true
                        break
                    }
                    if state.accounts[syncedIndex].rawUserDataPayload != nil,
                       let accountIndex = accountIndex(id: account.id),
                       state.accounts[accountIndex].rawUserDataPayload == nil {
                        // 桌面已是新号但邮箱匹配慢时，仍把 payload 留在账号上。
                        matchedNewAccount = true
                        break
                    }
                }
            }
            if matchedNewAccount {
                // 桌面会话已确认：补一次完整同步刷新本周额度数字。
                if let synced = await syncActiveAppSessionAndQuota(),
                   let syncedIndex = accountIndex(id: synced),
                   state.accounts[syncedIndex].email.lowercased() == account.email.lowercased() {
                    liveAccountEmail = state.accounts[syncedIndex].email
                    liveRemainingCharacters = state.accounts[syncedIndex].remainingCharacters
                    lastKnownRemainingForInterval = liveRemainingCharacters
                }
            }
        }
        if preserveCurrentAccount {
            statusMessage = automationComplete
                ? "热备账号已就绪：\(account.email)"
                : "热备注册未完成，等待下次补齐：\(account.email)"
            return automationComplete ? account.id : nil
        }
        statusMessage = automationComplete
            ? "全自动换号已完成，已同步 Google Chrome / Typeless 桌面端并复制新邮箱：\(account.email)"
            : "自动换号已推进到兜底确认阶段；旧账号未标记用完：\(account.email)"
        return automationComplete ? account.id : currentID
    }

    /// 解析启动参数：GUI / 单次 daemon 巡检 / CLI 批量换号。
    static func resolveRunMode(from arguments: [String] = CommandLine.arguments) -> SwitchboardRunMode {
        if arguments.contains("--daemon-check") || arguments.contains("--quota-guard-once") {
            return .daemonOnce
        }
        if arguments.contains("--auto-switch-count") {
            return .cliAutoSwitch
        }
        return .gui
    }

    /// LaunchAgent / 定时任务入口：同步额度 → 低额度自动换号 → 可选补热备 → 退出。
    /// 不启动 GUI、不常驻循环。
    func runDaemonQuotaGuardOnceIfRequested() async -> Bool {
        let arguments = CommandLine.arguments
        guard arguments.contains("--daemon-check") || arguments.contains("--quota-guard-once") else {
            return false
        }

        let startedAt = Date()
        print("TypelessSwitchboard daemon: quota guard check starting")
        autoRotateMonitorStatus = "daemon：正在单次巡检额度…"

        // 单次巡检：忽略 GUI 的 isAutoRotateEnabled 开关（Agent 本身就是用户选择的守护方式）。
        // 但仍尊重阈值、热备、池空自动注册配置。
        let previousAutoRotate = state.settings.isAutoRotateEnabled
        let previousCreate = state.settings.autoCreateWhenPoolEmpty
        state.settings.isAutoRotateEnabled = true
        // 无 API Key 时 performAutoRotateCheck 仍可做静默池切换，但无法全自动注册。
        let apiKey = KeychainStore.readAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        if apiKey.isEmpty {
            print("TypelessSwitchboard daemon: warning — MoeMail API Key missing; silent switch only, no auto-register")
        }

        let resultID = await performAutoRotateCheck(apiKey: apiKey.isEmpty ? nil : apiKey)
        // 额度充足且本周数字新鲜时才补热备。
        if lastQuotaSyncFresh, !apiKey.isEmpty, state.settings.autoCreateWhenPoolEmpty {
            await ensureHotSpareIfNeeded(apiKey: apiKey, domain: state.settings.domains.first ?? "")
        }

        // 近阈值时把 LaunchAgent 间隔压到约 20 秒，额度回升后再拉回用户设定分钟数。
        if QuotaGuardLaunchAgent.isInstalled {
            let threshold = SmartSwitchPolicy.normalizeThreshold(state.settings.autoRotateRemainingThreshold)
            let desiredSeconds: Int
            if lastQuotaSyncFresh,
               let remaining = liveRemainingCharacters,
               SmartSwitchPolicy.isApproachingQuotaLimit(remaining: remaining, threshold: threshold) {
                desiredSeconds = Int(SmartSwitchPolicy.urgentCheckIntervalSeconds)
            } else {
                desiredSeconds = SmartSwitchPolicy.normalizeCheckIntervalMinutes(
                    state.settings.autoRotateCheckIntervalMinutes
                ) * 60
            }
            QuotaGuardLaunchAgent.reconcileIntervalSecondsIfNeeded(desiredSeconds)
        }

        state.settings.isAutoRotateEnabled = previousAutoRotate
        state.settings.autoCreateWhenPoolEmpty = previousCreate
        save()

        let elapsed = Date().timeIntervalSince(startedAt)
        let remainingText = liveRemainingCharacters.map(String.init) ?? "unknown"
        let usedText = lastQuotaUsedCharacters.map(String.init) ?? "-"
        let limitText = lastQuotaMonthlyLimit.map(String.init) ?? "-"
        print(
            "TypelessSwitchboard daemon: done weekly used=\(usedText)/\(limitText) remaining=\(remainingText) " +
            "fresh=\(lastQuotaSyncFresh) email=\(liveAccountEmail.ifEmpty("-")) " +
            "resultID=\(resultID?.uuidString ?? "nil") reason=\(lastAutoRotateDecisionReason.ifEmpty(autoRotateMonitorStatus)) " +
            "elapsed=\(String(format: "%.1f", elapsed))s"
        )
        appendDaemonLog(
            remaining: liveRemainingCharacters,
            email: liveAccountEmail,
            reason: "\(weeklyQuotaSummaryLine) | \(lastAutoRotateDecisionReason.ifEmpty(autoRotateMonitorStatus))",
            resultID: resultID
        )
        return true
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

    func commandLineValue(for flag: String, in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return ""
        }
        return arguments[index + 1]
    }

    func appendDaemonLog(remaining: Int?, email: String, reason: String, resultID: UUID?) {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let logURL = dir.appendingPathComponent("quota-guard-daemon.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] remaining=\(remaining.map(String.init) ?? "-") email=\(email.ifEmpty("-")) result=\(resultID?.uuidString ?? "-") \(reason)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
        }
    }
}
