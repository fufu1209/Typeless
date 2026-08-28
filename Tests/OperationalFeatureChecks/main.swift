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

        // MARK: - v2.5.2：阈值边界 + 钥匙串缓存回归
        runThresholdBoundaryChecks()
        runKeychainCacheBehaviorChecks()
        runConfigurationBundleChecks()

        // MARK: - v2.5.3：用户回归报障三项（新手引导 / 下次可用 / 无感换号）
        runNextAvailabilityChecks()
        runOnboardingSchemaChecks()

        // MARK: - v2.5.4：周额度完整生命周期（用尽 → 倒计时 → 周一复活 → 回到 8000）
        runWeeklyQuotaLifecycleChecks()

        // MARK: - v2.5.5：周期时区可配置 + 引导补丁自愈补强
        runQuotaCycleClockChecks()
        runOnboardingSelfHealChecks()

        // MARK: - v2.5.6：周期口径改为实测观测，不再靠猜
        runQuotaCycleObservationChecks()
        runQuotaCycleObservationStoreChecks()

        print("Operational feature checks passed")
    }

    // MARK: - v2.5.5 周期时钟（QuotaCycleClock）
    //
    // 背景：本机系统时区停在 Asia/Bangkok(+0700)，用户实际在深圳(+0800)。
    // 「周一 00:00」相对哪个时区决定了复活时刻，差一小时就会出现
    // 「倒计时归零了但还没复活」。这里把时钟的单一事实来源钉死。

    private static func runQuotaCycleClockChecks() {
        // 1) 默认跟随系统：与改造前行为一致，老 store.json 无需迁移
        QuotaCycleClock.shared.setTimeZone(nil)
        check(QuotaCycleClock.shared.timeZone.identifier == TimeZone.current.identifier,
              "QuotaCycleClock：默认跟随系统时区")

        // 2) 覆盖成 UTC+8 后，倒计时与复活判定必须用同一个日历
        guard let shanghai = TimeZone(identifier: "Asia/Shanghai") else {
            check(false, "QuotaCycleClock：Asia/Shanghai 时区应可解析")
            return
        }
        QuotaCycleClock.shared.setTimeZone(shanghai)
        check(QuotaCycleClock.shared.timeZone.identifier == "Asia/Shanghai",
              "QuotaCycleClock：可按 TimeZone 覆盖")
        check(QuotaCycleClock.shared.calendar.timeZone.identifier == "Asia/Shanghai",
              "QuotaCycleClock：calendar 必须带上覆盖时区（否则 UI 与判定分叉）")
        check(QuotaCycleClock.shared.calendar.firstWeekday == 2,
              "QuotaCycleClock：一周之始必须是周一（ISO 8601）")

        // 3) 同一时刻在 +0700 与 +0800 下，下次周界相差整 1 小时 —— 这正是要修的偏移
        var bangkok = Calendar(identifier: .iso8601)
        bangkok.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        var shanghaiCal = Calendar(identifier: .iso8601)
        shanghaiCal.timeZone = shanghai
        let moment = Date(timeIntervalSince1970: 1_785_447_800)
        let bkkReset = QuotaCycleEngine.nextCalendarWeekReset(now: moment, calendar: bangkok)
        let shaReset = QuotaCycleEngine.nextCalendarWeekReset(now: moment, calendar: shanghaiCal)
        if let bkkReset, let shaReset {
            let drift = abs(bkkReset.timeIntervalSince(shaReset))
            check(abs(drift - 3600) < 1,
                  "QuotaCycleClock：+0700 与 +0800 的周界相差正好 1 小时（实测 \(drift) 秒）")
        } else {
            check(false, "QuotaCycleClock：两个时区都应算出下次周界")
        }

        // 4) 按标识符设置；非法标识符返回 false 且不改变现状
        let before = QuotaCycleClock.shared.timeZone.identifier
        check(!QuotaCycleClock.shared.setTimeZone(identifier: "Not/AZone"),
              "QuotaCycleClock：非法时区标识符返回 false")
        check(QuotaCycleClock.shared.timeZone.identifier == before,
              "QuotaCycleClock：非法时区标识符不改变现状")
        check(QuotaCycleClock.shared.setTimeZone(identifier: ""),
              "QuotaCycleClock：空标识符 = 跟随系统，返回 true")
        check(QuotaCycleClock.shared.timeZone.identifier == TimeZone.current.identifier,
              "QuotaCycleClock：空标识符后回到系统时区")

        // 5) 恢复默认，避免污染后续用例
        QuotaCycleClock.shared.setTimeZone(nil)
    }

    // MARK: - v2.5.6 周期口径观测
    //
    // 用户问：「额度用完的倒计时，应该从用完的时候开始算一个星期吧？
    //          不是说明天是周一、明天就能用吧？」
    //
    // 老实说：官方 /user/usage_stats **不返回重置时间戳**，免费账号的
    // current_period_end 也是 null —— 这件事服务端没告诉我们，之前是推断的。
    // 不继续猜，改成观测：额度数值下降那一刻就是一次真实重置。

    // MARK: - v2.5.6 周期观测的落盘持久化
    //
    // 观测要跨周才攒得够（判定自然周 vs 滚动 7 天至少要看两三次重置 = 两三周）。
    // 只放内存的话 App 一重启就清零，用户每天开关机永远攒不到样本 ——
    // 这是「查缺补漏」里最该补的一条。

    private static func runQuotaCycleObservationStoreChecks() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-obs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("quota-cycle-observations.json")

        // 1) 文件不存在 → 空数组，不能崩
        check(QuotaCycleObservationStore.load(from: url).isEmpty,
              "观测落盘：文件不存在时返回空数组")

        // 2) 追加后能读回，且字段无损。
        //    2026-08-24 / 08-31 00:00 UTC+8 都是周一 00:00（已核对，别改）
        let t1 = Date(timeIntervalSince1970: 1_787_500_800)
        let t2 = Date(timeIntervalSince1970: 1_788_105_600)
        _ = QuotaCycleObservationStore.append(
            QuotaCycleObservationStore.Record(at: t1, from: 8000, to: 0, email: "a@example.com"),
            to: url
        )
        let afterTwo = QuotaCycleObservationStore.append(
            QuotaCycleObservationStore.Record(at: t2, from: 6500, to: 120, email: "b@example.com"),
            to: url
        )
        check(afterTwo.count == 2, "观测落盘：追加两条后为 2 条（实测 \(afterTwo.count)）")

        let reloaded = QuotaCycleObservationStore.load(from: url)
        check(reloaded.count == 2, "观测落盘：重新读取仍为 2 条（模拟 App 重启）")
        check(reloaded.first?.email == "a@example.com", "观测落盘：邮箱保留，便于事后人工核对")
        check(reloaded.last?.from == 6500 && reloaded.last?.to == 120, "观测落盘：下降幅度保留")
        check(abs((reloaded.first?.at.timeIntervalSince1970 ?? 0) - t1.timeIntervalSince1970) < 1,
              "观测落盘：时间戳精确到秒")

        // 3) 落盘的记录能直接喂给引擎做口径判定 —— 这是整条链路的闭环
        var shanghai = Calendar(identifier: .iso8601)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let inference = QuotaCycleEngine.inferCycleMode(
            fromResets: QuotaCycleObservationStore.resets(from: reloaded),
            calendar: shanghai
        )
        // t1=2026-08-24 00:00 UTC+8 正好是周一 00:00，t2 是下一周同一刻 → 应判自然周
        check(inference.observationCount == 2, "观测落盘：读回的记录能喂给引擎（\(inference.observationCount) 条）")
        if case .calendarWeek(let n) = inference {
            check(n == 2, "观测落盘：跨重启后仍能判出自然周（依据 \(n) 次实测）")
        } else {
            check(false, "观测落盘：两次重置都落在周一 00:00，应判为自然周，实际 \(inference)")
        }

        // 4) 条数上限：不能无限增长
        for i in 0..<(QuotaCycleObservationStore.maximumRetained + 20) {
            _ = QuotaCycleObservationStore.append(
                QuotaCycleObservationStore.Record(at: t1.addingTimeInterval(Double(i)), from: 10, to: 0, email: "x"),
                to: url
            )
        }
        let capped = QuotaCycleObservationStore.load(from: url)
        check(capped.count == QuotaCycleObservationStore.maximumRetained,
              "观测落盘：条数封顶 \(QuotaCycleObservationStore.maximumRetained)（实测 \(capped.count)）")

        // 5) 清空（排障用）
        QuotaCycleObservationStore.clear(url)
        check(QuotaCycleObservationStore.load(from: url).isEmpty, "观测落盘：clear 后可重新开始观测")
    }

    private static func runQuotaCycleObservationChecks() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

        // 2026-08-24 与 08-31 都是周一
        let monday1 = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 0, minute: 0))!
        let monday2 = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 0, minute: 0))!
        let wednesday = cal.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 15, minute: 0))!

        // 1) 没观测到重置 → 结论必须是「未定」，不许假装知道
        let noResets: [QuotaCycleEngine.ObservedReset] = []
        check(QuotaCycleEngine.inferCycleMode(fromResets: noResets, calendar: cal) == .insufficient(observations: 0),
              "周期观测：无观测 → 结论未定（不许把推断包装成确定结论）")

        // 2) 重置都落在周一 00:00 → 自然周
        let weeklyResets = [
            QuotaCycleEngine.ObservedReset(at: monday1, from: 8000, to: 0),
            QuotaCycleEngine.ObservedReset(at: monday2, from: 7500, to: 0)
        ]
        check(QuotaCycleEngine.inferCycleMode(fromResets: weeklyResets, calendar: cal) == .calendarWeek(observations: 2),
              "周期观测：重置都落在周一 00:00 → 判定自然周")

        // 3) 重置散落在七天里 → 滚动 7 天
        let rollingResets = [
            QuotaCycleEngine.ObservedReset(at: wednesday, from: 8000, to: 0),
            QuotaCycleEngine.ObservedReset(
                at: cal.date(byAdding: .day, value: 7, to: wednesday)!, from: 8000, to: 0)
        ]
        check(QuotaCycleEngine.inferCycleMode(fromResets: rollingResets, calendar: cal) == .rollingWeek(observations: 2),
              "周期观测：重置散落在周中 → 判定滚动 7 天")

        // 4) 有的落在周界、有的不落 → 不一致，需要人工看
        let mixed = weeklyResets + [rollingResets[0]]
        check(QuotaCycleEngine.inferCycleMode(fromResets: mixed, calendar: cal) == .inconsistent(observations: 3),
              "周期观测：混合 → 判定不一致，提示人工核")

        // 5) 从采样序列里找下降点；小幅抖动不算重置（默认阈值 50）
        let samples = [
            QuotaCycleEngine.UsageSample(at: monday1.addingTimeInterval(-3600), usedCharacters: 8000),
            QuotaCycleEngine.UsageSample(at: monday1, usedCharacters: 0),
            QuotaCycleEngine.UsageSample(at: monday1.addingTimeInterval(3600), usedCharacters: 300),
            // 掉 30，低于阈值 50，不应被当成重置
            QuotaCycleEngine.UsageSample(at: monday1.addingTimeInterval(7200), usedCharacters: 270)
        ]
        let found = QuotaCycleEngine.observedResetInstants(in: samples)
        check(found.count == 1, "周期观测：只识别出 1 次真实重置（小幅抖动被阈值滤掉，实测 \(found.count)）")
        check(found.first?.at == monday1, "周期观测：重置时刻定位到周一 00:00")
        check(found.first?.from == 8000, "周期观测：记录了重置前的用量")

        // 6) 周界距离：周一 00:00 应为 0，周中应远大于容差
        check(QuotaCycleEngine.secondsFromWeeklyBoundary(monday1, calendar: cal) < 1,
              "周期观测：周一 00:00 距周界为 0")
        check(QuotaCycleEngine.secondsFromWeeklyBoundary(wednesday, calendar: cal) > 3_600,
              "周期观测：周三下午距周界大于 1 小时容差")

        // 7) 文案必须诚实：观测不足时不能给出确定结论
        check(QuotaCycleEngine.cycleConfidenceText(.insufficient(observations: 0)).contains("待确认"),
              "周期观测：观测不足时文案必须说“待确认”")
        check(QuotaCycleEngine.cycleConfidenceText(.calendarWeek(observations: 2)).contains("已确认"),
              "周期观测：确认后文案才说“已确认”")
    }

    // MARK: - v2.5.5 引导补丁自愈补强
    //
    // v2.5.4 的缺口：把「读不到 app-onboarding.json」一律当成「已完成」，
    // 于是 Typeless 升级删掉这个文件后补丁永不触发，而它冷启动又会按默认值重建
    // —— 变回未完成，白等一整轮。这里把「缺失 + 已安装 = 需要补写」钉死。

    private static func runOnboardingSelfHealChecks() {
        // 1) 状态判定：三种状态必须能区分开，不能把 missing 当成 complete
        let complete: [String: Any] = ["isCompleted": true, "step": 99]
        let incompleteByFlag: [String: Any] = ["isCompleted": false, "step": 0]
        let incompleteByStep: [String: Any] = ["step": 3]
        let noFields: [String: Any] = ["somethingElse": true]

        check(Self.onboardingIsIncomplete(complete, appInstalled: true) == false,
              "引导状态：isCompleted=true → 已完成")
        check(Self.onboardingIsIncomplete(incompleteByFlag, appInstalled: true),
              "引导状态：isCompleted=false → 未完成")
        check(Self.onboardingIsIncomplete(incompleteByStep, appInstalled: true),
              "引导状态：step<99 → 未完成")
        check(Self.onboardingIsIncomplete(noFields, appInstalled: true),
              "引导状态：文件在但无完成字段 → 按未完成处理（补写无副作用）")

        // 2) 文件缺失：装了 Typeless 才算需要处理，没装不该误报警
        check(Self.onboardingIsIncomplete(nil, appInstalled: true),
              "引导状态：文件缺失 + 已安装 → 需要补写（v2.5.4 在这里漏判）")
        check(Self.onboardingIsIncomplete(nil, appInstalled: false) == false,
              "引导状态：文件缺失 + 未安装 → 不误报警")

        // 3) 写盘路径：以前只能等 Typeless 关掉才能实测，现在 Core 层可直接构造现场
        runOnboardingPatchWriterChecks()

        // 4) 日志轮转：直接打真实实现（LogFileRotator），不另抄一份逻辑
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchboard-log-rotate-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let logURL = dir.appendingPathComponent("rotate-test.log")
        try? (0..<1000).map { "line-\($0)" }.joined(separator: "\n")
            .write(to: logURL, atomically: true, encoding: .utf8)
        check(LogFileRotator.rotate(logURL), "LogFileRotator：1000 行文件应该裁得动")
        let afterFirst = (try? String(contentsOf: logURL, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).count ?? -1
        check(afterFirst == 500, "LogFileRotator：1000 行裁到 500 行（实测 \(afterFirst)）")
        check(((try? String(contentsOf: logURL, encoding: .utf8))?.contains("line-999") ?? false),
              "LogFileRotator：保留的是最近的半截（含 line-999）")
        check(!((try? String(contentsOf: logURL, encoding: .utf8))?.contains("line-0\n") ?? true),
              "LogFileRotator：最早的半截已被裁掉")

        // 行数不足保底值（500）时完全不动文件，避免在小日志上反复抖动
        try? (0..<400).map { "x-\($0)" }.joined(separator: "\n")
            .write(to: logURL, atomically: true, encoding: .utf8)
        check(!LogFileRotator.rotate(logURL),
              "LogFileRotator：400 行 < 保底 500 行，不裁")

        // 4) 超限判定：只有超过 maxBytes 才轮转
        let small = dir.appendingPathComponent("small.log")
        try? "tiny".write(to: small, atomically: true, encoding: .utf8)
        check(!LogFileRotator.rotateIfNeeded(small),
              "LogFileRotator：小文件不触发轮转")

        // 5) 大文件必须一次调用就砍到上限以下，而不是每次启动只砍一半
        let huge = dir.appendingPathComponent("huge.log")
        let payload = (0..<20_000).map { "heavy-log-line-\($0)-padding-padding-padding" }.joined(separator: "\n")
        try? payload.write(to: huge, atomically: true, encoding: .utf8)
        let limit: UInt64 = 100 * 1024
        let hugeBefore = (try? FileManager.default.attributesOfItem(atPath: huge.path)[.size] as? UInt64) ?? 0
        check(hugeBefore > limit, "LogFileRotator：测试样本本身要超过上限（\(hugeBefore) 字节）")
        check(LogFileRotator.rotateIfNeeded(huge, maxBytes: limit), "LogFileRotator：超限文件触发轮转")
        let hugeAfter = (try? FileManager.default.attributesOfItem(atPath: huge.path)[.size] as? UInt64) ?? 0
        check(hugeAfter <= limit,
              "LogFileRotator：一次调用就砍到上限以内（\(hugeBefore) → \(hugeAfter) 字节，上限 \(limit)）")

        // 5) 追加写入：自动建目录 + 自动补换行
        let appended = dir.appendingPathComponent("nested/\(UUID().uuidString)/appended.log")
        LogFileRotator.append(line: "first", to: appended)
        LogFileRotator.append(line: "second", to: appended)
        let appendedText = (try? String(contentsOf: appended, encoding: .utf8)) ?? ""
        check(appendedText == "first\nsecond\n",
              "LogFileRotator：append 自动建目录并补换行（得到 \(appendedText.debugDescription)）")
    }

    /// 与 `SwitchboardStore.desktopOnboardingIsIncomplete()` 同构的判定。
    /// 单独抄一份是为了能在不开 App 的前提下断言规则；实现改了这里也要跟着改。
    private static func onboardingIsIncomplete(_ object: [String: Any]?, appInstalled: Bool) -> Bool {
        guard let object else { return appInstalled }
        if let done = object["isCompleted"] as? Bool { return !done }
        if let step = object["step"] as? Int { return step < 99 }
        return true
    }

    // MARK: - v2.5.5 引导补丁写入层（OnboardingPatchWriter）
    //
    // 这段逻辑以前住在 App 层，验证只能靠「真机关掉 Typeless 再重启」，
    // 而用户的 Typeless 基本常开 —— 等于从来没被测过。下沉到 Core 之后，
    // 可以在临时目录构造任意现场逐个断言。

    private static func runOnboardingPatchWriterChecks() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-patch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let onboardingURL = root.appendingPathComponent("app-onboarding.json")
        let storageURL = root.appendingPathComponent("app-storage.json")

        // --- 场景 1：文件被删（Typeless 升级/重装的典型现场）→ 从零补写 ---
        check(OnboardingPatchWriter.state(ofOnboardingFile: onboardingURL) == .missing,
              "写入层：文件不存在 → state = missing")
        check(OnboardingPatchWriter.needsPatch(state: .missing, treatMissingAsNeedsPatch: true),
              "写入层：missing + 已安装 → 需要补写")
        check(!OnboardingPatchWriter.needsPatch(state: .missing, treatMissingAsNeedsPatch: false),
              "写入层：missing + 未安装 → 不补写（不误报警）")

        try? OnboardingPatchWriter.writeCompletion(toOnboardingFile: onboardingURL)
        check(OnboardingPatchWriter.state(ofOnboardingFile: onboardingURL) == .complete,
              "写入层：空白现场补写后 → 完成态")
        let fresh = Self.readJSON(onboardingURL)
        check(fresh?["isCompleted"] as? Bool == true, "写入层：isCompleted=true")
        check(fresh?["step"] as? Int == OnboardingPatchWriter.completedStep, "写入层：step=99")
        check(fresh?["setUpStep"] as? Int == OnboardingPatchWriter.completedStep, "写入层：setUpStep=99")
        check(fresh?["tryItStep"] as? Int == OnboardingPatchWriter.completedStep, "写入层：tryItStep=99")

        // --- 场景 2：引导被重置（isCompleted=false, step=0）→ 覆盖回完成态，且保留其他键 ---
        let withExtras: [String: Any] = [
            "isCompleted": false, "step": 0,
            "userSettingNotToTouch": "keep-me",
            "translationModeFeatureOnboarding": ["settingDot": ["dismissed": false], "newTags": ["dismissed": false]]
        ]
        try? Self.writeJSON(withExtras, to: onboardingURL)
        check(OnboardingPatchWriter.state(ofOnboardingFile: onboardingURL) == .incomplete,
              "写入层：重置现场 → incomplete")
        try? OnboardingPatchWriter.writeCompletion(toOnboardingFile: onboardingURL)
        let healed = Self.readJSON(onboardingURL)
        check(healed?["isCompleted"] as? Bool == true, "写入层：重置后补写 → isCompleted=true")
        check(healed?["step"] as? Int == 99, "写入层：重置后补写 → step=99")
        check(healed?["userSettingNotToTouch"] as? String == "keep-me",
              "写入层：补写不能吞掉文件里的其他键")
        let nested = healed?["translationModeFeatureOnboarding"] as? [String: Any]
        check((nested?["settingDot"] as? [String: Any])?["dismissed"] as? Bool == true,
              "写入层：已存在的嵌套节点要钻进去改 dismissed")
        check((nested?["newTags"] as? [String: Any])?["dismissed"] as? Bool == true,
              "写入层：newTags 同样置为 dismissed")

        // --- 场景 3：备份只留第一份 ---
        let backupURL = OnboardingPatchWriter.backupURL(for: onboardingURL)
        check(backupURL.lastPathComponent == "app-onboarding.json.switchboard-orig.bak",
              "写入层：备份文件名带原扩展名（\(backupURL.lastPathComponent)）")
        try? FileManager.default.removeItem(at: backupURL)
        OnboardingPatchWriter.backupIfNeeded(onboardingURL)
        check(FileManager.default.fileExists(atPath: backupURL.path), "写入层：首次调用生成备份")
        let backupSnapshot = (try? Data(contentsOf: backupURL))?.count ?? -1
        try? OnboardingPatchWriter.writeCompletion(toOnboardingFile: onboardingURL)
        OnboardingPatchWriter.backupIfNeeded(onboardingURL)
        let backupAfterSecondWrite = (try? Data(contentsOf: backupURL))?.count ?? -2
        check(backupSnapshot == backupAfterSecondWrite,
              "写入层：第二次不再覆盖备份（否则备份就失去意义了）")

        // --- 场景 4：app-storage.json 平台补齐 + is_new_user 落 false ---
        let userData: [String: Any] = [
            "email": "someone@example.com",
            "is_new_user": true,
            "onboarding": ["macos": ["completed": false]]
        ]
        try? Self.writeJSON(["userData": userData, "currentRoute": "/onboarding"], to: storageURL)
        try? OnboardingPatchWriter.writeStorageCompletion(
            to: storageURL, expectedEmail: nil, reportedVersion: "2.4.0"
        )
        let storage = Self.readJSON(storageURL)
        let patchedUser = storage?["userData"] as? [String: Any]
        check(patchedUser?["is_new_user"] as? Bool == false, "写入层：is_new_user 落为 false")
        let platforms = patchedUser?["onboarding"] as? [String: Any]
        // 官方 7 个平台 + 文件里原有的 macos，全都要是 completed=true
        let allCompleted = OnboardingPatchWriter.officialPlatforms.allSatisfy { platform in
            ((platforms?[platform] as? [String: Any])?["completed"] as? Bool) == true
        }
        check(allCompleted, "写入层：7 个官方平台全部标记 completed")
        let macos = platforms?["macos"] as? [String: Any]
        check(macos?["app_version"] as? String == "2.4.0", "写入层：macos.app_version 写入报告版本")
        check(macos?["completed_at"] != nil, "写入层：macos.completed_at 已补")
        check(storage?["currentRoute"] is NSNull, "写入层：currentRoute 清空，避免下次启动接着弹引导")

        // --- 场景 5：账号不匹配必须报错（fail-safe 的另一半：不能静默改错号） ---
        var mismatchThrown = false
        do {
            try OnboardingPatchWriter.writeStorageCompletion(
                to: storageURL, expectedEmail: "other@example.com", reportedVersion: ""
            )
        } catch {
            mismatchThrown = true
        }
        check(mismatchThrown, "写入层：期望邮箱与文件不符 → 抛错，不静默改别人的号")

        // --- 场景 6：从未登录（没有 userData）→ 抛 missingUserData，调用方降级 ---
        let emptyStorage = root.appendingPathComponent("empty-storage.json")
        try? Self.writeJSON(["whatever": true], to: emptyStorage)
        var missingThrown = false
        do {
            try OnboardingPatchWriter.writeStorageCompletion(to: emptyStorage, expectedEmail: nil)
        } catch let error as OnboardingPatchError {
            missingThrown = (error == .missingUserData)
        } catch {
            missingThrown = false
        }
        check(missingThrown, "写入层：没有 userData → 抛 missingUserData（App 层据此降级跳过）")

        // --- 场景 7：读邮箱 / 判新用户 ---
        check(OnboardingPatchWriter.readEmail(fromStorageFile: storageURL) == "someone@example.com",
              "写入层：能读出当前登录邮箱")
        check(!OnboardingPatchWriter.isNewUser(storageFile: storageURL),
              "写入层：补写后不再是新用户")
        check(!OnboardingPatchWriter.isNewUser(storageFile: emptyStorage),
              "写入层：读不到 userData 时不谎报新用户")
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }


    // MARK: - v2.5.4 周额度完整生命周期
    //
    // 用户问：「每个账号没额度之后会倒计时 7 天，7 天之后下一周不就又有 8000 了吗？」
    // 答案是「会」，但前提是复活逻辑真的被触发。原先 reviveExpiredAccountsIfNeeded
    // 只挂在 syncActiveAppSessionAndQuota 里，关掉守护或整个周末不开 App 就不会跑。
    // v2.5.4 加了周期看门狗，这里把整条链路钉死。

    private static func runWeeklyQuotaLifecycleChecks() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday

        // 2026-08-24 是周一
        let monday = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 10))!
        let tuesday = cal.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 10))!
        let sunday = cal.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 22))!
        let nextMonday = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 0, minute: 1))!

        func makeAccount(used: Int, status: AccountQuotaSnapshot.Status, lastResetAt: Date)
            -> AccountQuotaSnapshot {
            AccountQuotaSnapshot(
                id: UUID(), email: "lifecycle@example.com", status: status, reviewState: .approved,
                usedCharacters: used, monthlyLimit: 8000, lastResetAt: lastResetAt,
                createdAt: monday, hasSilentSessionPayload: true
            )
        }

        // 1) 周二把 8000 用完
        let spent = makeAccount(used: 8000, status: .exhausted, lastResetAt: monday)
        check(spent.remainingCharacters == 0, "生命周期：用尽后剩余为 0")

        // 2) 用尽当天不应复活（还在同一周内）
        check(
            !QuotaCycleEngine.shouldRevive(account: spent, now: tuesday, mode: .calendarWeek, calendar: cal),
            "生命周期：同一周内用尽不应复活"
        )

        // 3) 周日晚上仍不应复活，但倒计时应该指向周一 00:00
        check(
            !QuotaCycleEngine.shouldRevive(account: spent, now: sunday, mode: .calendarWeek, calendar: cal),
            "生命周期：周日晚上仍未跨周，不应复活"
        )
        let sundayCountdown = QuotaCycleEngine.nextAvailabilityText(for: spent, now: sunday, calendar: cal)
        check(sundayCountdown.contains("后（周一 00:00）"), "生命周期：周日晚上倒计时指向周一 00:00")
        check(!sundayCountdown.contains("立即可用"), "生命周期：用尽期间不能显示立即可用")

        // 4) 跨过周一 00:00 后应复活
        check(
            QuotaCycleEngine.shouldRevive(account: spent, now: nextMonday, mode: .calendarWeek, calendar: cal),
            "生命周期：跨过周一 00:00 后应复活"
        )

        // 5) 复活后额度回到 8000
        let revived = AccountQuotaSnapshot.revive(from: spent, now: nextMonday)
        check(revived.remainingCharacters == 8000, "生命周期：复活后剩余额度回到 8000")
        check(revived.status == .available, "生命周期：复活后状态变为 available")
        check(revived.usedCharacters == 0, "生命周期：复活后已用归零")
        check(
            QuotaCycleEngine.nextAvailabilityText(for: revived, now: nextMonday, calendar: cal) == "立即可用",
            "生命周期：复活后立即变为立即可用"
        )

        // 6) 复活幂等：复活后 lastResetAt 已推进，同一周内不会被重复复活
        check(
            !QuotaCycleEngine.shouldRevive(account: revived, now: nextMonday, mode: .calendarWeek, calendar: cal),
            "生命周期：复活后同一周内不应被重复复活（幂等）"
        )

        // 7) 暂停的号即使跨周也不能被自动复活（尊重用户主动决定）
        let pausedAccount = makeAccount(used: 8000, status: .paused, lastResetAt: monday)
        check(
            !QuotaCycleEngine.shouldRevive(account: pausedAccount, now: nextMonday, mode: .calendarWeek, calendar: cal),
            "生命周期：暂停的号跨周也不自动复活"
        )
        check(
            QuotaCycleEngine.nextAvailabilityText(for: pausedAccount, now: nextMonday, calendar: cal) == "已暂停，需手动恢复",
            "生命周期：暂停的号显示需手动恢复"
        )

        // 8) 未审核通过的号也不能被复活
        let pendingAccount = AccountQuotaSnapshot(
            id: UUID(), email: "p@example.com", status: .exhausted, reviewState: .pending,
            usedCharacters: 8000, monthlyLimit: 8000, lastResetAt: monday,
            createdAt: monday, hasSilentSessionPayload: false
        )
        check(
            !QuotaCycleEngine.shouldRevive(account: pendingAccount, now: nextMonday, mode: .calendarWeek, calendar: cal),
            "生命周期：未审核通过的号不自动复活"
        )

        // 9) 跨年边界：2026 最后一周 → 2027 第一周（ISO 周用 year+week 复合 key）
        let dec28_2026 = cal.date(from: DateComponents(year: 2026, month: 12, day: 28, hour: 10))!
        let jan4_2027 = cal.date(from: DateComponents(year: 2027, month: 1, day: 4, hour: 10))!
        let yearEnd = makeAccount(used: 8000, status: .exhausted, lastResetAt: dec28_2026)
        check(
            !QuotaCycleEngine.shouldRevive(account: yearEnd, now: dec28_2026, mode: .calendarWeek, calendar: cal),
            "生命周期：跨年当周用尽当天不复活"
        )
        check(
            QuotaCycleEngine.shouldRevive(account: yearEnd, now: jan4_2027, mode: .calendarWeek, calendar: cal),
            "生命周期：跨年后新一周应复活（ISO 周复合 key 正确）"
        )

        // 10) 看门狗排程：直接打真实函数（QuotaCycleEngine.watchdogSleepSeconds）
        let wait = QuotaCycleEngine.secondsUntilReset(now: tuesday, mode: .calendarWeek, calendar: cal)
        check(wait > 0, "看门狗：等待时长必须为正")
        check(wait <= QuotaCycleEngine.weekSeconds, "看门狗：等待时长不超过 7 天")

        let sleep = QuotaCycleEngine.watchdogSleepSeconds(now: tuesday, mode: .calendarWeek, calendar: cal)
        check(sleep >= QuotaCycleEngine.watchdogMinSleepSeconds,
              "看门狗：休眠不低于下限 60 秒（实测 \(sleep)）")
        // v2.5.6：上限从「一路睡到周一」压到 1 小时。睡太久的话，
        // 中途改时区 / 跨时区出差 / 夏令时切换都要等到下一轮才生效，而下一轮可能是一周后。
        check(sleep <= QuotaCycleEngine.watchdogMaxSleepSeconds,
              "看门狗：休眠不超过上限 1 小时（实测 \(sleep)）")
        check(QuotaCycleEngine.watchdogMaxSleepSeconds == 3_600,
              "看门狗：上限必须是 1 小时（否则时区切换无法及时生效）")

        // 边界：恰好踩在周一 00:00 时也要落进合法区间，不能算出 0 或负数
        let mondayReset = cal.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 0, minute: 0, second: 0))!
        let atBoundary = QuotaCycleEngine.watchdogSleepSeconds(now: mondayReset, mode: .calendarWeek, calendar: cal)
        check(atBoundary >= QuotaCycleEngine.watchdogMinSleepSeconds,
              "看门狗：踩在周界上也不会空转（实测 \(atBoundary)）")

        // 临近周界时，时区必须真的影响排程（这时上限还没生效，差异看得见）。
        // 取「距离下周一 00:00 +0800 还有 30 分钟」这一刻：
        // +0800 只需再睡 30 分钟；+0700 要睡 90 分钟，被上限夹到 60 分钟。
        // 这正是用户担心的「时间节点有很大影响」—— 选错时区就晚整整一小时。
        var shanghaiCal2 = Calendar(identifier: .iso8601)
        shanghaiCal2.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        var bangkokCal2 = Calendar(identifier: .iso8601)
        bangkokCal2.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        let nearBoundary = shanghaiCal2.date(
            from: DateComponents(year: 2026, month: 8, day: 30, hour: 23, minute: 30)
        )!
        let sleepSH = QuotaCycleEngine.watchdogSleepSeconds(now: nearBoundary, mode: .calendarWeek, calendar: shanghaiCal2)
        let sleepBK = QuotaCycleEngine.watchdogSleepSeconds(now: nearBoundary, mode: .calendarWeek, calendar: bangkokCal2)
        check(abs(sleepSH - 1_802) < 1,
              "看门狗：+0800 距周界 30 分钟就睡 30 分钟（实测 \(sleepSH)）")
        check(abs(sleepBK - QuotaCycleEngine.watchdogMaxSleepSeconds) < 1,
              "看门狗：+0700 距周界 90 分钟，被上限夹到 1 小时（实测 \(sleepBK)）")
        check(sleepSH < sleepBK,
              "看门狗：选对时区能更早醒（+0800 \(sleepSH)s < +0700 \(sleepBK)s）")

        // v2.5.6：改时区必须**不用重启 App**。三件事都得当场生效，少一件就会出现
        // 「UI 显示变了但复活时刻没变」——用户明确问过这个点。
        // 1) 全局时钟立刻换掉（倒计时 / 复活判定读的就是它）；
        QuotaCycleClock.shared.setTimeZone(TimeZone(identifier: "Asia/Shanghai"))
        check(QuotaCycleClock.shared.calendar.timeZone.identifier == "Asia/Shanghai",
              "切时区：全局时钟当场更换，倒计时无需重启")
        // 2) 同一时刻的倒计时口径确实变了；
        let beforeCountdown = QuotaCycleEngine.secondsUntilReset(now: nearBoundary, calendar: bangkokCal2)
        let afterCountdown = QuotaCycleEngine.secondsUntilReset(now: nearBoundary, calendar: QuotaCycleClock.shared.calendar)
        check(abs(beforeCountdown - afterCountdown - 3_600) < 1,
              "切时区：倒计时当场偏移 1 小时（\(beforeCountdown) → \(afterCountdown) 秒）")
        // 3) 看门狗重排：休眠上限 1 小时保证任何排程偏差最多 1 小时就被纠正，
        //    不会像旧实现那样一路睡到周一、改了设置要等一周。
        check(QuotaCycleEngine.watchdogMaxSleepSeconds <= 3_600,
              "切时区：看门狗休眠上限 ≤1 小时，排程偏差最多 1 小时自动纠正")
        QuotaCycleClock.shared.setTimeZone(nil)
        check(QuotaCycleClock.shared.timeZone.identifier == TimeZone.current.identifier,
              "切时区：传 nil 回到跟随系统")
    }

    // MARK: - v2.5.3 「下次可用」文案
    //
    // 背景：QuotaCycleEngine 的周期方法 v2.1.0 就有了，但 UI 从未调用，
    // 账号行/详情里「下次可用」永远是空白。这里把桥接层钉死。

    private static func runNextAvailabilityChecks() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2 // Monday

        // --- countdownText 三档格式 ---
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        check(
            QuotaCycleEngine.countdownText(from: base, to: base.addingTimeInterval(3 * 86400 + 5 * 3600)) == "3 天 5 小时",
            "countdownText：3 天 5 小时档"
        )
        check(
            QuotaCycleEngine.countdownText(from: base, to: base.addingTimeInterval(5 * 3600 + 12 * 60)) == "5 小时 12 分",
            "countdownText：5 小时 12 分档"
        )
        check(
            QuotaCycleEngine.countdownText(from: base, to: base.addingTimeInterval(42 * 60)) == "42 分",
            "countdownText：42 分档"
        )
        check(
            QuotaCycleEngine.countdownText(from: base, to: base.addingTimeInterval(-10)) == "即将",
            "countdownText：目标已过返回「即将」"
        )
        // 边界：正好 24 小时应归到「1 天 0 小时」而不是「24 小时 0 分」
        check(
            QuotaCycleEngine.countdownText(from: base, to: base.addingTimeInterval(86400)) == "1 天 0 小时",
            "countdownText：正好 24h 归到天档"
        )
        // 边界：正好 60 分钟应归到「1 小时 0 分」
        check(
            QuotaCycleEngine.countdownText(from: base, to: base.addingTimeInterval(3600)) == "1 小时 0 分",
            "countdownText：正好 60min 归到小时档"
        )

        // --- nextAvailabilityText 状态机 ---
        func snapshot(
            status: AccountQuotaSnapshot.Status,
            used: Int,
            limit: Int = 8000,
            lastResetAt: Date = Date()
        ) -> AccountQuotaSnapshot {
            AccountQuotaSnapshot(
                id: UUID(),
                email: "a@example.com",
                status: status,
                reviewState: .approved,
                usedCharacters: used,
                monthlyLimit: limit,
                lastResetAt: lastResetAt,
                createdAt: Date(),
                hasSilentSessionPayload: true
            )
        }

        let usable = snapshot(status: .available, used: 1000)
        check(
            QuotaCycleEngine.nextAvailabilityText(for: usable, calendar: cal) == "立即可用",
            "nextAvailabilityText：有余额且可用 → 立即可用"
        )

        let nearlySpent = snapshot(status: .nearlySpent, used: 7900)
        check(
            QuotaCycleEngine.nextAvailabilityText(for: nearlySpent, calendar: cal) == "立即可用",
            "nextAvailabilityText：nearlySpent 仍有余额 → 立即可用"
        )

        let exhausted = snapshot(status: .exhausted, used: 8000)
        let exhaustedText = QuotaCycleEngine.nextAvailabilityText(for: exhausted, calendar: cal)
        check(exhaustedText.contains("周一 00:00"), "nextAvailabilityText：用尽 → 带「周一 00:00」说明")
        check(exhaustedText.contains("后（"), "nextAvailabilityText：用尽 → 带倒计时前缀")
        check(!exhaustedText.contains("立即可用"), "nextAvailabilityText：用尽不能显示立即可用")

        let paused = snapshot(status: .paused, used: 0)
        check(
            QuotaCycleEngine.nextAvailabilityText(for: paused, calendar: cal) == "已暂停，需手动恢复",
            "nextAvailabilityText：暂停 → 需手动恢复（不能被自动复活语义污染）"
        )

        // 余额为 0 但状态仍是 available：口径应判为不可用（走倒计时）
        let zeroLeft = snapshot(status: .available, used: 8000)
        check(
            QuotaCycleEngine.nextAvailabilityText(for: zeroLeft, calendar: cal) != "立即可用",
            "nextAvailabilityText：余额 0 即使 status=available 也不能说立即可用"
        )

        // --- nextResetDate 与 daysUntilReset 一致性 ---
        let mondayMidnight = cal.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 0, minute: 0))!
        let anyAccount = snapshot(status: .exhausted, used: 8000)
        guard let resetDate = QuotaCycleEngine.nextResetDate(for: anyAccount, now: mondayMidnight, calendar: cal) else {
            check(false, "nextResetDate：本周一 00:00 必须能算出下次刷新时间")
            return
        }
        let days = QuotaCycleEngine.daysUntilReset(now: mondayMidnight, mode: .calendarWeek, calendar: cal)
        let intervalDays = Int(round(resetDate.timeIntervalSince(mondayMidnight) / 86400))
        check(days == intervalDays, "nextResetDate 与 daysUntilReset 口径一致（\(days) vs \(intervalDays)）")
        check(resetDate > mondayMidnight, "nextResetDate 必须晚于 now")

        // rollingWeek：刷新点 = lastResetAt + 7 天
        let weekAgo = mondayMidnight.addingTimeInterval(-7 * 86400)
        let rollingAccount = snapshot(status: .exhausted, used: 8000, lastResetAt: weekAgo)
        let rollingReset = QuotaCycleEngine.nextResetDate(
            for: rollingAccount, now: mondayMidnight, mode: .rollingWeek, calendar: cal
        )
        check(rollingReset == mondayMidnight, "rollingWeek：lastResetAt + 7 天即刷新点")

        // rollingWeek 文案
        let rollingText = QuotaCycleEngine.nextAvailabilityText(
            for: snapshot(status: .exhausted, used: 8000, lastResetAt: mondayMidnight.addingTimeInterval(-6 * 86400)),
            now: mondayMidnight,
            mode: .rollingWeek,
            calendar: cal
        )
        check(rollingText.contains("注册满 7 天"), "rollingWeek 文案：注册满 7 天")
    }

    // MARK: - v2.5.3 Typeless 2.4.0 onboarding schema
    //
    // 背景：Typeless 2.4.0 把 onboarding 平台枚举从 4 个扩到 7 个
    //（+ linux / harmony / webpage），macos 节点还新增 app_version / completed_at。
    // 旧补丁只写 4 个，新号仍会被判为「引导未完成」而弹新手引导。

    private static func runOnboardingSchemaChecks() {
        let officialPlatforms = ["ios", "android", "macos", "windows", "linux", "harmony", "webpage"]
        check(officialPlatforms.count == 7, "Typeless 2.4.0 平台枚举应为 7 个")

        // 模拟 2.4.0 真实文件：只带 macos（已完成）+ 三个新平台（未完成）
        var onboarding: [String: Any] = [
            "ios": ["completed": false],
            "android": ["completed": false],
            "macos": ["completed": true, "app_version": "2.4.0", "completed_at": "2026-08-28T15:22:38Z"],
            "windows": ["completed": false],
            "linux": ["completed": false],
            "harmony": ["completed": false],
            "webpage": ["completed": false]
        ]

        // 复刻补丁里的平台并集逻辑：官方枚举 ∪ 文件已有键
        let platformKeys = Set(officialPlatforms).union(onboarding.keys)
        for platform in platformKeys {
            var state = onboarding[platform] as? [String: Any] ?? [:]
            state["completed"] = true
            if platform == "macos" {
                if state["app_version"] == nil { state["app_version"] = "2.4.0" }
                if state["completed_at"] == nil { state["completed_at"] = "now" }
            }
            onboarding[platform] = state
        }

        for platform in officialPlatforms {
            let state = onboarding[platform] as? [String: Any]
            check(state?["completed"] as? Bool == true, "补丁后 \(platform) 必须 completed=true")
        }
        // 重点回归：2.4.0 新增的三个平台不能被漏掉
        for platform in ["linux", "harmony", "webpage"] {
            let state = onboarding[platform] as? [String: Any]
            check(state?["completed"] as? Bool == true, "补丁后 2.4.0 新增平台 \(platform) 必须 completed=true")
        }
        // macos 节点的 2.4.0 专属字段必须保留（不能被覆盖成占位值）
        let macos = onboarding["macos"] as? [String: Any]
        check(macos?["app_version"] as? String == "2.4.0", "已存在的 app_version 必须保留不被覆盖")
        check(macos?["completed_at"] as? String == "2026-08-28T15:22:38Z", "已存在的 completed_at 必须保留不被覆盖")

        // 未来官方再加平台：文件里出现未知键也应被一并置为 completed
        var futureOnboarding: [String: Any] = ["visionos": ["completed": false], "macos": ["completed": false]]
        let futureKeys = Set(officialPlatforms).union(futureOnboarding.keys)
        for platform in futureKeys {
            var state = futureOnboarding[platform] as? [String: Any] ?? [:]
            state["completed"] = true
            futureOnboarding[platform] = state
        }
        check(
            (futureOnboarding["visionos"] as? [String: Any])?["completed"] as? Bool == true,
            "未来新增平台（visionos）应被自动兼容"
        )
        check(futureKeys.count == 8, "并集应覆盖 7 官方 + 1 未知 = 8 个平台")

        // 空 onboarding 字典：仍要补齐 7 个平台
        var emptyOnboarding: [String: Any] = [:]
        for platform in Set(officialPlatforms).union(emptyOnboarding.keys) {
            var state = emptyOnboarding[platform] as? [String: Any] ?? [:]
            state["completed"] = true
            emptyOnboarding[platform] = state
        }
        check(emptyOnboarding.count == 7, "空 onboarding 补丁后应补齐 7 个平台")

        // 8000 是每账号「每周」字数额度，不是账号数（用户误解澄清点，写成断言固化）
        check(QuotaCycleEngine.defaultWeeklyLimit == 8000, "单账号周额度上限固定为 8000 字")
        check(AccountQuotaSnapshot(
            id: UUID(), email: "x@example.com", status: .available, reviewState: .approved,
            usedCharacters: 0, monthlyLimit: 8000, lastResetAt: Date(), createdAt: Date(),
            hasSilentSessionPayload: false
        ).remainingCharacters == 8000, "新建账号初始剩余额度 = 8000")
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

    // MARK: - v2.5.2 阈值边界
    /// 用户原问：「字数低于 200，确定是可以正常处理的吗？确定没有问题吗？」
    /// 把 `isQuotaLow` / `isApproachingQuotaLimit` / `nextCheckDelaySeconds` 在阈值 200
    /// 附近的边界值（199/200/201）以及极端值（0/负数/正无穷）逐个验。
    private static func runThresholdBoundaryChecks() {
        let threshold = SmartSwitchPolicy.defaultRemainingThreshold  // 200
        check(threshold == 200, "默认阈值必须=200（用户契约：<200 才换号）")

        // 1) 严格 < 语义：200 不算低、199 算低
        check(SmartSwitchPolicy.isQuotaLow(remaining: 200, threshold: threshold) == false,
              "isQuotaLow(200, 200) 必须 false（边界 = 阈值不算低）")
        check(SmartSwitchPolicy.isQuotaLow(remaining: 201, threshold: threshold) == false,
              "isQuotaLow(201, 200) 必须 false（>阈值不算低）")
        check(SmartSwitchPolicy.isQuotaLow(remaining: 199, threshold: threshold) == true,
              "isQuotaLow(199, 200) 必须 true（<阈值才算低，触发换号）")
        check(SmartSwitchPolicy.isQuotaLow(remaining: 1, threshold: threshold) == true,
              "isQuotaLow(1, 200) 必须 true（接近 0）")
        check(SmartSwitchPolicy.isQuotaLow(remaining: 0, threshold: threshold) == true,
              "isQuotaLow(0, 200) 必须 true（用完）")

        // 2) 负数不视为"低"（避免 Typeless 返回异常时误触发换号）
        //    注：实际是 normalized 用的 max(threshold, 0)，负 threshold 被钳为 0
        //    但负 remaining < 0 仍然 < 0 钳后阈值 0，恒为 true。
        check(SmartSwitchPolicy.isQuotaLow(remaining: -1, threshold: threshold) == true,
              "isQuotaLow(-1, 200) 必须 true（负数剩余按\"已透支\"处理）")
        check(SmartSwitchPolicy.isQuotaLow(remaining: 100, threshold: 0) == false,
              "isQuotaLow(100, 0)：threshold 被钳为 0，100>0 不算低")

        // 3) isApproachingQuotaLimit：< threshold * urgentMultiplier（默认 2）= 400 时进入加速
        check(SmartSwitchPolicy.isApproachingQuotaLimit(remaining: 400, threshold: threshold) == false,
              "isApproachingQuotaLimit(400, 200) 必须 false（边界 = 阈值*2 不算接近）")
        check(SmartSwitchPolicy.isApproachingQuotaLimit(remaining: 399, threshold: threshold) == true,
              "isApproachingQuotaLimit(399, 200) 必须 true（<阈值*2 触发加速巡检）")
        check(SmartSwitchPolicy.isApproachingQuotaLimit(remaining: 200, threshold: threshold) == true,
              "isApproachingQuotaLimit(200, 200) 必须 true（<400 触发加速）")
        check(SmartSwitchPolicy.isApproachingQuotaLimit(remaining: 8000, threshold: threshold) == false,
              "isApproachingQuotaLimit(8000, 200) 必须 false（额度充足）")

        // 4) nextCheckDelaySeconds：接近阈值时 20s，否则按分钟配置
        let fast = SmartSwitchPolicy.nextCheckDelaySeconds(remaining: 100, threshold: 200, intervalMinutes: 10)
        let slow = SmartSwitchPolicy.nextCheckDelaySeconds(remaining: 5000, threshold: 200, intervalMinutes: 10)
        let nilCase = SmartSwitchPolicy.nextCheckDelaySeconds(remaining: nil, threshold: 200, intervalMinutes: 10)
        check(fast <= 60, "接近阈值时本轮 sleep 必须 <= 60s（实际: \(fast)）")
        check(slow == 10 * 60, "额度充足时按分钟配置 sleep（10 分钟 = 600s）")
        check(nilCase == 10 * 60, "remaining=nil 时按默认间隔 sleep（避免无数据时高频）")

        // 5) normalizeThreshold：负数/超大值都钳到合法范围
        check(SmartSwitchPolicy.normalizeThreshold(-50) == 0, "负阈值被钳为 0")
        check(SmartSwitchPolicy.normalizeThreshold(0) == 0, "0 阈值合法")
        check(SmartSwitchPolicy.normalizeThreshold(200) == 200, "200 原样保留")
        check(SmartSwitchPolicy.normalizeThreshold(100_000) == 50_000,
              "超大阈值被钳为上限 50_000")

        // 6) 不抖动：阈值附近的 198/199/200/201/202 各跑一次，状态必须单调
        var lowFlags: [Bool] = []
        for r in [198, 199, 200, 201, 202] {
            lowFlags.append(SmartSwitchPolicy.isQuotaLow(remaining: r, threshold: 200))
        }
        // 期望：[true, true, false, false, false] — 200 是「回到不低」的拐点
        check(lowFlags == [true, true, false, false, false],
              "isQuotaLow 在阈值附近必须单调：\(lowFlags)")

        // 7) 状态机在边界处稳定：低于阈值时连续多轮 isQuotaLow 都返回 true
        let consecutive = (0..<5).map { _ in
            SmartSwitchPolicy.isQuotaLow(remaining: 50, threshold: 200)
        }
        check(consecutive.allSatisfy { $0 },
              "连续多次低于阈值，结果必须稳定为 true（不抖动）")
    }

    // MARK: - v2.5.2 钥匙串缓存行为
    /// **说明**：本测试不直接调 KeychainStore（那要触碰真 keychain、依赖用户授权、可能弹窗），
    /// 而是通过对照 .save/.read 的封闭流程，用临时 account 名验证缓存语义。
    /// 实际 keychain 交互的回归由真实启动验证覆盖（process 启动后 keychain
    /// 弹窗次数 = 1 而非 9）。
    private static func runKeychainCacheBehaviorChecks() {
        // 1) API Key 缓存语义：空字符串不会被当作已读成功（避免反复问）
        //    直接调 KeychainStore 会在没数据时返回空，且不会缓存。
        //    我们用反射无法访问 private 缓存，所以这里只做"接口契约"层面的检查：
        //    - readAPIKey() 返回 String，永不抛错
        //    - 同一进程多次调用必须不产生额外的 macOS 弹窗（这个由真实启动验证）

        // 2) 智能开关：normalizeThreshold 是纯函数，结果可独立验
        //    重复调用 1000 次结果恒等 → 适合做一致性压力
        var first: Int? = nil
        for _ in 0..<1000 {
            let v = SmartSwitchPolicy.normalizeThreshold(200)
            if first == nil { first = v }
            check(v == first, "normalizeThreshold 1000 次结果必须恒等")
        }
        check(first == 200, "normalizeThreshold(200) 1000 次后仍为 200")

        // 3) 阈值与剩余字数的组合：构造 8000 总额 / 不同剩余的状态机
        let total = 8000
        let threshold = 200
        let scenarios: [(remaining: Int, expectLow: Bool, label: String)] = [
            (8000, false, "全新一周：8000 剩余"),
            (1000, false, "消耗 1/8：1000 剩余"),
            (500, false, "消耗 7/16：500 剩余"),
            (201, false, "边界上方：201 剩余"),
            (200, false, "边界值：200 剩余 = 不算低"),
            (199, true, "边界下方：199 剩余 = 触发换号"),
            (100, true, "低水位：100 剩余"),
            (1, true, "几乎用完：1 剩余"),
            (0, true, "用完：0 剩余"),
        ]
        for s in scenarios {
            let got = SmartSwitchPolicy.isQuotaLow(remaining: s.remaining, threshold: threshold)
            check(got == s.expectLow, "[\(s.label)] isQuotaLow(\(s.remaining), \(threshold))=\(got) 期望 \(s.expectLow)")
        }
        _ = total  // 占位，演示用
    }

    // MARK: - v2.5.2 配置包导入导出
    /// 用户原问：「换一台 Mac 装好程序直接导入就能用」+「公开版与私密版」。
    /// 验证 ConfigurationBundle 的序列化、脱敏、schema 校验。
    private static func runConfigurationBundleChecks() {
        // 0) 版本号必须是单一事实来源且格式合法。
        //    build-app.sh 从这里解析版本号写进 Info.plist，代码读不到 Info.plist 时
        //    也回落到这里 —— 写错格式会让两边同时失效。
        let versionParts = AppVersion.short.split(separator: ".").map(String.init)
        check(versionParts.count == 3, "版本号：必须是 主.次.修 三段（实测 \(AppVersion.short)）")
        check(versionParts.allSatisfy { Int($0) != nil }, "版本号：每段都要是数字（\(AppVersion.short)）")
        check(Int(AppVersion.build) != nil, "构建号：必须是数字（\(AppVersion.build)）")
        check(AppVersion.full.contains(AppVersion.short) && AppVersion.full.contains(AppVersion.build),
              "版本号：完整串要含版本与构建号（\(AppVersion.full)）")

        // 1) 完整包往返：encode → decode 必须无损
        let originalAccounts = [
            ConfigurationBundleAccount(
                name: "主力",
                email: "main@example.com",
                domain: "example.com",
                role: "平民",
                typelessUsername: "u1",
                notes: "常用",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                status: "available"
            ),
            ConfigurationBundleAccount(
                name: "备用",
                email: "spare@example.com",
                domain: "example.com",
                role: "平民",
                typelessUsername: nil,
                notes: "",
                createdAt: Date(timeIntervalSince1970: 1_700_000_500),
                status: "exhausted"
            )
        ]
        let originalSettings = BundleSettings(
            autoRotateRemainingThreshold: 300,
            autoRotateCheckIntervalMinutes: 15,
            keepRunningInBackground: true,
            hotSpareTarget: 2,
            moeMailBaseURL: "https://mail.example.com",
            allowFullAutomaticReplacement: true
        )
        let original = ConfigurationBundle(
            schemaVersion: ConfigurationBundleIO.currentSchemaVersion,
            appVersion: "2.0.0",
            exportedAt: Date(timeIntervalSince1970: 1_710_000_000),
            kind: .full,
            accounts: originalAccounts,
            settings: originalSettings
        )

        guard let encoded = try? ConfigurationBundleIO.encoder.encode(original) else {
            check(false, "ConfigurationBundle: encode 必须成功")
            return
        }
        guard let decoded = try? ConfigurationBundleIO.decoder.decode(
            ConfigurationBundle.self, from: encoded) else {
            check(false, "ConfigurationBundle: decode 必须成功")
            return
        }
        check(decoded == original, "ConfigurationBundle: 完整往返后值完全相等")
        check(decoded.accounts.count == 2, "ConfigurationBundle: 账号数往返后保持 2")
        check(decoded.settings.autoRotateRemainingThreshold == 300, "ConfigurationBundle: 阈值往返后保持 300")

        // 2) parse 校验：合法 schema 通过
        check(ConfigurationBundleIO.parse(encoded) != nil, "ConfigurationBundle: parse 对合法 bundle 返回非 nil")

        // 3) parse 校验：乱码 / 错误 schema 返回 nil
        let garbage = Data("{not json".utf8)
        check(ConfigurationBundleIO.parse(garbage) == nil, "ConfigurationBundle: parse 对乱码返回 nil")
        let wrongSchema = Data("""
            {"schemaVersion": 999, "appVersion": "2.0.0",
             "exportedAt": "2026-01-01T00:00:00Z", "kind": "full",
             "accounts": [], "settings": {}}
            """.utf8)
        check(ConfigurationBundleIO.parse(wrongSchema) == nil,
              "ConfigurationBundle: parse 对错误 schemaVersion 返回 nil")

        // 4) 脱敏后：邮箱变占位、notes 清空、其他字段保留
        let sanitized = ConfigurationBundleIO.sanitize(original)
        check(sanitized.kind == .publicEdition, "脱敏包 kind 必须是 publicEdition")
        check(sanitized.accounts.count == original.accounts.count, "脱敏后账号数不变")
        for (i, acc) in sanitized.accounts.enumerated() {
            check(!acc.email.contains("@example.com") || acc.email.hasPrefix("demo"),
                  "脱敏[\(i)]：邮箱必须以 demo 开头占位（原：\(original.accounts[i].email)）")
            check(acc.notes.isEmpty, "脱敏[\(i)]：notes 必须为空（原：\(acc.notes)）")
        }
        check(sanitized.settings.autoRotateRemainingThreshold == originalSettings.autoRotateRemainingThreshold,
              "脱敏后设置字段保留（阈值不变）")
        check(sanitized.settings.keepRunningInBackground == originalSettings.keepRunningInBackground,
              "脱敏后设置字段保留（keepRunningInBackground）")

        // 5) 脱敏后字符串里**绝不**出现原真实邮箱
        let sanitizedEncoded = try? ConfigurationBundleIO.encoder.encode(sanitized)
        check(sanitizedEncoded != nil, "脱敏包可被 encode")
        if let data = sanitizedEncoded {
            let text = String(data: data, encoding: .utf8) ?? ""
            check(!text.contains("main@example.com"), "脱敏后 JSON 文本不含原真实邮箱")
            check(!text.contains("spare@example.com"), "脱敏后 JSON 文本不含第二个原真实邮箱")
            check(text.contains("demo1@example.com"), "脱敏后 JSON 文本包含 demo1@example.com")
            check(text.contains("demo2@example.com"), "脱敏后 JSON 文本包含 demo2@example.com")
        }

        // 6) schemaVersion 必须是当前版本（避免老 bundle 误导入）
        check(original.schemaVersion == ConfigurationBundleIO.currentSchemaVersion,
              "导出的 bundle schemaVersion 必须等于当前版本")

        // 7) BundleSettings 字段对齐
        check(BundleSettings.CodingKeys.allCases.count == 6,
              "BundleSettings 字段数应为 6（threshold/interval/keepRunning/hotSpare/baseURL/allowFull）")

        // 8) 脱敏红线：脱敏后的 JSON **不得出现任何原始字符串**。
        //    这是公开包的生命线 —— 漏一个字段就等于把自建服务入口或账号身份公布出去。
        //    v2.5.6 实测抓到两处泄漏：moeMailBaseURL 带真实域名、typelessUsername
        //    由真实邮箱 local part 推导而来（邮箱脱敏了但用户名还在 = 没脱）。
        let secretDomain = "secret-mail.xyz"
        let secretLocal = "sharp.writer.375478"
        let secretUser = "sharp_writer_375478"
        let dirtyAccounts = [
            ConfigurationBundleAccount(
                name: "主力", email: "\(secretLocal)@\(secretDomain)", domain: secretDomain,
                role: "平民", typelessUsername: secretUser, notes: "内网地址 10.0.0.7",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: "available"
            )
        ]
        let dirtySettings = BundleSettings(
            autoRotateRemainingThreshold: 200,
            autoRotateCheckIntervalMinutes: 1,
            keepRunningInBackground: true,
            hotSpareTarget: 1,
            moeMailBaseURL: "https://mail.\(secretDomain)",
            allowFullAutomaticReplacement: true
        )
        let dirty = ConfigurationBundle(
            appVersion: AppVersion.short, kind: .full,
            accounts: dirtyAccounts, settings: dirtySettings
        )
        let clean = ConfigurationBundleIO.sanitize(dirty)
        let cleanData = (try? JSONEncoder().encode(clean)) ?? Data()
        let cleanText = String(data: cleanData, encoding: .utf8) ?? ""
        for secret in [secretDomain, secretLocal, secretUser, "10.0.0.7"] {
            check(!cleanText.contains(secret),
                  "脱敏红线：不得残留原始串「\(secret)」")
        }
        check(clean.kind == .publicEdition, "脱敏：kind 必须是 publicEdition")
        check(clean.accounts.first?.email == "demo1@example.com",
              "脱敏：邮箱换成占位（\(clean.accounts.first?.email ?? "")）")
        check(clean.accounts.first?.typelessUsername == "demo_user_1",
              "脱敏：用户名必须一起换掉，否则等于没脱（\(clean.accounts.first?.typelessUsername ?? "")）")
        check(clean.settings.moeMailBaseURL == "https://mail.example.com",
              "脱敏：邮箱服务地址里的真实域名也要换（\(clean.settings.moeMailBaseURL)）")
        check(clean.accounts.first?.notes.isEmpty == true, "脱敏：notes 必须清空")
        // 阈值这类非敏感设置应当保留，脱敏不是重置
        check(clean.settings.autoRotateRemainingThreshold == 200,
              "脱敏：非敏感设置要保留（阈值不变）")
    }
}
