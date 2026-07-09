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

        let switchboardSource = try String(contentsOfFile: "Sources/TypelessSwitchboard/main.swift")
        if let start = switchboardSource.range(of: "func runOneClickAutomaticReplacement("),
           let end = switchboardSource.range(of: "func retryLastAutomation()", range: start.lowerBound..<switchboardSource.endIndex) {
            let oneClickSource = String(switchboardSource[start.lowerBound..<end.lowerBound])
            check(!oneClickSource.contains("prepareSwitch(from: currentID)"), "one-click automation must not fall back to manual switch that opens inbox/browser pages")
            check(!oneClickSource.contains("openURL(account.inboxURL)"), "one-click automation must not open MoeMail inbox page during registration")
            check(oneClickSource.contains("注册阶段后台运行"), "one-click automation documents background registration stage")
            check(oneClickSource.contains("prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement"), "one-click automation prepares local Typeless desktop app environment")
            check(oneClickSource.contains("prepareRetainedTypelessBrowserSessionsForAutomaticReplacement"), "one-click automation prepares retained Typeless web session environment")
            check(oneClickSource.contains("preparePersonalChromeTypelessWebSessionForAutomaticReplacement"), "one-click automation clears the user's Chrome Typeless web session")
            check(oneClickSource.contains("resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement"), "one-click automation resolves any stale Chrome Typeless.app prompt before clearing environments")
            check(oneClickSource.contains("closePersonalChromeTypelessTabsBeforeReplacement"), "one-click automation closes stale personal Chrome Typeless tabs before creating the clean login tab")
            check(oneClickSource.contains("syncPersonalChromeTypelessWebSession"), "one-click automation switches the user's Chrome Typeless web session to the new account")
            check(oneClickSource.contains("completeTypelessDesktopOnboardingIfPresent"), "one-click automation completes or skips Typeless desktop onboarding after handoff")
            check(oneClickSource.contains("preflightMacPermissionsBeforeAutomaticReplacement"), "one-click automation preflights macOS permissions before creating a new email")
            check(oneClickSource.range(of: "preflightMacPermissionsBeforeAutomaticReplacement")!.lowerBound < oneClickSource.range(of: "createMoeMailRegistrationCandidate")!.lowerBound, "permission preflight happens before MoeMail account generation")
            check(oneClickSource.contains("timeoutSeconds: 120"), "one-click automation waits long enough for desktop handoff before onboarding patch")
            check(!oneClickSource.contains("openRetainedBrowserSession("), "one-click automation must not open an extra Playwright/Chromium browser after success")
            check(oneClickSource.contains("未自动打开额外浏览器"), "one-click automation documents that retained browser session is saved but not auto-opened")
        } else {
            check(false, "can locate one-click automation source")
        }

        check(switchboardSource.contains("func prepareRetainedTypelessBrowserSessionsForAutomaticReplacement"), "switchboard can isolate previously retained Typeless web sessions")
        check(switchboardSource.contains("BrowserSessionBackups"), "retained Typeless web session isolation keeps backups")
        check(switchboardSource.contains("terminateRetainedTypelessBrowserSessions"), "retained Typeless web session isolation terminates old browser windows")
        check(switchboardSource.contains("pkill\", \"-f\", retainedTypelessBrowserProfileRootURL().path"), "retained Typeless web session isolation closes old Playwright Chromium processes by profile root")
        check(switchboardSource.contains("已隔离旧网页登录态"), "retained Typeless web session isolation logs old web session backup")
        check(switchboardSource.contains("func resetTypelessDeviceIdentityForAutomaticReplacement"), "one-click automation fully resets Typeless device identity like typeless-toolkit resetDevice")
        check(switchboardSource.contains("now.typeless.desktop.deviceIdentifier"), "device reset deletes the real macOS Typeless Keychain service")
        check(switchboardSource.contains("now.typeless.desktop.security.auth_key"), "device reset deletes the real macOS Typeless Keychain account")
        check(switchboardSource.contains("Typeless.deviceIdentifier"), "device reset also handles the toolkit legacy credential target")
        check(switchboardSource.contains("SecItemDelete"), "device reset removes Typeless device credentials from Keychain")
        check(switchboardSource.contains("delete-generic-password"), "device reset falls back to the macOS security CLI when Keychain API deletion is denied")
        check(switchboardSource.contains("device.cache"), "device reset removes Typeless device.cache files")
        check(switchboardSource.contains("user-data.json"), "device reset removes encrypted user-data login credentials")
        check(switchboardSource.contains("quotaUsage"), "device reset clears quotaUsage from app-storage")
        check(switchboardSource.contains("\"Local Storage\"") && switchboardSource.contains("\"Network\"") && switchboardSource.contains("\"Cookies\""), "device reset clears Electron local storage, network state, and cookies")
        if let start = switchboardSource.range(of: "func prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement"),
           let end = switchboardSource.range(of: "func prepareRetainedTypelessBrowserSessionsForAutomaticReplacement", range: start.lowerBound..<switchboardSource.endIndex) {
            let desktopPreparationSource = String(switchboardSource[start.lowerBound..<end.lowerBound])
            check(desktopPreparationSource.contains("resetTypelessDeviceIdentityForAutomaticReplacement"), "one-click desktop preparation resets device identity before new desktop handoff")
        } else {
            check(false, "can locate desktop preparation source")
        }
        check(switchboardSource.contains("func preparePersonalChromeTypelessWebSessionForAutomaticReplacement"), "switchboard can clear personal Chrome Typeless session")
        check(switchboardSource.contains("func syncPersonalChromeTypelessWebSession"), "switchboard can sync personal Chrome to the new Typeless session")
        check(switchboardSource.contains("func handoffRetainedTypelessProfileToDesktopOnce"), "one-click automation performs a background retained-profile desktop handoff without opening an extra browser")
        check(switchboardSource.contains("makeDesktopHandoffScript"), "one-click automation has a dedicated one-shot desktop handoff script")
        check(switchboardSource.contains("typeless://"), "desktop handoff script handles Typeless external protocol URLs")
        check(switchboardSource.contains("/usr/bin/open"), "desktop handoff script opens Typeless protocol URLs through macOS open")
        check(switchboardSource.contains("makeTypelessDesktopAuthURL"), "desktop handoff constructs a complete Typeless auth protocol URL from extracted tokens")
        check(switchboardSource.contains("access_token") && switchboardSource.contains("refresh_token") && switchboardSource.contains("user_id"), "desktop auth protocol URL includes the fields required by Typeless desktop")
        check(switchboardSource.contains("forceLaunchTypelessBeforeAuthProtocol"), "desktop handoff launches Typeless before replaying the auth protocol so macOS does not drop the cold-start URL event")
        check(switchboardSource.contains("[1.0, 3.0, 6.0, 12.0, 24.0, 60.0]"), "onboarding patch is re-applied long enough to beat server userData refresh")
        check(switchboardSource.contains("func resolvePendingChromeTypelessAppPromptBeforeAutomaticReplacement"), "switchboard can approve stale Chrome Typeless.app prompts before cleanup")
        check(switchboardSource.contains("func closePersonalChromeTypelessTabsBeforeReplacement"), "switchboard can close stale personal Chrome Typeless tabs")
        check(switchboardSource.contains("始终允许 www.typeless.com"), "Chrome prompt approval handles the always-allow checkbox")
        check(switchboardSource.contains("Always allow"), "Chrome prompt approval handles English always-allow checkbox text")
        check(switchboardSource.contains("AXCheckBox"), "Chrome prompt approval searches checkbox accessibility elements")
        check(switchboardSource.contains("MAXAI_CLIENT__FEATURES__AUTH__TOKEN_INFO"), "Chrome sync uses Typeless token info from the completed session")
        check(switchboardSource.contains("func completeTypelessDesktopOnboardingIfPresent"), "switchboard can complete Typeless onboarding after switch")
        check(!switchboardSource.contains("全自动换号已完成，已打开新账号浏览器会话"), "completion message must not claim an extra browser session was opened")
        check(switchboardSource.contains("func writeTypelessStorageOnboardingCompletion"), "onboarding patch also updates app-storage userData onboarding state")
        if let start = switchboardSource.range(of: "func completeTypelessDesktopOnboardingIfPresent"),
           let end = switchboardSource.range(of: "func writeTypelessOnboardingCompletion", range: start.lowerBound..<switchboardSource.endIndex) {
            let desktopOnboardingSource = String(switchboardSource[start.lowerBound..<end.lowerBound])
            check(desktopOnboardingSource.contains("writeTypelessStorageOnboardingCompletion"), "onboarding patch updates app-storage before relaunching Typeless")
        } else {
            check(false, "can locate desktop onboarding completion source")
        }
        if let start = switchboardSource.range(of: "func enforceTypelessDesktopOnboardingPatchAfterRelaunch"),
           let end = switchboardSource.range(of: "func waitForTypelessDesktopStorage", range: start.lowerBound..<switchboardSource.endIndex) {
            let enforcementSource = String(switchboardSource[start.lowerBound..<end.lowerBound])
            check(enforcementSource.contains("writeTypelessStorageOnboardingCompletion"), "onboarding patch re-applies app-storage userData completion after relaunch")
        } else {
            check(false, "can locate onboarding relaunch enforcement source")
        }
        check(switchboardSource.contains("\"is_new_user\""), "onboarding patch marks the local Typeless user as not new")
        check(switchboardSource.contains("\"macos\""), "onboarding patch marks macOS onboarding complete in userData")
        check(switchboardSource.contains("\"completed\""), "onboarding patch writes completed flags")
        check(switchboardSource.contains("func waitForTypelessDesktopStorage"), "onboarding patch waits for Typeless desktop storage files created after handoff")
        check(switchboardSource.contains("func enforceTypelessDesktopOnboardingPatchAfterRelaunch"), "onboarding patch is re-applied after Typeless relaunch")
        check(switchboardSource.contains("onboardingShortcutCalloutDismissedStep"), "onboarding patch dismisses shortcut callout state")
        check(switchboardSource.contains("pressToStopDictationOnboardingShown"), "onboarding patch dismisses press-to-stop dictation tips")
        check(switchboardSource.contains("func appendMacPermissionDiagnostics"), "setup diagnostics include macOS permission checks")
        check(switchboardSource.contains("func preflightMacPermissionsBeforeAutomaticReplacement"), "one-click flow includes a dedicated up-front permission preflight")
        check(switchboardSource.contains("AXIsProcessTrustedWithOptions"), "permission preflight prompts for Accessibility before registration")
        check(switchboardSource.contains("一键换号已在注册前暂停"), "permission preflight stops before account generation if critical permissions are missing")
        check(switchboardSource.contains("全自动换号确认状态"), "empty review queue explains automatic confirmation instead of showing manual approval work")
        check(switchboardSource.contains("兜底确认队列"), "pending accounts are framed as fallback confirmation only")
        check(!switchboardSource.contains("人工审核队列"), "successful one-click UI must not show an artificial/manual review queue label")
        check(switchboardSource.contains("按 typeless-toolkit resetDevice"), "main copy documents real toolkit-style device identity reset")
        check(switchboardSource.contains("AXIsProcessTrusted"), "setup diagnostics checks Accessibility permission")
        check(switchboardSource.contains("Privacy_Automation"), "setup diagnostics exposes Automation privacy settings")
        check(switchboardSource.contains("func copyMacPermissionChecklist"), "switchboard can copy the complete macOS permission checklist")
        check(switchboardSource.contains("func openMacPermissionSettings"), "switchboard can open macOS privacy panes")
        check(switchboardSource.contains("--auto-switch-count"), "switchboard exposes a controlled CLI multi-switch test entrypoint")
        check(switchboardSource.contains("runCommandLineAutomaticReplacementIfRequested"), "switchboard can run repeated one-click replacements from CLI")
        check(switchboardSource.contains("lastCompletedAutomationAccountID"), "CLI multi-switch continues from the last completed account")
        check(switchboardSource.contains("KeychainStore.readAPIKey()"), "CLI multi-switch reads MoeMail API key from Keychain")
        check(switchboardSource.contains("isAutomationRuntimeCached"), "automation runtime skips install when Playwright is already cached")
        check(switchboardSource.contains("isPlaywrightChromiumExecutableAvailable"), "automation runtime cache verifies the Playwright Chromium executable before skipping install")
        check(switchboardSource.contains("chromium.executablePath()"), "automation runtime cache probes Chromium executable path through Playwright")
        check(switchboardSource.contains("markAutomationRuntimeReady"), "automation runtime writes a ready marker after prewarm")
        check(switchboardSource.contains("跳过 npm install / playwright install"), "automation runtime reports cached fast path")
        check(switchboardSource.contains("typelessAppQuitGraceSeconds"), "Typeless app quit wait is bounded by a short grace constant")
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

        print("Operational feature checks passed")
    }
}
