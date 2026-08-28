import Foundation

// MARK: - OnboardingPatchWriter
//
// Typeless 桌面端「新手引导」补丁的**纯文件读写层**。不依赖 AppKit、不碰进程、
// 路径全靠参数注入，所以能被 `OperationalFeatureChecks` 直接单测。
//
// 为什么下沉到 Core：
// 这段逻辑的验证一直卡在一个死结上 —— 它只在「Typeless 没在运行」时才允许写盘，
// 而用户的 Typeless 基本是常开的，于是写入路径永远没法在真机上实测，
// 每次改动只能靠「读日志看它有没有报错」来猜。下沉之后可以用临时目录
// 构造任意现场（文件缺失 / 被重置 / 账号不匹配 / 从未登录）逐个断言。
//
// 分工：本文件只管**把文件写成什么**，App 层（`SwitchboardStore+OnboardingPatch`）
// 管**什么时候该写、写完记什么日志**。

public enum OnboardingPatchWriter {

    /// 引导完成标记里的「步骤终值」。Typeless 用 step 推进引导流程，
    /// 直接顶到 99 表示每一步都走完了。
    public static let completedStep = 99
    /// 备份文件后缀。原文件只留第一份，见 `backupIfNeeded`。
    public static let backupSuffix = "switchboard-orig.bak"

    // MARK: - 状态判定

    /// `app-onboarding.json` 的引导状态。
    public enum State: Equatable, Sendable {
        /// 明确写了完成标记。
        case complete
        /// 文件在，但还没走完引导。
        case incomplete
        /// 文件不存在或读不出来。**不等于「已完成」** —— 见文件头说明。
        case missing
    }

    /// 读取引导状态。
    ///
    /// 判定顺序：`isCompleted`（布尔，最权威）→ `step`（数值兜底）→ 都没有则按未完成。
    /// 最后一种情况补写一遍没有副作用，宁可多写也不要漏。
    public static func state(ofOnboardingFile url: URL) -> State {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .missing
        }
        if let done = object["isCompleted"] as? Bool { return done ? .complete : .incomplete }
        if let step = object["step"] as? Int { return step >= completedStep ? .complete : .incomplete }
        return .incomplete
    }

    /// 是否需要打补丁。
    ///
    /// 「文件缺失」的语义由调用方裁定：装了 Typeless 就该补写，没装则不必管。
    /// 这里不自己判断 App 是否安装 —— 那是 App 层的事，Core 保持无副作用。
    public static func needsPatch(
        state: State,
        treatMissingAsNeedsPatch: Bool
    ) -> Bool {
        switch state {
        case .complete: return false
        case .incomplete: return true
        case .missing: return treatMissingAsNeedsPatch
        }
    }

    // MARK: - 备份

    /// 首次改写前留一份原文件，万一补丁把状态写坏了能手动还原。
    /// 只留第一份 —— 每次巡检都覆盖的话，备份本身就失去意义了。
    /// 原文件不存在时什么都不做。
    public static func backupIfNeeded(_ url: URL) {
        let backupURL = backupURL(for: url)
        guard !FileManager.default.fileExists(atPath: backupURL.path),
              FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }

    public static func backupURL(for url: URL) -> URL {
        let ext = url.pathExtension
        return url.deletingPathExtension()
            .appendingPathExtension(ext.isEmpty ? backupSuffix : "\(ext).\(backupSuffix)")
    }

    // MARK: - 写 app-onboarding.json

    /// 把引导标记写成完成态。
    ///
    /// 关键性质：
    /// - **保留文件里已有的键**。只覆盖引导相关字段，不动用户其他设置。
    /// - **文件不存在时从空字典开始**，等价于新建一份完成态配置。
    /// - 平台列表用「已有键 ∪ 官方枚举」，未来 Typeless 加平台能自动兼容。
    public static func writeCompletion(toOnboardingFile url: URL) throws {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = existing
        }

        object["isCompleted"] = true
        object["step"] = completedStep
        object["setUpStep"] = completedStep
        object["tryItStep"] = completedStep
        object["tryItPlaygroundStep"] = completedStep
        object["onboardingStep"] = NSNull()
        object["onboardingMaxReachedStep"] = NSNull()
        object["onboardingAutoLanguageDetection"] = true
        object["onboardingCompletedFloatingBarStart"] = true
        object["onboardingCompletedFloatingBarRelease"] = true
        object["onboardingHomePageClickAppToShowFloatingBar"] = []
        object["onboardingTryItPlaygroundIsCompleted"] = true
        object["onboardingMaxTryItPlaygroundStepValue"] = completedStep
        object["onboardingShortcutCalloutDismissedStep"] = completedStep
        object["pressToStopDictationOnboardingShown"] = [
            "voice_transcript_release": true,
            "voice_transcript": true,
            "voice_command": true,
            "voice_translation": true
        ]
        object["translationModeFeatureAlertOnboarding"] = [
            "dictationCount": completedStep,
            "shown": true
        ]

        // 这三个是嵌套字典：只在**已存在**时钻进去改 dismissed，
        // 不存在就不凭空造 —— 造出来的结构可能不符合 Typeless 的预期。
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

        try write(object, to: url)
    }

    // MARK: - 写 app-storage.json

    /// Typeless 官方平台枚举。2.4.0 从 4 个扩到 7 个。
    public static let officialPlatforms = ["ios", "android", "macos", "windows", "linux", "harmony", "webpage"]

    /// 把 `app-storage.json` 里的账号标记为「非新用户 + 全平台引导已完成」。
    ///
    /// - Parameters:
    ///   - url: `app-storage.json` 路径。
    ///   - expectedEmail: 期望的登录邮箱。**传 nil 时不校验邮箱**，
    ///     直接改当前文件里那个 userData —— 这正是 fail-safe 的关键。
    ///   - reportedVersion: 写进 `onboarding.macos.app_version` 的版本号，留空则不写。
    /// - Throws: 文件里没有 `userData`（从未登录）时抛错，调用方按需降级。
    public static func writeStorageCompletion(
        to url: URL,
        expectedEmail: String?,
        reportedVersion: String = ""
    ) throws {
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var userData = object["userData"] as? [String: Any] else {
            throw OnboardingPatchError.missingUserData
        }

        if let expectedEmail, !expectedEmail.isEmpty {
            guard let email = userData["email"] as? String,
                  email.caseInsensitiveCompare(expectedEmail) == .orderedSame else {
                throw OnboardingPatchError.emailMismatch(actual: (userData["email"] as? String) ?? "未知")
            }
        }

        userData["is_new_user"] = false

        // 平台列表 = 文件里已有的键 ∪ 官方枚举。以后官方再加平台也能自动覆盖。
        var onboarding = userData["onboarding"] as? [String: Any] ?? [:]
        let platformKeys = Set(officialPlatforms).union(onboarding.keys)
        let completedAt = ISO8601DateFormatter().string(from: Date())

        for platform in platformKeys {
            var platformState = onboarding[platform] as? [String: Any] ?? [:]
            platformState["completed"] = true
            if platform == "macos" {
                // 2.4.0 起 macos 节点带 app_version / completed_at，
                // 缺了会被判定为「从未完成过」，补写才算数。
                if platformState["app_version"] == nil, !reportedVersion.isEmpty {
                    platformState["app_version"] = reportedVersion
                }
                if platformState["completed_at"] == nil {
                    platformState["completed_at"] = completedAt
                }
            }
            onboarding[platform] = platformState
        }
        userData["onboarding"] = onboarding

        object["userData"] = userData
        // 停留在引导路由会让下次启动接着弹引导，清掉。
        if object.keys.contains("currentRoute") {
            object["currentRoute"] = NSNull()
        }

        try write(object, to: url)
    }

    /// 桌面端当前登录邮箱。读不到返回 nil（文件不存在 / 没有 userData / 邮箱为空）。
    public static func readEmail(fromStorageFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = object["userData"] as? [String: Any],
              let email = userData["email"] as? String,
              !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return email
    }

    /// 桌面端是否仍被判定为新用户（UI 用来提示「会有新手引导」）。
    public static func isNewUser(storageFile url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userData = object["userData"] as? [String: Any] else {
            return false
        }
        return (userData["is_new_user"] as? Bool) ?? false
    }

    // MARK: - 内部

    private static func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - 错误

public enum OnboardingPatchError: LocalizedError, Equatable {
    /// `app-storage.json` 里没有 userData —— 通常是桌面端从未登录过。
    case missingUserData
    /// 文件里的账号与期望账号不一致。
    case emailMismatch(actual: String)

    public var errorDescription: String? {
        switch self {
        case .missingUserData:
            return "未找到 Typeless 桌面端 app-storage.json 里的 userData"
        case .emailMismatch(let actual):
            return "app-storage.json 账号不匹配：\(actual)"
        }
    }
}
