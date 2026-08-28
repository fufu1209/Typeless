import Foundation
import TypelessSwitchboardCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}


func runCommand(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    var environment = ProcessInfo.processInfo.environment
    let pathAdditions = [
        NSHomeDirectory() + "/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]
    let currentPath = environment["PATH"] ?? ""
    environment["PATH"] = (pathAdditions + currentPath.split(separator: ":").map(String.init))
        .reduce(into: [String]()) { result, item in
            if !result.contains(item) { result.append(item) }
        }
        .joined(separator: ":")
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    } catch {
        return (-1, error.localizedDescription)
    }
}

@main
struct OperationalFeatureChecks {
    static func main() throws {
        let raw: [String: Any] = [
            "email": "alpha@example.com",
            "nickname": "Alpha",
            "role": "free",
            "user_id": "user-1",
            "token": "secret-token",
            "refresh_token": "secret-refresh"
        ]
        let imported = ToolkitAccountImporter.importableAccount(from: raw, existingDomains: ["example.com"])
        check(imported.account.email == "alpha@example.com", "toolkit email imported")
        check(imported.account.typelessUsername == "user-1", "toolkit user id imported")
        check(imported.tokenSummary?.accessTokenFingerprint == "sha256:930bbdc51b6aed5c", "access token fingerprint")
        check(imported.tokenSummary?.refreshTokenFingerprint == "sha256:6c2b02ce86b168b5", "refresh token fingerprint")
        check(!imported.account.notes.contains("secret-token"), "raw access token redacted")
        check(!imported.account.notes.contains("secret-refresh"), "raw refresh token redacted")

        let manifest = LoginSnapshotManifest.make(
            sourcePath: "/Users/test/Library/Application Support/Typeless",
            files: [
                SnapshotFile(path: "Cookies", byteCount: 1024, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                SnapshotFile(path: "Local Storage/leveldb/000003.log", byteCount: 2048, modifiedAt: Date(timeIntervalSince1970: 1_700_000_100))
            ],
            includeSensitiveContents: false
        )
        check(manifest.sourcePath == "/Users/test/Library/Application Support/Typeless", "snapshot source path")
        check(manifest.files.count == 2, "snapshot files counted")
        check(!manifest.includesSensitiveContents, "snapshot avoids sensitive contents")
        check(manifest.summary.contains("仅保存清单"), "snapshot summary explains manifest-only")
        check(!manifest.summary.localizedCaseInsensitiveContains("cookie value"), "snapshot summary redacts contents")

        let report = DeviceInfoReport.make(
            hostName: "MacBook-Pro.local",
            osVersion: "macOS 15.5",
            modelIdentifier: "Mac15,3",
            appPath: "/Applications/Typeless.app",
            loginDataPath: "/Users/test/Library/Application Support/Typeless",
            cachePath: "/Users/test/Library/Application Support/Typeless/Cache"
        )
        check(report.markdown.contains("MacBook-Pro.local"), "device hostname")
        check(report.markdown.contains("Mac15,3"), "device model")
        check(report.markdown.contains("/Applications/Typeless.app"), "device app path")
        check(!report.markdown.contains("删除"), "device report no destructive instructions")
        check(!report.markdown.localizedCaseInsensitiveContains("reset fingerprint"), "device report no fingerprint reset")

        let candidate = RegistrationCandidate(
            displayName: "Bright Note",
            username: "bright_note_123456",
            email: "bright.note.123456@example.com",
            domain: "example.com",
            passwordHint: "已放入密码管理器"
        )
        let plan = RegistrationPreparationPlan.make(candidate: candidate, typelessURL: "https://www.typeless.com/")
        check(plan.email == candidate.email, "registration email")
        check(plan.username == candidate.username, "registration username")
        check(plan.registrationURL == "https://www.typeless.com/", "registration URL")
        check(plan.steps.first == "复制邮箱并打开注册页", "registration first step")
        check(plan.steps.contains("工具自动轮询邮箱验证码并尝试提交"), "registration automation verification step")
        check(plan.steps.contains("页面结构变化时保留验证码和资料供手动兜底"), "registration plan documents fallback")


        let codeSamples = [
            "Your Typeless verification code is 482913. It expires in 10 minutes.",
            "【Typeless】验证码：739204，请勿泄露给他人",
            "Use 135790 to finish signing in to Typeless"
        ]
        check(VerificationCodeExtractor.extract(from: codeSamples[0]) == "482913", "extracts english verification code")
        check(VerificationCodeExtractor.extract(from: codeSamples[1]) == "739204", "extracts chinese verification code")
        check(VerificationCodeExtractor.extract(from: codeSamples[2]) == "135790", "extracts signin verification code")
        check(VerificationCodeExtractor.extract(from: "Your Typeless verification code is 482-913") == "482913", "extracts dashed verification code")
        check(VerificationCodeExtractor.extract(from: "【Typeless】验证码：739 204，请勿泄露") == "739204", "extracts spaced verification code")
        check(VerificationCodeExtractor.extract(from: "no numeric verification content") == nil, "ignores messages without codes")
        check(RegistrationAutomationTiming.moeMailPollingWindowSeconds >= RegistrationAutomationTiming.verificationBridgeWaitSeconds, "MoeMail polling covers browser verification bridge wait")
        check(RegistrationAutomationTiming.moeMailPollingWindowSeconds >= 90, "MoeMail polling waits long enough for delayed verification email")
        check(RegistrationAutomationTiming.moeMailPollingAttempts == RegistrationAutomationTiming.moeMailPollingDelayScheduleSeconds.count + 1, "MoeMail polling attempts include the initial immediate check")
        check(RegistrationAutomationTiming.moeMailPollingDelayScheduleSeconds.prefix(4).allSatisfy { $0 <= 2 }, "MoeMail polling uses short initial delays for faster code pickup")
        check(RegistrationAutomationTiming.moeMailPollingDelaySeconds(afterAttempt: 1) == RegistrationAutomationTiming.moeMailPollingDelayScheduleSeconds.first, "MoeMail polling delay lookup uses the schedule")
        check(RegistrationAutomationTiming.moeMailPollingDelaySeconds(afterAttempt: RegistrationAutomationTiming.moeMailPollingAttempts) == nil, "MoeMail polling does not sleep after the final attempt")

        let permissionItems = MacPermissionChecklist.recommendedItems
        check(permissionItems.contains { $0.title.contains("辅助功能") && $0.settingsPaneIdentifier == "Privacy_Accessibility" && $0.isRequiredForOneClickSwitch }, "permission checklist includes Accessibility for Chrome/System Events control")
        check(permissionItems.contains { $0.title.contains("自动化") && $0.settingsPaneIdentifier == "Privacy_Automation" && $0.isRequiredForOneClickSwitch }, "permission checklist includes Automation Apple Events")
        check(permissionItems.contains { $0.title.contains("麦克风") && $0.settingsPaneIdentifier == "Privacy_Microphone" }, "permission checklist includes Typeless microphone permission")
        check(permissionItems.contains { $0.title.contains("输入监听") && $0.settingsPaneIdentifier == "Privacy_ListenEvent" }, "permission checklist includes Typeless input monitoring permission")
        check(permissionItems.contains { $0.title.contains("屏幕录制") && $0.settingsPaneIdentifier == "Privacy_ScreenCapture" }, "permission checklist includes Typeless screen recording permission")
        check(MacPermissionChecklist.markdown.contains("Google Chrome 外部协议"), "permission checklist explains Chrome external protocol allowance")
        check(MacPermissionChecklist.markdown.contains("始终允许"), "permission checklist tells user to always allow Typeless.app handoff")

        let macProfile = TypelessToolkitCompatibilityMatrix.macOS
        check(macProfile.supportLevel == .productionVerified, "macOS profile remains production verified")
        check(macProfile.executableCandidates.contains("/Applications/Typeless.app/Contents/MacOS/Typeless"), "macOS profile keeps Typeless.app executable path")
        check(macProfile.deviceCacheDirectoryCandidates.contains("~/Library/Application Support/now.typeless.desktop"), "macOS profile includes real now.typeless.desktop device cache")
        check(macProfile.credentialTargets.contains { $0.contains("now.typeless.desktop.deviceIdentifier") && $0.contains("now.typeless.desktop.security.auth_key") }, "macOS profile includes real Keychain service/account")
        check(macProfile.credentialTargets.contains("Typeless.deviceIdentifier"), "macOS profile keeps toolkit legacy credential target")

        let windowsProfile = TypelessToolkitCompatibilityMatrix.windows
        check(windowsProfile.supportLevel == .toolkitCompatible, "Windows profile is toolkit compatible")
        check(windowsProfile.executableCandidates.contains("%LOCALAPPDATA%\\Programs\\Typeless\\Typeless.exe"), "Windows profile mirrors toolkit executable path")
        check(windowsProfile.userDataDirectoryCandidates.contains("%APPDATA%\\Typeless.exe"), "Windows profile mirrors toolkit user data path")
        check(windowsProfile.deviceCacheDirectoryCandidates.contains("%APPDATA%\\Typeless\\Cache"), "Windows profile mirrors toolkit device cache path")
        check(windowsProfile.credentialTargets == ["Typeless.deviceIdentifier"], "Windows profile mirrors toolkit credential target")
        check(TypelessToolkitCompatibilityMatrix.resetDeviceSteps.contains { $0.contains("device.cache") }, "compatibility matrix documents device.cache reset")
        check(TypelessToolkitCompatibilityMatrix.resetDeviceSteps.contains { $0.contains("app-storage.json") && $0.contains("quotaUsage") }, "compatibility matrix documents app-storage quota reset")
        check(TypelessToolkitCompatibilityMatrix.linux.supportLevel == .planned, "Linux is explicitly planned rather than silently claimed supported")
        check(TypelessToolkitCompatibilityMatrix.markdown.contains("跨平台兼容矩阵"), "compatibility matrix can be exported as markdown")

        let portablePreflightSyntax = runCommand("node", ["--check", "scripts/typeless-portable-preflight.js"])
        check(portablePreflightSyntax.status == 0, "portable preflight script passes node --check: \(portablePreflightSyntax.output)")
        let portablePreflightRun = runCommand("node", ["scripts/typeless-portable-preflight.js"])
        check(portablePreflightRun.status == 0, "portable preflight script runs read-only on this machine: \(portablePreflightRun.output)")
        check(portablePreflightRun.output.contains("\"readOnly\": true"), "portable preflight is read-only")
        check(portablePreflightRun.output.contains("\"platform\": \"macos\""), "portable preflight detects current macOS platform")

        let fixtureAutomationPassword = ["Auto", "Password", "482913"].joined(separator: "-")
        let automationInput = BrowserRegistrationAutomationInput(
            registrationURL: "https://www.typeless.com/register",
            email: "bright.note.123456@example.com",
            username: "bright_note_123456",
            password: fixtureAutomationPassword,
            verificationCode: "482913"
        )
        let automationScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: automationInput)
        check(automationScript.contains("https://www.typeless.com/register"), "script contains registration URL")
        check(automationScript.contains("bright.note.123456@example.com"), "script contains email")
        check(automationScript.contains("bright_note_123456"), "script contains username")
        check(automationScript.contains(fixtureAutomationPassword), "script contains password for browser filling")
        check(automationScript.contains("482913"), "script contains verification code")
        check(automationScript.contains("getByLabel") || automationScript.contains("locator"), "script uses Playwright selectors")
        check(automationScript.contains("ensureRegistrationForm"), "script can navigate from homepage to registration form")
        check(automationScript.contains("a:has-text(\"Sign up\")"), "script searches sign up links")
        check(automationScript.contains("button:has-text(\"Get started\")"), "script searches get started buttons")
        check(automationScript.contains("requestVerificationCode"), "script has dedicated verification code request step")
        check(automationScript.contains("submitRegistration"), "script has dedicated final submit step")
        check(automationScript.contains("button:has-text(\"发送验证码\")"), "script searches chinese send-code buttons")
        check(automationScript.contains("button:has-text(\"Create account\")"), "script searches create account submit buttons")

        let bridgeInput = BrowserRegistrationAutomationInput(
            registrationURL: "https://www.typeless.com/register",
            email: "bridge@example.com",
            username: "bridge_user",
            password: fixtureAutomationPassword,
            verificationCode: nil,
            verificationCodeFilePath: "/tmp/typeless-code.txt"
        )
        let bridgeScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: bridgeInput)
        check(bridgeScript.contains("/tmp/typeless-code.txt"), "bridge script contains verification code file path")
        check(bridgeScript.contains("waitForVerificationCodeFile"), "bridge script waits for verification code file")
        check(bridgeScript.contains("fs.existsSync"), "bridge script checks code file existence")

        let envPasswordInput = BrowserRegistrationAutomationInput(
            registrationURL: "https://www.typeless.com/register",
            email: "env-password@example.com",
            username: "env_password_user",
            password: fixtureAutomationPassword,
            verificationCode: nil,
            verificationCodeFilePath: "/tmp/typeless-code.txt",
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD"
        )
        let envPasswordScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: envPasswordInput)
        check(envPasswordScript.contains("process.env.TYPELESS_AUTOMATION_PASSWORD"), "script reads password from environment")
        check(!envPasswordScript.contains(fixtureAutomationPassword), "script avoids writing env password literal")

        let resultBridgeInput = BrowserRegistrationAutomationInput(
            registrationURL: "https://www.typeless.com/register",
            email: "result-bridge@example.com",
            username: "result_bridge_user",
            password: fixtureAutomationPassword,
            verificationCode: "482913",
            automationResultFilePath: "/tmp/typeless-result.json",
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD"
        )
        let resultBridgeScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: resultBridgeInput)
        check(resultBridgeScript.contains("/tmp/typeless-result.json"), "result bridge script contains result file path")
        check(resultBridgeScript.contains("writeAutomationResult"), "result bridge script writes automation result")
        check(resultBridgeScript.contains("page.title()"), "result bridge captures page title")
        check(resultBridgeScript.contains("page.url()"), "result bridge captures final URL")

        check(resultBridgeScript.contains("login/app/success"), "script waits for Typeless magic-link success URL")
        check(resultBridgeScript.contains("open the desktop app"), "script treats Typeless desktop handoff page as complete")
        check(resultBridgeScript.contains("log in as"), "script treats Typeless logged-in handoff copy as complete")

        check(resultBridgeScript.contains("refreshTypelessLoginHandoff"), "script refreshes Typeless login page after magic-code submit before writing result")
        check(resultBridgeScript.contains("page.reload"), "script can reload Typeless login page to expose app success handoff")

        let persistentSessionInput = BrowserRegistrationAutomationInput(
            registrationURL: "https://www.typeless.com/register",
            email: "persistent-session@example.com",
            username: "persistent_session_user",
            password: fixtureAutomationPassword,
            verificationCode: "482913",
            automationResultFilePath: "/tmp/typeless-result.json",
            browserProfileDirectoryPath: "/tmp/typeless-switchboard-profile",
            clearBrowserProfileBeforeRun: true,
            passwordEnvironmentVariable: "TYPELESS_AUTOMATION_PASSWORD"
        )
        let persistentSessionScript = BrowserAutomationScriptBuilder.makeRegistrationScript(input: persistentSessionInput)
        check(persistentSessionScript.contains("/tmp/typeless-switchboard-profile"), "script contains persistent browser profile path")
        check(persistentSessionScript.contains("chromium.launchPersistentContext"), "script uses persistent browser context when profile path is provided")
        check(persistentSessionScript.contains("await context.newPage()"), "persistent script opens a page from the retained context")
        check(!persistentSessionScript.contains("chromium.launch({ headless:"), "persistent script does not use disposable browser launch")
        check(persistentSessionScript.contains("clearBrowserProfileBeforeRun"), "script has explicit profile clearing flag")
        check(persistentSessionScript.contains("fs.rmSync(browserProfileDirectoryPath"), "script clears old browser profile before registering")
        check(persistentSessionScript.contains("logoutIfSignedIn"), "script tries to log out any existing Typeless session before registering")
        check(persistentSessionScript.contains("button:has-text(\"登出\")"), "script can click Chinese logout")
        check(persistentSessionScript.contains("button:has-text(\"Log out\")"), "script can click English logout")
        let persistentSyntaxCheckURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeless-persistent-registration-automation-check.js")
        try persistentSessionScript.write(to: persistentSyntaxCheckURL, atomically: true, encoding: .utf8)
        let persistentNodeSyntax = runCommand("node", ["--check", persistentSyntaxCheckURL.path])
        check(persistentNodeSyntax.status == 0, "generated persistent Playwright script passes node --check: \(persistentNodeSyntax.output)")

        let openSessionInput = BrowserSessionAutomationInput(
            targetURL: "https://www.typeless.com/app",
            browserProfileDirectoryPath: "/tmp/typeless-switchboard-profile",
            headless: false
        )
        let openSessionScript = BrowserAutomationScriptBuilder.makeOpenSessionScript(input: openSessionInput)
        check(openSessionScript.contains("/tmp/typeless-switchboard-profile"), "open-session script contains persistent browser profile path")
        check(openSessionScript.contains("https://www.typeless.com/app"), "open-session script contains target URL")
        check(openSessionScript.contains("chromium.launchPersistentContext"), "open-session script uses retained browser context")
        check(openSessionScript.contains("waitForEvent('close')"), "open-session script keeps browser open until user closes it")
        check(openSessionScript.contains("openTypelessDesktopAppFromHandoff"), "open-session script can click Typeless desktop handoff")
        check(openSessionScript.contains("Open the desktop app"), "open-session script targets Typeless desktop handoff button")
        check(openSessionScript.contains("openExternalTypelessProtocolURL"), "open-session script can hand Typeless protocol URL to macOS")
        check(openSessionScript.contains("page.on('request'"), "open-session script listens for Typeless external protocol requests")
        check(openSessionScript.contains("typeless://"), "open-session script detects Typeless external protocol scheme")
        check(openSessionScript.contains("execFileSync('/usr/bin/open'"), "open-session script uses macOS open for Typeless desktop handoff")
        let openSessionSyntaxCheckURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeless-open-session-check.js")
        try openSessionScript.write(to: openSessionSyntaxCheckURL, atomically: true, encoding: .utf8)
        let openSessionNodeSyntax = runCommand("node", ["--check", openSessionSyntaxCheckURL.path])
        check(openSessionNodeSyntax.status == 0, "generated open-session Playwright script passes node --check: \(openSessionNodeSyntax.output)")


        let syntaxCheckURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typeless-registration-automation-check.js")
        try resultBridgeScript.write(to: syntaxCheckURL, atomically: true, encoding: .utf8)
        let nodeSyntax = runCommand("node", ["--check", syntaxCheckURL.path])
        check(nodeSyntax.status == 0, "generated Playwright script passes node --check: \(nodeSyntax.output)")

        let successfulBrowserResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "registration submitted",
            url: "https://app.typeless.com/dashboard",
            title: "Typeless Dashboard",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(successfulBrowserResult.isLikelyRegistrationComplete, "dashboard result is likely complete")
        check(RegistrationAutomationCompletionPolicy.isComplete(verificationCode: nil, browserResult: successfulBrowserResult), "browser-proven completion does not require extracted code")
        check(RegistrationAutomationCompletionPolicy.isComplete(verificationCode: "482913", browserResult: successfulBrowserResult), "browser-proven completion accepts extracted code")
        check(!RegistrationAutomationCompletionPolicy.isComplete(verificationCode: "482913", browserResult: nil), "verification code alone does not prove registration completion")

        let dashboardAfterRegisterURLResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "registration form submitted or attempted",
            url: "file:///tmp/mock-register.html#/dashboard",
            title: "Typeless Dashboard",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(dashboardAfterRegisterURLResult.isLikelyRegistrationComplete, "dashboard result wins over register in historical URL")

        let allSetBrowserResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "registration form submitted or attempted",
            url: "https://www.typeless.com/next-step",
            title: "You're all set",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(allSetBrowserResult.isLikelyRegistrationComplete, "all-set result is likely complete")

        let accountCreatedBrowserResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "account created",
            url: "https://www.typeless.com/next-step",
            title: "Account created",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(accountCreatedBrowserResult.isLikelyRegistrationComplete, "account-created result is likely complete")

        let typelessMagicLinkSuccessResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "Log in as codex-real@example.com Open the desktop app",
            url: "https://www.typeless.com/login/app/success",
            title: "Typeless | AI Voice Dictation That's Actually Intelligent",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(typelessMagicLinkSuccessResult.isLikelyRegistrationComplete, "Typeless login/app/success result is likely complete")

        let stuckBrowserResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "registration attempted",
            url: "https://www.typeless.com/register",
            title: "Create your account",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(!stuckBrowserResult.isLikelyRegistrationComplete, "register page result is not complete")

        let errorBrowserResult = BrowserAutomationResultPayload(
            status: "submitted",
            detail: "registration attempted",
            url: "https://www.typeless.com/error",
            title: "Verification failed",
            timestamp: "2026-07-07T00:00:00Z"
        )
        check(!errorBrowserResult.isLikelyRegistrationComplete, "error result is not complete")

        let automationResult = RegistrationAutomationResult(
            previousAccountID: UUID(uuidString: "00000000-0000-0000-0000-000000000999"),
            previousAccountEmail: "old.account@example.com",
            accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000123"),
            accountEmail: "bright.note.123456@example.com",
            username: "bright_note_123456",
            status: .codeFound,
            verificationCode: "482913",
            scriptPath: "/Users/test/automation.js",
            verificationCodeFilePath: "/Users/test/code.txt",
            browserResultFilePath: "/Users/test/result.json",
            browserProfileDirectoryPath: "/Users/test/profile",
            passwordStoredInKeychain: true,
            log: ["邮箱已创建", "密码已保存到 Keychain", "验证码已提取"]
        )
        check(automationResult.markdown.contains("bright.note.123456@example.com"), "automation markdown includes email")
        check(automationResult.markdown.contains("old.account@example.com"), "automation markdown records previous account email")
        check(automationResult.markdown.contains("482913"), "automation markdown includes verification code")
        check(automationResult.markdown.contains("密码已保存到 Keychain"), "automation markdown states keychain password")
        check(automationResult.markdown.contains("00000000-0000-0000-0000-000000000123"), "automation markdown includes account id")
        check(automationResult.markdown.contains("/Users/test/code.txt"), "automation markdown includes verification bridge path")
        check(automationResult.markdown.contains("/Users/test/result.json"), "automation markdown includes browser result path")
        check(automationResult.markdown.contains("/Users/test/profile"), "automation markdown includes browser profile path")
        check(automationResult.canRetry, "automation result with account and script can retry")
        check(automationResult.canOpenBrowserSession, "automation result with browser profile can open retained session")
        check(!automationResult.markdown.contains(fixtureAutomationPassword), "automation markdown redacts raw password")

        let nonRetryableAutomationResult = RegistrationAutomationResult(
            accountEmail: "missing@example.com",
            username: "missing_user",
            status: .failed,
            verificationCode: nil,
            scriptPath: nil,
            passwordStoredInKeychain: false,
            log: []
        )
        check(!nonRetryableAutomationResult.canRetry, "automation result without account and script cannot retry")
        check(!nonRetryableAutomationResult.canOpenBrowserSession, "automation result without browser profile cannot open retained session")

        // MARK: - v2.1.0 QuotaCycleEngine 真实行为测试
        // 之前的"func daysUntilReset" 等源串包含测试已经在这次升级中被替换为真实行为断言。
        runQuotaCycleEngineChecks()

        // MARK: - v2.4.0 测试改革：删 108 条源串包含断言，换成 4 个真实行为模块
        runSmartSwitchPolicyChecks()
        runRegistrationCompletionPolicyChecks()
        runBrowserAutomationResultPayloadChecks()
        runToolkitAccountImporterEdgeCaseChecks()
        runStoreRecoveryChecks()
        runQuotaGuardLaunchAgentPlannerChecks()

        print("Operational feature checks passed")
    }

    private static func runQuotaCycleEngineChecks() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday

        // 用一个固定 now（本周一 00:00）测：距离下次刷新应该是 7 天。
        let mondayMidnight = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 0, minute: 0))!
        check(
            QuotaCycleEngine.daysUntilReset(now: mondayMidnight, mode: .calendarWeek, calendar: cal) == 7,
            "calendarWeek: 本周一 00:00 → 距离下次刷新 7 天"
        )
        // 周日 23:59 应该只差 1 天到下周一 00:00
        let sundayLateNight = cal.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 23, minute: 59))!
        check(
            QuotaCycleEngine.daysUntilReset(now: sundayLateNight, mode: .calendarWeek, calendar: cal) == 1,
            "calendarWeek: 周日 23:59 → 距离下次刷新 1 天"
        )
        // 周一 00:00 刚过 → 6 天
        let mondayAfterMidnight = cal.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 0, minute: 5))!
        check(
            QuotaCycleEngine.daysUntilReset(now: mondayAfterMidnight, mode: .calendarWeek, calendar: cal) == 6,
            "calendarWeek: 本周一 00:05 → 距离下次刷新 6 天"
        )

        // rollingWeek：lastResetAt 8 天前 → 0 天（已经超过 7 天）
        let eightDaysAgo = Date(timeIntervalSinceNow: -8 * 24 * 60 * 60)
        check(
            QuotaCycleEngine.daysUntilReset(now: Date(), mode: .rollingWeek, lastResetAt: eightDaysAgo) == 0,
            "rollingWeek: 距 lastResetAt 8 天 → 0 天（已刷新）"
        )
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        let rollingDays = QuotaCycleEngine.daysUntilReset(now: Date(), mode: .rollingWeek, lastResetAt: twoDaysAgo)
        check(
            rollingDays == 5,
            "rollingWeek: 距 lastResetAt 2 天 → 5 天（向上取整）"
        )

        // shouldRevive: .exhausted + 跨周 → true
        let lastWeekReset = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 0, minute: 0))!
        let exhaustedLastWeek = AccountQuotaSnapshot(
            id: UUID(),
            email: "alpha@example.com",
            status: .exhausted,
            reviewState: .approved,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: lastWeekReset,
            createdAt: lastWeekReset,
            hasSilentSessionPayload: true
        )
        check(
            QuotaCycleEngine.shouldRevive(
                account: exhaustedLastWeek,
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ),
            "shouldRevive: .exhausted + 跨周 → true"
        )

        // shouldRevive: .exhausted + 同周 → false
        let sameWeekReset = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 0, minute: 0))!
        let exhaustedSameWeek = AccountQuotaSnapshot(
            id: UUID(),
            email: "alpha@example.com",
            status: .exhausted,
            reviewState: .approved,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: sameWeekReset,
            createdAt: sameWeekReset,
            hasSilentSessionPayload: true
        )
        check(
            !QuotaCycleEngine.shouldRevive(
                account: exhaustedSameWeek,
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ),
            "shouldRevive: .exhausted + 同周 → false"
        )

        // shouldRevive: .available 跨周也返回 false（不必复活）
        let availableLastWeek = AccountQuotaSnapshot(
            id: UUID(),
            email: "beta@example.com",
            status: .available,
            reviewState: .approved,
            usedCharacters: 1000,
            monthlyLimit: 8000,
            lastResetAt: lastWeekReset,
            createdAt: lastWeekReset,
            hasSilentSessionPayload: true
        )
        check(
            !QuotaCycleEngine.shouldRevive(
                account: availableLastWeek,
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ),
            "shouldRevive: .available → false（无需复活）"
        )

        // shouldRevive: .paused 跨周也返回 false
        let pausedLastWeek = AccountQuotaSnapshot(
            id: UUID(),
            email: "gamma@example.com",
            status: .paused,
            reviewState: .approved,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: lastWeekReset,
            createdAt: lastWeekReset,
            hasSilentSessionPayload: true
        )
        check(
            !QuotaCycleEngine.shouldRevive(
                account: pausedLastWeek,
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ),
            "shouldRevive: .paused → false（被用户主动暂停）"
        )

        // shouldRevive: .pending (未确认) 跨周 → false（避免自动复活兜底确认前的号）
        let pendingLastWeek = AccountQuotaSnapshot(
            id: UUID(),
            email: "delta@example.com",
            status: .exhausted,
            reviewState: .pending,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: lastWeekReset,
            createdAt: lastWeekReset,
            hasSilentSessionPayload: true
        )
        check(
            !QuotaCycleEngine.shouldRevive(
                account: pendingLastWeek,
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ),
            "shouldRevive: reviewState=.pending → false（兜底确认前不复活）"
        )

        // rollingWeek: 8 天前 .exhausted → true
        let rollingExhausted = AccountQuotaSnapshot(
            id: UUID(),
            email: "epsilon@example.com",
            status: .exhausted,
            reviewState: .approved,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: eightDaysAgo,
            createdAt: Date(),
            hasSilentSessionPayload: true
        )
        check(
            QuotaCycleEngine.shouldRevive(
                account: rollingExhausted,
                now: Date(),
                mode: .rollingWeek,
                calendar: cal
            ),
            "shouldRevive: rollingWeek + 8 天前 → true"
        )

        // pickNext: 复活号 > 静默就绪 > 余额
        let silentReadyHigh = AccountQuotaSnapshot(
            id: UUID(),
            email: "silent-high@example.com",
            status: .available,
            reviewState: .approved,
            usedCharacters: 1000, // 剩 7000
            monthlyLimit: 8000,
            lastResetAt: sameWeekReset,
            createdAt: Date(),
            hasSilentSessionPayload: true
        )
        let silentReadyLow = AccountQuotaSnapshot(
            id: UUID(),
            email: "silent-low@example.com",
            status: .available,
            reviewState: .approved,
            usedCharacters: 7000, // 剩 1000
            monthlyLimit: 8000,
            lastResetAt: sameWeekReset,
            createdAt: Date(),
            hasSilentSessionPayload: true
        )
        let revived = AccountQuotaSnapshot(
            id: UUID(),
            email: "revived@example.com",
            status: .exhausted,
            reviewState: .approved,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: lastWeekReset,
            createdAt: Date(),
            hasSilentSessionPayload: false // 没有静默会话缓存
        )
        let pick = QuotaCycleEngine.pickNext(
            among: [silentReadyHigh, silentReadyLow, revived],
            now: mondayMidnight,
            mode: .calendarWeek,
            calendar: cal
        )
        check(
            pick?.email == "revived@example.com",
            "pickNext: 复活号优先（即便它没静默会话缓存）"
        )

        // pickNext: 没有复活 → 静默就绪里余额最多
        let onlySilent = QuotaCycleEngine.pickNext(
            among: [silentReadyLow, silentReadyHigh],
            now: mondayMidnight,
            mode: .calendarWeek,
            calendar: cal
        )
        check(
            onlySilent?.email == "silent-high@example.com",
            "pickNext: 没有复活 → 静默就绪 + 余额最多"
        )

        // pickNext: 既不复活、也没有静默会话缓存 → nil
        // 注意：这里必须用「同周 exhausted」或「无 payload 的 available」，
        // 不能用跨周 exhausted（那个本来就该复活，pickNext 会正确返回它）。
        let noPayloadAvailable = AccountQuotaSnapshot(
            id: UUID(),
            email: "nope@example.com",
            status: .available,
            reviewState: .approved,
            usedCharacters: 1000, // 剩 7000
            monthlyLimit: 8000,
            lastResetAt: sameWeekReset,
            createdAt: Date(),
            hasSilentSessionPayload: false // 没有静默会话缓存
        )
        check(
            QuotaCycleEngine.pickNext(
                among: [noPayloadAvailable],
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ) == nil,
            "pickNext: 不复活 + 无静默缓存 → nil（应走全自动注册）"
        )

        // 同周 exhausted（还没到刷新点）也应该选不到 → nil，不该误把上一周的号当复活
        let sameWeekExhausted = AccountQuotaSnapshot(
            id: UUID(),
            email: "sameweek@example.com",
            status: .exhausted,
            reviewState: .approved,
            usedCharacters: 8000,
            monthlyLimit: 8000,
            lastResetAt: sameWeekReset, // 本周内
            createdAt: Date(),
            hasSilentSessionPayload: true
        )
        check(
            QuotaCycleEngine.pickNext(
                among: [sameWeekExhausted],
                now: mondayMidnight,
                mode: .calendarWeek,
                calendar: cal
            ) == nil,
            "pickNext: 同周 exhausted（未到刷新点）→ nil，不误复活"
        )

        // pickNext: currentID 不影响复活号（v2.1.0 核心价值：切回原号）
        let switched = QuotaCycleEngine.pickNext(
            among: [silentReadyHigh, revived],
            excluding: silentReadyHigh.id,
            now: mondayMidnight,
            mode: .calendarWeek,
            calendar: cal
        )
        check(
            switched?.email == "revived@example.com",
            "pickNext: currentID 不屏蔽复活号（可切回原号）"
        )

        // revivedAccounts: 按 usedCharacters 升序
        let multipleRevived = [
            AccountQuotaSnapshot(
                id: UUID(),
                email: "r2@example.com",
                status: .exhausted,
                reviewState: .approved,
                usedCharacters: 8000,
                monthlyLimit: 8000,
                lastResetAt: lastWeekReset,
                createdAt: Date(),
                hasSilentSessionPayload: false
            ),
            AccountQuotaSnapshot(
                id: UUID(),
                email: "r1@example.com",
                status: .exhausted,
                reviewState: .approved,
                usedCharacters: 8000,
                monthlyLimit: 8000,
                lastResetAt: lastWeekReset,
                createdAt: Date(),
                hasSilentSessionPayload: false
            )
        ]
        let ordered = QuotaCycleEngine.revivedAccounts(
            in: multipleRevived,
            now: mondayMidnight,
            mode: .calendarWeek,
            calendar: cal
        )
        check(
            ordered.count == 2,
            "revivedAccounts: 全部 .exhausted + 跨周都被识别为可复活"
        )

        // nextCalendarWeekReset: 跨年/跨 ISO 周安全
        let newYearEve = cal.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 12, minute: 0))!
        let nextReset = QuotaCycleEngine.nextCalendarWeekReset(now: newYearEve, calendar: cal)
        check(
            nextReset != nil && nextReset! > newYearEve,
            "nextCalendarWeekReset: 跨年时仍能给出下一个周一 00:00"
        )

        // 摘要文案包含"距离刷新还有 N 天"
        let summary = QuotaCycleEngine.summary(
            for: silentReadyHigh,
            now: mondayMidnight,
            mode: .calendarWeek,
            calendar: cal
        )
        check(
            summary.contains("距离刷新还有") && summary.contains("1000/8000"),
            "QuotaCycleEngine.summary: 含周度已用 + 距离刷新天数"
        )
    }

    // MARK: - v2.4.0 SmartSwitchPolicy 真实行为
    private static func runSmartSwitchPolicyChecks() {
        // 阈值判定：isQuotaLow 严格小于
        check(SmartSwitchPolicy.isQuotaLow(remaining: 0, threshold: 200), "isQuotaLow: remaining 0 < 200 → true")
        check(SmartSwitchPolicy.isQuotaLow(remaining: 199, threshold: 200), "isQuotaLow: remaining 199 < 200 → true")
        check(!SmartSwitchPolicy.isQuotaLow(remaining: 200, threshold: 200), "isQuotaLow: remaining 200 NOT < 200 → false（边界）")
        check(!SmartSwitchPolicy.isQuotaLow(remaining: 1000, threshold: 200), "isQuotaLow: remaining 1000 < 200 → false")
        check(!SmartSwitchPolicy.isQuotaLow(remaining: 50, threshold: 0), "isQuotaLow: threshold=0 → 永远 false（防止负阈值乱触发）")
        check(SmartSwitchPolicy.isQuotaLow(remaining: -1, threshold: 0), "isQuotaLow: remaining=-1 threshold=0 → -1<0 true（数学正确，UI 应避免）")

        // 路径选择：额度充足 + 无 forceSwitch → .none
        let idleDecision = SmartSwitchPolicy.decide(
            currentRemaining: 5000, threshold: 200, forceSwitch: false,
            candidates: [
                SmartSwitchCandidate(id: UUID(), email: "a@x.com", remainingCharacters: 7000, hasSilentSessionPayload: true)
            ],
            allowFullAutomaticReplacement: true
        )
        check(idleDecision.path == .none, "decide: 额度充足 + forceSwitch=false → .none")
        check(idleDecision.targetAccountID == nil, "decide: 空闲时无目标账号")
        check(idleDecision.reason.contains("充足"), "decide: 空闲时 reason 解释额度充足")

        // 路径选择：额度低 + 有静默就绪 → .silentPoolSwitch
        let silentSwitch = SmartSwitchPolicy.decide(
            currentRemaining: 50, threshold: 200, forceSwitch: false,
            candidates: [
                SmartSwitchCandidate(id: UUID(), email: "ready@x.com", remainingCharacters: 6000, hasSilentSessionPayload: true),
                SmartSwitchCandidate(id: UUID(), email: "more@x.com", remainingCharacters: 3000, hasSilentSessionPayload: true)
            ],
            allowFullAutomaticReplacement: true
        )
        check(silentSwitch.path == .silentPoolSwitch, "decide: 额度低 + 有静默就绪 → .silentPoolSwitch")
        check(silentSwitch.targetAccountID != nil, "decide: silentPoolSwitch 必须给目标 ID")
        check(silentSwitch.targetEmail == "ready@x.com", "decide: silentPoolSwitch 选余额最多的（6000 > 3000）")
        check(silentSwitch.reason.contains("6000"), "decide: silentPoolSwitch reason 解释剩余字数")

        // 路径选择：额度低 + 无静默就绪 + 允许全自动 → .fullAutomaticReplacement
        let autoReplacement = SmartSwitchPolicy.decide(
            currentRemaining: 50, threshold: 200, forceSwitch: false,
            candidates: [
                SmartSwitchCandidate(id: UUID(), email: "noPayload@x.com", remainingCharacters: 100, hasSilentSessionPayload: false)
            ],
            allowFullAutomaticReplacement: true
        )
        check(autoReplacement.path == .fullAutomaticReplacement, "decide: 额度低 + 无静默就绪 + 允许全自动 → .fullAutomaticReplacement")

        // 路径选择：额度低 + 无可用号 + 不允许全自动 → .none + reason 解释
        let blocked = SmartSwitchPolicy.decide(
            currentRemaining: 50, threshold: 200, forceSwitch: false,
            candidates: [
                SmartSwitchCandidate(id: UUID(), email: "empty@x.com", remainingCharacters: 0, hasSilentSessionPayload: false)
            ],
            allowFullAutomaticReplacement: false
        )
        check(blocked.path == .none, "decide: 额度低 + 不允许全自动 → .none（不擅自注册）")
        check(blocked.reason.contains("未允许自动创建新号"),
              "decide: 无号 + 不允许全自动时 reason 必须解释给用户：\(blocked.reason)")

        // 路径选择：forceSwitch=true 跳过额度判定
        let forced = SmartSwitchPolicy.decide(
            currentRemaining: 9999, threshold: 200, forceSwitch: true,
            candidates: [
                SmartSwitchCandidate(id: UUID(), email: "any@x.com", remainingCharacters: 1, hasSilentSessionPayload: true)
            ],
            allowFullAutomaticReplacement: false
        )
        check(forced.path == .silentPoolSwitch, "decide: forceSwitch=true 跳过额度判定，直接走静默池")

        // 设备用户数超限识别（各种文案变体 + 缺空格变体）
        check(SmartSwitchPolicy.isDeviceUserLimitError("The number of users logged into this device has exceeded the limit"),
              "isDeviceUserLimitError: 完整英文文案")
        check(SmartSwitchPolicy.isDeviceUserLimitError("Numberofusersloggedintothisdevicehasexceededthelimit"),
              "isDeviceUserLimitError: 缺空格英文文案（hasexceeded）")
        check(SmartSwitchPolicy.isDeviceUserLimitError("登录该设备的用户数已超过限制"),
              "isDeviceUserLimitError: 中文完整文案")
        check(SmartSwitchPolicy.isDeviceUserLimitError("设备登录用户数已超"),
              "isDeviceUserLimitError: 中文短文案")
        check(!SmartSwitchPolicy.isDeviceUserLimitError(nil),
              "isDeviceUserLimitError: nil → false（不误判）")
        check(!SmartSwitchPolicy.isDeviceUserLimitError(""),
              "isDeviceUserLimitError: 空字符串 → false")
        check(!SmartSwitchPolicy.isDeviceUserLimitError("normal quota error"),
              "isDeviceUserLimitError: 普通额度错误不误判为设备超限")

        // 巡检间隔换算
        check(SmartSwitchPolicy.normalizeCheckIntervalMinutes(0) == 1, "normalizeCheckIntervalMinutes: 0 → 1（下限保护）")
        check(SmartSwitchPolicy.normalizeCheckIntervalMinutes(-5) == 1, "normalizeCheckIntervalMinutes: 负数 → 1")
        check(SmartSwitchPolicy.normalizeCheckIntervalMinutes(60) == 60, "normalizeCheckIntervalMinutes: 60 不变")
        check(SmartSwitchPolicy.normalizeCheckIntervalMinutes(500) == 120, "normalizeCheckIntervalMinutes: 500 → 120（上限）")

        // nextCheckDelaySeconds: 接近阈值时 20s 加速，否则按分钟
        let urgent = SmartSwitchPolicy.nextCheckDelaySeconds(remaining: 350, threshold: 200, intervalMinutes: 5)
        check(urgent == SmartSwitchPolicy.urgentCheckIntervalSeconds,
              "nextCheckDelaySeconds: remaining 350 < 200*2=400 → 加速到 20s")
        let idle = SmartSwitchPolicy.nextCheckDelaySeconds(remaining: 1000, threshold: 200, intervalMinutes: 5)
        check(idle == 5 * 60, "nextCheckDelaySeconds: remaining 1000 充足 → 5 分钟")
        let noQuotaYet = SmartSwitchPolicy.nextCheckDelaySeconds(remaining: nil, threshold: 200, intervalMinutes: 3)
        check(noQuotaYet == 3 * 60, "nextCheckDelaySeconds: remaining=nil（无数据）→ 用默认间隔")
    }

    // MARK: - v2.4.0 RegistrationAutomationCompletionPolicy 真实行为
    private static func runRegistrationCompletionPolicyChecks() {
        // 浏览器结果为 nil：未完成
        check(!RegistrationAutomationCompletionPolicy.isComplete(verificationCode: nil, browserResult: nil),
              "isComplete: browserResult=nil → false（不能仅凭验证码就判定完成）")
        check(!RegistrationAutomationCompletionPolicy.isComplete(verificationCode: "123456", browserResult: nil),
              "isComplete: 验证码 + browserResult=nil → false（防误判）")

        // 浏览器结果是 Dashboard：完成
        let dashboard = BrowserAutomationResultPayload(
            status: "ok", detail: "registration completed", url: "https://app.typeless.com/dashboard",
            title: "Dashboard - Typeless", timestamp: "2026-08-28T19:00:00Z"
        )
        check(RegistrationAutomationCompletionPolicy.isComplete(verificationCode: "123456", browserResult: dashboard),
              "isComplete: dashboard 页面 → true")

        // 浏览器结果是 Workspace：完成
        let workspace = BrowserAutomationResultPayload(
            status: "ok", detail: "ready", url: "https://app.typeless.com/workspace/abc",
            title: "Workspace", timestamp: "2026-08-28T19:00:00Z"
        )
        check(RegistrationAutomationCompletionPolicy.isComplete(verificationCode: nil, browserResult: workspace),
              "isComplete: workspace 页面 → true（无验证码也完成）")

        // 浏览器结果是错误页：未完成
        let error = BrowserAutomationResultPayload(
            status: "fail", detail: "captcha required", url: "https://typeless.com/register",
            title: "Verify", timestamp: "2026-08-28T19:00:00Z"
        )
        check(!RegistrationAutomationCompletionPolicy.isComplete(verificationCode: "123456", browserResult: error),
              "isComplete: 错误/验证页面 → false")

        // 浏览器结果在注册页：未完成
        let stillRegistering = BrowserAutomationResultPayload(
            status: "ok", detail: "form filled", url: "https://typeless.com/signup",
            title: "Sign up", timestamp: "2026-08-28T19:00:00Z"
        )
        check(!RegistrationAutomationCompletionPolicy.isComplete(verificationCode: nil, browserResult: stillRegistering),
              "isComplete: 仍在注册页 → false")
    }

    // MARK: - v2.4.0 BrowserAutomationResultPayload 真实行为
    private static func runBrowserAutomationResultPayloadChecks() {
        // 正向标记
        let cases: [(String, String, String, Bool)] = [
            ("ok", "https://app.typeless.com/dashboard", "Dashboard", true),
            ("ok", "https://app.typeless.com/workspace/abc", "Workspace", true),
            ("ok", "https://app.typeless.com/home", "Welcome", true),
            ("ok", "https://app.typeless.com/", "Open the desktop app", true),
            ("ok", "https://app.typeless.com/login/app/success", "Success", true),
            ("ok", "https://app.typeless.com/ready", "You're all set", true),
        ]
        for (status, url, title, expected) in cases {
            let p = BrowserAutomationResultPayload(status: status, detail: "ok", url: url, title: title, timestamp: "t")
            check(p.isLikelyRegistrationComplete == expected, "isLikelyRegistrationComplete: \(url) → \(expected)")
        }

        // 负向标记
        let negCases: [(String, String, String, String)] = [
            ("fail", "captcha", "https://typeless.com/register", "Verify"),
            ("error", "invalid", "https://typeless.com/login", "Login"),
            ("ok", "verification failed", "https://typeless.com/signup", "Sign up"),
            ("ok", "请输入验证码", "https://typeless.com/", "注册"),
        ]
        for (status, detail, url, title) in negCases {
            let p = BrowserAutomationResultPayload(status: status, detail: detail, url: url, title: title, timestamp: "t")
            check(!p.isLikelyRegistrationComplete, "isLikelyRegistrationComplete: \(status) \(detail) \(title) → false")
        }

        // summary 字段组合
        let p = BrowserAutomationResultPayload(
            status: "ok", detail: "ok", url: "https://app.typeless.com/dashboard", title: "  Dashboard  ",
            timestamp: "t"
        )
        check(p.summary.contains("Dashboard"), "summary: 保留 title（含 trim 后）")
        check(p.summary.contains("dashboard"), "summary: 含 url")
        let noTitle = BrowserAutomationResultPayload(status: "ok", detail: "ok", url: "https://x.com", title: "   ", timestamp: "t")
        check(noTitle.summary.contains("无标题"), "summary: 空 title 显示「无标题」")
    }

    // MARK: - v2.4.0 ToolkitAccountImporter 边界 & 安全
    private static func runToolkitAccountImporterEdgeCaseChecks() {
        // 缺字段时必须用 fallback，不崩
        let minimal: [String: Any] = ["email": "x@y.com"]
        let r1 = ToolkitAccountImporter.importableAccount(from: minimal, existingDomains: ["y.com"])
        check(r1.account.email == "x@y.com", "importableAccount: 最小输入能导入")
        check(r1.account.name == "x", "importableAccount: 缺 nickname 用 email 本地部分")
        check(r1.account.role == "free", "importableAccount: 缺 role 默认 free")
        check(r1.tokenSummary == nil, "importableAccount: 无 token 不产生 tokenSummary")

        // token 是 NSNumber 而非 String：必须能识别
        let numeric: [String: Any] = [
            "email": "n@y.com",
            "user_id": 12345 as NSNumber,
            "token": 999999 as NSNumber
        ]
        let r2 = ToolkitAccountImporter.importableAccount(from: numeric, existingDomains: ["y.com"])
        check(r2.account.typelessUsername == "12345", "importableAccount: NSNumber user_id 转 string")
        check(r2.tokenSummary?.accessTokenFingerprint == "sha256:937377f056160fc4",
              "importableAccount: NSNumber token 仍生成指纹：实际值 \(r2.tokenSummary?.accessTokenFingerprint ?? "nil")")

        // 空白字段被 trim
        let padded: [String: Any] = [
            "email": "  p@y.com  ",
            "nickname": "   ",
            "user_id": "  uid-1  "
        ]
        let r3 = ToolkitAccountImporter.importableAccount(from: padded, existingDomains: ["y.com"])
        check(r3.account.email == "p@y.com", "importableAccount: email 被 trim")
        check(r3.account.typelessUsername == "uid-1", "importableAccount: user_id 被 trim")

        // refresh_token 但无 access_token：只记 refresh
        let refreshOnly: [String: Any] = [
            "email": "r@y.com",
            "refresh_token": "r-secret"
        ]
        let r4 = ToolkitAccountImporter.importableAccount(from: refreshOnly, existingDomains: ["y.com"])
        check(r4.tokenSummary?.accessTokenFingerprint == nil, "importableAccount: 无 access_token → access 指纹 nil")
        check(r4.tokenSummary?.refreshTokenFingerprint != nil, "importableAccount: 有 refresh_token → refresh 指纹存在")
        check(r4.tokenSummary?.discoveredKeys == ["refresh_token"], "importableAccount: discoveredKeys 只含 refresh_token")

        // 邮箱无 @：domain fallback 到 existingDomains.first
        let noAt: [String: Any] = ["email": "weird-format", "nickname": "weird"]
        let r5 = ToolkitAccountImporter.importableAccount(from: noAt, existingDomains: ["fallback.com"])
        check(r5.account.domain == "fallback.com", "importableAccount: 无 @ 邮箱 → domain 走 fallback")

        // notes 包含「明文 token 警示」
        let r6 = ToolkitAccountImporter.importableAccount(
            from: ["email": "n@y.com", "token": "super-secret-token"],
            existingDomains: ["y.com"]
        )
        check(r6.account.notes.contains("未保存明文 token"),
              "importableAccount: notes 必须告知「未保存明文」")
        check(!r6.account.notes.contains("super-secret-token"),
              "importableAccount: notes 不能含明文 token")

        // 完全空输入：email="", name=""（@ 切分首段为 ""）, domain=fallback, role=free
        let empty: [String: Any] = [:]
        let r7 = ToolkitAccountImporter.importableAccount(from: empty, existingDomains: ["only.com"])
        check(r7.account.email == "", "importableAccount: 空输入 email=''")
        check(r7.account.name.isEmpty, "importableAccount: 完全空时 name 为空（email 本地部分 = ''）")
        check(r7.account.domain == "only.com", "importableAccount: 完全空时 domain 走 fallback")
        check(r7.tokenSummary == nil, "importableAccount: 完全空无 token")

        // email 无 @ + nickname 为空：name 走 email 本地部分（无 @ 时 first = 整体）
        let noAtNoNick: [String: Any] = ["email": "weird-format"]
        let r8 = ToolkitAccountImporter.importableAccount(from: noAtNoNick, existingDomains: ["only.com"])
        check(r8.account.name == "weird-format",
              "importableAccount: 无 @ 邮箱切分 first = 整体（当前实现行为）")
        check(r8.account.domain == "only.com",
              "importableAccount: 无 @ 邮箱 → domain 走 existingDomains fallback")
    }

    // MARK: - StoreRecovery：真的读写临时目录，不做源码字符串断言

    private static func runStoreRecoveryChecks() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("store-recovery-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        struct Payload: Equatable { let value: Int }
        let timeZone = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fixedNow = Date(timeIntervalSince1970: 1_755_000_000) // 2025-08-13T09:20:00Z

        // 1. 备份后缀必须文件名安全：无冒号、无斜杠、无空格
        let suffix = StoreRecovery.corruptedBackupNameSuffix(fixedNow, timeZone: timeZone)
        check(suffix.count == 15, "StoreRecovery: 后缀长度 15（yyyyMMdd-HHmmss），实际 \(suffix.count)")
        check(suffix.contains("-"), "StoreRecovery: 后缀含日期-时间分隔符")
        let illegal: Set<Character> = [":", "/", " ", "\\"]
        check(suffix.allSatisfy { !illegal.contains($0) }, "StoreRecovery: 后缀文件名安全（无 : / 空格）")

        // 2. 完整备份文件名 = store.json.corrupted-<后缀>
        let backupName = StoreRecovery.corruptedBackupFileName(fixedNow, timeZone: timeZone)
        check(backupName.hasPrefix("store.json.corrupted-"), "StoreRecovery: 备份名前缀 store.json.corrupted-")
        check(backupName == "store.json.corrupted-\(suffix)", "StoreRecovery: 备份名拼装一致")

        // 3. 正常读取 + 解码成功：返回 success，且磁盘上文件仍存在（不能被误备份移走）
        let goodURL = root.appendingPathComponent("store.json")
        try? Data("{\"value\":7}".utf8).write(to: goodURL)
        let good = StoreRecovery.load(
            from: goodURL, now: fixedNow, timeZone: timeZone, fileManager: fm
        ) { data -> Payload in
            let text = String(data: data, encoding: .utf8) ?? ""
            return Payload(value: Int(text.filter(\.isNumber)) ?? -1)
        }
        check(good == .success(Payload(value: 7)), "StoreRecovery: 正常文件解码成功")
        check(fm.fileExists(atPath: goodURL.path), "StoreRecovery: 成功路径绝不动原文件")

        // 4. 解码失败：原文件被移走备份，且备份内容与原文件逐字节一致（这是 P0-2 的核心保证）
        let badURL = root.appendingPathComponent("store.json")
        let originalBytes = Data("NOT-VALID-JSON-Ω".utf8)
        try? originalBytes.write(to: badURL)

        enum DecodeBoom: Error { case boom }
        let bad = StoreRecovery.load(
            from: badURL, now: fixedNow, timeZone: timeZone, fileManager: fm
        ) { _ -> Payload in throw DecodeBoom.boom }

        guard case .failure(let failure) = bad else {
            fputs("FAIL: StoreRecovery: 解码失败必须返回 .failure\n", stderr)
            exit(1)
        }
        check(failure.backupFileName == backupName, "StoreRecovery: 失败时备份名 = store.json.corrupted-<ts>")
        check(failure.backupErrorDescription == nil, "StoreRecovery: 备份成功时无 backupError")
        check(!fm.fileExists(atPath: badURL.path),
              "StoreRecovery: 损坏文件已被移走（不会在下一次读取时二次损坏）")
        let backupURL = root.appendingPathComponent(backupName)
        check(fm.fileExists(atPath: backupURL.path), "StoreRecovery: 备份文件真实落盘")
        check(fm.contents(atPath: backupURL.path) == originalBytes,
              "StoreRecovery: 备份内容与原文件逐字节一致（Keychain 密码不丢）")
        check(failure.message.contains("已备份为 \(backupName)"),
              "StoreRecovery: 用户文案说明已备份，实际：\(failure.message)")

        // 5. 文件根本不存在：同样走失败分支，文案里带解码错误，不会 crash
        let missingURL = root.appendingPathComponent("never-written.json")
        let missing = StoreRecovery.load(
            from: missingURL, now: fixedNow, timeZone: timeZone, fileManager: fm
        ) { _ -> Payload in Payload(value: 0) }
        guard case .failure(let missingFailure) = missing else {
            fputs("FAIL: StoreRecovery: 文件不存在必须返回 .failure\n", stderr)
            exit(1)
        }
        check(!missingFailure.decodeErrorDescription.isEmpty,
              "StoreRecovery: 缺失文件带出可读错误描述")
        check(missingFailure.message.contains("无法读取账号池"),
              "StoreRecovery: 缺失文件文案包含「无法读取账号池」")

        // 6. 备份目标已存在同名文件：先删后移，不被旧备份卡住
        let collisionURL = root.appendingPathComponent("store.json")
        try? Data("BROKEN-AGAIN".utf8).write(to: collisionURL)
        try? Data("OLD-BACKUP".utf8).write(to: root.appendingPathComponent(backupName))
        let collision = StoreRecovery.load(
            from: collisionURL, now: fixedNow, timeZone: timeZone, fileManager: fm
        ) { _ -> Payload in throw DecodeBoom.boom }
        guard case .failure(let collisionFailure) = collision else {
            fputs("FAIL: StoreRecovery: 同名备份冲突场景必须返回 .failure\n", stderr)
            exit(1)
        }
        check(collisionFailure.backupErrorDescription == nil,
              "StoreRecovery: 同名旧备份被覆盖，不报错")
        check(fm.contents(atPath: root.appendingPathComponent(backupName).path) == Data("BROKEN-AGAIN".utf8),
              "StoreRecovery: 同名备份被新内容覆盖")
    }

    // MARK: - QuotaGuardLaunchAgentPlanner：对真实 plist 文本做断言

    private static func runQuotaGuardLaunchAgentPlannerChecks() {
        let planner = QuotaGuardLaunchAgentPlanner.self

        // 1. 间隔换算走 SmartSwitchPolicy 归一化：0/负数 → 1 分钟，超上限 → 120 分钟
        check(planner.intervalSeconds(intervalMinutes: 5) == 300, "Planner: 5 分钟 → 300 秒")
        check(planner.intervalSeconds(intervalMinutes: 0) == 60, "Planner: 0 分钟被拉到 1 分钟（60 秒）")
        check(planner.intervalSeconds(intervalMinutes: -30) == 60, "Planner: 负数被拉到 1 分钟")
        check(planner.intervalSeconds(intervalMinutes: 9999) == 120 * 60, "Planner: 超大值压到 120 分钟上限")

        // 2. daemon 动态调间隔的钳制：launchd 低于 20 秒会拒绝加载
        check(planner.reconciledIntervalSeconds(1) == planner.minimumIntervalSeconds,
              "Planner: 1 秒被拉到最小 \(planner.minimumIntervalSeconds) 秒")
        check(planner.reconciledIntervalSeconds(0) == planner.minimumIntervalSeconds, "Planner: 0 秒同样钳到最小")
        check(planner.reconciledIntervalSeconds(10_000) == planner.maximumIntervalSeconds,
              "Planner: 超大秒数压到 \(planner.maximumIntervalSeconds) 秒")
        check(planner.reconciledIntervalSeconds(600) == 600, "Planner: 合法值原样返回")

        // 3. 日志路径：目录标准化 + 固定文件名
        let logDir = "/tmp/typeless//./logs"
        let logs = planner.logPaths(logDirectory: logDir)
        check(logs.stdout.hasSuffix("quota-guard-launchd.out.log"), "Planner: stdout 日志文件名")
        check(logs.stderr.hasSuffix("quota-guard-launchd.err.log"), "Planner: stderr 日志文件名")
        check(!logs.stdout.contains("//") && !logs.stdout.contains("/./"),
              "Planner: 日志路径已标准化（无 // 与 /./）")

        // 4. 生成的 plist 必须是可被 PropertyListSerialization 解析的真实 XML（不是"看起来像"）
        let programPath = "/Applications/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard"
        let plist = planner.plistDocument(programPath: programPath, intervalMinutes: 3, logDirectory: logDir)
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: Data(plist.utf8), options: [], format: nil
        ) as? [String: Any] else {
            fputs("FAIL: Planner: 生成的 plist 无法被 PropertyListSerialization 解析\n", stderr)
            exit(1)
        }
        check(parsed["Label"] as? String == planner.label, "Planner: plist Label 正确")
        check(parsed["RunAtLoad"] as? Bool == true, "Planner: plist RunAtLoad = true")
        check(parsed["StartInterval"] as? Int == 180, "Planner: plist StartInterval = 180（3 分钟）")
        check(parsed["ProcessType"] as? String == planner.processType, "Planner: plist ProcessType = Background")
        check(parsed["Nice"] as? Int == planner.niceValue, "Planner: plist Nice = 10")
        let args = parsed["ProgramArguments"] as? [String]
        check(args?.count == 2, "Planner: ProgramArguments 有 2 项")
        check(args?.first == programPath, "Planner: ProgramArguments[0] 是可执行路径")
        check(args?.last == planner.daemonFlag, "Planner: ProgramArguments[1] = \(planner.daemonFlag)")
        check(parsed["StandardOutPath"] as? String == logs.stdout, "Planner: plist stdout 路径与 logPaths 一致")

        // 5. StartInterval 回读：文本路径与 Data 路径必须给出同一个值
        check(planner.startIntervalSeconds(inPlistText: plist) == 180, "Planner: 从文本回读 StartInterval")
        check(planner.startIntervalSeconds(inPlistData: Data(plist.utf8)) == 180, "Planner: 从 Data 回读 StartInterval")

        // 6. StartInterval 缺失时两个入口都返回 nil（调用方据此放弃改写）
        let noInterval = plist.replacingOccurrences(of: "<key>StartInterval</key>\n  <integer>180</integer>", with: "")
        check(planner.startIntervalSeconds(inPlistText: noInterval) == nil, "Planner: 无 StartInterval 文本 → nil")
        check(planner.startIntervalSeconds(inPlistData: Data(noInterval.utf8)) == nil, "Planner: 无 StartInterval Data → nil")
        check(planner.replacingStartInterval(inPlistText: noInterval, seconds: 90) == nil,
              "Planner: 无 StartInterval 时改写返回 nil（不硬写坏 plist）")

        // 7. 就地改写：只动 StartInterval，其余键完好，且改后仍可解析
        guard let updated = planner.replacingStartInterval(inPlistText: plist, seconds: 60) else {
            fputs("FAIL: Planner: StartInterval 存在时改写不应返回 nil\n", stderr)
            exit(1)
        }
        check(updated != plist, "Planner: 改写确实产生了变化")
        check(planner.startIntervalSeconds(inPlistText: updated) == 60, "Planner: 改写后回读 = 60")
        guard let reparsed = try? PropertyListSerialization.propertyList(
            from: Data(updated.utf8), options: [], format: nil
        ) as? [String: Any] else {
            fputs("FAIL: Planner: 改写后的 plist 无法解析\n", stderr)
            exit(1)
        }
        check(reparsed["StartInterval"] as? Int == 60, "Planner: 改写后仍是合法 plist 且 StartInterval = 60")
        check(reparsed["Label"] as? String == planner.label, "Planner: 改写未破坏 Label")
        check((reparsed["ProgramArguments"] as? [String])?.last == planner.daemonFlag,
              "Planner: 改写未破坏 ProgramArguments")
        check(reparsed["RunAtLoad"] as? Bool == true, "Planner: 改写未破坏 RunAtLoad")

        // 8. 上限对齐：Planner 最大间隔与 SmartSwitchPolicy 归一化上限一致，不能两边各说各话
        check(planner.maximumIntervalSeconds == SmartSwitchPolicy.normalizeCheckIntervalMinutes(120) * 60,
              "Planner: 最大间隔与 SmartSwitchPolicy 上限对齐")
    }
}
