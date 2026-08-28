import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
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
