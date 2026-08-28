import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func exportAccountsToClipboard() {
        do {
            let data = try JSONEncoder.appEncoder.encode(state)
            if let text = String(data: data, encoding: .utf8) {
                copyToClipboard(text)
                statusMessage = "已复制账号备份 JSON"
            }
        } catch {
            statusMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func importAccountsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            statusMessage = "剪贴板没有可导入的 JSON"
            return
        }

        do {
            let imported = try JSONDecoder.appDecoder.decode(PersistedState.self, from: data)
            state = imported
            save()
            statusMessage = "已从剪贴板导入账号备份"
        } catch {
            statusMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    func importToolkitAccountsFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let data = text.data(using: .utf8) else {
            statusMessage = "剪贴板没有 typeless-toolkit accounts.json"
            return
        }

        do {
            let root = try JSONSerialization.jsonObject(with: data)
            let rawAccounts: [[String: Any]]
            if let array = root as? [[String: Any]] {
                rawAccounts = array
            } else if let dict = root as? [String: Any],
                      let array = (dict["accounts"] ?? dict["data"]) as? [[String: Any]] {
                rawAccounts = array
            } else {
                statusMessage = "无法识别 toolkit 账号 JSON"
                return
            }

            if state.tokenSummaries == nil { state.tokenSummaries = [] }
            var importedCount = 0
            var tokenCount = 0

            for raw in rawAccounts {
                let imported = ToolkitAccountImporter.importableAccount(from: raw, existingDomains: state.settings.domains)
                let item = imported.account

                var account = Account.blank(settings: state.settings)
                account.name = item.name
                account.email = item.email
                account.domain = item.domain.ifEmpty(state.settings.domains.first ?? "")
                account.role = item.role
                account.typelessUsername = item.typelessUsername
                account.status = .paused
                account.reviewState = .pending
                account.reviewedAt = nil
                account.notes = item.notes

                if let index = state.accounts.firstIndex(where: { !$0.email.isEmpty && $0.email == item.email }) {
                    account.id = state.accounts[index].id
                    account.createdAt = state.accounts[index].createdAt
                    state.accounts[index] = account
                } else {
                    state.accounts.append(account)
                }

                if let summary = imported.tokenSummary {
                    state.tokenSummaries?.removeAll { $0.accountEmail == summary.accountEmail }
                    state.tokenSummaries?.append(summary)
                    tokenCount += 1
                }
                importedCount += 1
            }

            save()
            statusMessage = "已导入 \(importedCount) 个 toolkit 账号；记录 \(tokenCount) 条 token 指纹"
        } catch {
            statusMessage = "toolkit 账号导入失败：\(error.localizedDescription)"
        }
    }

    func exportAccountsCSVToClipboard() {
        let headers = [
            "name", "email", "domain", "role", "monthly_limit", "used_characters",
            "status", "review_state", "moemail_id", "typeless_username", "notes"
        ]
        let rows = state.accounts.map { account in
            [
                account.name,
                account.email,
                account.domain,
                account.role,
                String(account.monthlyLimit),
                String(account.usedCharacters),
                account.status.rawValue,
                account.effectiveReviewState.rawValue,
                account.moeMailEmailID ?? "",
                account.typelessUsername ?? "",
                account.notes
            ]
        }
        let csv = ([headers] + rows)
            .map { $0.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n")
        copyToClipboard(csv)
        statusMessage = "已复制账号表格 CSV"
    }

    func importAccountsCSVFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusMessage = "剪贴板没有可导入的 CSV"
            return
        }

        let rows = parseCSV(text)
        guard let header = rows.first else {
            statusMessage = "CSV 内容为空"
            return
        }

        let keys = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element.lowercased(), $0.offset) })
        var importedCount = 0

        for row in rows.dropFirst() {
            let email = csvValue(row, keys: keys, name: "email")
            guard !email.isEmpty else { continue }

            let domain = csvValue(row, keys: keys, name: "domain")
                .ifEmpty(email.components(separatedBy: "@").last ?? state.settings.domains.first ?? "")
            let status = AccountStatus(rawValue: csvValue(row, keys: keys, name: "status")) ?? .paused
            let reviewState = ReviewState(rawValue: csvValue(row, keys: keys, name: "review_state")) ?? .pending

            var account = Account.blank(settings: state.settings)
            account.name = csvValue(row, keys: keys, name: "name").ifEmpty(email.components(separatedBy: "@").first ?? "导入账号")
            account.email = email
            account.domain = domain
            account.role = csvValue(row, keys: keys, name: "role").ifEmpty("平民")
            account.monthlyLimit = Int(csvValue(row, keys: keys, name: "monthly_limit")) ?? 8000
            account.usedCharacters = Int(csvValue(row, keys: keys, name: "used_characters")) ?? 0
            account.status = status
            account.reviewState = reviewState
            account.reviewedAt = reviewState == .approved ? Date() : nil
            account.moeMailEmailID = csvValue(row, keys: keys, name: "moemail_id").nilIfEmpty
            account.typelessUsername = csvValue(row, keys: keys, name: "typeless_username").nilIfEmpty
            account.notes = csvValue(row, keys: keys, name: "notes")

            if let index = state.accounts.firstIndex(where: { $0.email == email }) {
                account.id = state.accounts[index].id
                account.createdAt = state.accounts[index].createdAt
                state.accounts[index] = account
            } else {
                state.accounts.append(account)
            }
            importedCount += 1
        }

        save()
        statusMessage = "已导入 \(importedCount) 个 CSV 账号"
    }

    func copyToClipboard(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    func csvValue(_ row: [String], keys: [String: Int], name: String) -> String {
        guard let index = keys[name], row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toolkitString(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] as? String {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let number = dictionary[key] as? NSNumber {
                return number.stringValue
            }
        }
        return ""
    }

    func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n" && !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
