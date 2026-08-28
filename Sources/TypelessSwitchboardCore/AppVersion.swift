import Foundation

// MARK: - AppVersion
//
// 版本号的**单一事实来源**。
//
// 以前版本散在两处且会漂移：
//   - `scripts/build-app.sh` 里的 `VERSION_SHORT` / `VERSION_BUILD`（写进 Info.plist）
//   - `appVersionString()` 里读不到 Info.plist 时的硬编码回落值
//
// 漂移的后果很具体：从 `.build/release/` 直接跑裸二进制时（CLI 导出配置包、
// daemon 巡检都会这么跑），`Bundle.main` 没有 Info.plist，回落到硬编码。
// 那个值停在 2.0.0，于是导出的配置包写着 `appVersion: 2.0.0`，
// 而实际跑的是 2.5.6 —— 排查导入兼容性时会被这个假版本号带偏。
//
// 现在：Core 里定义唯一常量，build-app.sh 从本文件解析，代码回落到本文件。

public enum AppVersion {
    /// 对外版本号（CFBundleShortVersionString）。
    public static let short = "2.5.6"
    /// 构建号（CFBundleVersion），每次打包递增。
    public static let build = "9"

    /// 完整版本串，例如 "2.5.6 (9)"。日志与配置包用这个。
    public static var full: String {
        "\(short) (\(build))"
    }
}
