import Foundation
import Security

/// v2.5.2：钥匙串访问加进程级缓存，避免每次 UI 刷新都触发 macOS 弹窗。
///
/// **背景**：本 App 是 ad-hoc 签名（`codesign --sign -`），不是 Apple 公证过的；
/// macOS 每次都可能在第一次访问 `kSecClassGenericPassword` 时弹「请输入登录钥匙串密码」。
/// 即使之前选过「始终允许」，app 升级或重新签名后又会再问一次。
///
/// **优化策略**：
/// 1. 加 `kSecAttrAccessibleAfterFirstUnlock`：设备解锁后即可读，不要求钥匙串始终处于解锁态，
///    比默认的 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 更宽松，弹窗概率更低。
/// 2. 加进程级缓存：首次读取后存到 `cachedAPIKey` / `cachedPasswords`，
///    后续调用直接返回缓存，**不再触发 `SecItemCopyMatching`**，不再弹窗。
/// 3. `saveAPIKey` / `saveAccountPassword` 写入时同步更新缓存，
///    保证 UI 立刻看到新值，无需重新读 keychain。
///
/// **范围**：
/// - 缓存只在进程内有效，跨进程会重读（这是正确的：app 升级/重启后第一次仍可能弹一次）
/// - 仅缓存已成功读到的非空值；读不到时返回空串，不缓存（让调用方重新尝试）
enum KeychainStore {
    private static let service = "local.typeless.switchboard"
    private static let account = "moemail-api-key"
    private static let accountPasswordPrefix = "typeless-account-password-"

    // MARK: - 进程级缓存（v2.5.2 新增）

    /// 锁：缓存读/写是单线程访问，但保险起见加锁
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedAPIKey: String?
    /// 已确认"不存在"（避免反复问 keychain 同一个不存在的条目）
    nonisolated(unsafe) private static var didConfirmAPIKeyMissing = false
    nonisolated(unsafe) private static var cachedPasswords: [UUID: String] = [:]
    nonisolated(unsafe) private static var missingPasswords: Set<UUID> = []

    // MARK: - API Key 入口

    static func readAPIKey() -> String {
        cacheLock.lock()
        if let cached = cachedAPIKey {
            cacheLock.unlock()
            return cached
        }
        if didConfirmAPIKeyMissing {
            cacheLock.unlock()
            return ""
        }
        cacheLock.unlock()

        let value = readRaw(account: account)
        cacheLock.lock()
        if value.isEmpty {
            didConfirmAPIKeyMissing = true
        } else {
            cachedAPIKey = value
        }
        cacheLock.unlock()
        return value
    }

    static func saveAPIKey(_ value: String) {
        save(value, account: account)
        cacheLock.lock()
        if value.isEmpty {
            cachedAPIKey = nil
            didConfirmAPIKeyMissing = true
        } else {
            cachedAPIKey = value
            didConfirmAPIKeyMissing = false
        }
        cacheLock.unlock()
    }

    // MARK: - 账号强密码入口

    static func readAccountPassword(accountID: UUID) -> String {
        cacheLock.lock()
        if let cached = cachedPasswords[accountID] {
            cacheLock.unlock()
            return cached
        }
        if missingPasswords.contains(accountID) {
            cacheLock.unlock()
            return ""
        }
        cacheLock.unlock()

        let key = accountPasswordPrefix + accountID.uuidString
        let value = readRaw(account: key)
        cacheLock.lock()
        if value.isEmpty {
            missingPasswords.insert(accountID)
        } else {
            cachedPasswords[accountID] = value
        }
        cacheLock.unlock()
        return value
    }

    static func saveAccountPassword(_ value: String, accountID: UUID) {
        let key = accountPasswordPrefix + accountID.uuidString
        save(value, account: key)
        cacheLock.lock()
        if value.isEmpty {
            cachedPasswords.removeValue(forKey: accountID)
            missingPasswords.insert(accountID)
        } else {
            cachedPasswords[accountID] = value
            missingPasswords.remove(accountID)
        }
        cacheLock.unlock()
    }

    /// 删除账号时同步清缓存与 keychain 条目，避免内存里残留已删账号的密码。
    static func purgeAccountPasswordCache(accountID: UUID) {
        cacheLock.lock()
        cachedPasswords.removeValue(forKey: accountID)
        missingPasswords.remove(accountID)
        cacheLock.unlock()
        let key = accountPasswordPrefix + accountID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 底层 keychain 读写

    private static func readRaw(account: String) -> String {
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
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            SecItemAdd(createQuery as CFDictionary, nil)
        } else if updateStatus != errSecSuccess {
            // 旧条目没有 Accessible 属性导致权限不一致时，先删再建
            SecItemDelete(query as CFDictionary)
            var createQuery = query
            createQuery[kSecValueData as String] = data
            SecItemAdd(createQuery as CFDictionary, nil)
        }
    }
}
