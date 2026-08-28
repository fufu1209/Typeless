import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

enum QuotaGuardLaunchAgent {
    static let label = QuotaGuardLaunchAgentPlanner.label
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func statusSummary(intervalMinutes: Int) -> String {
        if isInstalled {
            let minutes = SmartSwitchPolicy.normalizeCheckIntervalMinutes(intervalMinutes)
            let live = currentStartIntervalSeconds()
            if let live, live < minutes * 60 {
                return "开机轻量插件：已安装 · 近阈值加速约每 \(live) 秒巡检（常规 \(minutes) 分钟）"
            }
            return "开机轻量插件：已安装 · 约每 \(minutes) 分钟巡检本周额度（不常驻窗口）"
        }
        return "开机轻量插件：未安装（推荐安装，不必一直开着本 App）"
    }

    /// 读取当前 plist 里的 StartInterval（秒）。
    static func currentStartIntervalSeconds() -> Int? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return QuotaGuardLaunchAgentPlanner.startIntervalSeconds(inPlistData: data)
    }

    /// daemon 根据本周剩余额度动态调整巡检间隔：接近阈值 → 约 20 秒；否则恢复用户设定分钟数。
    static func reconcileIntervalSecondsIfNeeded(_ desiredSeconds: Int) {
        let clamped = QuotaGuardLaunchAgentPlanner.reconciledIntervalSeconds(desiredSeconds)
        guard isInstalled else { return }
        if currentStartIntervalSeconds() == clamped { return }
        guard let data = try? Data(contentsOf: plistURL),
              let text = String(data: data, encoding: .utf8),
              let updated = QuotaGuardLaunchAgentPlanner.replacingStartInterval(inPlistText: text, seconds: clamped) else {
            return
        }
        // 替换 <key>StartInterval</key> 后的 integer。
        try? updated.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// 优先用已打包的 .app 可执行文件；否则用当前进程路径（swift run / 开发构建）。
    static func resolveProgramPath() throws -> String {
        if let bundled = Bundle.main.executablePath,
           bundled.contains(".app/"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let candidates = [
            FileManager.default.currentDirectoryPath + "/TypelessSwitchboard.app/Contents/MacOS/TypelessSwitchboard"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // 开发态：当前可执行文件本身
        let argv0 = CommandLine.arguments[0]
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            return argv0
        }
        if let path = Bundle.main.executablePath, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw NSError(
            domain: "QuotaGuardLaunchAgent",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "找不到 TypelessSwitchboard 可执行文件，请先 ./scripts/build-app.sh"]
        )
    }

    static func install(programPath: String, intervalMinutes: Int) throws {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TypelessSwitchboard/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let plist = QuotaGuardLaunchAgentPlanner.plistDocument(
            programPath: programPath,
            intervalMinutes: intervalMinutes,
            logDirectory: logDir.path
        )

        let agentsDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        // 先 bootout 再 bootstrap，兼容已安装场景。
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        let load = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        if load.status != 0 {
            // 旧系统 fallback
            let legacy = runLaunchctl(["load", "-w", plistURL.path])
            if legacy.status != 0 {
                throw NSError(
                    domain: "QuotaGuardLaunchAgent",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "launchctl 加载失败：\(load.output.ifEmpty(legacy.output))"]
                )
            }
        }
        // 立刻 kick 一次，方便确认可用。
        _ = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    static func uninstall() throws {
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        _ = runLaunchctl(["unload", "-w", plistURL.path])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

/// 关窗继续跑 + 菜单栏状态，支撑「后台无感守护」。
