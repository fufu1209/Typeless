import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    // MARK: - 开机轻量插件（LaunchAgent）

    func refreshLaunchAgentStatus() {
        launchAgentStatusMessage = QuotaGuardLaunchAgent.statusSummary(
            intervalMinutes: state.settings.autoRotateCheckIntervalMinutes
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
