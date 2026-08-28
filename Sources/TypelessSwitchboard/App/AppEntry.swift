import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

enum TypelessSwitchboardMain {
    /// 必须是 @MainActor：`resolveRunMode` 与 AppKit 装配都在主线程上下文。
    /// 原先靠 `@main` 属性隐式获得隔离，去掉 @main 后需要显式标注。
    @MainActor static func main() {
        let mode = SwitchboardStore.resolveRunMode()
        switch mode {
        case .gui:
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
                .frame(minWidth: 1180, minHeight: 760)
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
