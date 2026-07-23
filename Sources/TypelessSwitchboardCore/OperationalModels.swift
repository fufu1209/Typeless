import Foundation
import CryptoKit

public struct OperationalImportedAccount: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var domain: String
    public var role: String
    public var typelessUsername: String?
    public var notes: String

    public init(name: String, email: String, domain: String, role: String, typelessUsername: String?, notes: String) {
        self.name = name
        self.email = email
        self.domain = domain
        self.role = role
        self.typelessUsername = typelessUsername
        self.notes = notes
    }
}

public struct TokenSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var accountEmail: String
    public var accessTokenFingerprint: String?
    public var refreshTokenFingerprint: String?
    public var discoveredKeys: [String]
    public var importedAt: Date

    public init(
        id: UUID = UUID(),
        accountEmail: String,
        accessTokenFingerprint: String?,
        refreshTokenFingerprint: String?,
        discoveredKeys: [String],
        importedAt: Date = Date()
    ) {
        self.id = id
        self.accountEmail = accountEmail
        self.accessTokenFingerprint = accessTokenFingerprint
        self.refreshTokenFingerprint = refreshTokenFingerprint
        self.discoveredKeys = discoveredKeys
        self.importedAt = importedAt
    }
}

public struct ToolkitImportResult: Codable, Equatable, Sendable {
    public var account: OperationalImportedAccount
    public var tokenSummary: TokenSummary?

    public init(account: OperationalImportedAccount, tokenSummary: TokenSummary?) {
        self.account = account
        self.tokenSummary = tokenSummary
    }
}

public enum ToolkitAccountImporter {
    public static func importableAccount(from raw: [String: Any], existingDomains: [String]) -> ToolkitImportResult {
        let email = string(raw, keys: ["email", "mail", "address"])
        let nickname = string(raw, keys: ["nickname", "name", "display_name"])
            .ifEmpty(email.components(separatedBy: "@").first ?? "toolkit 账号")
        let userID = string(raw, keys: ["user_id", "uid", "id"])
        let role = string(raw, keys: ["role"]).ifEmpty("free")
        let domain = (email.contains("@") ? (email.components(separatedBy: "@").last ?? "") : "")
            .ifEmpty(existingDomains.first ?? "")

        let accessToken = string(raw, keys: ["token", "access_token", "accessToken", "auth_token"])
        let refreshToken = string(raw, keys: ["refresh_token", "refreshToken"])
        let discovered = [
            accessToken.isEmpty ? nil : "token",
            refreshToken.isEmpty ? nil : "refresh_token"
        ].compactMap { $0 }

        let account = OperationalImportedAccount(
            name: nickname,
            email: email,
            domain: domain,
            role: role,
            typelessUsername: userID.nilIfEmpty,
            notes: discovered.isEmpty
                ? "从 typeless-toolkit 导入；未发现 token 字段，等待兜底确认"
                : "从 typeless-toolkit 导入；已记录 token 指纹，未保存明文 token"
        )

        let summary: TokenSummary? = discovered.isEmpty ? nil : TokenSummary(
            accountEmail: email,
            accessTokenFingerprint: accessToken.nilIfEmpty.map(fingerprint),
            refreshTokenFingerprint: refreshToken.nilIfEmpty.map(fingerprint),
            discoveredKeys: discovered
        )

        return ToolkitImportResult(account: account, tokenSummary: summary)
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String {
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

    private static func fingerprint(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(String(hex.prefix(16)))"
    }
}

public struct SnapshotFile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { path }
    public var path: String
    public var byteCount: Int64
    public var modifiedAt: Date

    public init(path: String, byteCount: Int64, modifiedAt: Date) {
        self.path = path
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct LoginSnapshotManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var sourcePath: String
    public var createdAt: Date
    public var files: [SnapshotFile]
    public var includesSensitiveContents: Bool
    public var summary: String

    public init(
        id: UUID = UUID(),
        sourcePath: String,
        createdAt: Date = Date(),
        files: [SnapshotFile],
        includesSensitiveContents: Bool,
        summary: String
    ) {
        self.id = id
        self.sourcePath = sourcePath
        self.createdAt = createdAt
        self.files = files
        self.includesSensitiveContents = includesSensitiveContents
        self.summary = summary
    }

    public static func make(sourcePath: String, files: [SnapshotFile], includeSensitiveContents: Bool) -> LoginSnapshotManifest {
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.byteCount }
        let summary = "登录态快照：\(includeSensitiveContents ? "包含文件内容" : "仅保存清单")；文件 \(files.count) 个；合计 \(totalBytes) bytes；来源 \(sourcePath)"
        return LoginSnapshotManifest(
            sourcePath: sourcePath,
            files: files.sorted { $0.path < $1.path },
            includesSensitiveContents: includeSensitiveContents,
            summary: summary
        )
    }

    public var markdown: String {
        var lines = [
            "# Typeless 登录态快照清单",
            "",
            "来源：\(sourcePath)",
            "生成时间：\(createdAt)",
            "模式：\(includesSensitiveContents ? "包含文件内容" : "仅保存清单，不含 Cookie / token / LocalStorage 明文")",
            "文件数量：\(files.count)",
            ""
        ]
        lines += files.map { "- \($0.path) — \($0.byteCount) bytes — \($0.modifiedAt)" }
        return lines.joined(separator: "\n")
    }
}

public struct DeviceInfoReport: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var markdown: String

    public init(id: UUID = UUID(), capturedAt: Date = Date(), markdown: String) {
        self.id = id
        self.capturedAt = capturedAt
        self.markdown = markdown
    }

    public static func make(
        hostName: String,
        osVersion: String,
        modelIdentifier: String,
        appPath: String,
        loginDataPath: String,
        cachePath: String
    ) -> DeviceInfoReport {
        let markdown = [
            "# Typeless 设备信息报告",
            "",
            "主机名：\(hostName)",
            "系统版本：\(osVersion)",
            "设备型号：\(modelIdentifier)",
            "Typeless App：\(appPath)",
            "登录态目录：\(loginDataPath)",
            "缓存目录：\(cachePath)",
            "",
            "用途：用于本机排障、备份核验和手动交接。"
        ].joined(separator: "\n")
        return DeviceInfoReport(markdown: markdown)
    }
}

public struct RegistrationCandidate: Codable, Equatable, Sendable {
    public var displayName: String
    public var username: String
    public var email: String
    public var domain: String
    public var passwordHint: String

    public init(displayName: String, username: String, email: String, domain: String, passwordHint: String) {
        self.displayName = displayName
        self.username = username
        self.email = email
        self.domain = domain
        self.passwordHint = passwordHint
    }
}

public struct RegistrationPreparationPlan: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var email: String
    public var username: String
    public var registrationURL: String
    public var steps: [String]
    public var createdAt: Date

    public init(id: UUID = UUID(), email: String, username: String, registrationURL: String, steps: [String], createdAt: Date = Date()) {
        self.id = id
        self.email = email
        self.username = username
        self.registrationURL = registrationURL
        self.steps = steps
        self.createdAt = createdAt
    }

    public static func make(candidate: RegistrationCandidate, typelessURL: String) -> RegistrationPreparationPlan {
        RegistrationPreparationPlan(
            email: candidate.email,
            username: candidate.username,
            registrationURL: typelessURL,
            steps: [
                "复制邮箱并打开注册页",
                "填写用户名、邮箱和 Keychain 中的强密码",
                "工具自动轮询邮箱验证码并尝试提交",
                "页面结构变化时保留验证码和资料供手动兜底",
                "浏览器结果证明完成后进入已确认可用池"
            ]
        )
    }

    public var markdown: String {
        var lines = [
            "# Typeless 注册准备包",
            "",
            "邮箱：\(email)",
            "用户名：\(username)",
            "注册入口：\(registrationURL)",
            "生成时间：\(createdAt)",
            "",
            "## 步骤"
        ]
        lines += steps.enumerated().map { index, step in "\(index + 1). \(step)" }
        return lines.joined(separator: "\n")
    }
}

public enum RegistrationAutomationStatus: String, Codable, Equatable, Sendable {
    case idle
    case running
    case waitingForCode
    case codeFound
    case completed
    case needsAttention
    case failed

    public var title: String {
        switch self {
        case .idle: "未开始"
        case .running: "自动化运行中"
        case .waitingForCode: "等待验证码"
        case .codeFound: "已提取验证码"
        case .completed: "已完成"
        case .needsAttention: "待兜底确认"
        case .failed: "失败"
        }
    }
}

public enum VerificationCodeExtractor {
    public static func extract(from text: String) -> String? {
        let lower = text.lowercased()
        let hasCodeContext = [
            "verification", "verify", "code", "signing in", "login", "typeless",
            "验证码", "校验码", "动态码", "确认码", "登录", "注册"
        ].contains { lower.contains($0.lowercased()) }
        guard hasCodeContext else { return nil }

        let patterns = [
            #"(?i)(?:code|verification|verify|验证码|校验码|动态码|确认码)[^\d]{0,20}(\d(?:[\s-]?\d){3,7})"#,
            #"(?i)(\d(?:[\s-]?\d){3,7})[^\d]{0,20}(?:code|verification|验证码|校验码|动态码|确认码)"#,
            #"(?i)(?:use|输入|填写|使用)[^\d]{0,20}(\d(?:[\s-]?\d){3,7})"#
        ]

        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: text) {
                return match
            }
        }
        return nil
    }

    public static func extract(from fields: [String]) -> String? {
        extract(from: fields.joined(separator: "\n"))
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return normalizeCode(String(text[captureRange]))
    }

    private static func normalizeCode(_ value: String) -> String? {
        let digits = value.filter(\.isNumber)
        guard (4...8).contains(digits.count) else { return nil }
        return String(digits)
    }
}

public enum RegistrationAutomationTiming {
    public static let verificationBridgeWaitSeconds: Int = 90
    public static let moeMailPollingDelayScheduleSeconds: [UInt64] = [
        1, 1, 2, 2,
        3, 3,
        5, 5, 5,
        8, 8, 8,
        10, 10, 10, 10, 10
    ]
    public static let moeMailPollingAttempts: Int = moeMailPollingDelayScheduleSeconds.count + 1
    public static let moeMailPollingDelaySeconds: UInt64 = 5

    public static var moeMailPollingWindowSeconds: Int {
        moeMailPollingDelayScheduleSeconds.reduce(0) { $0 + Int($1) }
    }

    public static func moeMailPollingDelaySeconds(afterAttempt attempt: Int) -> UInt64? {
        guard attempt > 0, attempt <= moeMailPollingDelayScheduleSeconds.count else {
            return nil
        }
        return moeMailPollingDelayScheduleSeconds[attempt - 1]
    }
}

public struct MacPermissionChecklistItem: Codable, Equatable, Sendable {
    public var title: String
    public var detail: String
    public var settingsPaneIdentifier: String?
    public var isRequiredForOneClickSwitch: Bool

    public init(
        title: String,
        detail: String,
        settingsPaneIdentifier: String?,
        isRequiredForOneClickSwitch: Bool
    ) {
        self.title = title
        self.detail = detail
        self.settingsPaneIdentifier = settingsPaneIdentifier
        self.isRequiredForOneClickSwitch = isRequiredForOneClickSwitch
    }

    public var settingsURLString: String? {
        guard let settingsPaneIdentifier else { return nil }
        return "x-apple.systempreferences:com.apple.preference.security?\(settingsPaneIdentifier)"
    }
}

public enum MacPermissionChecklist {
    public static let recommendedItems: [MacPermissionChecklistItem] = [
        MacPermissionChecklistItem(
            title: "辅助功能 Accessibility",
            detail: "允许 TypelessSwitchboard 控制 Google Chrome、System Events 和 Typeless.app，才能自动点弹窗、退出旧账号并完成桌面端交接。",
            settingsPaneIdentifier: "Privacy_Accessibility",
            isRequiredForOneClickSwitch: true
        ),
        MacPermissionChecklistItem(
            title: "自动化 Automation / Apple Events",
            detail: "允许 TypelessSwitchboard 控制 Google Chrome、System Events、Typeless.app；首次运行 macOS 会弹出授权。",
            settingsPaneIdentifier: "Privacy_Automation",
            isRequiredForOneClickSwitch: true
        ),
        MacPermissionChecklistItem(
            title: "Google Chrome 外部协议",
            detail: "Chrome 出现“要打开 Typeless.app 吗？”时勾选“始终允许 www.typeless.com 在关联的应用中打开此类链接”，后续一键换号会更快。",
            settingsPaneIdentifier: nil,
            isRequiredForOneClickSwitch: true
        ),
        MacPermissionChecklistItem(
            title: "麦克风 Microphone",
            detail: "给 Typeless.app 打开麦克风权限，保证新账号切入后可直接录音/转写。",
            settingsPaneIdentifier: "Privacy_Microphone",
            isRequiredForOneClickSwitch: true
        ),
        MacPermissionChecklistItem(
            title: "输入监听 Input Monitoring",
            detail: "给 Typeless.app 打开输入监听权限，保证全局快捷键、Fn 键和后台唤起可用。",
            settingsPaneIdentifier: "Privacy_ListenEvent",
            isRequiredForOneClickSwitch: true
        ),
        MacPermissionChecklistItem(
            title: "屏幕录制 Screen Recording",
            detail: "给 Typeless.app 打开屏幕录制权限，保证浮窗、上下文识别和引导步骤不被权限卡住。",
            settingsPaneIdentifier: "Privacy_ScreenCapture",
            isRequiredForOneClickSwitch: true
        ),
        MacPermissionChecklistItem(
            title: "通知 Notifications",
            detail: "给 Typeless.app 打开通知权限，方便接收登录、转写和后台状态提醒。",
            settingsPaneIdentifier: "Privacy_Notifications",
            isRequiredForOneClickSwitch: false
        ),
        MacPermissionChecklistItem(
            title: "钥匙串 Keychain",
            detail: "允许 TypelessSwitchboard 读取 MoeMail API Key 并保存新账号强密码；密钥不会写进项目文件。",
            settingsPaneIdentifier: nil,
            isRequiredForOneClickSwitch: true
        )
    ]

    public static var markdown: String {
        var lines = [
            "# Typeless 一键换号 macOS 权限清单",
            "",
            "需要打开的权限："
        ]
        for item in recommendedItems {
            let required = item.isRequiredForOneClickSwitch ? "必开" : "建议"
            if let settingsURLString = item.settingsURLString {
                lines.append("- 【\(required)】\(item.title)：\(item.detail)（系统设置：\(settingsURLString)）")
            } else {
                lines.append("- 【\(required)】\(item.title)：\(item.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public struct BrowserRegistrationAutomationInput: Codable, Equatable, Sendable {
    public var registrationURL: String
    public var email: String
    public var username: String
    public var password: String
    public var verificationCode: String?
    public var verificationCodeFilePath: String?
    public var automationResultFilePath: String?
    public var browserProfileDirectoryPath: String?
    public var clearBrowserProfileBeforeRun: Bool
    public var passwordEnvironmentVariable: String?
    public var headless: Bool

    public init(
        registrationURL: String,
        email: String,
        username: String,
        password: String,
        verificationCode: String? = nil,
        verificationCodeFilePath: String? = nil,
        automationResultFilePath: String? = nil,
        browserProfileDirectoryPath: String? = nil,
        clearBrowserProfileBeforeRun: Bool = false,
        passwordEnvironmentVariable: String? = nil,
        headless: Bool = false
    ) {
        self.registrationURL = registrationURL
        self.email = email
        self.username = username
        self.password = password
        self.verificationCode = verificationCode
        self.verificationCodeFilePath = verificationCodeFilePath
        self.automationResultFilePath = automationResultFilePath
        self.browserProfileDirectoryPath = browserProfileDirectoryPath
        self.clearBrowserProfileBeforeRun = clearBrowserProfileBeforeRun
        self.passwordEnvironmentVariable = passwordEnvironmentVariable
        self.headless = headless
    }
}

public struct BrowserSessionAutomationInput: Codable, Equatable, Sendable {
    public var targetURL: String
    public var browserProfileDirectoryPath: String
    public var headless: Bool

    public init(targetURL: String, browserProfileDirectoryPath: String, headless: Bool = false) {
        self.targetURL = targetURL
        self.browserProfileDirectoryPath = browserProfileDirectoryPath
        self.headless = headless
    }
}

public enum BrowserAutomationScriptBuilder {
    public static func makeOpenSessionScript(input: BrowserSessionAutomationInput) -> String {
        let targetURL = jsString(input.targetURL)
        let browserProfileDirectoryPath = jsString(input.browserProfileDirectoryPath)
        let headless = input.headless ? "true" : "false"

        return """
        const { chromium } = require('playwright');
        const fs = require('fs');
        const { execFileSync } = require('child_process');

        const targetURL = \(targetURL);
        const browserProfileDirectoryPath = \(browserProfileDirectoryPath);
        let typelessProtocolOpened = false;

        function openExternalTypelessProtocolURL(url) {
          if (!url || !url.startsWith('typeless://')) return false;
          if (typelessProtocolOpened) return true;
          typelessProtocolOpened = true;
          try {
            execFileSync('/usr/bin/open', [url], { stdio: 'ignore' });
            console.log('Typeless desktop protocol handoff opened');
            return true;
          } catch (error) {
            console.error('Typeless desktop protocol handoff failed: ' + error.message);
            return false;
          }
        }

        (async () => {
          if (!browserProfileDirectoryPath || browserProfileDirectoryPath.length === 0) {
            throw new Error('Missing browser profile directory path');
          }
          fs.mkdirSync(browserProfileDirectoryPath, { recursive: true });
          const context = await chromium.launchPersistentContext(browserProfileDirectoryPath, { headless: \(headless) });
          const page = context.pages()[0] || await context.newPage();
          page.on('request', request => {
            openExternalTypelessProtocolURL(request.url());
          });
          await page.goto(targetURL, { waitUntil: 'domcontentloaded' });
          async function openTypelessDesktopAppFromHandoff() {
            const candidates = [
              'button:has-text("Open the desktop app")',
              '[role="button"]:has-text("Open the desktop app")',
              'button:has-text("打开桌面应用")',
              '[role="button"]:has-text("打开桌面应用")'
            ];
            for (const selector of candidates) {
              const locator = page.locator(selector).first();
              try {
                if (await locator.isVisible({ timeout: 3000 })) {
                  await locator.click({ timeout: 3000 });
                  return selector;
                }
              } catch (error) {}
            }
            return null;
          }
          await page.waitForLoadState('domcontentloaded', { timeout: 10000 }).catch(() => {});
          await page.waitForTimeout(1000);
          await openTypelessDesktopAppFromHandoff();
          await page.waitForTimeout(3000);
          console.log('Typeless retained browser session opened at ' + targetURL);
          await context.waitForEvent('close');
        })().catch(error => {
          console.error(error);
          process.exit(1);
        });
        """
    }

    public static func makeRegistrationScript(input: BrowserRegistrationAutomationInput) -> String {
        let registrationURL = jsString(input.registrationURL)
        let email = jsString(input.email)
        let username = jsString(input.username)
        let password = jsString(input.passwordEnvironmentVariable == nil ? input.password : "")
        let passwordEnvironmentVariable = input.passwordEnvironmentVariable ?? ""
        let verificationCode = jsString(input.verificationCode ?? "")
        let verificationCodeFilePath = jsString(input.verificationCodeFilePath ?? "")
        let automationResultFilePath = jsString(input.automationResultFilePath ?? "")
        let browserProfileDirectoryPath = jsString(input.browserProfileDirectoryPath ?? "")
        let clearBrowserProfileBeforeRun = input.clearBrowserProfileBeforeRun ? "true" : "false"
        let headless = input.headless ? "true" : "false"
        let usesPersistentBrowserProfile = !(input.browserProfileDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let browserOpenScript = usesPersistentBrowserProfile
            ? """
          if (clearBrowserProfileBeforeRun && browserProfileDirectoryPath.length > 0) {
            fs.rmSync(browserProfileDirectoryPath, { recursive: true, force: true });
          }
          if (browserProfileDirectoryPath.length > 0) {
            fs.mkdirSync(browserProfileDirectoryPath, { recursive: true });
          }
          const context = await chromium.launchPersistentContext(browserProfileDirectoryPath, { headless: \(headless) });
          const page = await context.newPage();
        """
            : """
          const browser = await chromium.launch({ headless: \(headless) });
          const page = await browser.newPage();
        """
        let browserCloseScript = usesPersistentBrowserProfile
            ? "await context.close();"
            : "await browser.close();"

        return """
        const { chromium } = require('playwright');
        const fs = require('fs');

        const registrationURL = \(registrationURL);
        const email = \(email);
        const username = \(username);
        const password = \(passwordEnvironmentVariable.isEmpty ? password : "process.env.\(passwordEnvironmentVariable) || ''");
        const verificationCode = \(verificationCode);
        const verificationCodeFilePath = \(verificationCodeFilePath);
        const automationResultFilePath = \(automationResultFilePath);
        const browserProfileDirectoryPath = \(browserProfileDirectoryPath);
        const clearBrowserProfileBeforeRun = \(clearBrowserProfileBeforeRun);
        let detectedPreviousAccountEmail = '';

        async function fillFirst(page, selectors, value) {
          for (const selector of selectors) {
            const locator = page.locator(selector);
            const count = await locator.count();
            for (let index = 0; index < count; index++) {
              const candidate = locator.nth(index);
              try {
                if (!(await candidate.isVisible({ timeout: 300 }))) continue;
                if (!(await candidate.isEditable({ timeout: 300 }))) continue;
                await candidate.fill(value, { timeout: 1500 });
                return selector;
              } catch (error) {}
            }
          }
          return null;
        }

        async function fillAll(page, selectors, value) {
          let filled = 0;
          for (const selector of selectors) {
            const locator = page.locator(selector);
            const count = await locator.count();
            for (let index = 0; index < count; index++) {
              try {
                await locator.nth(index).fill(value, { timeout: 1500 });
                filled += 1;
              } catch (error) {}
            }
          }
          return filled;
        }

        async function fillFirstByLabel(page, labels, value) {
          for (const label of labels) {
            const locator = page.getByLabel(label, { exact: false }).first();
            if (await locator.count()) {
              try {
                await locator.fill(value, { timeout: 1500 });
                return label;
              } catch (error) {}
            }
          }
          return null;
        }

        async function fillField(page, selectors, labels, value) {
          return (await fillFirst(page, selectors, value)) ||
            (await fillFirstByLabel(page, labels, value));
        }

        async function fillPasswordField(page, selectors, labels, value) {
          const filled = await fillAll(page, selectors, value);
          if (filled > 0) return filled;
          return await fillFirstByLabel(page, labels, value) ? 1 : 0;
        }

        async function fillVerificationCode(page, code) {
          const splitInputs = page.locator([
            'input[autocomplete="one-time-code"]',
            'input[inputmode="numeric"]',
            'input[maxlength="1"]',
            'input[name*="otp" i]',
            'input[name*="code" i]',
            'input[id*="otp" i]',
            'input[id*="code" i]',
            'input[data-testid*="otp" i]',
            'input[data-testid*="code" i]',
            'input[data-testid*="verification" i]',
            'input[data-cy*="otp" i]',
            'input[data-cy*="code" i]',
            'input[data-cy*="verification" i]',
            'input[aria-label*="digit" i]',
            'input[aria-label*="code" i]',
            'input[aria-label*="verification" i]',
            'input[aria-label*="验证码" i]'
          ].join(', '));
          const splitCount = await splitInputs.count();
          if (splitCount >= code.length) {
            let filledDigits = 0;
            for (let index = 0; index < code.length; index++) {
              try {
                await splitInputs.nth(index).fill(code[index], { timeout: 1500 });
                filledDigits += 1;
              } catch (error) {}
            }
            if (filledDigits === code.length) return 'split-code-inputs';
          }

          return await fillField(page, [
            'input[name="code"]',
            'input[name="otp"]',
            'input[name*="code" i]',
            'input[name*="verification" i]',
            'input[name*="otp" i]',
            'input[id*="code" i]',
            'input[id*="verification" i]',
            'input[id*="otp" i]',
            'input[data-testid*="code" i]',
            'input[data-testid*="verification" i]',
            'input[data-testid*="otp" i]',
            'input[data-testid*="pin" i]',
            'input[data-cy*="code" i]',
            'input[data-cy*="verification" i]',
            'input[data-cy*="otp" i]',
            'input[data-cy*="pin" i]',
            'input[autocomplete="one-time-code"]',
            'input[inputmode="numeric"]',
            'input[type="tel"]',
            'input[aria-label*="code" i]',
            'input[aria-label*="pin" i]',
            'input[aria-label*="security" i]',
            'input[aria-label*="verification" i]',
            'input[placeholder*="code" i]',
            'input[placeholder*="pin" i]',
            'input[placeholder*="security" i]',
            'input[placeholder*="verification" i]',
            'input[placeholder*="验证码" i]'
          ], [
            'Verification code',
            'Security code',
            'One-time code',
            'Code',
            'PIN',
            '验证码',
            '校验码',
            '动态码'
          ], code);
        }

        async function clickFirst(page, selectors) {
          for (const selector of selectors) {
            const locator = page.locator(selector);
            const count = await locator.count();
            for (let index = 0; index < count; index++) {
              const candidate = locator.nth(index);
              try {
                if (!(await candidate.isVisible({ timeout: 300 }))) continue;
                await candidate.click({ timeout: 1500 });
                return selector;
              } catch (error) {}
            }
          }
          return null;
        }

        async function dismissBlockingBanners(page) {
          return await clickFirst(page, [
            'button:has-text("Accept all")',
            'button:has-text("Accept")',
            'button:has-text("Agree")',
            'button:has-text("Allow all")',
            'button:has-text("Allow")',
            'button:has-text("Got it")',
            'button:has-text("OK")',
            'button:has-text("Close")',
            '[role="button"]:has-text("Accept all")',
            '[role="button"]:has-text("Accept")',
            '[role="button"]:has-text("Agree")',
            '[role="button"]:has-text("Allow all")',
            '[role="button"]:has-text("Allow")',
            '[role="button"]:has-text("Got it")',
            '[role="button"]:has-text("OK")',
            '[role="button"]:has-text("Close")',
            'button:has-text("接受全部")',
            'button:has-text("接受")',
            'button:has-text("同意")',
            'button:has-text("允许")',
            'button:has-text("知道了")',
            'button:has-text("关闭")',
            '[role="button"]:has-text("接受全部")',
            '[role="button"]:has-text("接受")',
            '[role="button"]:has-text("同意")',
            '[role="button"]:has-text("允许")',
            '[role="button"]:has-text("知道了")',
            '[role="button"]:has-text("关闭")'
          ]);
        }

        async function logoutIfSignedIn(page) {
          const logoutSelectors = [
            'button:has-text("登出")',
            'button:has-text("退出")',
            'button:has-text("注销")',
            'button:has-text("Log out")',
            'button:has-text("Logout")',
            'button:has-text("Sign out")',
            'a:has-text("登出")',
            'a:has-text("退出")',
            'a:has-text("注销")',
            'a:has-text("Log out")',
            'a:has-text("Logout")',
            'a:has-text("Sign out")',
            '[role="button"]:has-text("登出")',
            '[role="button"]:has-text("退出")',
            '[role="button"]:has-text("注销")',
            '[role="button"]:has-text("Log out")',
            '[role="button"]:has-text("Logout")',
            '[role="button"]:has-text("Sign out")',
            '[role="menuitem"]:has-text("登出")',
            '[role="menuitem"]:has-text("退出")',
            '[role="menuitem"]:has-text("注销")',
            '[role="menuitem"]:has-text("Log out")',
            '[role="menuitem"]:has-text("Logout")',
            '[role="menuitem"]:has-text("Sign out")'
          ];
          let clicked = await clickFirst(page, logoutSelectors);
          if (clicked) {
            await page.waitForLoadState('domcontentloaded', { timeout: 8000 }).catch(() => {});
            await page.waitForTimeout(800);
            return clicked;
          }

          const menuSelectors = [
            'button[aria-haspopup="menu"]',
            '[role="button"][aria-haspopup="menu"]',
            'button[aria-label*="account" i]',
            'button[aria-label*="user" i]',
            'button[aria-label*="profile" i]',
            '[role="button"][aria-label*="account" i]',
            '[role="button"][aria-label*="user" i]',
            '[role="button"][aria-label*="profile" i]',
            'button:has-text("账户")',
            'button:has-text("账号")'
          ];
          const openedMenu = await clickFirst(page, menuSelectors);
          if (!openedMenu) return null;
          await page.waitForTimeout(500);
          clicked = await clickFirst(page, logoutSelectors);
          if (clicked) {
            await page.waitForLoadState('domcontentloaded', { timeout: 8000 }).catch(() => {});
            await page.waitForTimeout(800);
          }
          return clicked;
        }

        async function detectVisibleEmail(page) {
          try {
            const text = await page.locator('body').innerText({ timeout: 1000 });
            const match = text.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i);
            return match ? match[0] : '';
          } catch (error) {
            return '';
          }
        }

        async function hasRegistrationInputs(page) {
          const emailCount = await page.locator('input[name="email"], input[type="email"], input[autocomplete="email"], input[placeholder*="email" i], input[placeholder*="邮箱" i], input[data-testid*="email" i], input[data-testid*="mail" i], input[data-cy*="email" i], input[data-cy*="mail" i]').count();
          const passwordCount = await page.locator('input[name="password"], input[type="password"], input[autocomplete="new-password"], input[placeholder*="password" i], input[placeholder*="密码" i], input[data-testid*="password" i], input[data-testid*="passwd" i], input[data-cy*="password" i], input[data-cy*="passwd" i]').count();
          return emailCount > 0 && passwordCount > 0;
        }

        async function ensureRegistrationForm(page) {
          if (await hasRegistrationInputs(page)) return 'already-on-form';

          const entrySelectors = [
            'a:has-text("Sign up")',
            'a:has-text("Signup")',
            'a:has-text("Register")',
            'a:has-text("Create account")',
            'a:has-text("Get started")',
            'a:has-text("Start free")',
            'a:has-text("Try for free")',
            'a:has-text("注册")',
            'a:has-text("创建账号")',
            'a:has-text("开始使用")',
            'button[data-testid="typeless--auth--email-sign-in"]',
            '[role="button"][data-testid="typeless--auth--email-sign-in"]',
            'button:has-text("Sign up")',
            'button:has-text("Register")',
            'button:has-text("Create account")',
            'button:has-text("Continue with email")',
            'button:has-text("Get started")',
            'button:has-text("Start free")',
            'button:has-text("Try for free")',
            'button:has-text("注册")',
            'button:has-text("创建账号")',
            'button:has-text("开始使用")',
            '[role="button"]:has-text("Continue with email")',
            '[role="button"]:has-text("Sign up")',
            '[role="button"]:has-text("Register")',
            '[role="button"]:has-text("Create account")',
            '[role="button"]:has-text("Get started")',
            '[role="button"]:has-text("Start free")',
            '[role="button"]:has-text("Try for free")',
            '[role="button"]:has-text("注册")',
            '[role="button"]:has-text("创建账号")',
            '[role="button"]:has-text("开始使用")'
          ];

          for (const selector of entrySelectors) {
            const clicked = await clickFirst(page, [selector]);
            if (clicked) {
              await page.waitForLoadState('domcontentloaded', { timeout: 8000 }).catch(() => {});
              await page.waitForTimeout(1000);
              if (await hasRegistrationInputs(page)) return clicked;
            }
          }

          return 'registration-form-not-found';
        }

        async function requestVerificationCode(page) {
          const sendCodeSelectors = [
            'button:has-text("Send code")',
            'button:has-text("Get code")',
            'button:has-text("Email code")',
            'button:has-text("Verify email")',
            'button:has-text("Continue with email")',
            'button[data-testid*="send" i]',
            'button[data-testid*="code" i]',
            'button[data-testid*="verify" i]',
            'button[data-cy*="send" i]',
            'button[data-cy*="code" i]',
            'button[data-cy*="verify" i]',
            'a:has-text("Send code")',
            'a:has-text("Get code")',
            'a:has-text("Email code")',
            'a:has-text("Verify email")',
            'a:has-text("Continue with email")',
            'a[data-testid*="send" i]',
            'a[data-testid*="code" i]',
            'a[data-testid*="verify" i]',
            'a[data-cy*="send" i]',
            'a[data-cy*="code" i]',
            'a[data-cy*="verify" i]',
            'button:has-text("发送验证码")',
            'button:has-text("获取验证码")',
            'button:has-text("发送邮件")',
            'button:has-text("验证邮箱")',
            'a:has-text("发送验证码")',
            'a:has-text("获取验证码")',
            'a:has-text("发送邮件")',
            'a:has-text("验证邮箱")',
            'input[type="button"][value*="Send code" i]',
            'input[type="button"][value*="Get code" i]',
            'input[type="button"][value*="Email code" i]',
            'input[type="button"][value*="Verify email" i]',
            'input[type="submit"][value*="Send code" i]',
            'input[type="submit"][value*="Get code" i]',
            'input[type="submit"][value*="Email code" i]',
            'input[type="submit"][value*="Verify email" i]',
            'input[type="button"][value*="发送验证码" i]',
            'input[type="button"][value*="获取验证码" i]',
            'input[type="submit"][value*="发送验证码" i]',
            'input[type="submit"][value*="获取验证码" i]',
            '[role="button"]:has-text("Send code")',
            '[role="button"]:has-text("Get code")',
            '[role="button"]:has-text("Email code")',
            '[role="button"]:has-text("Verify email")',
            '[role="button"]:has-text("Continue with email")',
            '[role="button"][data-testid*="send" i]',
            '[role="button"][data-testid*="code" i]',
            '[role="button"][data-testid*="verify" i]',
            '[role="button"][data-cy*="send" i]',
            '[role="button"][data-cy*="code" i]',
            '[role="button"][data-cy*="verify" i]',
            '[role="button"]:has-text("发送验证码")',
            '[role="button"]:has-text("获取验证码")',
            '[role="button"]:has-text("发送邮件")',
            '[role="button"]:has-text("验证邮箱")'
          ];
          const sent = await clickFirst(page, sendCodeSelectors);
          if (sent) return sent;
          await advanceRegistrationStep(page);
          return await clickFirst(page, sendCodeSelectors);
        }

        async function advanceRegistrationStep(page) {
          const clicked = await clickFirst(page, [
            'button:has-text("Continue")',
            'button:has-text("Continue with email")',
            'button:has-text("Next")',
            'button:has-text("Verify email")',
            'button[data-testid*="continue" i]',
            'button[data-testid*="next" i]',
            'button[data-testid*="verify" i]',
            'button[data-cy*="continue" i]',
            'button[data-cy*="next" i]',
            'button[data-cy*="verify" i]',
            'button:has-text("继续")',
            'button:has-text("下一步")',
            'button:has-text("验证邮箱")',
            'input[type="button"][value*="Continue" i]',
            'input[type="button"][value*="Next" i]',
            'input[type="button"][value*="Verify email" i]',
            'input[type="submit"][value*="Continue" i]',
            'input[type="submit"][value*="Next" i]',
            'input[type="submit"][value*="Verify email" i]',
            'input[type="button"][value*="继续" i]',
            'input[type="button"][value*="下一步" i]',
            'input[type="submit"][value*="继续" i]',
            'input[type="submit"][value*="下一步" i]',
            '[role="button"]:has-text("Continue")',
            '[role="button"]:has-text("Continue with email")',
            '[role="button"]:has-text("Next")',
            '[role="button"]:has-text("Verify email")',
            '[role="button"][data-testid*="continue" i]',
            '[role="button"][data-testid*="next" i]',
            '[role="button"][data-testid*="verify" i]',
            '[role="button"][data-cy*="continue" i]',
            '[role="button"][data-cy*="next" i]',
            '[role="button"][data-cy*="verify" i]',
            '[role="button"]:has-text("继续")',
            '[role="button"]:has-text("下一步")',
            '[role="button"]:has-text("验证邮箱")'
          ]);
          if (clicked) {
            await page.waitForLoadState('domcontentloaded', { timeout: 5000 }).catch(() => {});
            await page.waitForTimeout(500);
          }
          return clicked;
        }

        async function acceptRequiredAgreements(page) {
          const selectors = [
            'input[type="checkbox"][required]',
            'input[type="checkbox"][name*="terms" i]',
            'input[type="checkbox"][id*="terms" i]',
            'input[type="checkbox"][name*="privacy" i]',
            'input[type="checkbox"][id*="privacy" i]',
            'label:has-text("I agree") input[type="checkbox"]',
            'label:has-text("Terms") input[type="checkbox"]',
            'label:has-text("Privacy") input[type="checkbox"]',
            'label:has-text("同意") input[type="checkbox"]',
            'label:has-text("条款") input[type="checkbox"]',
            'label:has-text("隐私") input[type="checkbox"]'
          ];
          let checked = 0;
          for (const selector of selectors) {
            const locator = page.locator(selector);
            const count = await locator.count();
            for (let index = 0; index < count; index++) {
              const checkbox = locator.nth(index);
              try {
                if (!(await checkbox.isChecked({ timeout: 500 }))) {
                  await checkbox.check({ timeout: 1500 });
                }
                checked += 1;
              } catch (error) {}
            }
          }
          const roleSelectors = [
            '[role="checkbox"][aria-checked="false"]:has-text("I agree")',
            '[role="checkbox"][aria-checked="false"]:has-text("Terms")',
            '[role="checkbox"][aria-checked="false"]:has-text("Privacy")',
            '[role="checkbox"][aria-checked="false"]:has-text("同意")',
            '[role="checkbox"][aria-checked="false"]:has-text("条款")',
            '[role="checkbox"][aria-checked="false"]:has-text("隐私")'
          ];
          for (const selector of roleSelectors) {
            const locator = page.locator(selector);
            const count = await locator.count();
            for (let index = 0; index < count; index++) {
              try {
                await locator.nth(index).click({ timeout: 1500 });
                checked += 1;
              } catch (error) {}
            }
          }
          return checked;
        }

        async function submitRegistration(page) {
          const clicked = await clickFirst(page, [
            'button[type="submit"]',
            'button:has-text("Create account")',
            'button:has-text("Sign up")',
            'button:has-text("Register")',
            'button:has-text("Submit")',
            'button:has-text("Verify")',
            'button:has-text("Continue")',
            'button[data-testid*="create" i]',
            'button[data-testid*="register" i]',
            'button[data-testid*="submit" i]',
            'button[data-testid*="verify" i]',
            'button[data-cy*="create" i]',
            'button[data-cy*="register" i]',
            'button[data-cy*="submit" i]',
            'button[data-cy*="verify" i]',
            'a:has-text("Create account")',
            'a:has-text("Sign up")',
            'a:has-text("Register")',
            'a:has-text("Submit")',
            'a:has-text("Verify")',
            'a:has-text("Continue")',
            'a[data-testid*="create" i]',
            'a[data-testid*="register" i]',
            'a[data-testid*="submit" i]',
            'a[data-testid*="verify" i]',
            'a[data-cy*="create" i]',
            'a[data-cy*="register" i]',
            'a[data-cy*="submit" i]',
            'a[data-cy*="verify" i]',
            'button:has-text("创建账号")',
            'button:has-text("注册")',
            'button:has-text("提交")',
            'button:has-text("验证")',
            'button:has-text("完成")',
            'a:has-text("创建账号")',
            'a:has-text("注册")',
            'a:has-text("提交")',
            'a:has-text("验证")',
            'a:has-text("完成")',
            'input[type="submit"]',
            'input[type="button"][value*="Create account" i]',
            'input[type="button"][value*="Sign up" i]',
            'input[type="button"][value*="Register" i]',
            'input[type="button"][value*="Submit" i]',
            'input[type="button"][value*="Verify" i]',
            'input[type="submit"][value*="Create account" i]',
            'input[type="submit"][value*="Sign up" i]',
            'input[type="submit"][value*="Register" i]',
            'input[type="submit"][value*="Submit" i]',
            'input[type="submit"][value*="Verify" i]',
            'input[type="button"][value*="创建账号" i]',
            'input[type="button"][value*="注册" i]',
            'input[type="button"][value*="提交" i]',
            'input[type="button"][value*="验证" i]',
            'input[type="submit"][value*="创建账号" i]',
            'input[type="submit"][value*="注册" i]',
            'input[type="submit"][value*="提交" i]',
            'input[type="submit"][value*="验证" i]',
            '[role="button"]:has-text("Create account")',
            '[role="button"]:has-text("Sign up")',
            '[role="button"]:has-text("Register")',
            '[role="button"]:has-text("Submit")',
            '[role="button"]:has-text("Verify")',
            '[role="button"]:has-text("Continue")',
            '[role="button"][data-testid*="create" i]',
            '[role="button"][data-testid*="register" i]',
            '[role="button"][data-testid*="submit" i]',
            '[role="button"][data-testid*="verify" i]',
            '[role="button"][data-cy*="create" i]',
            '[role="button"][data-cy*="register" i]',
            '[role="button"][data-cy*="submit" i]',
            '[role="button"][data-cy*="verify" i]',
            '[role="button"]:has-text("创建账号")',
            '[role="button"]:has-text("注册")',
            '[role="button"]:has-text("提交")',
            '[role="button"]:has-text("验证")',
            '[role="button"]:has-text("完成")'
          ]);
          if (clicked) return clicked;
          try {
            await page.keyboard.press('Enter');
            return 'keyboard-enter';
          } catch (error) {}
          return null;
        }

        async function writeAutomationResult(page, status, detail) {
          if (!automationResultFilePath || automationResultFilePath.length === 0) return;
          const payload = {
            status,
            detail,
            url: page.url(),
            title: await page.title().catch(() => ''),
            detectedPreviousAccountEmail,
            timestamp: new Date().toISOString()
          };
          fs.writeFileSync(automationResultFilePath, JSON.stringify(payload, null, 2));
        }

        async function waitForPostSubmitOutcome(page, timeoutMs = 45000) {
          await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {});
          await page.waitForFunction(() => {
            const urlHaystack = window.location.href.toLowerCase();
            const textHaystack = [
              document.title,
              document.body ? document.body.innerText : ''
            ].join(' ').toLowerCase();
            const fullHaystack = [urlHaystack, textHaystack].join(' ');
            const positiveURLMarkers = ['dashboard', 'workspace', 'app.typeless', 'login/app/success'];
            const positiveTextMarkers = [
              'dashboard', 'workspace', 'welcome', 'home',
              'success', 'completed', 'complete', 'logged in', 'signed in',
              'all set', 'account created', 'account is ready', 'ready to go',
              'log in as', 'open the desktop app',
              '控制台', '工作台', '首页', '成功', '已登录'
            ];
            const blockingNegativeMarkers = [
              'verification failed', 'error', 'failed', 'failure', 'invalid',
              'captcha', 'turnstile', '验证失败', '错误', '失败'
            ];
            const pendingMarkers = [
              'creating workspace', 'creating account', 'loading', 'please wait',
              'processing', 'provisioning', '创建中', '处理中', '请稍候'
            ];
            if (pendingMarkers.some(marker => textHaystack.includes(marker))) {
              return false;
            }
            return positiveURLMarkers.some(marker => urlHaystack.includes(marker)) ||
              positiveTextMarkers.some(marker => textHaystack.includes(marker)) ||
              blockingNegativeMarkers.some(marker => fullHaystack.includes(marker));
          }, null, { timeout: timeoutMs }).catch(() => {});
        }

        async function refreshTypelessLoginHandoff(page) {
          const current = page.url().toLowerCase();
          if (!current.includes('typeless.com/login') || current.includes('login/app/success')) return;
          await page.waitForTimeout(3000);
          await page.reload({ waitUntil: 'domcontentloaded', timeout: 15000 }).catch(() => {});
          await waitForPostSubmitOutcome(page, 15000);
        }

        async function waitForVerificationCodeFile(path, timeoutMs = \(RegistrationAutomationTiming.verificationBridgeWaitSeconds * 1000)) {
          if (!path || path.length === 0) return '';
          const start = Date.now();
          while (Date.now() - start < timeoutMs) {
            if (fs.existsSync(path)) {
              const modifiedAt = fs.statSync(path).mtimeMs;
              const value = fs.readFileSync(path, 'utf8').trim();
              if (/^\\d{4,8}$/.test(value)) return value;
              if (value === 'NO_CODE' && modifiedAt >= start) return '';
            }
            await new Promise(resolve => setTimeout(resolve, 1000));
          }
          return '';
        }

        (async () => {
        \(browserOpenScript)
          try {
          await page.goto(registrationURL, { waitUntil: 'domcontentloaded' });
          await dismissBlockingBanners(page);
          detectedPreviousAccountEmail = await detectVisibleEmail(page);
          await logoutIfSignedIn(page);
          await page.goto(registrationURL, { waitUntil: 'domcontentloaded' }).catch(() => {});
          await dismissBlockingBanners(page);
          await ensureRegistrationForm(page);
          await dismissBlockingBanners(page);

          await fillField(page, [
            'input[name="email"]',
            'input[name*="email" i]',
            'input[name*="mail" i]',
            'input[id*="email" i]',
            'input[id*="mail" i]',
            'input[data-testid*="email" i]',
            'input[data-testid*="mail" i]',
            'input[data-cy*="email" i]',
            'input[data-cy*="mail" i]',
            'input[type="email"]',
            'input[autocomplete="email"]',
            'input[aria-label*="email" i]',
            'input[aria-label*="mail" i]',
            'input[placeholder*="email" i]',
            'input[placeholder*="邮箱" i]'
          ], ['Email address', 'Email', 'Mail', '邮箱', '电子邮箱'], email);

          await advanceRegistrationStep(page);

          await fillField(page, [
            'input[name="username"]',
            'input[name="name"]',
            'input[name*="username" i]',
            'input[name*="user" i]',
            'input[id*="username" i]',
            'input[id*="user" i]',
            'input[id*="display-name" i]',
            'input[data-testid*="username" i]',
            'input[data-testid*="user" i]',
            'input[data-testid*="display-name" i]',
            'input[data-testid*="name" i]',
            'input[data-cy*="username" i]',
            'input[data-cy*="user" i]',
            'input[data-cy*="display-name" i]',
            'input[data-cy*="name" i]',
            'input[autocomplete="username"]',
            'input[aria-label*="username" i]',
            'input[aria-label*="user" i]',
            'input[aria-label*="display name" i]',
            'input[placeholder*="username" i]',
            'input[placeholder*="用户名" i]',
            'input[placeholder*="昵称" i]'
          ], ['Username', 'User name', 'Display name', 'Name', '用户名', '昵称'], username);

          await fillPasswordField(page, [
            'input[name="password"]',
            'input[name*="password" i]',
            'input[name*="confirm" i]',
            'input[name*="repeat" i]',
            'input[id*="password" i]',
            'input[id*="confirm" i]',
            'input[id*="repeat" i]',
            'input[data-testid*="password" i]',
            'input[data-testid*="passwd" i]',
            'input[data-testid*="confirm" i]',
            'input[data-testid*="repeat" i]',
            'input[data-cy*="password" i]',
            'input[data-cy*="passwd" i]',
            'input[data-cy*="confirm" i]',
            'input[data-cy*="repeat" i]',
            'input[type="password"]',
            'input[autocomplete="new-password"]',
            'input[aria-label*="password" i]',
            'input[aria-label*="confirm" i]',
            'input[aria-label*="repeat" i]',
            'input[placeholder*="confirm" i]',
            'input[placeholder*="repeat" i]',
            'input[placeholder*="password" i]',
            'input[placeholder*="密码" i]'
            ], ['New password', 'Password', 'Confirm password', 'Repeat password', '密码', '确认密码'], password);

          let resolvedVerificationCode = verificationCode;
          if (resolvedVerificationCode.length === 0 && verificationCodeFilePath.length > 0) {
            await dismissBlockingBanners(page);
            await requestVerificationCode(page);
            resolvedVerificationCode = await waitForVerificationCodeFile(verificationCodeFilePath);
          }

          if (resolvedVerificationCode.length > 0) {
            await fillVerificationCode(page, resolvedVerificationCode);
          }

          await acceptRequiredAgreements(page);
          await dismissBlockingBanners(page);

          await submitRegistration(page);

          await waitForPostSubmitOutcome(page);
          await refreshTypelessLoginHandoff(page);
          await writeAutomationResult(page, 'submitted', 'registration form submitted or attempted');
          console.log('Typeless registration automation attempted for ' + email);
          } finally {
            \(browserCloseScript)
          }
        })().catch(error => {
          console.error(error);
          process.exit(1);
        });
        """
    }

    private static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }
}

public struct RegistrationAutomationResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var previousAccountID: UUID?
    public var previousAccountEmail: String?
    public var accountID: UUID?
    public var accountEmail: String
    public var username: String
    public var status: RegistrationAutomationStatus
    public var verificationCode: String?
    public var scriptPath: String?
    public var verificationCodeFilePath: String?
    public var browserResultFilePath: String?
    public var browserProfileDirectoryPath: String?
    public var passwordStoredInKeychain: Bool
    public var log: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        previousAccountID: UUID? = nil,
        previousAccountEmail: String? = nil,
        accountID: UUID? = nil,
        accountEmail: String,
        username: String,
        status: RegistrationAutomationStatus,
        verificationCode: String?,
        scriptPath: String?,
        verificationCodeFilePath: String? = nil,
        browserResultFilePath: String? = nil,
        browserProfileDirectoryPath: String? = nil,
        passwordStoredInKeychain: Bool,
        log: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.previousAccountID = previousAccountID
        self.previousAccountEmail = previousAccountEmail
        self.accountID = accountID
        self.accountEmail = accountEmail
        self.username = username
        self.status = status
        self.verificationCode = verificationCode
        self.scriptPath = scriptPath
        self.verificationCodeFilePath = verificationCodeFilePath
        self.browserResultFilePath = browserResultFilePath
        self.browserProfileDirectoryPath = browserProfileDirectoryPath
        self.passwordStoredInKeychain = passwordStoredInKeychain
        self.log = log
        self.createdAt = createdAt
    }

    public var markdown: String {
        var lines = [
            "# Typeless 自动注册结果",
            "",
            "状态：\(status.title)",
            "旧账号 ID：\(previousAccountID?.uuidString ?? "未记录")",
            "旧账号邮箱：\(previousAccountEmail ?? "未记录")",
            "账号 ID：\(accountID?.uuidString ?? "未记录")",
            "邮箱：\(accountEmail)",
            "用户名：\(username)",
            "验证码：\(verificationCode ?? "未提取")",
            "密码：\(passwordStoredInKeychain ? "密码已保存到 Keychain" : "未保存")",
            "脚本：\(scriptPath ?? "未生成")",
            "验证码桥接：\(verificationCodeFilePath ?? "未生成")",
            "浏览器结果：\(browserResultFilePath ?? "未生成")",
            "浏览器登录态目录：\(browserProfileDirectoryPath ?? "未生成")",
            "时间：\(createdAt)",
            "",
            "## 日志"
        ]
        lines += log.map { "- \($0)" }
        return lines.joined(separator: "\n")
    }

    public var canRetry: Bool {
        accountID != nil &&
        !(scriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) &&
        passwordStoredInKeychain
    }

    public var canOpenBrowserSession: Bool {
        !(browserProfileDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

public struct BrowserAutomationResultPayload: Codable, Equatable, Sendable {
    public var status: String
    public var detail: String
    public var url: String
    public var title: String
    public var detectedPreviousAccountEmail: String?
    public var timestamp: String

    public init(status: String, detail: String, url: String, title: String, detectedPreviousAccountEmail: String? = nil, timestamp: String) {
        self.status = status
        self.detail = detail
        self.url = url
        self.title = title
        self.detectedPreviousAccountEmail = detectedPreviousAccountEmail
        self.timestamp = timestamp
    }

    public var summary: String {
        "\(status)；\(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "无标题" : title)；\(url)"
    }

    public var isLikelyRegistrationComplete: Bool {
        let haystack = [status, detail, url, title]
            .joined(separator: " ")
            .lowercased()

        let blockingNegativeMarkers = [
            "error", "failed", "failure", "invalid", "captcha", "turnstile",
            "verification failed", "验证失败", "错误", "失败"
        ]
        if blockingNegativeMarkers.contains(where: { haystack.contains($0) }) {
            return false
        }

        let positiveMarkers = [
            "dashboard", "workspace", "app.typeless", "welcome", "home",
            "success", "completed", "complete", "logged in", "signed in",
            "all set", "account created", "account is ready", "ready to go",
            "login/app/success", "log in as", "open the desktop app",
            "控制台", "工作台", "首页", "成功", "已登录"
        ]
        if positiveMarkers.contains(where: { haystack.contains($0) }) {
            return true
        }

        let pendingRegistrationMarkers = [
            "register", "signup", "sign-up", "create account", "verify", "verification",
            "注册", "创建账号", "验证码"
        ]
        if pendingRegistrationMarkers.contains(where: { haystack.contains($0) }) {
            return false
        }

        return false
    }
}

public enum RegistrationAutomationCompletionPolicy {
    public static func isComplete(
        verificationCode: String?,
        browserResult: BrowserAutomationResultPayload?
    ) -> Bool {
        browserResult?.isLikelyRegistrationComplete == true
    }
}

// MARK: - Smart switch / auto-rotate policy

/// 智能换号走哪条路径：池内静默注入，或全自动注册新号。
public enum SmartSwitchPath: String, Codable, Equatable, Sendable {
    case none
    case silentPoolSwitch
    case fullAutomaticReplacement
}

public struct SmartSwitchCandidate: Equatable, Sendable {
    public var id: UUID
    public var email: String
    public var remainingCharacters: Int
    public var hasSilentSessionPayload: Bool

    public init(id: UUID, email: String, remainingCharacters: Int, hasSilentSessionPayload: Bool) {
        self.id = id
        self.email = email
        self.remainingCharacters = remainingCharacters
        self.hasSilentSessionPayload = hasSilentSessionPayload
    }
}

public struct SmartSwitchDecision: Equatable, Sendable {
    public var path: SmartSwitchPath
    public var targetAccountID: UUID?
    public var targetEmail: String?
    public var reason: String

    public init(path: SmartSwitchPath, targetAccountID: UUID?, targetEmail: String?, reason: String) {
        self.path = path
        self.targetAccountID = targetAccountID
        self.targetEmail = targetEmail
        self.reason = reason
    }
}

/// 统一「点一下换号」与后台额度监测的决策逻辑，避免 UI / monitor 各写一套。
public enum SmartSwitchPolicy {
    /// 剩余字数低于该值时立刻静默换号。
    public static let defaultRemainingThreshold = 200
    /// 常规巡检间隔（分钟）；额度接近阈值时会自动加速。
    public static let defaultCheckIntervalMinutes = 1
    /// App 启动后首次巡检等待：尽量短，让菜单栏尽快显示真实剩余字数。
    public static let defaultStartupDelaySeconds: UInt64 = 2
    /// 额度接近阈值时的加速巡检间隔（秒）。
    public static let urgentCheckIntervalSeconds: UInt64 = 20
    /// remaining < threshold * urgentMultiplier 时进入加速巡检。
    public static let urgentRemainingMultiplier = 2
    /// 热备池目标：始终尽量保有这么多「可静默注入」的备用号。
    public static let defaultHotSpareTarget = 1
    public static let sessionCaptureRetryAttempts = 8
    public static let sessionCaptureRetryDelaySeconds: UInt64 = 2
    /// 静默注入后等待桌面端读入新会话 / 生成新 device.cache 的秒数。
    public static let silentInjectSettleSeconds: UInt64 = 2
    /// 静默切换后校验目标邮箱的最大轮数（每轮会再同步官方额度）。
    public static let silentSwitchVerifyAttempts = 8
    public static let silentSwitchVerifyDelaySeconds: UInt64 = 2

    public static func isQuotaLow(remaining: Int, threshold: Int) -> Bool {
        remaining < max(threshold, 0)
    }

    /// 监控文案：额度充足时只巡检不换号；低于阈值才触发静默/全自动换号。
    public static func monitorIdleStatus(remaining: Int, threshold: Int) -> String {
        let normalized = max(threshold, 0)
        if remaining >= normalized {
            return "监控中：剩余 \(remaining) ≥ 阈值 \(normalized)，只巡检不换号"
        }
        return "额度偏低：剩余 \(remaining) < 阈值 \(normalized)，准备换号"
    }

    public static func monitorIdleDecisionReason(remaining: Int, threshold: Int) -> String {
        let normalized = max(threshold, 0)
        if remaining >= normalized {
            return "当前额度充足（剩余 \(remaining)，阈值 \(normalized)）：持续监控，暂不换号"
        }
        return "当前额度低于阈值 \(normalized)（剩余 \(remaining)）"
    }

    /// Typeless 服务端「同一设备登录用户数超限」类错误。命中后应重置设备身份并优先走全自动换号。
    public static func isDeviceUserLimitError(_ message: String?) -> Bool {
        guard let message else { return false }
        // 官方文案偶发缺空格（如 hasexceeded）；同时做「折叠空白」和「去空白」两套匹配。
        let lower = message.lowercased()
        let spaced = lower.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let compact = lower.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        let spacedNeedles = [
            "number of users logged into this device has exceeded the limit",
            "users logged into this device has exceeded",
            "device has exceeded the limit",
            "device user limit",
            "too many users on this device",
            "登录该设备的用户数已超过限制",
            "设备登录用户数已超",
            "设备用户数超限",
            "此设备登录的用户数已超过限制"
        ]
        if spacedNeedles.contains(where: { spaced.contains($0) }) {
            return true
        }
        let compactNeedles = [
            "numberofusersloggedintothisdevicehasexceededthelimit",
            "usersloggedintothisdevicehasexceeded",
            "devicehasexceededthelimit",
            "deviceuserlimit",
            "toomanyusersonthisdevice",
            "登录该设备的用户数已超过限制",
            "设备登录用户数已超",
            "设备用户数超限",
            "此设备登录的用户数已超过限制"
        ]
        return compactNeedles.contains { compact.contains($0) }
    }

    public static func isApproachingQuotaLimit(remaining: Int, threshold: Int) -> Bool {
        let normalized = max(threshold, 0)
        return remaining < normalized * urgentRemainingMultiplier
    }

    /// 根据当前剩余额度选择本轮 sleep 秒数：接近阈值时 20 秒一轮，否则按分钟配置。
    public static func nextCheckDelaySeconds(remaining: Int?, threshold: Int, intervalMinutes: Int) -> UInt64 {
        if let remaining, isApproachingQuotaLimit(remaining: remaining, threshold: threshold) {
            return urgentCheckIntervalSeconds
        }
        return UInt64(normalizeCheckIntervalMinutes(intervalMinutes)) * 60
    }

    public static func silentReadyCount(in candidates: [SmartSwitchCandidate]) -> Int {
        candidates.filter { $0.hasSilentSessionPayload && $0.remainingCharacters > 0 }.count
    }

    public static func needsHotSpare(candidates: [SmartSwitchCandidate], target: Int) -> Bool {
        silentReadyCount(in: candidates) < max(target, 0)
    }

    /// - Parameters:
    ///   - forceSwitch: 用户主动点换号时为 true，忽略“额度仍充足”。
    ///   - allowFullAutomaticReplacement: 监测场景在无 API Key / 关闭自动创建时可关掉全自动注册。
    public static func decide(
        currentRemaining: Int?,
        threshold: Int,
        forceSwitch: Bool,
        candidates: [SmartSwitchCandidate],
        allowFullAutomaticReplacement: Bool
    ) -> SmartSwitchDecision {
        let normalizedThreshold = max(threshold, 0)
        if !forceSwitch, let remaining = currentRemaining, !isQuotaLow(remaining: remaining, threshold: normalizedThreshold) {
            return SmartSwitchDecision(
                path: .none,
                targetAccountID: nil,
                targetEmail: nil,
                reason: monitorIdleDecisionReason(remaining: remaining, threshold: normalizedThreshold)
            )
        }

        let silentReady = candidates
            .filter { $0.hasSilentSessionPayload && $0.remainingCharacters > 0 }
            .sorted {
                if $0.remainingCharacters == $1.remainingCharacters {
                    return $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending
                }
                return $0.remainingCharacters > $1.remainingCharacters
            }

        if let best = silentReady.first {
            return SmartSwitchDecision(
                path: .silentPoolSwitch,
                targetAccountID: best.id,
                targetEmail: best.email,
                reason: forceSwitch
                    ? "池内静默切换到「\(best.email)」（剩余 \(best.remainingCharacters)）"
                    : "额度低于 \(normalizedThreshold)，静默切换到「\(best.email)」（剩余 \(best.remainingCharacters)）"
            )
        }

        if allowFullAutomaticReplacement {
            return SmartSwitchDecision(
                path: .fullAutomaticReplacement,
                targetAccountID: nil,
                targetEmail: nil,
                reason: forceSwitch
                    ? "账号池没有可静默注入的会话，执行全自动注册换号"
                    : "额度偏低且没有可静默注入的备用号，自动创建并切换新账号"
            )
        }

        let usableWithoutPayload = candidates.filter { $0.remainingCharacters > 0 && !$0.hasSilentSessionPayload }
        if !usableWithoutPayload.isEmpty {
            return SmartSwitchDecision(
                path: .none,
                targetAccountID: nil,
                targetEmail: nil,
                reason: "池中有 \(usableWithoutPayload.count) 个可用账号但缺少桌面会话缓存；请先「同步官方 App 登录与额度」，或开启自动创建新号"
            )
        }

        return SmartSwitchDecision(
            path: .none,
            targetAccountID: nil,
            targetEmail: nil,
            reason: "没有可用备用账号，且未允许自动创建新号"
        )
    }

    /// 把浏览器 profile 里的 token JSON 转成桌面端 `user-data.json` 明文结构，供静默注入复用。
    public static func desktopUserDataPayload(fromBrowserTokenInfo tokenInfoJSON: String) -> String? {
        guard let data = tokenInfoJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let accessToken = (object["accessToken"] as? String)
            ?? (object["access_token"] as? String)
            ?? ""
        let refreshToken = (object["refreshToken"] as? String)
            ?? (object["refresh_token"] as? String)
            ?? ""
        let userID = (object["userId"] as? String)
            ?? (object["user_id"] as? String)
            ?? ""
        let email = (object["email"] as? String) ?? ""

        guard !accessToken.isEmpty, !userID.isEmpty else { return nil }

        let credentials: [String: Any] = [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "user_id": userID,
            "email": email
        ]
        guard let credentialsData = try? JSONSerialization.data(withJSONObject: credentials, options: []),
              let credentialsString = String(data: credentialsData, encoding: .utf8) else {
            return nil
        }

        let wrapper: [String: Any] = ["userData": credentialsString]
        guard let wrapperData = try? JSONSerialization.data(withJSONObject: wrapper, options: []),
              let wrapperString = String(data: wrapperData, encoding: .utf8) else {
            return nil
        }
        return wrapperString
    }

    public static func normalizeCheckIntervalMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 120)
    }

    public static func normalizeThreshold(_ threshold: Int) -> Int {
        min(max(threshold, 0), 50_000)
    }

    public static func normalizeHotSpareTarget(_ target: Int) -> Int {
        min(max(target, 0), 5)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
