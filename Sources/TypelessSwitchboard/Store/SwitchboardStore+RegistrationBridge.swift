import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func loadMessages(for account: Account, apiKey: String) async {
        guard let emailID = account.moeMailEmailID, !emailID.isEmpty else {
            statusMessage = "这个账号还没有关联 MoeMail 邮箱 ID"
            return
        }
        guard let url = moeMailURL(path: "/api/emails/\(emailID)") else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        do {
            // 验证码轮询路径必须用短超时：轮询总窗口有限，慢请求会挤占后续轮次。
            let data = try await moeMailRequest(url: url, apiKey: apiKey, timeoutInterval: 8)
            moeMailMessages = parseMoeMailMessages(from: data)
            statusMessage = moeMailMessages.isEmpty ? "没有读取到邮件" : "已读取 \(moeMailMessages.count) 封邮件"
        } catch {
            statusMessage = "邮件列表读取失败：\(error.localizedDescription)"
        }
    }


    func pollVerificationCode(for account: Account, apiKey: String, attempts: Int, delaySeconds: UInt64) async -> String? {
        let totalAttempts = max(attempts, 1)
        for attempt in 1...totalAttempts {
            await loadMessages(for: account, apiKey: apiKey)
            if let code = verificationCode(from: moeMailMessages) {
                return code
            }
            statusMessage = "正在等待验证码邮件（\(attempt)/\(totalAttempts)）..."
            guard attempt < totalAttempts else { continue }
            let scheduledDelay = RegistrationAutomationTiming.moeMailPollingDelaySeconds(afterAttempt: attempt) ?? delaySeconds
            try? await Task.sleep(nanoseconds: scheduledDelay * 1_000_000_000)
        }
        return nil
    }


    func verificationCode(from messages: [MoeMailMessage]) -> String? {
        for message in messages {
            let fields = [message.subject, message.sender, message.receivedAt, message.preview]
            if let code = VerificationCodeExtractor.extract(from: fields) {
                return code
            }
        }
        return nil
    }


    func makeVerificationCodeBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-code-\(safeEmail)-\(account.id.uuidString).txt")
    }


    func makeAutomationResultBridgeFileURL(account: Account) -> URL {
        let folder = automationDirectoryURL()
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return folder.appendingPathComponent("typeless-result-\(safeEmail)-\(account.id.uuidString).json")
    }


    func makeBrowserProfileDirectoryURL(account: Account) -> URL {
        let safeEmail = account.email
            .replacingOccurrences(of: "@", with: "_at_")
            .replacingOccurrences(of: ".", with: "_")
        return retainedTypelessBrowserProfileRootURL()
            .appendingPathComponent("\(safeEmail)-\(account.id.uuidString)", isDirectory: true)
    }


    func retainedTypelessBrowserProfileRootURL() -> URL {
        automationDirectoryURL()
            .appendingPathComponent("BrowserProfiles", isDirectory: true)
    }


    func writeVerificationCode(_ code: String, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try code.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            statusMessage = "写入验证码桥接文件失败：\(error.localizedDescription)"
        }
    }


    func writeRegistrationAutomationScript(
        account: Account,
        password: String,
        verificationCode: String?,
        verificationCodeFileURL: URL?,
        automationResultFileURL: URL?
    ) -> URL? {
        do {
            let folder = automationDirectoryURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let safeEmail = account.email
                .replacingOccurrences(of: "@", with: "_at_")
                .replacingOccurrences(of: ".", with: "_")
            let scriptURL = folder.appendingPathComponent("typeless-register-\(safeEmail)-\(Date().timeIntervalSince1970).js")
            let input = BrowserRegistrationAutomationInput(
                registrationURL: account.typelessURL,
                email: account.email,
                username: account.typelessUsername ?? account.name,
                password: password,
                verificationCode: verificationCode,
                verificationCodeFilePath: verificationCodeFileURL?.path,
                automationResultFilePath: automationResultFileURL?.path,
                browserProfileDirectoryPath: makeBrowserProfileDirectoryURL(account: account).path,
                clearBrowserProfileBeforeRun: true,
                passwordEnvironmentVariable: typelessAutomationPasswordEnvironmentKey,
                headless: true
            )
            try BrowserAutomationScriptBuilder
                .makeRegistrationScript(input: input)
                .write(to: scriptURL, atomically: true, encoding: .utf8)
            return scriptURL
        } catch {
            statusMessage = "写入自动化脚本失败：\(error.localizedDescription)"
            return nil
        }
    }


    func readAutomationResult(from url: URL) -> BrowserAutomationResultPayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BrowserAutomationResultPayload.self, from: data)
    }


    nonisolated static func safeTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

}
