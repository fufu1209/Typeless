import Foundation

// MARK: - LogFileRotator
//
// 日志轮转。为什么不早点加：守护每 60 秒写一行，一天 1440 行约 300KB，
// 一个月就能把日志喂到 10MB。实测本机 `quota-guard-*.log` 已经堆到 24MB，
// 而日志只是排障用的，不需要永久保存。
//
// 关键约束：**必须原地截断，不能替换文件**。
// launchd 的 stdout / stderr 重定向持有的是老 inode，用 `write(to:atomically:)`
// 换文件会让守护继续往一个已删除的 inode 里写 —— 磁盘空间不释放、新日志也看不到。
// 所以这里一律用 FileHandle 的 seek + write + truncateFile。

public enum LogFileRotator {
    /// 单个日志文件的体积上限（默认 2MB，约 1 万行守护日志）。
    public static let defaultMaxBytes: UInt64 = 2 * 1024 * 1024
    /// 轮转后至少保留的行数，避免日志很短时被反复裁。
    public static let minimumKeptLines = 500

    /// 追加一行（自动补换行）；写入前若已超限先轮转。
    public static func append(line: String, to fileURL: URL, maxBytes: UInt64 = defaultMaxBytes) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        rotateIfNeeded(fileURL, maxBytes: maxBytes)
        let text = line.hasSuffix("\n") ? line : line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 反复裁到体积达标为止。返回是否裁过。
    ///
    /// 为什么不是裁一次就收工：每次只砍一半，一个 15MB 的日志要砍 3 次才到 2MB 以下，
    /// 只砍一次的话用户要重启三次 App 才见效。上限 10 轮防止异常文件里死循环。
    @discardableResult
    public static func rotateIfNeeded(_ fileURL: URL, maxBytes: UInt64 = defaultMaxBytes) -> Bool {
        var didRotate = false
        for _ in 0..<10 {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let size = attributes[.size] as? UInt64,
                  size > maxBytes else { break }
            guard rotate(fileURL) else { break }
            didRotate = true
        }
        return didRotate
    }

    /// 原地裁掉最早的一半，保留最近 `max(总行数/2, minimumKeptLines)` 行。
    /// 行数本身就不多时不动文件。
    @discardableResult
    public static func rotate(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: fileURL) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(),
              let content = String(data: data, encoding: .utf8) else { return false }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // 行数本来就不多时不值得裁，避免在小文件上反复抖动。
        guard lines.count > minimumKeptLines else { return false }
        let keepCount = max(lines.count / 2, minimumKeptLines)
        guard keepCount < lines.count else { return false }

        guard let newData = Array(lines.suffix(keepCount)).joined(separator: "\n").data(using: .utf8) else {
            return false
        }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: newData)
        } catch {
            return false
        }
        handle.truncateFile(atOffset: UInt64(newData.count))
        return true
    }
}
