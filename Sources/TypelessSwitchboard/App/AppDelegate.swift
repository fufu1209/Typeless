import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

@MainActor
final class SwitchboardAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private weak var store: SwitchboardStore?
    private var statusItem: NSStatusItem?
    private var statusCancellable: AnyCancellable?
    private var mainWindow: NSWindow?
    private var didInstallWakeObserver = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 允许关主窗后进程仍在，靠菜单栏保活。
        NSApp.setActivationPolicy(.regular)
        installWakeObserverIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 默认不退出；用户可在设置里关掉 keepRunningInBackground。
        !(store?.state.settings.keepRunningInBackground ?? true)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 从后台/其他 App 切回来时刷一次菜单栏；守护本身不依赖前台。
        refreshStatusItemTitle()
    }

    func bind(store: SwitchboardStore) {
        guard self.store == nil else { return }
        self.store = store
        installStatusItemIfNeeded()
        installWakeObserverIfNeeded()

        // v2.5.5：把设置里的周期时区灌进全局时钟。必须在看门狗之前，
        // 否则看门狗会先按系统时区算出错误的休眠时长。
        store.applyQuotaCycleTimeZone()
        // v2.5.5：顺手裁一次守护日志（实测堆到过 24MB，launchd 那两个本进程管不着写入）。
        store.rotateQuotaGuardLogsIfNeeded()
        // v2.5.4：启动即复活 + 周界看门狗。与「无感守护」开关解耦，
        // 关掉守护、或整个周末没开 App，周一打开也能立刻把额度恢复回来。
        store.startQuotaCycleWatchdogIfNeeded()
        // v2.5.4：Typeless 没在跑时静默自愈引导标记；在跑则只标记状态，由横幅提示用户点一下。
        if !store.autoHealDesktopOnboardingIfSafe() {
            store.refreshDesktopOnboardingState()
        }
        // v2.5.5：常驻巡检。覆盖「App 连开好几天，期间 Typeless 升级把引导标记重置了」。
        store.startOnboardingGuardIfNeeded()
        statusCancellable = store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemTitle()
            }
        // 启动后稍等再刷一次标题；守护循环由 store.init 负责启动。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshStatusItemTitle()
        }
        // 再过几秒若还没读到剩余字数，主动踢一轮（避免用户以为「监控坏了」）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let store = self.store else { return }
            if store.state.settings.isAutoRotateEnabled, store.liveRemainingCharacters == nil {
                store.resumeRotateMonitorAfterWakeOrManualKick()
            }
            self.refreshStatusItemTitle()
        }
    }

    private func installWakeObserverIfNeeded() {
        guard !didInstallWakeObserver else { return }
        didInstallWakeObserver = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleSystemDidWake() {
        store?.resumeRotateMonitorAfterWakeOrManualKick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshStatusItemTitle()
        }
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "switch.2",
                accessibilityDescription: "Typeless Switchboard"
            )
            button.imagePosition = .imageLeading
            button.title = "守护"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "立即巡检额度", action: #selector(runCheckNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
        refreshStatusItemTitle()
    }

    private func refreshStatusItemTitle() {
        guard let store, let button = statusItem?.button else { return }
        let threshold = SmartSwitchPolicy.normalizeThreshold(store.state.settings.autoRotateRemainingThreshold)
        if store.isRunningAutomaticReplacement || store.isRunningSmartSwitch {
            button.title = "换号中"
            button.toolTip = store.autoRotateMonitorStatus
            return
        }
        if let remaining = store.liveRemainingCharacters {
            // 菜单栏：本周剩余字数；数字不新鲜加「?」；低于阈值加「↓」。
            let low = remaining < threshold
            if store.lastQuotaSyncFresh {
                button.title = low ? "↓\(remaining)" : "\(remaining)"
            } else {
                button.title = low ? "?↓\(remaining)" : "?\(remaining)"
            }
            button.toolTip = [
                store.liveAccountEmail.isEmpty ? nil : "当前：\(store.liveAccountEmail)",
                store.weeklyQuotaSummaryLine,
                store.lastQuotaSyncFresh
                    ? "换号阈值 \(threshold)（仅本周剩余 < 阈值才自动换）"
                    : "本周额度可能陈旧：本轮不自动换号",
                store.autoRotateMonitorStatus,
                store.lastAutoRotateDecisionReason.isEmpty ? nil : store.lastAutoRotateDecisionReason
            ].compactMap { $0 }.joined(separator: "\n")
        } else if store.state.settings.isAutoRotateEnabled || QuotaGuardLaunchAgent.isInstalled {
            button.title = store.lastQuotaSyncFresh ? "监控" : "?"
            button.toolTip = [
                "本周额度守护已开，等待读到官方本周剩余字数",
                store.weeklyQuotaSummaryLine,
                "换号阈值：本周剩余 < \(threshold) 且数字新鲜才自动换号",
                store.autoRotateMonitorStatus
            ].joined(separator: "\n")
        } else {
            button.title = "关闭"
            button.toolTip = "本周额度守护未开启（可安装开机轻量插件）"
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // 若窗口已被关，发通知让系统重建（SwiftUI WindowGroup 会在 activate 时恢复）。
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func runCheckNow() {
        guard let store else { return }
        store.resumeRotateMonitorAfterWakeOrManualKick()
        Task {
            // resume 里已可能触发检查；再刷一次标题保证菜单栏更新。
            try? await Task.sleep(nanoseconds: 500_000_000)
            refreshStatusItemTitle()
        }
    }

    @objc private func quitApp() {
        store?.stopRotateMonitor()
        store?.stopQuotaCycleWatchdog()
        store?.stopOnboardingGuard()
        NSApp.terminate(nil)
    }
}

/// 5-tab 根容器（见 `UI/RootView.swift`）。旧的侧边栏 / Inspector 已在 v2.2.0 拆分到 UI/ 下各 tab。
