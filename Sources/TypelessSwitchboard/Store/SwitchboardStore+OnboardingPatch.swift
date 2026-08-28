import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

// MARK: - Typeless 桌面端「新手引导」补丁
//
// ## v2.5.3 重写原因（用户回归报障）
//
// 现场证据（2026-08-28）：
//   ~/Library/Application Support/Typeless/app-onboarding.json  → isCompleted=false, step=0
//   ~/Library/Application Support/Typeless/app-storage.json     → userData.is_new_user=true
//   onboarding.macos.completed=true, completed_at=22:22:38, app_version=2.4.0
//
// 三个叠加缺陷：
// 1. **fail-closed**：旧实现一旦「检测到的邮箱 ≠ 期望邮箱」就整段 return，两个文件一个都不写，
//    Typeless 于是保持新用户态并弹出新手引导。这是最致命的一条。
// 2. **只挂在全自动注册路径上**：全工程只有 AutomaticReplacement.swift 一个调用点，
//    无感换号 / 智能换号 / 自动轮换 / 手动切换四条路径统统不打补丁。
//    新注册的号第一次登录必然是新用户 → 必然弹引导。
// 3. **Typeless 2.4.0 换了 schema**：onboarding 平台枚举从 4 个（ios/android/macos/windows）
//    扩到 7 个（+ linux/harmony/webpage），且 macos 节点新增 app_version / completed_at。
//    旧补丁只写 4 个，剩下 3 个仍是 false。
//
// 修复后的原则：
// - **fail-safe**：按「桌面端当前实际登录的账号」打补丁，而不是死等期望邮箱；
//   app-onboarding.json 是 App 级配置、与账号无关，无条件写，不存在串号风险。
// - **全路径覆盖**：提供无进程控制的纯文件写入版本，供无感换号在拉起 Typeless 之前调用，
//   让 Typeless 冷启动直接读到「非新用户」，做到真正的无感。
// - **schema 自适应**：平台列表 = 现有文件里出现过的键 ∪ 7 个官方枚举，未来再加平台自动兼容。

extension SwitchboardStore {

    // MARK: - 路径

    func typelessDesktopAppSupportFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Typeless", isDirectory: true)
    }

    func typelessStorageURL() -> URL {
        typelessDesktopAppSupportFolder().appendingPathComponent("app-storage.json")
    }

    func typelessOnboardingURL() -> URL {
        typelessDesktopAppSupportFolder().appendingPathComponent("app-onboarding.json")
    }

    /// Typeless 桌面端自报版本号（last_version.txt），写进 onboarding.macos.app_version。
    func typelessDesktopReportedVersion() -> String {
        let url = typelessDesktopAppSupportFolder().appendingPathComponent("last_version.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 主入口（fail-safe）

    /// 跳过 / 完成 Typeless 桌面端新手引导。
    ///
    /// 与旧实现的关键差别：**不再因为邮箱不匹配而整段放弃**。
    /// - `app-onboarding.json`（App 级）无条件写；
    /// - `app-storage.json`（账号级）按「桌面端当前实际登录的邮箱」写；
    /// - 若 `expectedEmail` 与实际的确有出入，只记一条提示日志，补丁照打。
    ///
    /// - Parameters:
    ///   - expectedEmail: 期望桌面端登录的账号；传 nil 表示「不管是谁，跳过引导即可」。
    ///   - timeoutSeconds: 等待桌面端落到某个登录态的超时。
    ///   - stopAndRelaunch: 是否先退出 Typeless 再重启。写盘前必须退出，
    ///     否则 Electron 退出时会用内存态覆盖掉我们刚写的文件。
    @discardableResult
    func patchTypelessDesktopOnboarding(
        expectedEmail: String?,
        timeoutSeconds: TimeInterval = 60,
        stopAndRelaunch: Bool = true
    ) async -> [String] {
        let storageURL = typelessStorageURL()
        let onboardingURL = typelessOnboardingURL()
        var log: [String] = []

        // 1) 先退 Typeless。它退出时会把内存态 flush 回磁盘，
        //    所以必须退出**之后**再写文件，否则写的内容会被覆盖。
        if stopAndRelaunch {
            log.append(await terminateInstalledTypelessApp())
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // 2) 等桌面端落到某个登录态（已退出时直接读盘，通常首轮就命中）。
        let readiness = await waitForTypelessDesktopStorage(
            storageURL: storageURL,
            onboardingURL: onboardingURL,
            expectedEmail: expectedEmail ?? "",
            timeoutSeconds: expectedEmail == nil ? 2 : timeoutSeconds
        )
        let actualEmail = readiness.email ?? readTypelessDesktopEmail(from: storageURL)

        if let expected = expectedEmail, !expected.isEmpty,
           let actual = actualEmail,
           actual.caseInsensitiveCompare(expected) != .orderedSame {
            log.append("提示：桌面端当前登录的是 \(actual)，与预期的 \(expected) 不一致；按当前实际登录账号跳过新手引导")
        }

        // 3) 写两个文件。失败不再静默，逐条记日志。
        log.append(contentsOf: writeTypelessDesktopOnboardingFiles(
            storageURL: storageURL,
            onboardingURL: onboardingURL,
            expectedEmail: actualEmail
        ))

        // 4) 重启 + 重试加固。Typeless 冷启动会按 is_new_user 重新初始化 onboarding 片段，
        //    所以启动后再补写若干轮，确保最终态稳定。
        if stopAndRelaunch {
            if let path = typelessAppPath() {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                await enforceTypelessDesktopOnboardingPatchAfterRelaunch(
                    storageURL: storageURL,
                    onboardingURL: onboardingURL,
                    expectedEmail: actualEmail
                )
                log.append("已重启 Typeless 并复核新手引导状态")
            } else {
                log.append("未找到 Typeless App 路径，跳过重启（文件已写好，下次启动生效）")
            }
        }

        return log
    }

    /// 只写文件、不做任何进程控制。
    ///
    /// 无感换号在「写入会话缓存之后、拉起 Typeless 之前」调用它，
    /// 让 Typeless 冷启动第一次读盘就是「非新用户」，从而完全不出现新手引导。
    @discardableResult
    func writeTypelessDesktopOnboardingFiles(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String?
    ) -> [String] {
        var log: [String] = []

        do {
            try writeTypelessOnboardingCompletion(to: onboardingURL)
            log.append("已写入桌面端新手引导完成标记（app-onboarding.json）")
        } catch {
            log.append("写入 app-onboarding.json 失败：\(error.localizedDescription)")
        }

        do {
            try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
            let who = expectedEmail ?? "当前登录账号"
            log.append("已把 \(who) 标记为非新用户（is_new_user=false，全平台 onboarding 已完成）")
        } catch {
            log.append("写入 app-storage.json 失败：\(error.localizedDescription)")
        }

        return log
    }

    /// 一键换号流程的向后兼容入口（AutomaticReplacement.swift 调用）。
    /// 行为等价于新的 fail-safe 实现。
    func completeTypelessDesktopOnboardingIfPresent(expectedEmail: String, timeoutSeconds: TimeInterval = 60) async -> [String] {
        await patchTypelessDesktopOnboarding(
            expectedEmail: expectedEmail,
            timeoutSeconds: timeoutSeconds,
            stopAndRelaunch: true
        )
    }

    /// 独立入口：不管当前登录的是哪个号，直接跳过新手引导。
    /// 供「自检排障 / 换号」页的一键按钮使用，不依赖换号流程。
    @discardableResult
    func skipTypelessDesktopOnboardingNow() async -> [String] {
        var log = ["开始跳过 Typeless 桌面端新手引导…"]
        log.append(contentsOf: await patchTypelessDesktopOnboarding(
            expectedEmail: nil,
            timeoutSeconds: 2,
            stopAndRelaunch: true
        ))
        return log
    }

    // MARK: - 文件写入

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

    /// 把 `app-storage.json` 里的账号标记为「非新用户 + 全平台引导已完成」。
    ///
    /// - Parameter expectedEmail: 期望的登录邮箱。**传 nil 时不校验邮箱**，
    ///   直接改当前文件里那个 userData —— 这正是 fail-safe 的关键。
    func writeTypelessStorageOnboardingCompletion(to storageURL: URL, expectedEmail: String?) throws {
        guard let data = try? Data(contentsOf: storageURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var userData = object["userData"] as? [String: Any] else {
            throw NSError(
                domain: "TypelessOnboardingPatch",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 Typeless 桌面端 app-storage.json 里的 userData"]
            )
        }

        if let expectedEmail, !expectedEmail.isEmpty {
            guard let email = userData["email"] as? String,
                  email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                let actualEmail = (userData["email"] as? String) ?? "未知"
                throw NSError(
                    domain: "TypelessOnboardingPatch",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "app-storage.json 账号不匹配：\(actualEmail)"]
                )
            }
        }

        userData["is_new_user"] = false

        // Typeless 2.4.0 把平台枚举扩到 7 个；这里用「文件里已有的键 ∪ 官方枚举」，
        // 以后官方再加平台也能自动覆盖，不用再改代码。
        var onboarding = userData["onboarding"] as? [String: Any] ?? [:]
        let officialPlatforms = ["ios", "android", "macos", "windows", "linux", "harmony", "webpage"]
        let platformKeys = Set(officialPlatforms).union(onboarding.keys)
        let version = typelessDesktopReportedVersion()
        let completedAt = ISO8601DateFormatter().string(from: Date())

        for platform in platformKeys {
            var platformState = onboarding[platform] as? [String: Any] ?? [:]
            platformState["completed"] = true
            if platform == "macos" {
                // 2.4.0 起 macos 节点带 app_version / completed_at，缺了会被判定为「未完成过」。
                if platformState["app_version"] == nil, !version.isEmpty {
                    platformState["app_version"] = version
                }
                if platformState["completed_at"] == nil {
                    platformState["completed_at"] = completedAt
                }
            }
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

    /// 重启后的加固：Typeless 冷启动会按内存态重写 onboarding 片段，
    /// 所以在启动后的若干时间点各补写一次，直到稳定。
    func enforceTypelessDesktopOnboardingPatchAfterRelaunch(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String?
    ) async {
        for delay in [1.0, 3.0, 6.0, 12.0, 24.0, 60.0] {
            // 可取消 sleep，不再硬冻结主线程；总等待上限不变。
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            if let expected = expectedEmail, !expected.isEmpty {
                guard let email = readTypelessDesktopEmail(from: storageURL),
                      email.caseInsensitiveCompare(expected) == .orderedSame else {
                    continue
                }
            }

            // 不再吞异常：把失败原因落到日志，方便排障。
            do {
                try writeTypelessOnboardingCompletion(to: onboardingURL)
            } catch {
                appendOnboardingPatchLog("复核时写 app-onboarding.json 失败：\(error.localizedDescription)")
            }
            do {
                try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
            } catch {
                appendOnboardingPatchLog("复核时写 app-storage.json 失败：\(error.localizedDescription)")
            }
        }
    }

    func appendOnboardingPatchLog(_ line: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypelessSwitchboard", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("onboarding-patch.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 探测

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

    /// 桌面端当前是否仍被判定为新用户（UI 用来提示「会有新手引导」）。
    func typelessDesktopIsNewUser() -> Bool {
        guard let data = try? Data(contentsOf: typelessStorageURL()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = object["userData"] as? [String: Any] else {
            return false
        }
        return (userData["is_new_user"] as? Bool) ?? false
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
}
