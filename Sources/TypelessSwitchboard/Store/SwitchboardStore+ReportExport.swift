import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
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
}
