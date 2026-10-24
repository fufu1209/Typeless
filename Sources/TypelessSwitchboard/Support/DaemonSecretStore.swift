import Foundation

/// 无界面进程（LaunchAgent `--daemon-check` / CLI 批量换号）的密源。
///
/// ## 为什么存在
///
/// 本 App 是 ad-hoc 签名（`codesign --sign -`）。钥匙串条目的 ACL 默认只信任
/// **创建时那个二进制**（按 designated requirement 匹配，ad-hoc 签名即 cdhash），
/// 于是每次重签：
///   - GUI 还能救：Security 框架弹授权框，用户点一次「始终允许」；
///   - 守护不能：launchd 以 `ProcessType=Background` 拉起，授权框弹不出来，
///     `SecItemCopyMatching` 永远挂在 SecurityServer 的 mach_msg 上。
///
/// 实测（2026-10-22 05:40 起）：v2.6.6 一装上，守护当分钟就卡死在
/// `KeychainStore.readAPIKey`，此后 launchd 里 job 显示 running、每分钟到点，
/// 实际每一轮都挂住 —— 额度守护静默停摆，与 v2.6.7 修的 JA3 停摆同型：
/// 界面看不出任何异常，只有 daemon 日志不再增长。`sample` 抓到的栈：
/// `runDaemonQuotaGuardOnceIfRequested → KeychainStore.readAPIKey →
/// SecItemCopyMatching → SecurityServer::ClientSession::decrypt → mach_msg`。
///
/// 即使 ACL 修好，登录钥匙串「睡眠时锁定」也能让无界面进程再次卡死
/// （解锁要输登录密码，同样弹不出框）。
///
/// ## 方案
///
/// 一个 0600 的边车 JSON 文件，与 store.json 同目录：
///   - GUI 仍以钥匙串为权威源，每次**成功读取/保存**都顺手把值镜像进边车
///     （值都到手了，镜像不引入新的授权面）；
///   - 无界面进程只读边车，全程不碰 Security 框架：没有弹框、没有锁定问题；
///   - 边车缺失时守护降级为「仅静默切换」并明确记日志，不猜不骗。
///
/// 安全口径：边车是 0600 本地文件，实际保护强度与「无需弹框的登录钥匙串条目」
/// 等同（登录钥匙串解锁态下任何本用户进程都能读），换来的是后台任务不挂死。
/// 对本 App 的场景（本机单人使用、守护必须能无人值守运行）这个交换是值得的，
/// 且不削弱既有防护：没有边车的攻击者同样过不了登录钥匙串。
enum DaemonSecretStore {
    /// 边车文件名。与 store.json 同目录（~/Library/Application Support/TypelessSwitchboard/）。
    static let fileName = "daemon-secrets.json"

    struct Payload: Codable, Equatable {
        var apiKey: String = ""
        /// key 为账号 UUID 字符串，value 为该账号的强密码。
        var passwords: [String: String] = [:]
    }

    // MARK: - 路径

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TypelessSwitchboard", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: - 读（无界面进程专用）

    static func readAPIKey() -> String {
        load().apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func readAccountPassword(accountID: UUID) -> String {
        load().passwords[accountID.uuidString] ?? ""
    }

    /// 边车是否存在且有 API Key。守护用它区分「没配 Key」和「边车没种子化」。
    static func hasAPIKey() -> Bool {
        !readAPIKey().isEmpty
    }

    private static func load() -> Payload {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder.appDecoder.decode(Payload.self, from: data) else {
            return Payload()
        }
        return payload
    }

    // MARK: - 写（GUI 专用，合并式）

    /// 把 API Key 镜像进边车（保留已有的密码条目）。
    static func mirrorAPIKey(_ value: String) {
        var payload = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.apiKey != trimmed else { return }
        payload.apiKey = trimmed
        write(payload)
    }

    /// 把账号密码镜像进边车（保留其它条目）。
    static func mirrorAccountPassword(_ value: String, accountID: UUID) {
        guard !value.isEmpty else { return }
        var payload = load()
        guard payload.passwords[accountID.uuidString] != value else { return }
        payload.passwords[accountID.uuidString] = value
        write(payload)
    }

    /// 原子落盘 + 0600 权限。先写临时文件再 replace，避免半截 JSON。
    private static func write(_ payload: Payload) {
        guard let data = try? JSONEncoder.appEncoder.encode(payload) else { return }
        let url = fileURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(fileName).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tempURL, options: .atomic)
            // 显式收紧权限：默认 umask 下可能是 644。
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
