import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

// MARK: - 单实例锁
//
// v2.5.3：现场抓到过两个实例同时跑（PID 119 与 99938，同一份 /Applications 二进制）。
// 成因是 LaunchAgent 与手动启动各拉起一次。两个实例会同时读写 store.json、
// 同时跑额度巡检、同时改桌面会话，表现为「数字乱跳 / 换号结果被互相覆盖」。
//
// 用 flock 文件锁：进程退出时内核自动释放，不会留下 stale lock。
enum SingleInstanceGuard {
    /// 只在进程启动期写一次，之后只读；用 nonisolated(unsafe) 满足 Swift 6 严格并发检查。
    nonisolated(unsafe) private static var fd: Int32 = -1

    /// 尝试取得单实例锁。已被别的实例持有时返回 false。
    /// - 仅 GUI 模式抢锁；daemonOnce / cliAutoSwitch 是一次性短任务，
    ///   必须允许与常驻 GUI 并存，否则 LaunchAgent 巡检会被主程序挡掉。
    @discardableResult
    static func acquire() -> Bool {
        let path = NSTemporaryDirectory() + "typeless-switchboard.gui.lock"
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true } // 拿不到文件句柄时放行，避免死锁主流程
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            fd = -1
            return false
        }
        return true
    }

    /// 已有实例在跑时：把它的窗口带到前台，然后安静退出。
    static func activateExistingInstanceAndExit() -> Never {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "local.typeless.switchboard"
        }
        if let existing = running.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
        }
        exit(0)
    }
}

enum TypelessSwitchboardMain {
    /// 必须是 @MainActor：`resolveRunMode` 与 AppKit 装配都在主线程上下文。
    /// 原先靠 `@main` 属性隐式获得隔离，去掉 @main 后需要显式标注。
    @MainActor static func main() {
        // v2.5.3：命令行一键跳过 Typeless 桌面端新手引导。
        // 用法：/Applications/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard --skip-onboarding
        // 这条路径不进 GUI、不抢单实例锁（要能和常驻 GUI 并存），跑完直接退出。
        if CommandLine.arguments.contains("--skip-onboarding") {
            runStandaloneOnboardingPatchAndExit()
        }
        // v2.8.0：无界面读一次额度（走 CDP 直读），用于排障与脚本化监控。
        //   TypelessSwitchboard --probe-quota [--port 9333]
        // 成功打印一行 JSON 并 exit 0；失败打印原因并 exit 1。
        if CommandLine.arguments.contains("--probe-quota") {
            runStandaloneQuotaProbeAndExit()
        }
        // v2.8.0：实时监听一段时间（CDP Network 事件），用于验证 / 观察。
        //   TypelessSwitchboard --watch-quota [--seconds 30] [--port 9333]
        if CommandLine.arguments.contains("--watch-quota") {
            runStandaloneQuotaWatchAndExit()
        }
        // v2.9.0：一行一条的健康报告（排障/巡检用；不写任何数据）。
        //   TypelessSwitchboard --health
        if CommandLine.arguments.contains("--health") {
            runStandaloneHealthAndExit()
        }
        // v2.9.0：把桌面端恢复到某个可用账号（默认挑剩余额度最多的可用会话）。
        //   TypelessSwitchboard --repair-login [--email x@y]
        if CommandLine.arguments.contains("--repair-login") {
            runStandaloneRepairLoginAndExit()
        }
        // v2.5.6：无界面导出配置包，供脚本化备份 / 换机迁移使用。
        //   --export-full-bundle    真实邮箱 + 完整设置（自用，别外传）
        //   --export-public-bundle  脱敏版（可分享 / 发 GitHub）
        // 可选 `--out <目录>`，默认 ~/Downloads。
        if CommandLine.arguments.contains("--export-full-bundle") {
            runStandaloneBundleExportAndExit(sanitized: false)
        }
        if CommandLine.arguments.contains("--export-public-bundle") {
            runStandaloneBundleExportAndExit(sanitized: true)
        }
        // 与导出配对：换机时 `git clone` 完一条命令就能把账号池恢复回来。
        //   --import-bundle <文件路径>
        if let path = value(of: "--import-bundle") {
            runStandaloneBundleImportAndExit(path: path)
        }

        let mode = SwitchboardStore.resolveRunMode()
        switch mode {
        case .gui:
            guard SingleInstanceGuard.acquire() else {
                SingleInstanceGuard.activateExistingInstanceAndExit()
            }
            TypelessSwitchboardApp.main()
        case .daemonOnce, .cliAutoSwitch:
            // NSApplication / AppKit 入口必须在主线程 + MainActor 上下文完成装配。
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    runHeadlessCLI(mode: mode)
                }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        runHeadlessCLI(mode: mode)
                    }
                }
            }
        }
    }

    /// v2.8.0：`--probe-quota` 的实现。
    ///
    /// 这是「额度直读」的最小可验证入口：不打开 GUI、不写 store、不碰账号池，
    /// 只连 `127.0.0.1:<port>` 的 DevTools，问一次 `usage_stats` 就把结果打成 JSON。
    /// 用户排障时可以把它贴进 issue，脚本也可以直接消费。
    @MainActor
    private static func runStandaloneQuotaProbeAndExit() -> Never {
        let port = Int(value(of: "--port") ?? "") ?? TypelessQuotaBridge.defaultPort
        print("TypelessSwitchboard: probing quota via CDP on port \(port)…")
        Task { @MainActor in
            let reader = TypelessCDPQuotaReader(port: port)
            if let snapshot = await reader.readQuota() {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(snapshot),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                } else {
                    print("直读成功但序列化失败：\(snapshot.summary)")
                }
                exit(0)
            }
            let reason = await reader.lastFailureDescription ?? "未知原因"
            print("直读失败：\(reason)")
            exit(1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// v2.9.0：`--health` 的实现。
    ///
    /// 只读：不写 store、不改会话、不触发换号。输出刻意做成一行一条，
    /// 用户复制进聊天窗口就能让支持方一眼看出「哪一环断了」。
    @MainActor
    private static func runStandaloneHealthAndExit() -> Never {
        let store = SwitchboardStore(runMode: .daemonOnce)
        Task { @MainActor in
            var lines: [String] = []
            lines.append("version: \(AppVersion.full)")

            let typelessVersion: String = {
                guard let path = store.typelessAppPath() else { return "not-installed" }
                let plistPath = path + "/Contents/Info.plist"
                guard let plist = NSDictionary(contentsOfFile: plistPath),
                      let version = plist["CFBundleShortVersionString"] as? String
                else { return "unknown" }
                return version
            }()
            let running = store.typelessIsRunning()
            let reachable = await store.isQuotaDebugPortReachable()
            lines.append("typeless: running=\(running) version=\(typelessVersion) cdpPort=\(store.cdpQuotaPort) reachable=\(reachable)")

            let reader = TypelessCDPQuotaReader(port: store.cdpQuotaPort)
            let liveSnapshot = await reader.readQuota()
            if let snapshot = liveSnapshot {
                lines.append("quota(live): \(snapshot.usedCharacters)/\(snapshot.weeklyLimit) remaining=\(snapshot.remainingCharacters) email=\(snapshot.email ?? "-") chunk=\(snapshot.clientChunk ?? "-")")
            } else {
                let reason = await reader.lastFailureDescription ?? "unknown"
                lines.append("quota: unavailable reason=\(reason)")
            }

            let syncAge = store.lastQuotaSyncAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
            let sourceText = liveSnapshot != nil ? "CDP 直读（live）" : (store.lastQuotaSource?.displayName ?? "unknown")
            lines.append("lastSync: age=\(syncAge)s source=\(sourceText) fresh=\(liveSnapshot != nil || store.lastQuotaSyncFresh)")
            lines.append("repair: last=\(store.state.lastCDPBridgeRepairAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
            lines.append("launchagent: installed=\(QuotaGuardLaunchAgent.isInstalled) loaded=\(QuotaGuardLaunchAgent.isLoaded)")
            if let lock = QuotaCheckLock.acquire() {
                lock.release()
                lines.append("checkLock: free")
            } else {
                lines.append("checkLock: held (另一进程正在巡检/换号)")
            }
            lines.append("automation: autoRotate=\(store.state.settings.isAutoRotateEnabled) cdp=\(store.state.settings.isCDPQuotaEnabled) port=\(store.cdpQuotaPort)")

            let accounts = store.state.accounts
            let available = accounts.filter { $0.status == .available }.count
            let pending = accounts.filter { $0.effectiveReviewState == .pending }.count
            let exhausted = accounts.filter { $0.status == .exhausted }.count
            let paused = accounts.filter { $0.status == .paused }.count
            lines.append("accounts: total=\(accounts.count) available=\(available) pending=\(pending) exhausted=\(exhausted) paused=\(paused)")

            let summary = store.switchHistorySummary(days: 7)
            lines.append("switches(7d): total=\(summary.total) ok=\(summary.succeeded) failed=\(summary.failed) median=\(String(format: "%.1f", summary.medianSeconds))s")
            print(lines.joined(separator: "\n"))
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// v2.9.0：`--repair-login` 的实现。
    @MainActor
    private static func runStandaloneRepairLoginAndExit() -> Never {
        let email = value(of: "--email")
        let store = SwitchboardStore(runMode: .daemonOnce)
        Task { @MainActor in
            let message = await store.repairDesktopLogin(preferredEmail: email, force: true)
            print(message)
            exit(message.contains("已恢复") ? 0 : 1)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// v2.8.0：`--watch-quota` 的实现。
    ///
    /// 旁听 Typeless 自己的 `usage_stats` 响应（不额外发请求）。适合验证
    /// 「实时监听到底通不通」：启动它，然后打开/刷新 Typeless 主窗口，应当立刻打印一行。
    @MainActor
    private static func runStandaloneQuotaWatchAndExit() -> Never {
        let port = Int(value(of: "--port") ?? "") ?? TypelessQuotaBridge.defaultPort
        let seconds = max(Int(value(of: "--seconds") ?? "") ?? 30, 5)
        print("TypelessSwitchboard: watching quota via CDP on port \(port) for \(seconds)s…")
        let watcher = TypelessQuotaLiveWatcher(port: port)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"

        Task { @MainActor in
            let stream = await watcher.start()
            // 3 秒后报一次连接状态：没连上（Typeless 没带端口 / 端口被占）时不至于静默空等。
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let connected = await watcher.isConnected
            if !connected {
                let reason = await watcher.lastFailureDescription ?? "未知原因"
                print("⚠️ 监听未连上：\(reason)")
            } else {
                print("已连上 Typeless DevTools，等待额度刷新事件…")
            }
            for await snapshot in stream {
                print("[\(formatter.string(from: snapshot.capturedAt))] \(snapshot.summary)")
            }
        }
        // 无论有没有事件，到点都退出（避免 CI / 脚本里挂死）。
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds)) {
            Task { await watcher.stop() }
            print("TypelessSwitchboard: watch finished")
            exit(0)
        }
        RunLoop.main.run()
        exit(0)
    }

    /// 独立跑一遍引导补丁并退出。供终端排障使用，也可以在 App 卡住时兜底。
    @MainActor
    private static func runStandaloneOnboardingPatchAndExit() -> Never {
        print("TypelessSwitchboard: skipping Typeless desktop onboarding…")
        let store = SwitchboardStore(runMode: .daemonOnce)
        Task { @MainActor in
            let log = await store.skipTypelessDesktopOnboardingNow()
            for line in log { print("  \(line)") }
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(log.contains(where: { $0.contains("失败") }) ? 1 : 0)
        }
        // 让 Task 有机会执行完：交给 runloop。
        RunLoop.main.run()
        exit(0)
    }

    /// 无界面导出配置包并退出。
    ///
    /// 为什么要单独做：换 Mac 迁移、定时备份这类场景应当能脚本化，
    /// 不能每次都开窗口点按钮。导出物**不含** Keychain 里的密码 / API Key，
    /// 也不含账号的桌面会话缓存（那东西与设备身份绑定，搬到新机器反而会触发
    /// 「设备登录用户数超限」）。
    @MainActor
    private static func runStandaloneBundleExportAndExit(sanitized: Bool) -> Never {
        let label = sanitized ? "脱敏配置包" : "完整配置包"
        print("TypelessSwitchboard: exporting \(label)…")
        let store = SwitchboardStore(runMode: .daemonOnce)
        let url = sanitized ? store.exportPublicBundle() : store.exportFullBundle()
        if let url {
            print("  已导出：\(url.path)")
            if sanitized {
                print("  邮箱已替换为 demo[N]@example.com，notes 已清空，可安全分享")
            } else {
                print("  含真实邮箱与完整设置；不含密码 / API Key / 会话缓存")
            }
            exit(0)
        } else {
            print("  导出失败：\(store.statusMessage)")
            exit(1)
        }
    }

    /// 读取 `--flag 值` 形式的命令行参数。
    private static func value(of flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        let value = CommandLine.arguments[index + 1]
        return value.isEmpty ? nil : value
    }

    /// 无界面导入配置包并退出。按邮箱去重，已有账号不会被重复添加。
    @MainActor
    private static func runStandaloneBundleImportAndExit(path: String) -> Never {
        print("TypelessSwitchboard: importing bundle from \(path)")
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let store = SwitchboardStore(runMode: .daemonOnce)
        let added = store.importFullBundle(from: url)
        switch added {
        case ..<0:
            // statusMessage 里已经带了「导入失败：」前缀，别再叠一层。
            print("  \(store.statusMessage)")
            exit(1)
        case 0:
            print("  没有新增账号：\(store.statusMessage)")
            exit(0)
        default:
            print("  已导入 \(added) 个账号：\(store.statusMessage)")
            // 设置也一并生效，导入函数内部已 save()。
            exit(0)
        }
    }

    @MainActor
    private static func runHeadlessCLI(mode: SwitchboardRunMode) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let runner = HeadlessCLIRunner(mode: mode)
        // 强引用 runner，避免 delegate 被释放。
        HeadlessCLIRunner.retained = runner
        app.delegate = runner
        app.run()
    }
}

/// 无界面 CLI：不弹主窗口，跑完 daemon/批量换号后 exit。
@MainActor
final class HeadlessCLIRunner: NSObject, NSApplicationDelegate {
    /// 保持进程级强引用，防止 `app.delegate` 的 weak 语义导致 runner 被回收。
    static var retained: HeadlessCLIRunner?

    private let mode: SwitchboardRunMode
    private var store: SwitchboardStore?

    init(mode: SwitchboardRunMode) {
        self.mode = mode
        super.init()
    }

    /// v2.9.0：守护进程收到「用户点了 App」时，另起一个 GUI 实例。
    ///
    /// 以前的坑：LaunchServices 认为 bundle 已经在跑（其实是 `--daemon-check`），
    /// 于是只「激活」那个后台进程 —— 用户双击 App 什么都不发生。
    /// `open -n` 强制新实例；单实例锁保证 GUI 只有一个。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SwitchboardStore(runMode: mode)
        self.store = store
        Task { @MainActor in
            switch mode {
            case .daemonOnce:
                _ = await store.runDaemonQuotaGuardOnceIfRequested()
            case .cliAutoSwitch:
                _ = await store.runCommandLineAutomaticReplacementIfRequested()
            case .gui:
                break
            }
            // 给一点时间把日志/文件刷盘。
            try? await Task.sleep(nanoseconds: 200_000_000)
            NSApp.terminate(nil)
            exit(0)
        }
    }
}

struct TypelessSwitchboardApp: App {
    @NSApplicationDelegateAdaptor(SwitchboardAppDelegate.self) private var appDelegate
    @StateObject private var store = SwitchboardStore(runMode: .gui)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                // v2.5.2：5 个 tab + 顶部右侧按钮，原来 1180 会把第 5 个 tab 标题
                // 裁切（「自检排障」显示成「自检排�」）。提到 1280 给侧边栏+tab+按钮留够空间。
                .frame(minWidth: 1280, minHeight: 760)
                .onAppear {
                    appDelegate.bind(store: store)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - 开机轻量额度守护 LaunchAgent

/// macOS LaunchAgent：开机登录后按间隔执行 `--daemon-check`，不常驻 GUI。


struct ContentView: View {
    var body: some View { RootView() }
}
