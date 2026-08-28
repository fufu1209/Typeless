import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func refreshMoeMailConfig(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return
        }
        guard let base = URL(string: state.settings.moeMailBaseURL),
              let url = URL(string: "/api/config", relativeTo: base) else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        var request = URLRequest(url: url)
        request.addValue(apiKey, forHTTPHeaderField: "X-API-Key")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                statusMessage = "MoeMail 配置读取失败：HTTP \(status)"
                return
            }

            let discovered = extractDomains(from: data)
            if discovered.isEmpty {
                statusMessage = "MoeMail 已连通，但没有识别到新域名"
            } else {
                var merged = state.settings.domains
                for domain in discovered where !merged.contains(domain) {
                    merged.append(domain)
                }
                state.settings.domains = merged
                save()
                statusMessage = "已同步 \(discovered.count) 个域名"
            }
        } catch {
            statusMessage = "MoeMail 连接失败：\(error.localizedDescription)"
        }
    }

    func loadMoeMailEmails(apiKey: String) async {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return
        }
        guard let url = moeMailURL(path: "/api/emails") else {
            statusMessage = "MoeMail 地址无效"
            return
        }

        do {
            let data = try await moeMailRequest(url: url, apiKey: apiKey)
            let emails = parseMoeMailEmails(from: data)
            moeMailEmails = emails
            statusMessage = emails.isEmpty ? "没有读取到邮箱" : "已读取 \(emails.count) 个邮箱"
        } catch {
            statusMessage = "邮箱列表读取失败：\(error.localizedDescription)"
        }
    }

    func generateMoeMailEmail(apiKey: String, name: String, domain: String, expiryTime: Int) async -> MoeMailEmail? {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "请先保存 MoeMail API Key"
            return nil
        }
        guard let url = moeMailURL(path: "/api/emails/generate") else {
            statusMessage = "MoeMail 地址无效"
            return nil
        }

        let payload: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "typeless" : name,
            "expiryTime": expiryTime,
            "domain": domain
        ]

        do {
            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try await moeMailRequest(url: url, apiKey: apiKey, method: "POST", body: body)
            let emails = parseMoeMailEmails(from: data)
            if let email = emails.first {
                if !moeMailEmails.contains(where: { $0.id == email.id }) {
                    moeMailEmails.insert(email, at: 0)
                }
                statusMessage = "已生成邮箱：\(email.address)"
                return email
            }

            await loadMoeMailEmails(apiKey: apiKey)
            statusMessage = "已请求生成邮箱，请在列表中确认"
            return nil
        } catch {
            statusMessage = "生成邮箱失败：\(error.localizedDescription)"
            return nil
        }
    }

    func createMoeMailRegistrationCandidate(
        apiKey: String,
        domain: String,
        expiryTime: Int,
        copyPasswordToClipboard: Bool = true
    ) async -> UUID? {
        let resolvedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty(state.settings.domains.first ?? "example.com")
        let profile = AccountProfileGenerator.make(domain: resolvedDomain)
        let localPart = profile.email.components(separatedBy: "@").first ?? profile.username

        guard let email = await generateMoeMailEmail(
            apiKey: apiKey,
            name: localPart,
            domain: resolvedDomain,
            expiryTime: expiryTime
        ) else {
            return nil
        }

        var account = Account.blank(settings: state.settings)
        account.moeMailEmailID = email.id
        account.name = profile.displayName
        account.typelessUsername = profile.username
        account.email = email.address.ifEmpty(profile.email)
        account.domain = email.domain.ifEmpty(resolvedDomain)
        account.passwordHint = "强密码已保存到 macOS Keychain"
        account.reviewState = .pending
        account.reviewedAt = nil
        account.status = .paused
        account.usedCharacters = 0
        account.inboxURL = state.settings.moeMailBaseURL
        account.notes = "MoeMail 已生成；等待兜底完成 Typeless 注册与邮箱验证码核验"

        if let index = state.accounts.firstIndex(where: { !$0.email.isEmpty && $0.email == account.email }) {
            account.id = state.accounts[index].id
            account.createdAt = state.accounts[index].createdAt
            state.accounts[index] = account
        } else {
            state.accounts.insert(account, at: 0)
        }

        KeychainStore.saveAccountPassword(profile.password, accountID: account.id)

        let candidate = RegistrationCandidate(
            displayName: account.name,
            username: account.typelessUsername ?? profile.username,
            email: account.email,
            domain: account.domain,
            passwordHint: "强密码已保存到 macOS Keychain"
        )
        let plan = RegistrationPreparationPlan.make(candidate: candidate, typelessURL: account.typelessURL)
        if state.registrationPlans == nil { state.registrationPlans = [] }
        state.registrationPlans?.insert(plan, at: 0)

        if copyPasswordToClipboard {
            copyToClipboard(profile.password)
        }
        save()
        statusMessage = copyPasswordToClipboard
            ? "已创建注册候选账号，强密码已保存到 Keychain 并复制：\(account.email)"
            : "已创建注册候选账号，强密码已保存到 Keychain：\(account.email)"
        return account.id
    }
}
