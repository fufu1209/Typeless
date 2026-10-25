import SwiftUI
import AppKit
import ApplicationServices
import Combine
import Security
import Darwin
import TypelessSwitchboardCore

extension SwitchboardStore {
    func prepareLocalTypelessDesktopEnvironmentForAutomaticReplacement() async -> [String] {
        var log: [String] = []
        log.append(await terminateInstalledTypelessApp())

        let backupRoot = automationDirectoryURL()
            .appendingPathComponent("DesktopSessionBackups", isDirectory: true)
            .appendingPathComponent(Self.safeTimestamp(), isDirectory: true)

        log.append(contentsOf: resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: backupRoot))

        for source in typelessDesktopSessionDataDirectories() {
            guard FileManager.default.fileExists(atPath: source.path) else {
                log.append("桌面登录态目录不存在，跳过：\(source.path)")
                continue
            }

            do {
                try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                let destination = backupRoot.appendingPathComponent(source.lastPathComponent, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: source, to: destination)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                log.append("已隔离旧桌面登录态：\(source.path) → \(destination.path)")
            } catch {
                log.append("隔离旧桌面登录态失败：\(source.path)：\(error.localizedDescription)")
            }
        }

        return log
    }


    func resetTypelessDeviceIdentityForAutomaticReplacement(backupRoot: URL) -> [String] {
        var log: [String] = []

        log.append(contentsOf: deleteTypelessDeviceCredentialsFromKeychain())

        for cacheDirectory in typelessDeviceCacheDirectories() {
            let deviceCache = cacheDirectory.appendingPathComponent("device.cache")
            if FileManager.default.fileExists(atPath: deviceCache.path) {
                do {
                    try FileManager.default.removeItem(at: deviceCache)
                    log.append("已删除 Typeless 设备缓存 device.cache：\(deviceCache.path)")
                } catch {
                    log.append("删除 Typeless 设备缓存失败：\(deviceCache.path)：\(error.localizedDescription)")
                }
            }
        }

        for dataDirectory in typelessDesktopSessionDataDirectories() {
            let userData = dataDirectory.appendingPathComponent("user-data.json")
            if FileManager.default.fileExists(atPath: userData.path) {
                do {
                    try FileManager.default.removeItem(at: userData)
                    log.append("已删除 Typeless 加密登录凭证 user-data.json：\(userData.path)")
                } catch {
                    log.append("删除 Typeless 加密登录凭证失败：\(userData.path)：\(error.localizedDescription)")
                }
            }

            let storage = dataDirectory.appendingPathComponent("app-storage.json")
            if FileManager.default.fileExists(atPath: storage.path) {
                do {
                    try clearTypelessAppStorageForDeviceReset(storage)
                    log.append("已清理 Typeless app-storage.json 的 userData / quotaUsage：\(storage.path)")
                } catch {
                    log.append("清理 Typeless app-storage.json 失败：\(storage.path)：\(error.localizedDescription)")
                }
            }

            // v2.7.3：删除「设备身份」时**不再**清理 Local Storage / Cookies /
            // Session Storage / Network 这些 Chromium 浏览器会话目录。
            //
            // 根因（2026-10-25 实测，Typeless 2.8.3）：这几个目录里存放着 Electron 的
            // 真实登录态。静默换号在「重置设备身份」这一步把它们连同 user-data.json 一起删掉，
            // 再只写回 user-data.json 并重拉 Typeless —— 结果 2.8.3 读不到会话、显示为未登录，
            // 把本来登录着的账号弄掉线（守护日志 13:36 的强制轮换即此坑）。
            // 设备身份只认 device.cache + keychain + app-storage 的 userData，与浏览器会话目录无关，
            // 删它们纯属误伤。去掉之后，轮换设备身份（避免服务端设备号上限）与「换号后仍能登录」
            // 两者才能兼得。
        }

        if log.isEmpty {
            log.append("未发现 Typeless 设备身份残留；继续隔离桌面登录态")
        } else {
            log.append("已按 typeless-toolkit resetDevice 逻辑重置本机 Typeless 设备身份")
        }
        _ = backupRoot
        return log
    }


    func deleteTypelessDeviceCredentialsFromKeychain() -> [String] {
        var log: [String] = []
        let candidates: [(service: String, account: String?)] = [
            (typelessCredentialTarget, typelessCredentialAccount),
            (typelessLegacyCredentialTarget, nil)
        ]

        for candidate in candidates {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: candidate.service
            ]
            if let account = candidate.account {
                query[kSecAttrAccount as String] = account
            }
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecSuccess {
                if let account = candidate.account {
                    log.append("已删除 Typeless 设备 Keychain 凭据：service=\(candidate.service), account=\(account)")
                } else {
                    log.append("已删除 Typeless 旧设备 Keychain 凭据：service=\(candidate.service)")
                }
            } else if status != errSecItemNotFound {
                if deleteTypelessDeviceCredentialWithSecurityCLI(service: candidate.service, account: candidate.account) {
                    log.append("已通过 security delete-generic-password 删除 Typeless 设备 Keychain 凭据：service=\(candidate.service)")
                } else {
                    log.append("删除 Typeless 设备 Keychain 凭据失败：service=\(candidate.service)，状态 \(status)")
                }
            }

            let labelQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrLabel as String: candidate.service
            ]
            let labelStatus = SecItemDelete(labelQuery as CFDictionary)
            if labelStatus == errSecSuccess {
                log.append("已删除 Typeless 设备 Keychain 标签凭据：label=\(candidate.service)")
            } else if labelStatus != errSecItemNotFound {
                if deleteTypelessDeviceCredentialWithSecurityCLI(label: candidate.service) {
                    log.append("已通过 security delete-generic-password 删除 Typeless 设备 Keychain 标签凭据：label=\(candidate.service)")
                } else {
                    log.append("删除 Typeless 设备 Keychain 标签凭据失败：label=\(candidate.service)，状态 \(labelStatus)")
                }
            }
        }

        if log.isEmpty {
            log.append("未发现 Typeless 设备 Keychain 凭据")
        }
        return log
    }


    func deleteTypelessDeviceCredentialWithSecurityCLI(service: String, account: String?) -> Bool {
        var arguments = ["security", "delete-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        let result = SwitchboardStore.runProcess(
            arguments: arguments,
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }


    func deleteTypelessDeviceCredentialWithSecurityCLI(label: String) -> Bool {
        let result = SwitchboardStore.runProcess(
            arguments: ["security", "delete-generic-password", "-l", label],
            environment: SwitchboardStore.automationEnvironment(),
            timeoutSeconds: 10
        )
        return result.status == 0
    }


    func clearTypelessAppStorageForDeviceReset(_ storageURL: URL) throws {
        guard let data = try? Data(contentsOf: storageURL),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        object["userData"] = [:]
        object.removeValue(forKey: "quotaUsage")
        if object.keys.contains("session") {
            object["session"] = NSNull()
        }
        if object.keys.contains("currentRoute") {
            object["currentRoute"] = NSNull()
        }

        let patchedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try patchedData.write(to: storageURL, options: .atomic)
    }

}
