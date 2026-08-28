import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

enum KeychainStore {
    private static let service = "local.typeless.switchboard"
    private static let account = "moemail-api-key"
    private static let accountPasswordPrefix = "typeless-account-password-"

    static func readAPIKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func saveAPIKey(_ value: String) {
        save(value, account: account)
    }

    static func readAccountPassword(accountID: UUID) -> String {
        read(account: accountPasswordPrefix + accountID.uuidString)
    }

    static func saveAccountPassword(_ value: String, accountID: UUID) {
        save(value, account: accountPasswordPrefix + accountID.uuidString)
    }

    private static func read(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    private static func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) != errSecSuccess {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            SecItemAdd(createQuery as CFDictionary, nil)
        }
    }
}

/// 真正入口：GUI 开窗口；`--daemon-check` / `--auto-switch-count` 走无界面单次任务后退出。
///
/// 注意这里**不能**加 `@main`：本模块已拆成多文件，`main.swift` 里有一行顶层调用，
/// 而 Swift 规定「含顶层代码的模块不能再有 @main 属性」。入口由 `main.swift` 显式调用。
