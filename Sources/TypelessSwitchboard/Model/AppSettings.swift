import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

struct AppSettings: Codable, Equatable, Sendable {
    var typelessLoginURL: String
    var moeMailBaseURL: String
    var domains: [String]
    var checklist: [SwitchTask]
    /// 后台无感额度守护：打开后定时同步官方额度，低额度时自动静默换号。
    var isAutoRotateEnabled: Bool
    /// 常规巡检间隔（分钟），1–120；额度接近阈值时会自动加速到约 20 秒。
    var autoRotateCheckIntervalMinutes: Int
    /// 剩余字数低于该阈值时触发自动换号（默认见 `SmartSwitchPolicy.defaultRemainingThreshold`）。
    var autoRotateRemainingThreshold: Int
    /// 监测到低额度且池内没有可静默切换账号时，是否自动走全自动注册换号。
    var autoCreateWhenPoolEmpty: Bool
    /// 热备池目标数量：始终尽量保有这么多可静默注入的备用号。
    var hotSpareTargetCount: Int
    /// 关主窗口时是否继续后台守护（菜单栏常驻）。
    var keepRunningInBackground: Bool
    /// 周额度刷新所用时区的标识符。**空串 = 跟随系统**。
    ///
    /// Typeless 的额度按「周一 00:00」刷新，这个 00:00 是相对某个时区的。
    /// 系统时区与本人所在时区不一致时（例如系统停在 +0700、人在深圳 +0800），
    /// 倒计时与自动复活会整体偏移。填 `Asia/Shanghai` 可锁定为北京时间。
    var quotaCycleTimeZoneIdentifier: String
    /// v2.8.0：额度直读（CDP）。开启后拉起 Typeless 时会带 `--remote-debugging-port`，
    /// 守护/同步直接问 Typeless 自己的渲染进程要 `usage_stats`（详见 `TypelessQuotaBridge`）。
    var isCDPQuotaEnabled: Bool
    /// v2.8.0：CDP 调试端口（1024–65535，默认 9333）。
    var cdpQuotaPort: Int

    static let defaults = AppSettings(
        typelessLoginURL: typelessDefaultLoginURL,
        // 中性占位，别填任何人的真实服务地址 —— 这个仓库是公开的。
        moeMailBaseURL: "https://mail.example.com",
        domains: defaultDomains,
        checklist: [
            SwitchTask(title: "确认当前账号本月额度已经用完", isRequired: true),
            SwitchTask(title: "在 Typeless 内正常退出当前账号", isRequired: true),
            SwitchTask(title: "选择下一个仍有额度的账号", isRequired: true),
            SwitchTask(title: "自动轮询对应邮箱验证码，必要时手动兜底", isRequired: true),
            SwitchTask(title: "登录完成后更新本工具里的已用字数", isRequired: false)
        ],
        // 默认不常驻 GUI：额度守护交给开机轻量 LaunchAgent；打开 App 时再按需开循环监控。
        isAutoRotateEnabled: false,
        autoRotateCheckIntervalMinutes: SmartSwitchPolicy.defaultCheckIntervalMinutes,
        autoRotateRemainingThreshold: SmartSwitchPolicy.defaultRemainingThreshold,
        autoCreateWhenPoolEmpty: true,
        hotSpareTargetCount: SmartSwitchPolicy.defaultHotSpareTarget,
        keepRunningInBackground: false,
        quotaCycleTimeZoneIdentifier: "",
        // v2.8.0：默认开启。CDP 直读是唯一还能拿到「真实剩余字数」的链路，
        // 关掉它等于回到「读屏 OCR + 盲轮换」。
        isCDPQuotaEnabled: true,
        cdpQuotaPort: TypelessQuotaBridge.defaultPort
    )

    enum CodingKeys: String, CodingKey {
        case typelessLoginURL
        case moeMailBaseURL
        case domains
        case checklist
        case isAutoRotateEnabled
        case autoRotateCheckIntervalMinutes
        case autoRotateRemainingThreshold
        case autoCreateWhenPoolEmpty
        case hotSpareTargetCount
        case keepRunningInBackground
        case quotaCycleTimeZoneIdentifier
        case isCDPQuotaEnabled
        case cdpQuotaPort
    }

    init(
        typelessLoginURL: String,
        moeMailBaseURL: String,
        domains: [String],
        checklist: [SwitchTask],
        isAutoRotateEnabled: Bool,
        autoRotateCheckIntervalMinutes: Int,
        autoRotateRemainingThreshold: Int,
        autoCreateWhenPoolEmpty: Bool,
        hotSpareTargetCount: Int,
        keepRunningInBackground: Bool,
        quotaCycleTimeZoneIdentifier: String,
        isCDPQuotaEnabled: Bool = true,
        cdpQuotaPort: Int = TypelessQuotaBridge.defaultPort
    ) {
        self.typelessLoginURL = typelessLoginURL
        self.moeMailBaseURL = moeMailBaseURL
        self.domains = domains
        self.checklist = checklist
        self.isAutoRotateEnabled = isAutoRotateEnabled
        self.autoRotateCheckIntervalMinutes = autoRotateCheckIntervalMinutes
        self.autoRotateRemainingThreshold = autoRotateRemainingThreshold
        self.autoCreateWhenPoolEmpty = autoCreateWhenPoolEmpty
        self.hotSpareTargetCount = hotSpareTargetCount
        self.keepRunningInBackground = keepRunningInBackground
        self.quotaCycleTimeZoneIdentifier = quotaCycleTimeZoneIdentifier
        self.isCDPQuotaEnabled = isCDPQuotaEnabled
        self.cdpQuotaPort = TypelessQuotaBridge.normalizePort(cdpQuotaPort)
    }

    /// 周额度周期时区。空串（跟随系统）时返回 nil，由调用方回落到 `TimeZone.current`。
    var quotaCycleTimeZone: TimeZone? {
        guard !quotaCycleTimeZoneIdentifier.isEmpty else { return nil }
        return TimeZone(identifier: quotaCycleTimeZoneIdentifier)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.defaults
        typelessLoginURL = try container.decodeIfPresent(String.self, forKey: .typelessLoginURL) ?? fallback.typelessLoginURL
        moeMailBaseURL = try container.decodeIfPresent(String.self, forKey: .moeMailBaseURL) ?? fallback.moeMailBaseURL
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? fallback.domains
        checklist = try container.decodeIfPresent([SwitchTask].self, forKey: .checklist) ?? fallback.checklist
        // 未写字段时：默认不常驻 GUI；额度守护推荐 LaunchAgent。
        isAutoRotateEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoRotateEnabled)
            ?? fallback.isAutoRotateEnabled
        autoRotateCheckIntervalMinutes = SmartSwitchPolicy.normalizeCheckIntervalMinutes(
            try container.decodeIfPresent(Int.self, forKey: .autoRotateCheckIntervalMinutes)
                ?? fallback.autoRotateCheckIntervalMinutes
        )
        autoRotateRemainingThreshold = SmartSwitchPolicy.normalizeThreshold(
            try container.decodeIfPresent(Int.self, forKey: .autoRotateRemainingThreshold)
                ?? fallback.autoRotateRemainingThreshold
        )
        autoCreateWhenPoolEmpty = try container.decodeIfPresent(Bool.self, forKey: .autoCreateWhenPoolEmpty)
            ?? fallback.autoCreateWhenPoolEmpty
        hotSpareTargetCount = SmartSwitchPolicy.normalizeHotSpareTarget(
            try container.decodeIfPresent(Int.self, forKey: .hotSpareTargetCount)
                ?? fallback.hotSpareTargetCount
        )
        keepRunningInBackground = try container.decodeIfPresent(Bool.self, forKey: .keepRunningInBackground)
            ?? fallback.keepRunningInBackground
        // 空串 = 跟随系统，与 v2.5.5 之前「一律用系统时区」的行为一致，老 store.json 无需迁移。
        quotaCycleTimeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .quotaCycleTimeZoneIdentifier)
            ?? fallback.quotaCycleTimeZoneIdentifier
        // v2.8.0：老 store.json 没有这两个键 → 用默认值（开启 / 9333），不挡解码。
        isCDPQuotaEnabled = try container.decodeIfPresent(Bool.self, forKey: .isCDPQuotaEnabled)
            ?? fallback.isCDPQuotaEnabled
        cdpQuotaPort = TypelessQuotaBridge.normalizePort(
            try container.decodeIfPresent(Int.self, forKey: .cdpQuotaPort) ?? fallback.cdpQuotaPort
        )
    }
}

struct SwitchTask: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isRequired: Bool
    var isDone: Bool

    init(id: UUID = UUID(), title: String, isRequired: Bool, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isRequired = isRequired
        self.isDone = isDone
    }
}

struct PersistedState: Codable, Equatable, Sendable {
    var accounts: [Account]
    var settings: AppSettings
    var tokenSummaries: [TokenSummary]?
    var loginSnapshots: [LoginSnapshotManifest]?
    var registrationPlans: [RegistrationPreparationPlan]?
    var deviceReport: DeviceInfoReport?
    var lastAutomationResult: RegistrationAutomationResult?
    /// 已经执行过的一次性迁移键。
    ///
    /// v2.6.0 新增。在此之前「是否迁移过」记在 `UserDefaults` 里，而 `UserDefaults`
    /// 有**两个致命问题**：
    ///   ① 它和 store.json 不是同一个存储，两者可以不一致；
    ///   ② 迁移只改内存、从不落盘，标记却被写死了 —— 于是迁移永远不生效（见
    ///      `SwitchboardStore.migrateDefaultsIfNeeded()` 的注释）。
    /// 现在把记录放进 store.json 本身：**数据和「数据已迁移」这个事实同生共死**，
    /// 落盘成功即迁移成功，不会再出现「标记说改过了、文件说没改」的分裂状态。
    ///
    /// 用可选类型是为了让旧版 store.json 仍然能解码（缺字段 → nil）。
    var appliedMigrations: [String]?

    /// 最近一次**成功拉到本周额度**的时间（与 `SwitchboardStore.lastQuotaSyncAt` 同源）。
    ///
    /// v2.6.6 新增，原因是一个「写进去就没了」的静默失效：
    /// `scripts/sync-account-quotas.js` 一直在写 `store.lastQuotaSyncAt`，但
    /// `SwitchboardStore.lastQuotaSyncAt` 当时只是个运行时 `@Published`，**不属于本结构**
    /// ⇒ 那份 JSON 被解码时该键被直接忽略，GUI 下一次落盘又把它抹掉。
    /// 结果：脚本记了同步时刻，界面照样显示「—」，重启后更是彻底丢失。
    ///
    /// 注意 `lastQuotaSyncFresh`（本次会话最近一次同步是否成功）**故意不持久化** ——
    /// 重启后还没验证过新鲜度，落盘一个 `true` 就是谎报。
    var lastQuotaSyncAt: Date?

    /// 最近一次**因额度 API 不可用而强制轮换**（降级模式：池内静默换到新鲜号）的时刻。
    ///
    /// v2.7.1 新增。背景：Typeless 在 2026-10-14 起对 `/user/usage_stats` 上线
    /// TLS 指纹（JA3）白名单（HTTP 418 / ja3_tls_code），Node 等外部客户端的握手
    /// 一律被拒；2026-11-17 实测又叠加了「客户端签名」这道门（code 20006）。
    ///
    /// **v2.8.0 更正**：当时认为「二进制启动器拒绝 --remote-debugging-port，所以没有
    /// 任何外部读额度的办法」是**误判** —— 那次测试的终端里带着
    /// `ELECTRON_RUN_AS_NODE=1`，Electron 因此退化成 node 解释器，把该参数当成
    /// 非法选项拒了。去掉这个环境变量后，Typeless 正常接受该参数，CDP 直读可用
    /// （见 `TypelessQuotaBridge`）。这条降级路径仍然保留：Typeless 没带端口启动时
    /// 它就是最后一道兜底。
    ///
    /// 老逻辑在「额度陈旧」时仍用**最后一次成功同步的冻结剩余值**做决策，这个值不会
    /// 递减 ⇒ 永远 ≥ 阈值 ⇒ 永不换号，用户额度用完只能手动点「智能换号」。
    ///
    /// 新逻辑：额度 API 持续不可用时，不再迷信冻结值，而是周期性轮换到池内一个
    /// 新鲜号（与手动「智能换号」等价），保证用户**永远不会卡在已耗尽的号上**。
    /// 用持久化时刻做退避，避免守护每分钟烧一轮（用户明确要求别过度占资源）。
    var lastForcedRotationAt: Date?

    /// 最近一次**自动注册尝试**（自治路径：额度巡检里的补热备 / 降级注册）的时刻。
    ///
    /// v2.6.9 新增，配 `autoRegistrationConsecutiveFailures` 做指数退避。
    /// 没有它之前，注册失败后守护会**每分钟重试一次全自动注册**：每轮都新建一个
    /// MoeMail 地址、跑一遍 Playwright —— 一天 1440 个废地址和 1440 次浏览器会话。
    /// 用户明确要求过「别过度占用资源」，这就是最直接的一处违规。
    ///
    /// 可选类型：旧 store.json 缺这个键 → nil，不挡解码。
    var lastAutoRegistrationAttemptAt: Date?

    /// 自动注册**连续失败**次数。成功一次即归零。
    ///
    /// 退避时长 = min(5 × 2^(n−1), 60) 分钟：5 → 10 → 20 → 40 → 60 封顶。
    /// 瞬时故障 5 分钟后就恢复重试；持续故障（MoeMail 挂 / Typeless 拒绝注册）
    /// 最多一小时一次，绝不会把资源烧成火焰山。
    var autoRegistrationConsecutiveFailures: Int?

    /// v2.8.0：最近一次「带端口重启 Typeless 以修复额度直读」的时间。
    ///
    /// 存在的理由：额度读不到时自动修复会**重启 Typeless**（打断听写），
    /// 必须限频（10 分钟一次），否则会变成新的抖动源。
    var lastCDPBridgeRepairAt: Date?

    /// v2.8.0：换号历史（新的在前，最多 `SwitchHistory.maximumEntries` 条）。
    /// 只记结果与耗时，不含任何令牌 / 密码 / 会话 payload。
    /// 可选类型：旧 store.json 缺这个键 → nil，不挡解码。
    var switchHistory: [SwitchHistoryEntry]?

    static let empty = PersistedState(
        accounts: [],
        settings: .defaults,
        tokenSummaries: [],
        loginSnapshots: [],
        registrationPlans: [],
        deviceReport: nil,
        lastAutomationResult: nil,
        appliedMigrations: [],
        lastQuotaSyncAt: nil,
        lastForcedRotationAt: nil,
        lastAutoRegistrationAttemptAt: nil,
        autoRegistrationConsecutiveFailures: nil,
        lastCDPBridgeRepairAt: nil,
        switchHistory: []
    )
}

/// App / CLI 运行模式：GUI 可常驻监控；daemon 只做单次巡检后退出。
enum SwitchboardRunMode: Equatable {
    case gui
    /// LaunchAgent / 定时任务：读额度，低于阈值则换号，然后退出（不常驻）。
    case daemonOnce
    /// CLI 批量全自动换号测试。
    case cliAutoSwitch
}

