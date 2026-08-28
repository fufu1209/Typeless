import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func checkTypelessEntry() async {
        guard let url = URL(string: state.settings.typelessLoginURL) else {
            statusMessage = "Typeless 入口地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<400).contains(code) {
                statusMessage = "Typeless 入口可访问：HTTP \(code)"
            } else {
                statusMessage = "Typeless 入口返回 HTTP \(code)，建议打开官网或本机 App"
            }
        } catch {
            statusMessage = "Typeless 入口检查失败：\(error.localizedDescription)"
        }
    }

    func runSetupDiagnostics(apiKey: String) async {
        var results: [DiagnosticItem] = []

        let appExists = typelessAppPath() != nil
        results.append(DiagnosticItem(
            title: "Typeless App",
            detail: appExists ? "已找到本机 Typeless App" : "未找到本机 App，会改用官网入口",
            level: appExists ? .ok : .warning
        ))
        appendMacPermissionDiagnostics(to: &results)

        if let url = URL(string: state.settings.typelessLoginURL) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                results.append(DiagnosticItem(
                    title: "Typeless 入口",
                    detail: (200..<400).contains(code) ? "入口可访问，HTTP \(code)" : "入口返回 HTTP \(code)，建议打开官网或本机 App",
                    level: (200..<400).contains(code) ? .ok : .warning
                ))
            } catch {
                results.append(DiagnosticItem(
                    title: "Typeless 入口",
                    detail: "入口检查失败：\(error.localizedDescription)",
                    level: .error
                ))
            }
        } else {
            results.append(DiagnosticItem(title: "Typeless 入口", detail: "入口地址格式无效", level: .error))
        }

        if URL(string: state.settings.moeMailBaseURL) == nil {
            results.append(DiagnosticItem(title: "MoeMail 地址", detail: "MoeMail 地址格式无效", level: .error))
        } else if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results.append(DiagnosticItem(title: "MoeMail API Key", detail: "未填写 API Key，无法读取邮箱和邮件", level: .warning))
        } else {
            do {
                guard let url = moeMailURL(path: "/api/config") else {
                    throw NSError(domain: "MoeMail", code: -1, userInfo: [NSLocalizedDescriptionKey: "MoeMail 地址无效"])
                }
                let data = try await moeMailRequest(url: url, apiKey: apiKey)
                let domains = extractDomains(from: data)
                results.append(DiagnosticItem(
                    title: "MoeMail 配置",
                    detail: domains.isEmpty ? "API 可连通，但没有识别到域名" : "API 可连通，识别到 \(domains.count) 个域名",
                    level: domains.isEmpty ? .warning : .ok
                ))
            } catch {
                results.append(DiagnosticItem(title: "MoeMail 配置", detail: "连接失败：\(error.localizedDescription)", level: .error))
            }
        }

        let nodeCheck = await automationCommandVersion(command: "node", versionArgument: "--version")
        results.append(DiagnosticItem(
            title: "Node.js 自动化",
            detail: nodeCheck.isEmpty ? "未检测到 node；全自动浏览器注册会降级为脚本和手动兜底" : "已检测到 node：\(nodeCheck)",
            level: nodeCheck.isEmpty ? .warning : .ok
        ))

        let npmCheck = await automationCommandVersion(command: "npm", versionArgument: "--version")
        results.append(DiagnosticItem(
            title: "npm / Playwright",
            detail: npmCheck.isEmpty ? "未检测到 npm；无法自动安装/运行 Playwright" : "已检测到 npm：\(npmCheck)，准备预热 Playwright 运行时",
            level: npmCheck.isEmpty ? .warning : .ok
        ))

        if !nodeCheck.isEmpty && !npmCheck.isEmpty {
            let runtime = await prepareAutomationRuntime()
            results.append(DiagnosticItem(
                title: "Playwright 运行时",
                detail: runtime.message,
                level: runtime.success ? .ok : .warning
            ))
        }

        let available = state.accounts.filter { $0.isUsable && $0.remainingCharacters > 0 }.count
        let pending = state.accounts.filter { $0.effectiveReviewState == .pending }.count
        results.append(DiagnosticItem(
            title: "可切换账号",
            detail: available > 0 ? "有 \(available) 个已确认可用账号" : "没有已确认可用账号，需要先导入账号或处理兜底确认账号",
            level: available > 0 ? .ok : .warning
        ))

        if pending > 0 {
            results.append(DiagnosticItem(title: "待兜底确认账号", detail: "\(pending) 个候选账号等待兜底确认", level: .warning))
        }

        diagnostics = results
        let errors = results.filter { $0.level == .error }.count
        let warnings = results.filter { $0.level == .warning }.count
        statusMessage = errors > 0 ? "自检完成：\(errors) 个问题需要处理" : "自检完成：\(warnings) 个注意项"
    }
}
