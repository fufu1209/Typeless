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

    /// launchd 里**真的**有这个 job 吗。
    ///
    /// 必须与 `isInstalled`（plist 文件在不在）分开看：只有文件、没有 job，
    /// 正是 v2.6.1 那次「界面说已安装、实际 24 小时没巡检」的静默失效形态。
    static var isLoaded: Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
    }

    static func statusSummary(configuredMinutes: Int) -> String {
        QuotaGuardLaunchAgentPlanner.statusText(
            isInstalled: isInstalled,
            isLoaded: isLoaded,
            configuredMinutes: configuredMinutes,
            liveIntervalSeconds: currentStartIntervalSeconds()
        )
    }

    /// 读取当前 plist 里的 StartInterval（秒）。
    static func currentStartIntervalSeconds() -> Int? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return QuotaGuardLaunchAgentPlanner.startIntervalSeconds(inPlistData: data)
    }

    /// 把 plist 的巡检间隔校正到用户配置值（GUI 调用）。
    @discardableResult
    static func normalizeIntervalToConfigured(minutes: Int) -> Bool {
        reconcileIntervalSecondsIfNeeded(
            QuotaGuardLaunchAgentPlanner.intervalSeconds(intervalMinutes: minutes)
        )
    }

    /// 改写 plist 的 StartInterval 并让 launchd 重新加载。
    ///
    /// ⚠️ **从被管理的 job 内调用会被直接拒绝**：bootout 会把本 job（含本进程）一起停掉，
    /// 紧随其后的 bootstrap 永远执行不到，结果是 plist 还在、launchd 里空无一物 ——
    /// 2026-09-29 那次「守护静默失效 24 小时」就是这么来的。
    @discardableResult
    static func reconcileIntervalSecondsIfNeeded(_ desiredSeconds: Int) -> Bool {
        let clamped = QuotaGuardLaunchAgentPlanner.reconciledIntervalSeconds(desiredSeconds)
        guard isInstalled else { return false }
        // 在 job 内：绝不自己 bootout，交给 GUI 校正。
        guard !QuotaGuardLaunchAgentPlanner.runsInsideManagedJob() else { return false }
        guard QuotaGuardLaunchAgentPlanner.needsReload(
            liveIntervalSeconds: currentStartIntervalSeconds(),
            desiredSeconds: clamped
        ) else { return true }
        guard let data = try? Data(contentsOf: plistURL),
              let text = String(data: data, encoding: .utf8),
              let updated = QuotaGuardLaunchAgentPlanner.replacingStartInterval(inPlistText: text, seconds: clamped) else {
            return false
        }
        try? updated.write(to: plistURL, atomically: true, encoding: .utf8)
        return reloadVerified()
    }

    /// 校验式重载：bootout → 等到 launchd 真的查不到 → bootstrap → **校验**，失败重试。
    /// 只允许在「不在该 job 内」的进程（GUI）里调用。
    @discardableResult
    static func reloadVerified(attempts: Int = 5) -> Bool {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"
        let rounds = max(attempts, 1)
        for attempt in 1...rounds {
            _ = runLaunchctl(["bootout", target])
            var waited = 0
            while runLaunchctl(["print", target]).status == 0, waited < 20 {
                usleep(500_000)
                waited += 1
            }
            _ = runLaunchctl(["bootstrap", domain, plistURL.path])
            if isLoaded { return true }
            if attempt < rounds { sleep(1) }
        }
        return false
    }

    /// 自愈：plist 在、launchd 里却没有 → 直接 bootstrap 回来（无需先 bootout）。
    @discardableResult
    static func ensureLoaded() -> Bool {
        guard isInstalled else { return false }
        if isLoaded { return true }
        _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        return isLoaded
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

        // 先 bootout 再 bootstrap，兼容已安装场景；装完必须**校验**（见 reloadVerified）。
        if !reloadVerified() {
            // 旧系统 fallback：老 launchctl 不认 bootstrap。
            let legacy = runLaunchctl(["load", "-w", plistURL.path])
            if legacy.status != 0 || !isLoaded {
                throw NSError(
                    domain: "QuotaGuardLaunchAgent",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "launchctl 加载失败：\(legacy.output.ifEmpty("校验未通过：launchd 里仍查不到该任务"))"]
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
