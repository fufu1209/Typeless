import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

@MainActor
final class SwitchboardStore: ObservableObject {
    @Published var state: PersistedState
    @Published var statusMessage = "本地数据已准备好"
    @Published var moeMailEmails: [MoeMailEmail] = []
    @Published var moeMailMessages: [MoeMailMessage] = []
    @Published var diagnostics: [DiagnosticItem] = []
    @Published var isRunningAutomaticReplacement = false
    /// 智能换号 / 静默池内切换进行中（与全自动注册共用互斥，避免双开）。
    @Published var isRunningSmartSwitch = false
    @Published var isSyncingSession = false
    @Published var syncStatusMessage = ""
    @Published var lastAutoRotateCheckAt: Date?
    @Published var lastAutoRotateDecisionReason = ""
    @Published var autoRotateMonitorStatus = "守护未开启"
    /// 最近一次静默换号失败原因（含设备用户数超限等），供 UI / 降级决策使用。
    @Published var lastSilentSwitchFailureReason = ""
    /// 最近一次同步官方会话时是否命中「设备登录用户数超限」。
    @Published var lastSyncHitDeviceUserLimit = false

    /// 官方拒绝了本客户端（HTTP 403 / code 20006）。
    /// 与「设备超限」不同，这种状态本地无解，必须换新版 App —— 所以要单独可见。
    @Published var lastSyncHitClientNotSupported = false
    /// P0-2：账号池文件解码失败时记录原因并保留损坏备份。UI 侧栏错误条要展示这个。
    @Published var accountLoadError: String?
    /// 最近一次「本周额度」官方 API 是否拿到新鲜数值（失败时不得当成额度充足）。
    @Published var lastQuotaSyncFresh = false
    /// 最近一次成功拉到本周额度的时间。
    @Published var lastQuotaSyncAt: Date?
    /// 最近一次官方本周已用 / 上限（与 remaining 同源：week_word_usage_*）。
    @Published var lastQuotaUsedCharacters: Int?
    @Published var lastQuotaMonthlyLimit: Int?
    /// 当前官方账号剩余字数（菜单栏展示用）。
    @Published var liveRemainingCharacters: Int?
    @Published var liveAccountEmail = ""
    /// 开机自启 LaunchAgent 状态摘要（侧栏展示）。
    @Published var launchAgentStatusMessage = ""

    // MARK: - v2.5.4 周额度周期看门狗
    //
    // 原先 `reviveExpiredAccountsIfNeeded` 只在 `syncActiveAppSessionAndQuota` 里被调用，
    // 而同步本身依赖 node 脚本 + Typeless 登录态。两个后果：
    //   1. 关掉「无感守护」时，周一 00:00 之后账号不会自动复活，额度被错杀；
    //   2. 整个周末没开 App，周一打开也不会复活，要等用户手动点「同步额度」。
    // 看门狗与守护开关解耦：不管 isAutoRotateEnabled 开不开都会跑，
    // 且只在本地纯计算，不请求网络、不依赖 node。
    var quotaCycleWatchdogTask: Task<Void, Never>?
    /// 引导巡检循环（v2.5.5）：5 分钟一轮，Typeless 未运行且引导标记被重置时静默补写。
    var onboardingGuardTask: Task<Void, Never>?
    /// 各账号最近一次观测到的「本周已用」数值（v2.5.6）。
    /// 官方 `/user/usage_stats` 不返回重置时间戳，只能靠数值下降沿来识别重置 ——
    /// 这是实测周期口径（自然周 vs 滚动 7 天）的唯一办法。仅内存态，不做持久化。
    var quotaUsageSamples: [UUID: Int] = [:]
    /// 观测到的额度重置时刻（v2.5.6）。攒够样本后自动给出口径结论，不再靠猜。
    /// **跨重启累积**：启动时从 `quota-cycle-observations.json` 读回，
    /// 否则用户每天开关机的话永远攒不够样本（判定口径至少要看两三次重置 = 两三周）。
    var quotaObservedResets: [QuotaCycleEngine.ObservedReset] = []
    /// 落盘版观测记录（含邮箱，便于事后人工核对）。
    var quotaObservationRecords: [QuotaCycleObservationStore.Record] = []
    /// 最近一次自动复活的时间点（UI 展示用）。
    @Published var lastWeeklyRevivalAt: Date?
    /// 最近一次自动复活了哪些账号（UI 展示用）。
    @Published var lastWeeklyRevivalEmails: [String] = []
    /// Typeless 桌面端引导状态是否未完成（v2.5.4：启动自检后提示用户一键跳过）。
    @Published var desktopOnboardingNeedsPatch = false

    let fileURL: URL
    let runMode: SwitchboardRunMode
    var rotateMonitorTask: Task<Void, Never>?
    var isAutoRotateCheckInFlight = false
    /// 上一轮巡检得到的剩余额度，用于自适应巡检间隔。
    var lastKnownRemainingForInterval: Int?

    var dataFileURL: URL {
        fileURL
    }

    /// 任一换号路径进行中时禁用主按钮。
    var isSwitchBusy: Bool {
        isRunningAutomaticReplacement || isRunningSmartSwitch || isSyncingSession
    }

    init(runMode: SwitchboardRunMode = .gui) {
        self.runMode = runMode
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        self.fileURL = folder.appendingPathComponent("store.json")

        // P0-2：解码失败不能静默吞错 + 落盘成空 state，否则 Keychain 里的密码永久找不到。
        // 先把损坏文件备份到 store.json.corrupted-<时间戳>，再置空，让用户从 UI 看到错误。
        switch StoreRecovery.load(from: fileURL, decode: { try JSONDecoder.appDecoder.decode(PersistedState.self, from: $0) }) {
        case .success(let loaded):
            state = loaded
        case .failure(let recovery):
            accountLoadError = recovery.message
            state = .empty
        }
        migrateDefaultsIfNeeded()
        // v2.5.5：周期时区必须在**所有运行模式**下生效，不能只挂在 GUI 的 AppDelegate 上。
        // LaunchAgent 守护（--daemon-check）是独立进程，它也要按同一个时区算周界，
        // 否则会出现「App 里显示该复活了，插件巡检却认为还没到点」。
        applyQuotaCycleTimeZone()
        // 必须在任何同步之前把历史观测读回来，否则恰好跨周重启会漏掉最关键的那条证据。
        loadQuotaCycleObservations()
        ensureExtractScript()
        refreshLaunchAgentStatus()

        // GUI 才常驻循环监控；daemon 单次巡检由 CLI 入口触发，避免无界面进程挂后台。
        if runMode == .gui, state.settings.isAutoRotateEnabled {
            startRotateMonitor()
            autoRotateMonitorStatus = "无感守护已开启，等待首次巡检（也可装开机轻量插件，不必开着本窗口）"
        } else if runMode == .gui {
            autoRotateMonitorStatus = "App 内循环守护已关闭（推荐用开机轻量插件）"
        } else {
            autoRotateMonitorStatus = "daemon 单次巡检模式"
        }
    }

    func migrateDefaultsIfNeeded() {
        // v2.6.0：迁移必须**落盘**，否则就是最阴的一类静默失效。
        //
        // 旧实现只改内存里的 `state`，然后把「已迁移」标记写进 UserDefaults，**从不写文件**。
        // 后果：标记被烧掉、数据没落地，下次启动看到标记为真就直接跳过 ——
        // 迁移永远不会生效，而且没有任何报错、日志、UI 提示。
        //
        // 本机实测就是这样：`didRescaleQuotaFor2000WeeklyLimit_v1` 已经是 true，
        // 而 store.json 里的阈值还停在 200 —— 在 2000 字/周下等于白扔 10% 的额度。
        //
        // 现在：函数末尾统一比对，只要有变化就原子落盘；并把幂等键从 UserDefaults
        // 挪进 store.json 的 `appliedMigrations`，让「数据」和「数据已迁移」同生共死。
        let stateBeforeMigration = state

        if state.settings.typelessLoginURL == oldTypelessLoginURL ||
            state.settings.typelessLoginURL == typelessOfficialURL {
            state.settings.typelessLoginURL = typelessDefaultLoginURL
        }

        // 一次性迁移到「无感守护」默认：开启监测、池空自动注册、关窗后台、阈值 200、热备 1、常规 1 分钟巡检。
        let seamlessMigrationKey = "didApplySeamlessGuardianDefaults_v1"
        if !UserDefaults.standard.bool(forKey: seamlessMigrationKey) {
            state.settings.isAutoRotateEnabled = true
            state.settings.autoCreateWhenPoolEmpty = true
            state.settings.keepRunningInBackground = true
            state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.defaultRemainingThreshold
            state.settings.autoRotateCheckIntervalMinutes = SmartSwitchPolicy.defaultCheckIntervalMinutes
            state.settings.hotSpareTargetCount = max(
                state.settings.hotSpareTargetCount,
                SmartSwitchPolicy.defaultHotSpareTarget
            )
            UserDefaults.standard.set(true, forKey: seamlessMigrationKey)
        }

        // v2：默认不再要求 GUI 常驻；额度守护交给 LaunchAgent 轻量插件（定时 --daemon-check）。
        let noResidentGUIKey = "didApplyLaunchAgentPreferredDefaults_v2"
        if !UserDefaults.standard.bool(forKey: noResidentGUIKey) {
            state.settings.keepRunningInBackground = false
            state.settings.isAutoRotateEnabled = false
            UserDefaults.standard.set(true, forKey: noResidentGUIKey)
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.appEncoder.encode(state) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }

        // v2.6.0：官方周额度 8000 → 2000，两处存量数据要跟着挪。
        //   ① 阈值 200 是 8000 时代的旧默认（占比 2.5%），到 2000 时代变成 10%，等于白扔额度；
        //   ② 库里存量账号的 monthlyLimit 还写着 8000，在轮到它之前会一直显示错误的剩余额度，
        //      也会让选号逻辑在各账号之间产生错误的高低比较。
        // 只动「恰好等于旧值」的数据：用户手改过的阈值一律不碰。
        //
        // 幂等键**只认 store.json 里的记录**，不认 UserDefaults：
        // 本机那个 UserDefaults 键早被旧代码写成 true 了，若两者取「或」，
        // 这次修复就会被那个假标记继续挡住。
        let appliedMigrations = state.appliedMigrations ?? []
        if LegacyQuotaRescale.shouldApply(appliedMigrations: appliedMigrations) {
            state.settings.autoRotateRemainingThreshold = LegacyQuotaRescale.rescaledThreshold(
                state.settings.autoRotateRemainingThreshold
            )
            for index in state.accounts.indices {
                state.accounts[index].monthlyLimit = LegacyQuotaRescale.rescaledWeeklyLimit(
                    state.accounts[index].monthlyLimit
                )
            }
            // 顺手把旧代码留下的那个假标记清掉，免得后人再被它误导。
            UserDefaults.standard.removeObject(forKey: LegacyQuotaRescale.migrationKey)
            state.appliedMigrations = appliedMigrations + [LegacyQuotaRescale.migrationKey]
        }

        if state.settings.autoRotateCheckIntervalMinutes <= 0 {
            state.settings.autoRotateCheckIntervalMinutes = SmartSwitchPolicy.defaultCheckIntervalMinutes
        }
        if state.settings.autoRotateRemainingThreshold <= 0 {
            state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.defaultRemainingThreshold
        }
        state.settings.autoRotateCheckIntervalMinutes = SmartSwitchPolicy.normalizeCheckIntervalMinutes(
            state.settings.autoRotateCheckIntervalMinutes
        )
        state.settings.autoRotateRemainingThreshold = SmartSwitchPolicy.normalizeThreshold(
            state.settings.autoRotateRemainingThreshold
        )
        state.settings.hotSpareTargetCount = SmartSwitchPolicy.normalizeHotSpareTarget(
            state.settings.hotSpareTargetCount
        )
        for index in state.settings.checklist.indices {
            if state.settings.checklist[index].title == "打开对应邮箱，手动处理必要验证码" {
                state.settings.checklist[index].title = "自动轮询对应邮箱验证码，必要时手动兜底"
            }
        }

        // 有变化才写盘：迁移是幂等的，没变化时重写纯属浪费 I/O，
        // 也会无谓地刷新 store.json 的 mtime（守护进程靠 mtime 判断外部改动）。
        guard state != stateBeforeMigration else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder.appEncoder.encode(state) {
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    /// 把 App 包内的会话/额度脚本铺到 Application Support，供 `node` 调用。
    ///
    /// v2.6.0 之前这段脚本是以 `#"""..."""#` 字符串**内嵌在本文件里**的，
    /// 同时仓库 `scripts/` 下还有一份独立副本。两份各自演化后彻底分叉：
    /// 线上真正跑的那份和仓库里那份已经不是同一个东西，改哪一份都不对。
    ///
    /// 现在脚本的唯一来源是 `Sources/TypelessSwitchboard/Resources/*.js`
    /// （随 App 包分发），本方法只负责复制，不再承担任何脚本内容。
    /// 内容没变就不重写，避免把正在运行的脚本换掉。
    func ensureExtractScript() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = appSupport.appendingPathComponent("TypelessSwitchboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var failure: String?
        for name in Self.automationScriptNames {
            guard let source = Self.bundledAutomationScriptURL(name) else {
                failure = "App 包内缺少自动化脚本 \(name)，请重新打包 App"
                continue
            }
            guard let content = try? String(contentsOf: source, encoding: .utf8) else {
                failure = "读取 \(name) 失败：\(source.path)"
                continue
            }
            let destination = folder.appendingPathComponent(name)
            if let existing = try? String(contentsOf: destination, encoding: .utf8), existing == content {
                continue
            }
            do {
                try content.write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                failure = "写入 \(name) 失败：\(error.localizedDescription)"
            }
        }
        lastAutomationScriptDeployError = failure
    }

    /// 需要铺到 Application Support 的自动化脚本清单。
    nonisolated static let automationScriptNames = [
        "extract-active-session.js",
        "write-active-session.js"
    ]

    /// 在 App 包内定位自动化脚本。三种打包形态都要能找到：
    ///   1. `swift build` / `swift run`：脚本在 SwiftPM 资源包 `*.bundle` 里
    ///   2. 手工组装的 `.app`：`build-app.sh` 把脚本拷进 `Contents/Resources/`
    ///   3. 直接跑裸二进制：脚本与可执行文件同目录
    nonisolated static func bundledAutomationScriptURL(_ name: String) -> URL? {
        let base = (name as NSString).deletingPathExtension
        var candidates: [URL] = []
        if let url = Bundle.module.url(forResource: base, withExtension: "js", subdirectory: "Resources") {
            candidates.append(url)
        }
        if let url = Bundle.module.url(forResource: base, withExtension: "js") {
            candidates.append(url)
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name))
            candidates.append(resources.appendingPathComponent("Resources/\(name)"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name))
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 最近一次铺设自动化脚本失败的原因；nil 表示成功。UI 用它提示「脚本没铺上」。
    var lastAutomationScriptDeployError: String?


    /// 最近一次成功写盘的内容快照：UI 逐字符输入也会触发 save，内容未变时跳过编码与写盘。
    var lastSavedStateData: Data?

    /// 权限探测结果缓存，避免后台热备/巡检反复触发系统弹窗。
    var cachedAccessibilityTrusted: Bool?
    var cachedAutomationOK: Bool?
    var cachedAutomationDetail = ""
    var lastPermissionProbeAt: Date?
    var didAutoOpenPermissionSettingsThisSession = false
    let permissionProbeCacheTTL: TimeInterval = 30 * 60

    /// - Parameter localOnly: 只做本地解密 + 账号匹配 + 会话缓存更新，不请求官方额度 API。
    ///   静默换号验证等「只需确认当前桌面账号」的场景使用，快且不受网络波动影响。
}
