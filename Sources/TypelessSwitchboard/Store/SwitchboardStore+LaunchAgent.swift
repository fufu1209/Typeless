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
            // 验证码轮询路径必须用短超时：轮询总窗口有限，慢请求会挤占后续轮次。
            let data = try await moeMailRequest(url: url, apiKey: apiKey, timeoutInterval: 8)
            moeMailMessages = parseMoeMailMessages(from: data)
            statusMessage = moeMailMessages.isEmpty ? "没有读取到邮件" : "已读取 \(moeMailMessages.count) 封邮件"
        } catch {
            statusMessage = "邮件列表读取失败：\(error.localizedDescription)"
        }
    }

    func pollVerificationCode(for account: Account, apiKey: String, attempts: Int, delaySeconds: UInt64) async -> String? {
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

    func automationCommandVersion(command: String, versionArgument: String) async -> String {
        await Task.detached(priority: .utility) {
            let result = SwitchboardStore.runProcess(arguments: [command, versionArgument], environment: SwitchboardStore.automationEnvironment())
            guard result.status == 0 else { return "" }
            return result.output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }

    func prepareAutomationRuntime() async -> (success: Bool, message: String) {
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

    func verificationCode(from messages: [MoeMailMessage]) -> String? {
        for message in messages {
            let fields = [message.subject, message.sender, message.receivedAt, message.preview]
            if let code = VerificationCodeExtractor.extract(from: fields) {
                return code
            }
        }
        return nil
    }

    func makeVerificationCodeBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-code-\(safeEmail)-\(account.id.uuidString).txt")
    }

    func makeAutomationResultBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-result-\(safeEmail)-\(account.id.uuidString).json")
    }

    func makeBrowserProfileDirectoryURL(account: Account) -> URL {
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return retainedTypelessBrowserProfileRootURL()
            .appendingPathComponent("\(safeEmail)-\(account.id.uuidString)", isDirectory: true)
    }

    func retainedTypelessBrowserProfileRootURL() -> URL {
        automationDirectoryURL()
            .appendingPathComponent("BrowserProfiles", isDirectory: true)
    }

    func automationDirectoryURL() -> URL {
        dataFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Automation", isDirectory: true)
    }

    func writeVerificationCode(_ code: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "写入验证码桥接文件失败：\(error.localizedDescription)"
        }
    }

    func writeRegistrationAutomationScript(
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

    func readAutomationResult(from url: URL) -> BrowserAutomationResultPayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserAutomationResultPayload.self, from: data)
    }

    func prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement() async -> [String] {
        var log: [String] = []
        log.append(await terminateInstalledTypelessApp())

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

    func resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: URL) -> [String] {
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

    func deleteTypelessDeviceCredentialsFromKeychain() -> [String] {
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

    func deleteTypelessDeviceCredentialWithSecurityCLI(service: String, account: String?) -> Bool {
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

    func deleteTypelessDeviceCredentialWithSecurityCLI(label: String) -> Bool {
        let result = SwitchboardStore.runProcess(
            arguments: ["security", "delete-generic-password", "-l", label],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }

    func clearTypelessAppStorageForDeviceReset(_ storageURL: URL) throws {
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

    func prepareRetainedTypelessBrowserSessionsForAutomaticReplacement() async -> [String] {
        var log: [String] = []
        log.append(await terminateRetainedTypelessBrowserSessions())

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

    func resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement() async -> [String] {
        let result = await approveChromeTypelessAppPrompt()
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

    func closePersonalChromeTypelessTabsBeforeReplacement() async -> [String] {
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
        let result = await runInlineAppleScript(
            script,
            label: "close-personal-chrome-typeless-tabs",
            timeoutSeconds: 10
        )
        if result.status == 0 {
            return ["已关闭 Google Chrome 里的旧 Typeless 标签：\(result.output.ifEmpty("closed 0 typeless tabs"))"]
        }
        return ["关闭 Google Chrome 旧 Typeless 标签失败：\(result.output.ifEmpty("退出码 \(result.status)"))"]
    }

    func preparePersonalChromeTypelessWebSessionForAutomaticReplacement() async -> [String] {
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

        let result = await runJavaScriptInPersonalChrome(
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

    func syncPersonalChromeTypelessWebSession(account: Account, profileDirectoryPath: String) async -> [String] {
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

        let syncResult = await runJavaScriptInPersonalChrome(
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
        _ = await runJavaScriptInPersonalChrome(
            openDesktopScript,
            label: "open-typeless-desktop-from-personal-chrome",
            targetURL: "https://www.typeless.com/login/app/success",
            delayBeforeJavaScriptSeconds: chromeSessionJavaScriptDelaySeconds,
            timeoutSeconds: 20
        )
        _ = await approveChromeTypelessAppPrompt()

        return ["已把 Google Chrome 的 Typeless 网页会话切到新账号：\(account.email)"]
    }

    func handoffRetainedTypelessProfileToDesktopOnce(profileDirectoryPath: String, expectedEmail: String) async -> String {
        if let tokenInfo = extractTypelessTokenInfo(fromBrowserProfile: profileDirectoryPath, expectedEmail: expectedEmail),
           let authURL = makeTypelessDesktopAuthURL(fromTokenInfo: tokenInfo) {
            await forceLaunchTypelessBeforeAuthProtocol()
            let firstOpen = await openTypelessAuthProtocol(authURL)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let secondOpen = await openTypelessAuthProtocol(authURL)
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
            // 该脚本会启动 Playwright 并在页面中点击 handoff，可能在后台线程执行，避免冻结主线程。
            let result = await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["node", scriptURL.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: 45
                )
            }.value
            if result.status == 0 {
                return "已后台触发新账号 Typeless 桌面端 handoff：\(result.output.ifEmpty("无输出"))"
            }
            return "后台触发 Typeless 桌面端 handoff 未完成：\(result.output.ifEmpty("退出码 \(result.status)"))"
        } catch {
            return "后台触发 Typeless 桌面端 handoff 失败：\(error.localizedDescription)"
        }
    }

    func forceLaunchTypelessBeforeAuthProtocol() async {
        if let path = typelessAppPath() {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            // 给 Electron 冷启动留时间，但用可取消 sleep，不再硬冻结主线程。
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }

    func openTypelessAuthProtocol(_ authURL: String) async -> Bool {
        let result = await Task.detached(priority: .utility) {
            SwitchboardStore.runProcess(
                arguments: ["open", authURL],
                environment: SwitchboardStore.automationEnvironment(),
                timeoutSeconds: 15
            )
        }.value
        return result.status == 0
    }

    func makeTypelessDesktopAuthURL(fromTokenInfo tokenInfo: String) -> String? {
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

    func makeDesktopHandoffScript(profileDirectoryPath: String) -> String {
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

    func completeTypelessDesktopOnboardingIfPresent(expectedEmail: String, timeoutSeconds: TimeInterval = 60) async -> [String] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let typelessFolder = appSupport.appendingPathComponent("Typeless", isDirectory: true)
        let storageURL = typelessFolder.appendingPathComponent("app-storage.json")
        let onboardingURL = typelessFolder.appendingPathComponent("app-onboarding.json")

        let readiness = await waitForTypelessDesktopStorage(
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
            await logOutAndStopTypelessForOnboardingPatch()
            try writeTypelessOnboardingCompletion(to: onboardingURL)
            try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
            if let path = typelessAppPath() {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                await enforceTypelessDesktopOnboardingPatchAfterRelaunch(
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

    func writeTypelessOnboardingCompletion(to onboardingURL: URL) throws {
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

    func writeTypelessStorageOnboardingCompletion(to storageURL: URL, expectedEmail: String) throws {
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

    func enforceTypelessDesktopOnboardingPatchAfterRelaunch(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String
    ) async {
        for delay in [1.0, 3.0, 6.0, 12.0, 24.0, 60.0] {
            // 可取消 sleep，不再硬冻结主线程；总等待上限不变。
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let email = readTypelessDesktopEmail(from: storageURL),
                  email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                continue
            }
            try? writeTypelessOnboardingCompletion(to: onboardingURL)
            try? writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
        }
    }

    func waitForTypelessDesktopStorage(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String,
        timeoutSeconds: TimeInterval
    ) async -> (email: String?, onboardingExists: Bool) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastEmail: String?
        var onboardingExists = FileManager.default.fileExists(atPath: onboardingURL.path)

        while Date() < deadline {
            if let email = readTypelessDesktopEmail(from: storageURL) {
                lastEmail = email
                onboardingExists = FileManager.default.fileExists(atPath: onboardingURL.path)
                if email.caseInsensitiveCompare(expectedEmail) == .orderedSame {
                    return (email, onboardingExists)
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return (lastEmail, onboardingExists)
    }

    func readTypelessDesktopEmail(from storageURL: URL) -> String? {
        guard let data = try? Data(contentsOf: storageURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = object["userData"] as? [String: Any],
              let email = userData["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return email
    }

    func logOutAndStopTypelessForOnboardingPatch() async {
        _ = await terminateInstalledTypelessApp()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
    }

    func terminateInstalledTypelessApp() async -> String {
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
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let forced = await Task.detached(priority: .utility) {
            SwitchboardStore.runProcess(
                arguments: ["pkill", "-f", "Typeless.app/Contents"],
                environment: SwitchboardStore.automationEnvironment(),
                timeoutSeconds: 5
            )
        }.value
        return forced.status == 0
            ? "已强制退出残留 Typeless App 进程"
            : "已请求退出 Typeless App；未发现可强制结束的残留进程"
    }

    func terminateRetainedTypelessBrowserSessions() async -> String {
        guard FileManager.default.fileExists(atPath: retainedTypelessBrowserProfileRootURL().path) else {
            return "旧网页登录态 profile 根目录不存在，无需关闭浏览器窗口"
        }

        let profileRoot = retainedTypelessBrowserProfileRootURL().path
        let running = await Task.detached(priority: .utility) {
            SwitchboardStore.runProcess(
                arguments: ["pgrep", "-f", profileRoot],
                environment: SwitchboardStore.automationEnvironment(),
                timeoutSeconds: 5
            )
        }.value
        guard running.status == 0 else {
            return "未发现旧网页登录浏览器窗口"
        }

        let forced = await Task.detached(priority: .utility) {
            SwitchboardStore.runProcess(
                arguments: ["pkill", "-f", profileRoot],
                environment: SwitchboardStore.automationEnvironment(),
                timeoutSeconds: 5
            )
        }.value
        return forced.status == 0
            ? "已关闭旧网页登录浏览器窗口"
            : "尝试关闭旧网页登录浏览器窗口失败：\(forced.output.ifEmpty("退出码 \(forced.status)"))"
    }

    func typelessDesktopSessionDataDirectories() -> [URL] {
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

    nonisolated static func safeTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    func runInlineAppleScript(
        _ appleScript: String,
        label: String,
        timeoutSeconds: TimeInterval
    ) async -> (status: Int32, output: String) {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("\(label)-\(Date().timeIntervalSince1970).applescript")
            try appleScript.write(to: url, atomically: true, encoding: .utf8)
            // osascript 可能被自动化授权弹窗/系统挂起拖住，必须在后台线程执行，避免冻结主线程。
            return await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["osascript", url.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: timeoutSeconds
                )
            }.value
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    func runJavaScriptInPersonalChrome(
        _ javaScript: String,
        label: String,
        targetURL: String,
        delayBeforeJavaScriptSeconds: Int,
        timeoutSeconds: TimeInterval
    ) async -> (status: Int32, output: String) {
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
            // Chrome AppleScript 可能等待页面加载 / 自动化授权，必须在后台线程执行，避免冻结主线程。
            return await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["osascript", appleScriptURL.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: timeoutSeconds
                )
            }.value
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    func approveChromeTypelessAppPrompt() async -> (status: Int32, output: String) {
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
            // 该脚本可能被 Chrome 弹窗 / 自动化授权卡住，必须在后台线程执行，避免冻结主线程。
            return await Task.detached(priority: .utility) {
                SwitchboardStore.runProcess(
                    arguments: ["osascript", url.path],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: folder,
                    timeoutSeconds: 10
                )
            }.value
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    func extractTypelessTokenInfo(fromBrowserProfile profileDirectoryPath: String, expectedEmail: String) -> String? {
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

    nonisolated static func javaScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }

    nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
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

    func accountForLastAutomationResult() -> Account? {
        guard let accountID = state.lastAutomationResult?.accountID,
              let index = accountIndex(id: accountID) else {
            return nil
        }
        return state.accounts[index]
    }

    func openRetainedBrowserSession(profileDirectoryPath: String, targetURL: String) -> String {
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

    func runPlaywrightScript(_ scriptURL: URL, password: String) async -> (success: Bool, message: String) {
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

    nonisolated static func automationEnvironment() -> [String: String] {
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

    nonisolated static func ensureAutomationPackageManifest(in folder: URL) throws {
        let packageFile = folder.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: packageFile.path) {
            try "{\"private\":true}".write(to: packageFile, atomically: true, encoding: .utf8)
        }
    }

    nonisolated static func automationRuntimeReadyMarkerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".typeless-playwright-runtime-ready.json")
    }

    nonisolated static func isAutomationRuntimeCached(in folder: URL) -> Bool {
        let packageFile = folder
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
            .appendingPathComponent("package.json")
        let markerFile = automationRuntimeReadyMarkerURL(in: folder)
        return FileManager.default.fileExists(atPath: packageFile.path) &&
            FileManager.default.fileExists(atPath: markerFile.path) &&
            isPlaywrightChromiumExecutableAvailable(in: folder)
    }

    nonisolated static func isPlaywrightChromiumExecutableAvailable(in folder: URL) -> Bool {
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

    nonisolated static func markAutomationRuntimeReady(in folder: URL) {
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

    nonisolated static func runAppleEventsProbe(_ appleScript: String) -> (success: Bool, message: String) {
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

    nonisolated static func runProcess(
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

        // 边跑边读：子进程输出超过管道缓冲（约 64KB）时会写阻塞，若等进程退出后才读会永远等不到退出。
        // 这里用一个后台读取线程持续消费管道，最多保留 512KB，超时终止时也能拿到已产生的部分输出。
        let readHandle = pipe.fileHandleForReading
        let outputBuffer = OutputBuffer(maxBytes: 512 * 1024)

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let group = DispatchGroup()
        group.enter() // 进程退出
        group.enter() // 管道读完
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            group.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = readHandle.availableData
                if chunk.isEmpty { break }
                outputBuffer.append(chunk)
            }
            group.leave()
        }

        let timedOut = group.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            // 给子进程死亡、管道 EOF 一点收尾时间。
            _ = group.wait(timeout: .now() + 2)
        }

        let output = outputBuffer.string()
        if timedOut {
            return (-2, "命令超时：\(arguments.joined(separator: " "))\(output.isEmpty ? "" : "\n\(output)")")
        }
        return (process.terminationStatus, output)
    }

    /// 线程安全的进程输出缓冲：后台读取线程持续写入，主调用方在结束时快照。
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private var data = Data()

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if data.count < maxBytes {
                let remaining = maxBytes - data.count
                data.append(chunk.prefix(remaining))
            }
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    func moeMailURL(path: String) -> URL? {
        guard let base = URL(string: state.settings.moeMailBaseURL) else { return nil }
        return URL(string: path, relativeTo: base)
    }

    func moeMailRequest(url: URL, apiKey: String, method: String = "GET", body: Data? = nil, timeoutInterval: TimeInterval = 15) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // 必须显式超时：轮询路径总窗口只有约 101 秒，一次请求挂起（默认 60s）就会吃掉整个窗口。
        request.timeoutInterval = timeoutInterval
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

    func parseMoeMailEmails(from data: Data) -> [MoeMailEmail] {
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

    func parseMoeMailMessages(from data: Data) -> [MoeMailMessage] {
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

    func collectDictionaries(from object: Any) -> [[String: Any]] {
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

    func stringValue(_ dictionary: [String: Any], keys: [String]) -> String {
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

    func summarize(_ dictionary: [String: Any]) -> String {
        dictionary
            .prefix(4)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "  ")
    }

    func extractDomains(from data: Data) -> [String] {
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

    func looksLikeDomain(_ value: String) -> Bool {
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

extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
