import Foundation

// MARK: - StoreRecovery
//
// 账号池 `store.json` 的读取 + 损坏恢复纯逻辑。原来内联在
// `Sources/TypelessSwitchboard/main.swift` 的 `SwitchboardStore.init`，测试 target import 不到。
//
// 关键行为（不是「源码里有没有这行」，而是真的会发生）：
// 1. 读文件或解码失败时，**先把损坏文件移走备份**为 `<原文件名>.corrupted-<yyyyMMdd-HHmmss>`，
//    绝不静默覆盖成空 state —— 否则 Keychain 里的密码就永久找不回来了；
// 2. 备份文件名必须文件名安全（不能有 `:` `/` 空格）。

public enum StoreRecovery {
    public static let defaultStoreFileName = "store.json"
    public static let corruptedBackupPrefix = "corrupted"

    public struct Failure: Equatable, Sendable, Error {
        public let backupFileName: String?
        public let backupErrorDescription: String?
        public let decodeErrorDescription: String

        public init(backupFileName: String?, backupErrorDescription: String?, decodeErrorDescription: String) {
            self.backupFileName = backupFileName
            self.backupErrorDescription = backupErrorDescription
            self.decodeErrorDescription = decodeErrorDescription
        }

        /// 用户在 UI 上看到的错误文案。备份成功/失败走不同分支。
        public var message: String {
            let note: String
            if let backupErrorDescription {
                note = "备份损坏文件失败：\(backupErrorDescription)"
            } else {
                note = "已备份为 \(backupFileName ?? "")"
            }
            return "无法读取账号池（\(note)）：\(decodeErrorDescription)"
        }
    }

    // MARK: - 备份命名

    /// 文件名安全的时间戳后缀：`yyyyMMdd-HHmmss`。
    public static func corruptedBackupNameSuffix(
        _ date: Date,
        timeZone: TimeZone = .current,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        var cal = calendar
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.timeZone = timeZone
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            year, month, day, hour, minute, second
        )
    }

    public static func corruptedBackupFileName(
        storeFileName: String = defaultStoreFileName,
        _ date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        "\(storeFileName).\(corruptedBackupPrefix)-\(corruptedBackupNameSuffix(date, timeZone: timeZone))"
    }

    // MARK: - 读取 + 恢复

    /// 读取并解码；失败时把损坏文件备份移走，返回 `.failure(Failure)`。
    /// 调用方拿到 failure 后应**保留空 state 并把 `failure.message` 暴露给用户**，切勿静默吞错落盘。
    public static func load<T>(
        from fileURL: URL,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default,
        decode: (Data) throws -> T
    ) -> Result<T, Failure> {
        do {
            let data = try Data(contentsOf: fileURL)
            return .success(try decode(data))
        } catch let loadError {
            let backupFileName = corruptedBackupFileName(
                storeFileName: fileURL.lastPathComponent,
                now,
                timeZone: timeZone
            )
            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupFileName)
            var moveError: Error?
            do {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.moveItem(at: fileURL, to: backupURL)
            } catch {
                moveError = error
            }
            return .failure(
                Failure(
                    backupFileName: backupFileName,
                    backupErrorDescription: moveError?.localizedDescription,
                    decodeErrorDescription: loadError.localizedDescription
                )
            )
        }
    }
}
