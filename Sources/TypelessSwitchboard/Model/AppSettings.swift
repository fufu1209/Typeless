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
    /// 剩余字数低于该阈值时触发自动换号（默认 200）。
    var autoRotateRemainingThreshold: Int
    /// 监测到低额度且池内没有可静默切换账号时，是否自动走全自动注册换号。
    var autoCreateWhenPoolEmpty: Bool
    /// 热备池目标数量：始终尽量保有这么多可静默注入的备用号。
    var hotSpareTargetCount: Int
    /// 关主窗口时是否继续后台守护（菜单栏常驻）。
    var keepRunningInBackground: Bool

    static let defaults = AppSettings(
        typelessLoginURL: typelessDefaultLoginURL,
        moeMailBaseURL: "https://mail.8888891.xyz",
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
        keepRunningInBackground: false
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
        keepRunningInBackground: Bool
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

    static let empty = PersistedState(
        accounts: [],
        settings: .defaults,
        tokenSummaries: [],
        loginSnapshots: [],
        registrationPlans: [],
        deviceReport: nil,
        lastAutomationResult: nil
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

