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
