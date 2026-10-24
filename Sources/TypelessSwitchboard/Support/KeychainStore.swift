import Foundation
import Security

/// v2.5.2：钥匙串访问加进程级缓存，避免每次 UI 刷新都触发 macOS 弹窗。
///
/// **背景**：本 App 是 ad-hoc 签名（`codesign --sign -`），不是 Apple 公证过的；
/// macOS 每次都可能在第一次访问 `kSecClassGenericPassword` 时弹「请输入登录钥匙串密码」。
/// 即使之前选过「始终允许」，app 升级或重新签名后又会再问一次。
///
/// **v2.6.8 补充**：所有成功读到的值都会镜像进 `DaemonSecretStore` 的边车文件，
/// 供无界面进程（LaunchAgent 守护 / CLI）读取 —— 守护弹不出授权框，
/// `SecItemCopyMatching` 会永远挂在 SecurityServer 上（实测卡死过整个额度守护，
/// 详见 `DaemonSecretStore` 的文档）。镜像只发生在「值已经到手」之后，
/// 不引入新的授权面。
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
            // v2.6.8：镜像给无界面进程。放在锁外做文件 IO，不堵其它读取方。
            cacheLock.unlock()
            DaemonSecretStore.mirrorAPIKey(value)
            cacheLock.lock()
        }
        cacheLock.unlock()
        return value
    }

    /// **边车优先**读 API Key：先读 `DaemonSecretStore` 边车，为空才走钥匙串。
    ///
    /// 为什么 GUI 也要边车优先：钥匙串条目的 ACL 可能不信任当前二进制
    /// （重签 / 恢复备份 / 钥匙串迁移都会造成），此时 `SecItemCopyMatching`
    /// 会等一个弹出来的授权框 —— 而**启动路径上弹不出来**：RootView 的
    /// `@State` 初始化就在主线程里读 Key，主线程卡在 mach_msg 上等 dialog，
    /// dialog 又要等主线程，整个窗口冻住（2026-10-25 实测：GUI 与守护
    /// 同时这样冻住，用户看到的就是一个永远不出现的窗口）。
    ///
    /// 边车优先把这个死局拆开：有边车值就秒返回，启动永不卡；
    /// 没有边车值才走钥匙串 —— 条目不存在时秒返回空串（首跑装 Key 之前），
    /// 条目存在但未授权时由**用户主动触发的路径**去承担那次授权
    /// （那时窗口已在，授权框点得动）。
    static func readAPIKeyPreferringSidecar() -> String {
        let sidecar = DaemonSecretStore.readAPIKey()
        if !sidecar.isEmpty { return sidecar }
        return readAPIKey()
    }

    static func saveAPIKey(_ value: String) {
        save(value, account: account)
        DaemonSecretStore.mirrorAPIKey(value)
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
            cacheLock.unlock()
            // v2.6.8：镜像给无界面进程（守护只读边车，不碰钥匙串）。
            DaemonSecretStore.mirrorAccountPassword(value, accountID: accountID)
            cacheLock.lock()
        }
        cacheLock.unlock()
        return value
    }

    static func saveAccountPassword(_ value: String, accountID: UUID) {
        let key = accountPasswordPrefix + accountID.uuidString
        save(value, account: key)
        DaemonSecretStore.mirrorAccountPassword(value, accountID: accountID)
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
