import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func automationCommandVersion(command: String, versionArgument: String) async -> String {
        await Task.detached(priority: .utility) {
            let result = SwitchboardStore.runProcess(arguments: [command, versionArgument], environment: SwitchboardStore.automationEnvironment())
            guard result.status == 0 else { return "" }
            return result.output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.value
    }


    func prepareAutomationRuntime() async -> (success: Bool, message: String) {
        let folder = automationDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.ensureAutomationPackageManifest(in: folder)
        } catch {
            return (false, "自动化目录准备失败：\(error.localizedDescription)")
        }

        return await Task.detached(priority: .utility) {
            let node = SwitchboardStore.runProcess(
                arguments: ["node", "--version"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard node.status == 0 else {
                return (false, "未检测到 node：\(node.output.ifEmpty("退出码 \(node.status)"))")
            }

            let npm = SwitchboardStore.runProcess(
                arguments: ["npm", "--version"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 15
            )
            guard npm.status == 0 else {
                return (false, "未检测到 npm：\(npm.output.ifEmpty("退出码 \(npm.status)"))")
            }

            let nodeVersion = node.output.components(separatedBy: .newlines).first ?? "node"
            let npmVersion = npm.output.components(separatedBy: .newlines).first ?? "npm"
            if SwitchboardStore.isAutomationRuntimeCached(in: folder) {
                return (true, "自动化运行环境已缓存，跳过 npm install / playwright install：\(nodeVersion)，npm \(npmVersion)")
            }

            let installPackage = SwitchboardStore.runProcess(
                arguments: ["npm", "install", "--silent", "--no-audit", "--no-fund", "playwright"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 90
            )
            guard installPackage.status == 0 else {
                return (false, "Playwright 包准备失败：\(installPackage.output.ifEmpty("退出码 \(installPackage.status)"))")
            }

            let installBrowser = SwitchboardStore.runProcess(
                arguments: ["npm", "exec", "--", "playwright", "install", "chromium"],
                environment: SwitchboardStore.automationEnvironment(),
                currentDirectory: folder,
                timeoutSeconds: 120
            )
            guard installBrowser.status == 0 else {
                return (false, "Playwright Chromium 准备失败：\(installBrowser.output.ifEmpty("退出码 \(installBrowser.status)"))")
            }

            SwitchboardStore.markAutomationRuntimeReady(in: folder)
            return (true, "自动化运行环境已准备：\(nodeVersion)，npm \(npmVersion)")
        }.value
    }


    func automationDirectoryURL() -> URL {
        dataFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("Automation", isDirectory: true)
    }


    func runPlaywrightScript(_ scriptURL: URL, password: String) async -> (success: Bool, message: String) {
        await Task.detached(priority: .utility) {
            switch SwitchboardStore.checkNodeScriptSyntax(scriptURL) {
            case .failed(let reason):
                return (false, "Playwright 脚本语法检查失败：\(reason)")
            case .unverified(let note):
                // 不拦：语法检查只是预检，紧接着的真实执行才是判据。
                print("TypelessSwitchboard: Playwright 脚本语法检查未完成，继续执行 —— \(note)")
            case .ok:
                break
            }

            let scriptFolder = scriptURL.deletingLastPathComponent()
            try? SwitchboardStore.ensureAutomationPackageManifest(in: scriptFolder)

            if !SwitchboardStore.isAutomationRuntimeCached(in: scriptFolder) {
                let installPackage = SwitchboardStore.runProcess(
                    arguments: ["npm", "install", "--silent", "--no-audit", "--no-fund", "playwright"],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: scriptFolder,
                    timeoutSeconds: 90
                )
                guard installPackage.status == 0 else {
                    return (false, "Playwright 包安装失败或超时，已保留脚本可重试：\(installPackage.output.ifEmpty("退出码 \(installPackage.status)"))")
                }

                let installBrowser = SwitchboardStore.runProcess(
                    arguments: ["npm", "exec", "--", "playwright", "install", "chromium"],
                    environment: SwitchboardStore.automationEnvironment(),
                    currentDirectory: scriptFolder,
                    timeoutSeconds: 120
                )
                guard installBrowser.status == 0 else {
                    return (false, "Playwright Chromium 准备失败或超时，已保留脚本可重试：\(installBrowser.output.ifEmpty("退出码 \(installBrowser.status)"))")
                }
                SwitchboardStore.markAutomationRuntimeReady(in: scriptFolder)
            }

            var environment = SwitchboardStore.automationEnvironment()
            environment[typelessAutomationPasswordEnvironmentKey] = password
            let run = SwitchboardStore.runProcess(
                arguments: ["node", scriptURL.path],
                environment: environment,
                currentDirectory: scriptFolder,
                timeoutSeconds: 180
            )
            if run.status == 0 {
                return (true, "Playwright 自动化已执行：\(run.output.ifEmpty("无输出"))")
            }
            return (false, "Playwright 自动化未完成，已保留脚本可重试：\(run.output.ifEmpty("退出码 \(run.status)"))")
        }.value
    }


    nonisolated static func automationEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let additions = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = environment["PATH"] ?? ""
        let merged = (additions + currentPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            .joined(separator: ":")
        environment["PATH"] = merged
        return environment
    }


    nonisolated static func ensureAutomationPackageManifest(in folder: URL) throws {
        let packageFile = folder.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: packageFile.path) {
            try "{\"private\":true}".write(to: packageFile, atomically: true, encoding: .utf8)
        }
    }


    nonisolated static func automationRuntimeReadyMarkerURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".typeless-playwright-runtime-ready.json")
    }


    nonisolated static func isAutomationRuntimeCached(in folder: URL) -> Bool {
        let packageFile = folder
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("playwright", isDirectory: true)
            .appendingPathComponent("package.json")
        let markerFile = automationRuntimeReadyMarkerURL(in: folder)
        return FileManager.default.fileExists(atPath: packageFile.path) &&
            FileManager.default.fileExists(atPath: markerFile.path) &&
            isPlaywrightChromiumExecutableAvailable(in: folder)
    }


    nonisolated static func isPlaywrightChromiumExecutableAvailable(in folder: URL) -> Bool {
        let probeScript = """
        const fs = require('fs');
        const { chromium } = require('playwright');
        const executablePath = chromium.executablePath();
        if (!executablePath || !fs.existsSync(executablePath)) {
          console.error('missing chromium executable: ' + executablePath);
          process.exit(2);
        }
        console.log(executablePath);
        """
        let result = runProcess(
            arguments: ["node", "-e", probeScript],
            environment: automationEnvironment(),
            currentDirectory: folder,
            timeoutSeconds: 15
        )
        return result.status == 0
    }


    nonisolated static func markAutomationRuntimeReady(in folder: URL) {
        let marker = automationRuntimeReadyMarkerURL(in: folder)
        let payload = [
            "readyAt": ISO8601DateFormatter().string(from: Date()),
            "package": "playwright",
            "browser": "chromium"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: marker, options: .atomic)
        }
    }


    nonisolated static func runAppleEventsProbe(_ appleScript: String) -> (success: Bool, message: String) {
        let result = runProcess(
            arguments: ["osascript", "-e", appleScript],
            environment: automationEnvironment(),
            timeoutSeconds: 8
        )
        if result.status == 0 {
            return (true, result.output.ifEmpty("OK"))
        }
        if result.output.contains("-1743") || result.output.localizedCaseInsensitiveContains("not authorized") {
            return (false, "未授权")
        }
        return (false, result.output.ifEmpty("退出码 \(result.status)"))
    }


    nonisolated static func runProcess(
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 60
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // 边跑边读：子进程输出超过管道缓冲（约 64KB）时会写阻塞，若等进程退出后才读会永远等不到退出。
        // 最多保留 512KB，超时终止时也能拿到已产生的部分输出。
        let outputBuffer = OutputBuffer(maxBytes: 512 * 1024)
        let exited = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)

        // v2.6.0 修复：全程改用**内核回调**，不再往 DispatchQueue.global 上丢阻塞线程。
        //
        // 旧实现每调一次 runProcess 就永久占用一个线程池线程去 `waitUntilExit()`，
        // 再拿第二个线程去阻塞读管道。而自动化流程里子进程调用非常密集
        // （node → npm → osascript → playwright 层层嵌套），叠上 Typeless 冷启动的 CPU 压力，
        // 线程池会被这些「只为等待而存在」的线程占满，后提交的 block 排不上队 ——
        // 于是明明 0.03 秒就跑完的 `node --check` 也会被判成「命令超时」。
        //
        // 实测后果很具体：全自动注册第 2 个账号因此中断（needsAttention），
        // 而生成的脚本本身完全正常。terminationHandler / readabilityHandler
        // 由内核直接回调，不占用线程池线程，从根上消除这类假超时。
        process.terminationHandler = { _ in exited.signal() }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            outputBuffer.append(chunk)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return (-1, error.localizedDescription)
        }

        let timedOut = exited.wait(timeout: .now() + timeoutSeconds) == .timedOut
        if timedOut {
            process.terminate()
            // 给子进程死亡一点收尾时间。
            _ = exited.wait(timeout: .now() + 2)
        }
        // 等管道读到 EOF，把尾部输出取干净（最多再等 1 秒，拿不到就算了，不能让收尾拖慢主流程）。
        _ = drained.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.readabilityHandler = nil

        let output = outputBuffer.string()
        if timedOut {
            return (-2, "命令超时：\(arguments.joined(separator: " "))\(output.isEmpty ? "" : "\n\(output)")")
        }
        return (process.terminationStatus, output)
    }

    /// `node --check` 的语义化结果。
    ///
    /// 必须区分两件事，因为处置完全相反：
    ///   * **真有语法错误** —— 脚本必然跑不起来，必须中止；
    ///   * **没能完成检查**（超时/无法执行）—— 只是「没验证过」，不该拦。
    ///
    /// v2.6.0 实测教训：`node --check` 明明 0.03 秒就能跑完，却因为 runProcess
    /// 的线程池耗尽报「命令超时」，把一次完全正常的全自动注册判成失败。
    /// 语法检查只是**廉价的预检**，真正的判据是紧接着的真实执行 —— 所以超时不拦，只留痕。
    enum NodeSyntaxCheck {
        case ok
        /// 确实有语法错误，附原因。
        case failed(String)
        /// 没检查成，附说明。
        case unverified(String)
    }

    nonisolated static func checkNodeScriptSyntax(
        _ scriptURL: URL,
        currentDirectory: URL? = nil,
        timeoutSeconds: TimeInterval = 30
    ) -> NodeSyntaxCheck {
        let result = runProcess(
            arguments: ["node", "--check", scriptURL.path],
            environment: automationEnvironment(),
            currentDirectory: currentDirectory,
            timeoutSeconds: timeoutSeconds
        )
        switch PreflightVerdict.from(exitStatus: result.status) {
        case .ok:
            return .ok
        case .unverified:
            return .unverified("node --check 未在 \(Int(timeoutSeconds)) 秒内完成；脚本未必有问题，交由后续真实执行判定")
        case .failed:
            return .failed(result.output.ifEmpty("退出码 \(result.status)"))
        }
    }


    /// 线程安全的进程输出缓冲：后台读取线程持续写入，主调用方在结束时快照。
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private var data = Data()

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if data.count < maxBytes {
                let remaining = maxBytes - data.count
                data.append(chunk.prefix(remaining))
            }
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

}
