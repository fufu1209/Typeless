import Foundation

public enum TypelessHostPlatform: String, Codable, CaseIterable, Sendable {
    case macOS = "macos"
    case windows = "windows"
    case linux = "linux"
    case unknown = "unknown"

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .windows: "Windows"
        case .linux: "Linux"
        case .unknown: "Unknown"
        }
    }
}

public enum TypelessCompatibilitySupportLevel: String, Codable, Sendable {
    case productionVerified
    case toolkitCompatible
    case planned
    case unsupported

    public var title: String {
        switch self {
        case .productionVerified: "本机已验证"
        case .toolkitCompatible: "toolkit 兼容"
        case .planned: "计划适配"
        case .unsupported: "暂不支持"
        }
    }
}

public struct TypelessToolkitPlatformProfile: Codable, Equatable, Sendable {
    public var platform: TypelessHostPlatform
    public var supportLevel: TypelessCompatibilitySupportLevel
    public var typelessProcessName: String
    public var executableCandidates: [String]
    public var userDataDirectoryCandidates: [String]
    public var deviceCacheDirectoryCandidates: [String]
    public var credentialTargets: [String]
    public var snapshotFiles: [String]
    public var electronResidualDirectories: [String]
    public var resetDeviceSteps: [String]
    public var requiredConfigKeys: [String]
    public var notes: [String]

    public init(
        platform: TypelessHostPlatform,
        supportLevel: TypelessCompatibilitySupportLevel,
        typelessProcessName: String,
        executableCandidates: [String],
        userDataDirectoryCandidates: [String],
        deviceCacheDirectoryCandidates: [String],
        credentialTargets: [String],
        snapshotFiles: [String],
        electronResidualDirectories: [String],
        resetDeviceSteps: [String],
        requiredConfigKeys: [String],
        notes: [String]
    ) {
        self.platform = platform
        self.supportLevel = supportLevel
        self.typelessProcessName = typelessProcessName
        self.executableCandidates = executableCandidates
        self.userDataDirectoryCandidates = userDataDirectoryCandidates
        self.deviceCacheDirectoryCandidates = deviceCacheDirectoryCandidates
        self.credentialTargets = credentialTargets
        self.snapshotFiles = snapshotFiles
        self.electronResidualDirectories = electronResidualDirectories
        self.resetDeviceSteps = resetDeviceSteps
        self.requiredConfigKeys = requiredConfigKeys
        self.notes = notes
    }

    public var canRunOneClickWorkflow: Bool {
        switch supportLevel {
        case .productionVerified, .toolkitCompatible:
            true
        case .planned, .unsupported:
            false
        }
    }

    public var markdown: String {
        var lines: [String] = [
            "## \(platform.title)",
            "- 支持级别：\(supportLevel.title)",
            "- Typeless 进程：\(typelessProcessName.ifEmpty("未适配"))",
            "- 可执行文件候选：\(executableCandidates.joined(separator: " | ").ifEmpty("未适配"))",
            "- 登录态目录候选：\(userDataDirectoryCandidates.joined(separator: " | ").ifEmpty("未适配"))",
            "- 设备缓存目录候选：\(deviceCacheDirectoryCandidates.joined(separator: " | ").ifEmpty("未适配"))",
            "- 设备凭据目标：\(credentialTargets.joined(separator: " | ").ifEmpty("未适配"))",
            "- 快照文件：\(snapshotFiles.joined(separator: ", ").ifEmpty("未适配"))",
            "- Electron 残留目录：\(electronResidualDirectories.joined(separator: ", ").ifEmpty("未适配"))",
            "- 配置键：\(requiredConfigKeys.joined(separator: ", ").ifEmpty("无"))"
        ]
        if !resetDeviceSteps.isEmpty {
            lines.append("- resetDevice 步骤：")
            lines += resetDeviceSteps.map { "  - \($0)" }
        }
        if !notes.isEmpty {
            lines.append("- 备注：")
            lines += notes.map { "  - \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

public enum TypelessToolkitCompatibilityMatrix {
    public static let snapshotFiles = [
        "app-storage.json",
        "user-data.json",
        "app-onboarding.json"
    ]

    public static let electronResidualDirectories = [
        "Local Storage",
        "Network",
        "Cookies",
        "Session Storage"
    ]

    public static let resetDeviceSteps = [
        "退出 Typeless 桌面进程",
        "删除设备凭据：Windows Credential Manager / macOS Keychain",
        "删除 device.cache",
        "删除 user-data.json",
        "清理 app-storage.json 中的 userData / quotaUsage / session / currentRoute",
        "清理 Electron 登录残留目录：Local Storage / Network / Cookies / Session Storage",
        "重新启动 Typeless 并等待新设备身份生成",
        "静默换号（池内注入）同样执行设备身份轮换，避免同一 deviceId 挂过多账号触发服务端设备用户数上限",
        "若检测到「The number of users logged into this device has exceeded the limit」类错误，跳过静默切换并降级为全自动 resetDevice + 注册"
    ]

    public static let macOS = TypelessToolkitPlatformProfile(
        platform: .macOS,
        supportLevel: .productionVerified,
        typelessProcessName: "Typeless",
        executableCandidates: [
            "/Applications/Typeless.app/Contents/MacOS/Typeless",
            "~/Applications/Typeless.app/Contents/MacOS/Typeless"
        ],
        userDataDirectoryCandidates: [
            "~/Library/Application Support/Typeless.exe",
            "~/Library/Application Support/Typeless"
        ],
        deviceCacheDirectoryCandidates: [
            "~/Library/Application Support/now.typeless.desktop",
            "~/Library/Application Support/Typeless/Cache",
            "~/Library/Application Support/Typeless.exe/Cache",
            "~/Library/Application Support/Typeless",
            "~/Library/Application Support/Typeless.exe"
        ],
        credentialTargets: [
            "now.typeless.desktop.deviceIdentifier / now.typeless.desktop.security.auth_key",
            "Typeless.deviceIdentifier"
        ],
        snapshotFiles: snapshotFiles,
        electronResidualDirectories: electronResidualDirectories,
        resetDeviceSteps: resetDeviceSteps,
        requiredConfigKeys: [
            "moeMailBaseURL",
            "moeMailAPIKey",
            "typelessLoginURL",
            "domains"
        ],
        notes: [
            "当前仓库的 macOS SwiftUI App 已在本机真实完成一键换号闭环验证。",
            "macOS 路径在 typeless-toolkit 默认值基础上增加了真实 Typeless Keychain service/account 与 now.typeless.desktop/device.cache 兼容。",
            "本机主流程继续使用 SwiftUI/AppKit/Security/Apple Events；不要用 Windows 逻辑覆盖。"
        ]
    )

    public static let windows = TypelessToolkitPlatformProfile(
        platform: .windows,
        supportLevel: .toolkitCompatible,
        typelessProcessName: "Typeless.exe",
        executableCandidates: [
            "%LOCALAPPDATA%\\Programs\\Typeless\\Typeless.exe"
        ],
        userDataDirectoryCandidates: [
            "%APPDATA%\\Typeless.exe"
        ],
        deviceCacheDirectoryCandidates: [
            "%APPDATA%\\Typeless\\Cache"
        ],
        credentialTargets: [
            "Typeless.deviceIdentifier"
        ],
        snapshotFiles: snapshotFiles,
        electronResidualDirectories: electronResidualDirectories,
        resetDeviceSteps: resetDeviceSteps,
        requiredConfigKeys: [
            "moeMailBaseURL",
            "moeMailAPIKey",
            "typelessLoginURL",
            "domains",
            "typeless_exe 可选覆盖",
            "userdata_dir 可选覆盖",
            "device_cache_dir 可选覆盖",
            "credential_target 可选覆盖"
        ],
        notes: [
            "与 typeless-toolkit 的 Windows platform.js 默认路径保持一致。",
            "Windows 原生 GUI/托盘版本应复用 Core/Playwright/MoeMail/平台矩阵，不应修改 macOS 已验证主流程。",
            "Windows 凭据删除对应 cmdkey /delete:Typeless.deviceIdentifier；Chrome/Typeless handoff 需使用 Windows shell start 或协议处理器。"
        ]
    )

    public static let linux = TypelessToolkitPlatformProfile(
        platform: .linux,
        supportLevel: .planned,
        typelessProcessName: "Typeless",
        executableCandidates: [],
        userDataDirectoryCandidates: [],
        deviceCacheDirectoryCandidates: [],
        credentialTargets: [],
        snapshotFiles: snapshotFiles,
        electronResidualDirectories: electronResidualDirectories,
        resetDeviceSteps: [],
        requiredConfigKeys: [
            "typeless_exe",
            "userdata_dir",
            "device_cache_dir",
            "credential_target / credential delete command"
        ],
        notes: [
            "typeless-toolkit README 标注 Linux 未适配；这里保留显式 planned 状态，避免误判为可一键运行。",
            "只有用户提供 Typeless 安装路径、数据目录、设备缓存目录和凭据删除命令后，才能升级为 toolkitCompatible。"
        ]
    )

    public static let all: [TypelessToolkitPlatformProfile] = [macOS, windows, linux]

    public static func profile(for platform: TypelessHostPlatform) -> TypelessToolkitPlatformProfile? {
        all.first { $0.platform == platform }
    }

    public static var markdown: String {
        ([
            "# Typeless Switchboard 跨平台兼容矩阵",
            "",
            "目标：保护当前 macOS 已验证一键换号链路，同时把 typeless-toolkit 的 Windows/macOS 平台差异沉淀为可测试配置矩阵。",
            ""
        ] + all.map(\.markdown)).joined(separator: "\n\n")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
