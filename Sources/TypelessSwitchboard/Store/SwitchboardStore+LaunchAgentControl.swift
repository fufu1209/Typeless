import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    // MARK: - 开机轻量插件（LaunchAgent）

    /// 刷新开机插件状态，并**顺手自愈**两类静默失效。
    ///
    /// 自愈 ①：plist 在、launchd 里却没有（历史上 bootout 之后 bootstrap 失败就会留下
    /// 这种状态）→ 直接 bootstrap 回来。守护自己发现不了这件事：它能跑就说明 job 在，
    /// job 不在它就永远不跑 —— 所以只能由 GUI 兜底。
    /// 自愈 ②：plist 的巡检间隔被历史版本改歪了 → 校正回用户配置值。
    ///
    /// 这两件事都只能放在 GUI 路径上：守护侧不得碰 launchd（bootout 会把它自己带走，
    /// 见 `QuotaGuardLaunchAgentPlanner` 的「重载安全」注释）。
    func refreshLaunchAgentStatus() {
        if QuotaGuardLaunchAgent.isInstalled {
            if !QuotaGuardLaunchAgent.isLoaded {
                if QuotaGuardLaunchAgent.ensureLoaded() {
                    appendDaemonLog(
                        remaining: liveRemainingCharacters,
                        email: liveAccountEmail,
                        reason: "launchagent-heal plist 已安装但 launchd 中无任务，已重新加载",
                        resultID: nil
                    )
                }
            }
            _ = QuotaGuardLaunchAgent.normalizeIntervalToConfigured(
                minutes: state.settings.autoRotateCheckIntervalMinutes
            )
        }
        launchAgentStatusMessage = QuotaGuardLaunchAgent.statusSummary(
            configuredMinutes: state.settings.autoRotateCheckIntervalMinutes
        )
    }


    @discardableResult
    func installQuotaGuardLaunchAgent(intervalMinutes: Int? = nil) -> Bool {
        let minutes = SmartSwitchPolicy.normalizeCheckIntervalMinutes(
            intervalMinutes ?? state.settings.autoRotateCheckIntervalMinutes
        )
        do {
            let program = try QuotaGuardLaunchAgent.resolveProgramPath()
            try QuotaGuardLaunchAgent.install(programPath: program, intervalMinutes: minutes)
            // 装上 Agent 后：默认关掉 GUI 常驻循环，避免双开巡检。
            state.settings.keepRunningInBackground = false
            state.settings.isAutoRotateEnabled = false
            stopRotateMonitor()
            autoRotateMonitorStatus = "已改用开机轻量插件（LaunchAgent），App 内循环守护已关"
            save()
            refreshLaunchAgentStatus()
            statusMessage = "已安装开机轻量额度守护（每 \(minutes) 分钟巡检一次，不常驻窗口）"
            return true
        } catch {
            refreshLaunchAgentStatus()
            statusMessage = "安装开机轻量插件失败：\(error.localizedDescription)"
            return false
        }
    }


    @discardableResult
    func uninstallQuotaGuardLaunchAgent() -> Bool {
        do {
            try QuotaGuardLaunchAgent.uninstall()
            refreshLaunchAgentStatus()
            statusMessage = "已卸载开机轻量额度守护"
            return true
        } catch {
            refreshLaunchAgentStatus()
            statusMessage = "卸载开机轻量插件失败：\(error.localizedDescription)"
            return false
        }
    }


    /// 立刻跑一轮与 LaunchAgent 相同的单次巡检（不退出 App）。
    func runQuotaGuardOnceFromUI() async {
        statusMessage = "正在执行与开机插件相同的单次额度巡检…"
        autoRotateMonitorStatus = "手动：单次 daemon 巡检中…"
        let apiKey = KeychainStore.readAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let resultID = await performAutoRotateCheck(apiKey: apiKey.isEmpty ? nil : apiKey)
        if !apiKey.isEmpty, state.settings.autoCreateWhenPoolEmpty {
            await ensureHotSpareIfNeeded(apiKey: apiKey, domain: state.settings.domains.first ?? "")
        }
        if let resultID, let index = accountIndex(id: resultID) {
            liveAccountEmail = state.accounts[index].email
            liveRemainingCharacters = state.accounts[index].remainingCharacters
        }
        statusMessage = "单次巡检完成：\(lastAutoRotateDecisionReason.ifEmpty(autoRotateMonitorStatus))"
        appendDaemonLog(
            remaining: liveRemainingCharacters,
            email: liveAccountEmail,
            reason: "ui-once " + lastAutoRotateDecisionReason.ifEmpty(autoRotateMonitorStatus),
            resultID: resultID
        )
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

}
