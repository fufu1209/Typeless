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

    // MARK: - 统一入口（v2.5.6）
    //
    // 以前有三套并行 API：`autoHealDesktopOnboardingIfSafe`（启动自愈）、
    // `skipTypelessDesktopOnboardingNow`（手动跳过）、
    // `completeTypelessDesktopOnboardingIfPresent`（换号后补写），
    // 各自判断状态、各自决定能不能写、各自记日志 —— 行为容易分叉，
    // 而且 8 个调用点里每新增一条代码路径，都要记得挑一个来调，漏一处用户就看到引导。
    //
    // 现在收成一个入口：调用方只声明「我要确保引导完成」+「允不允许重启 Typeless」，
    // 剩下的（要不要写、能不能写、写完验不验、记什么日志）全在这里决定。
    // 加上 5 分钟一轮的巡检，即便某条新路径忘了调用，状态也会被拉回来。

    /// 触发方式。
    enum OnboardingEnforcement {
        /// 静默：Typeless 正在跑就一个字都不写，只把横幅点亮等用户点。
        /// 用于启动自愈和巡检 —— 绝不打扰。
        case silent
        /// 交互：允许「退出 Typeless → 写盘 → 重启」。用户主动点的按钮 / CLI 走这条。
        case interactive
    }

    /// 确保 Typeless 桌面端的新手引导处于完成态。**这是全工程唯一该被调用的入口。**
    ///
    /// - Parameters:
    ///   - reason: 只进日志，例如「启动自愈」「手动跳过」「无感换号」。
    ///   - mode: `.silent` 遇到 Typeless 在跑会直接放弃；`.interactive` 会退出再重启。
    ///   - expectedEmail: 期望登录的账号。传 nil = 不管是谁，跳过引导即可（fail-safe）。
    ///     即便传了值，与实际登录的不一致时也**照打不误**，只多记一条提示 ——
    ///     `app-onboarding.json` 是 App 级配置，与账号无关，不存在串号风险。
    ///   - waitForLoginSeconds: 传了 `expectedEmail` 时，等待桌面端落到该登录态的超时。
    /// - Returns: 给 UI 展示的日志行。
    @discardableResult
    func ensureOnboardingCompleted(
        reason: String,
        mode: OnboardingEnforcement,
        expectedEmail: String? = nil,
        waitForLoginSeconds: TimeInterval = 60
    ) async -> [String] {
        let storageURL = typelessStorageURL()
        let onboardingURL = typelessOnboardingURL()
        var log: [String] = []

        // 1) 已经完成就直接返回。这是绝大多数情况下的路径，必须便宜。
        guard desktopOnboardingIsIncomplete() else {
            desktopOnboardingNeedsPatch = false
            return []
        }

        // 2) Typeless 在跑时**不能写**：它内存里持有未完成状态，
        //    退出时会把我们写的值 flush 覆盖回去，白写还可能造成状态打架。
        if typelessDesktopIsRunning() {
            guard mode == .interactive else {
                desktopOnboardingNeedsPatch = true
                appendOnboardingPatchLog("\(reason)：Typeless 正在运行，静默模式不写盘，等待用户处理")
                return []
            }
            log.append(await terminateInstalledTypelessApp())
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }

        // 3) 等桌面端落到某个登录态（已退出时直接读盘，通常首轮就命中）。
        let readiness = await waitForTypelessDesktopStorage(
            storageURL: storageURL,
            onboardingURL: onboardingURL,
            expectedEmail: expectedEmail ?? "",
            timeoutSeconds: expectedEmail == nil ? 2 : waitForLoginSeconds
        )
        let actualEmail = readiness.email ?? readTypelessDesktopEmail(from: storageURL)

        if let expected = expectedEmail, !expected.isEmpty,
           let actual = actualEmail,
           actual.caseInsensitiveCompare(expected) != .orderedSame {
            log.append("提示：桌面端当前登录的是 \(actual)，与预期的 \(expected) 不一致；按当前实际登录账号跳过新手引导")
        }

        // 4) 真正写盘（备份 → 写 → 回读校验 → 补 storage 的 is_new_user）。
        log.append(contentsOf: performOnboardingWrite(
            storageURL: storageURL,
            onboardingURL: onboardingURL,
            expectedEmail: actualEmail,
            reason: reason
        ))

        // 5) 交互模式重启并复核若干轮 —— Typeless 冷启动会按 is_new_user
        //    重新初始化 onboarding 片段，只写一次可能被它改回去。
        if mode == .interactive {
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

        // 6) 复查，让 UI 横幅立刻反映真实状态。
        desktopOnboardingNeedsPatch = desktopOnboardingIsIncomplete()
        log.append(desktopOnboardingNeedsPatch
                   ? "复查：仍未生效，可关闭 Typeless 后再点一次"
                   : "复查：引导已完成标记已生效")
        return log
    }

    /// 写盘本体：备份 → 写 → 回读校验 → 补 `app-storage.json`。
    /// 只在确认「现在写是安全的」之后调用，判断逻辑不在这里。
    @discardableResult
    func performOnboardingWrite(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String?,
        reason: String
    ) -> [String] {
        var log: [String] = ["已写入桌面端新手引导完成标记（app-onboarding.json）"]
        backupDesktopOnboardingFileIfNeeded(onboardingURL)

        do {
            try writeTypelessOnboardingCompletion(to: onboardingURL)
        } catch {
            log.append("写入 app-onboarding.json 失败：\(error.localizedDescription)")
            appendOnboardingPatchLog("\(reason)：写 app-onboarding.json 失败 — \(error.localizedDescription)")
            return log
        }

        // 回读校验：写成功不等于生效。磁盘满、权限、Typeless 退出 flush 都可能让写入落空。
        guard !desktopOnboardingIsIncomplete() else {
            log.append("回读校验失败：写入后仍不是完成态，请检查 Typeless 数据目录权限")
            appendOnboardingPatchLog("\(reason)：回读校验失败，请检查 ~/Library/Application Support/Typeless 权限")
            return log
        }

        // app-storage.json 是 best-effort：is_new_user 是服务端真值、联网会被覆盖，
        // 但 Typeless 没在跑时补写，能让它冷启动第一次读盘就判定为非新用户。
        do {
            try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
            // 口径必须诚实：实测 7 个平台里只有 macos 站得住，其余会被服务端打回。
            // 真正决定「弹不弹引导」的是 app-onboarding.json，那才是持久的。
            log.append("已标记非新用户（is_new_user=false）；该字段联网后会被服务端覆盖，持久的是 app-onboarding.json")
        } catch {
            log.append("app-storage.json 跳过（\(error.localizedDescription)）")
        }

        appendOnboardingPatchLog("\(reason)：已确保引导完成")
        return log
    }

    /// 只写文件、不做任何进程控制。
    ///
    /// 这是**低级原语**，只给「必须在拉起 Typeless 之前同步写盘」的场景用
    /// （无感换号：写入会话缓存之后、拉起之前）。其余场景一律走
    /// `ensureOnboardingCompleted(reason:mode:)`，它会替你判断能不能写。
    @discardableResult
    func writeTypelessDesktopOnboardingFiles(
        storageURL: URL,
        onboardingURL: URL,
        expectedEmail: String?
    ) -> [String] {
        backupDesktopOnboardingFileIfNeeded(onboardingURL)
        do {
            try writeTypelessOnboardingCompletion(to: onboardingURL)
        } catch {
            return ["写入 app-onboarding.json 失败：\(error.localizedDescription)"]
        }
        do {
            try writeTypelessStorageOnboardingCompletion(to: storageURL, expectedEmail: expectedEmail)
        } catch {
            // best-effort：缺 userData（从未登录）不算失败。
        }
        return ["已写入桌面端引导完成标记（app-onboarding.json + app-storage.json）"]
    }

    /// 全自动换号流程入口。换号后新号是全新用户，必须把引导走完。
    func completeTypelessDesktopOnboardingIfPresent(expectedEmail: String, timeoutSeconds: TimeInterval = 60) async -> [String] {
        await ensureOnboardingCompleted(
            reason: "全自动换号",
            mode: .interactive,
            expectedEmail: expectedEmail,
            waitForLoginSeconds: timeoutSeconds
        )
    }

    /// 独立入口：不管当前登录的是哪个号，直接跳过新手引导。
    /// 供顶部横幅 / 账号详情 / 自检排障三个按钮使用，不依赖换号流程。
    @discardableResult
    func skipTypelessDesktopOnboardingNow() async -> [String] {
        var log = ["开始跳过 Typeless 桌面端新手引导…"]
        log.append(contentsOf: await ensureOnboardingCompleted(
            reason: "手动跳过",
            mode: .interactive
        ))
        return log
    }

    // MARK: - 启动自检与自愈（v2.5.4，v2.5.5 补强）

    /// 引导巡检间隔（秒）。每轮只读一个几百字节的 JSON，开销可忽略。
    static let onboardingGuardIntervalSeconds: TimeInterval = 300

    /// 桌面端引导状态。
    ///
    /// v2.5.4 把「读不到文件」一律当成「已完成」，这是个真缺口：
    /// Typeless 升级 / 重装把 `app-onboarding.json` 删掉之后补丁永远不触发，
    /// 而它下次冷启动会按默认值重建这个文件 —— 又变回未完成，白等一整轮。
    enum DesktopOnboardingState: Equatable {
        /// 明确写了完成标记。
        case complete
        /// 文件在，但还没走完引导。
        case incomplete
        /// 文件不存在或读不出来。装了 Typeless 就该主动补写。
        case missing
    }

    /// 读取桌面端引导状态。只看 `app-onboarding.json` —— 它才是决定「弹不弹引导」的持久开关，
    /// `app-storage.json` 里的 `is_new_user` 是服务端真值，联网就会被同步覆盖。
    ///
    /// 判定规则在 Core 的 `OnboardingPatchWriter`（可被单测），App 层只负责拼路径。
    func desktopOnboardingState() -> DesktopOnboardingState {
        switch OnboardingPatchWriter.state(ofOnboardingFile: typelessOnboardingURL()) {
        case .complete: return .complete
        case .incomplete: return .incomplete
        case .missing: return .missing
        }
    }

    /// 桌面端引导是否仍未完成。
    ///
    /// 「文件缺失」只有在 **Typeless 已安装** 时才算需要处理 —— 没装 Typeless 的机器上
    /// 根本没有这个文件，不该天天误报警。
    func desktopOnboardingIsIncomplete() -> Bool {
        OnboardingPatchWriter.needsPatch(
            state: OnboardingPatchWriter.state(ofOnboardingFile: typelessOnboardingURL()),
            treatMissingAsNeedsPatch: typelessAppPath() != nil
        )
    }

    /// 刷新 `desktopOnboardingNeedsPatch`。App 启动时调一次，UI 据此显示一键修复横幅。
    @discardableResult
    func refreshDesktopOnboardingState() -> Bool {
        let needs = desktopOnboardingIsIncomplete()
        desktopOnboardingNeedsPatch = needs
        if needs {
            appendOnboardingPatchLog("启动自检：检测到 Typeless 桌面端新手引导未完成")
        }
        return needs
    }

    /// 桌面端 Typeless 是否正在运行。
    func typelessDesktopIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "now.typeless.desktop" ||
                app.localizedName == "Typeless" ||
                app.bundleURL?.path == typelessAppPath()
        }
    }

    /// 启动自愈 / 巡检：只在「Typeless 没在跑」时静默写引导标记，完全不打扰用户。
    ///
    /// Typeless 正在跑时**不写** —— 它内存里持有 isCompleted=false，
    /// 退出时会把我们写的值覆盖回去，白写还可能造成状态打架。
    /// 那种情况改由顶部横幅提示用户点一下，走完整的「退出 → 写盘 → 重启」流程。
    ///
    /// v2.5.6：这里不再自带一套写盘逻辑，改为走统一入口的 `.silent` 模式。
    /// 以前静默路径和手动路径各写各的（备份 / 校验 / 补 storage 三件事复制了两份），
    /// 改一处容易漏另一处 —— 那正是用户说的「补丁越打越多」的根源。
    /// - Returns: 是否真的写了盘。
    @discardableResult
    func autoHealDesktopOnboardingIfSafe() async -> Bool {
        guard desktopOnboardingIsIncomplete() else {
            desktopOnboardingNeedsPatch = false
            return false
        }
        await ensureOnboardingCompleted(reason: "静默自愈", mode: .silent)
        // ensureOnboardingCompleted 已经把 desktopOnboardingNeedsPatch 刷新过了。
        return !desktopOnboardingNeedsPatch
    }

    /// 首次改写前留一份原文件，万一补丁把状态写坏了能手动还原。
    /// 只留第一份 —— 每次巡检都覆盖的话，备份本身就失去意义了。
    func backupDesktopOnboardingFileIfNeeded(_ url: URL) {
        OnboardingPatchWriter.backupIfNeeded(url)
    }

    // MARK: - 常驻巡检（v2.5.5）

    /// 引导巡检：启动自愈只在 App 冷启动时跑一次，覆盖不到
    /// 「App 连开好几天，期间 Typeless 升级 / 重装把引导标记重置了」这种情况。
    ///
    /// 这里起一个 5 分钟一轮的轻量循环：只读一个小 JSON，Typeless 没在跑
    /// 且标记被重置（或文件被删）时才写一次。开销可以忽略，但能让标记始终保持在完成态。
    func startOnboardingGuardIfNeeded() {
        guard onboardingGuardTask == nil else { return }
        let interval = Self.onboardingGuardIntervalSeconds
        // 显式 @MainActor：Store 是 MainActor 隔离的，标明之后循环体里可以直接 await，
        // 不用再套 MainActor.run（它的闭包是同步的，塞不进 async 调用）。
        onboardingGuardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { break }
                _ = await self.autoHealDesktopOnboardingIfSafe()
            }
        }
    }

    func stopOnboardingGuard() {
        onboardingGuardTask?.cancel()
        onboardingGuardTask = nil
    }

    // MARK: - 文件写入

    func writeTypelessOnboardingCompletion(to onboardingURL: URL) throws {
        // 真正的字段写入在 Core，可被单测；App 层只负责转发。
        try OnboardingPatchWriter.writeCompletion(toOnboardingFile: onboardingURL)
    }

    /// 把 `app-storage.json` 里的账号标记为「非新用户 + 全平台引导已完成」。
    ///
    /// - Parameter expectedEmail: 期望的登录邮箱。**传 nil 时不校验邮箱**，
    ///   直接改当前文件里那个 userData —— 这正是 fail-safe 的关键。
    func writeTypelessStorageOnboardingCompletion(to storageURL: URL, expectedEmail: String?) throws {
        try OnboardingPatchWriter.writeStorageCompletion(
            to: storageURL,
            expectedEmail: expectedEmail,
            reportedVersion: typelessDesktopReportedVersion()
        )
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
        let stamp = ISO8601DateFormatter().string(from: Date())
        LogFileRotator.append(
            line: "[\(stamp)] \(line)",
            to: directory.appendingPathComponent("onboarding-patch.log")
        )
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
        OnboardingPatchWriter.readEmail(fromStorageFile: storageURL)
    }

    /// 桌面端当前是否仍被判定为新用户（UI 用来提示「会有新手引导」）。
    func typelessDesktopIsNewUser() -> Bool {
        OnboardingPatchWriter.isNewUser(storageFile: typelessStorageURL())
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
