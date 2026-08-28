import Foundation

// MARK: - QuotaGuardLaunchAgentPlanner
//
// 开机轻量额度守护（LaunchAgent）的**纯逻辑**：plist 文本生成、间隔分钟→秒换算、
// StartInterval 读写。原来这些逻辑内联在 `Sources/TypelessSwitchboard/main.swift`
// 的 `QuotaGuardLaunchAgent` 里，测试 target 只能 import Core，测不到。
//
// 现在 main.swift 调用本文件，行为完全一致，且可以在测试里对真实 plist 文本做断言
// （而不只是断言「源码里出现过 RunAtLoad 这个字符串」）。

public enum QuotaGuardLaunchAgentPlanner {
    public static let label = "local.typeless.switchboard.quota-guard"
    /// LaunchAgent 启动时传给本 App 的参数：单次巡检后退出。
    public static let daemonFlag = "--daemon-check"

    /// launchd 最小轮询间隔（秒）：低于此值 launchd 会拒绝加载。
    public static let minimumIntervalSeconds = 20
    /// 最大轮询间隔（秒）：与 `SmartSwitchPolicy.normalizeCheckIntervalMinutes` 上限 120 分钟对齐。
    public static let maximumIntervalSeconds = 120 * 60

    public static let processType = "Background"
    public static let niceValue = 10

    // MARK: - 间隔换算

    /// 用户配置的「巡检间隔分钟」→ plist 里的 `StartInterval`（秒）。
    /// 先按 `SmartSwitchPolicy` 归一化到 1...120 分钟，再乘 60。
    public static func intervalSeconds(intervalMinutes: Int) -> Int {
        SmartSwitchPolicy.normalizeCheckIntervalMinutes(intervalMinutes) * 60
    }

    /// daemon 动态调整间隔时的钳制：低于 20 秒拉到 20 秒，高于 120 分钟压到 120 分钟。
    public static func reconciledIntervalSeconds(_ desiredSeconds: Int) -> Int {
        max(minimumIntervalSeconds, min(desiredSeconds, maximumIntervalSeconds))
    }

    // MARK: - 日志路径

    public struct LogPaths: Equatable, Sendable {
        public let stdout: String
        public let stderr: String

        public init(stdout: String, stderr: String) {
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public static func logPaths(logDirectory: String) -> LogPaths {
        let directory = (logDirectory as NSString).standardizingPath
        return LogPaths(
            stdout: (directory as NSString).appendingPathComponent("quota-guard-launchd.out.log"),
            stderr: (directory as NSString).appendingPathComponent("quota-guard-launchd.err.log")
        )
    }

    // MARK: - plist 生成

    /// 生成完整的 launchd plist 文本。传出的是**最终文本**，可直接 `PropertyListSerialization` 解析。
    public static func plistDocument(
        programPath: String,
        intervalMinutes: Int,
        logDirectory: String
    ) -> String {
        let seconds = intervalSeconds(intervalMinutes: intervalMinutes)
        let logs = logPaths(logDirectory: logDirectory)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(programPath)</string>
            <string>\(daemonFlag)</string>
          </array>
          <key>RunAtLoad</key>
          <true/>
          <key>StartInterval</key>
          <integer>\(seconds)</integer>
          <key>StandardOutPath</key>
          <string>\(logs.stdout)</string>
          <key>StandardErrorPath</key>
          <string>\(logs.stderr)</string>
          <key>ProcessType</key>
          <string>\(processType)</string>
          <key>Nice</key>
          <integer>\(niceValue)</integer>
        </dict>
        </plist>
        """
    }

    // MARK: - StartInterval 读写

    /// 从已落盘的 plist Data 里读出 `StartInterval`（秒）。
    public static func startIntervalSeconds(inPlistData data: Data) -> Int? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let seconds = object["StartInterval"] as? Int else {
            return nil
        }
        return seconds
    }

    /// 从 plist 文本里读出 `StartInterval`（秒）。
    public static func startIntervalSeconds(inPlistText text: String) -> Int? {
        guard let range = text.range(of: #"<key>StartInterval</key>\s*<integer>\d+</integer>"#, options: .regularExpression),
              let integerRange = text.range(of: #"\d+"#, options: .regularExpression, range: range) else {
            return nil
        }
        return Int(text[integerRange])
    }

    /// 就地改写 plist 文本里的 `StartInterval`；找不到对应节点时返回 nil（调用方应放弃改写）。
    public static func replacingStartInterval(inPlistText text: String, seconds: Int) -> String? {
        guard let range = text.range(of: #"<key>StartInterval</key>\s*<integer>\d+</integer>"#, options: .regularExpression) else {
            return nil
        }
        var updated = text
        updated.replaceSubrange(range, with: "<key>StartInterval</key>\n  <integer>\(seconds)</integer>")
        return updated
    }
}
