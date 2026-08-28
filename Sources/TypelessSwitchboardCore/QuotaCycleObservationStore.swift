import Foundation

// MARK: - QuotaCycleObservationStore
//
// 额度周期观测的落盘读写。
//
// 为什么需要它：观测是**跨周**才能攒够的证据 —— 要判定「自然周还是滚动 7 天」，
// 至少得看到两三次真实的额度重置，也就是两三周。原先观测只存在内存里，
// App 一重启就清零，用户每天开关机的话永远攒不到样本，推断卡在「口径待确认」。
//
// 落成一个小 JSON，读在 Store 初始化时，写在每次观测到重置时。
// 纯文件读写 + 路径注入，所以能被 `OperationalFeatureChecks` 直接单测。

public enum QuotaCycleObservationStore {

    /// 最多保留多少条重置记录。几十条足够支撑口径判定，多了只是占空间。
    public static let maximumRetained = 64

    // 日期统一用 ISO 8601，与 store.json（App 层的 appEncoder/appDecoder）口径一致，
    // 方便人工拿文本编辑器直接看。Core 拿不到 App 层的扩展，这里自己配一份。
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 一条落盘的观测记录。`ObservedReset` 是内存用的轻量结构，
    /// 落盘时额外带上邮箱，拿到记录的人才知道这是哪个号。
    public struct Record: Codable, Equatable, Sendable {
        public let at: Date
        public let from: Int
        public let to: Int
        public let email: String

        public init(at: Date, from: Int, to: Int, email: String) {
            self.at = at
            self.from = from
            self.to = to
            self.email = email
        }

        var asObservedReset: QuotaCycleEngine.ObservedReset {
            QuotaCycleEngine.ObservedReset(at: at, from: from, to: to)
        }
    }

    /// 读取历史观测。文件不存在 / 损坏 / 格式不对一律返回空数组 ——
    /// 观测是辅助证据，读不出来就当没有，绝不能因此让 App 起不来。
    public static func load(from url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url),
              let records = try? decoder.decode([Record].self, from: data) else {
            return []
        }
        return Array(records.suffix(maximumRetained))
    }

    /// 转成引擎要的观测序列。
    public static func resets(from records: [Record]) -> [QuotaCycleEngine.ObservedReset] {
        records.map(\.asObservedReset)
    }

    /// 追加一条观测并落盘。保留最近 `maximumRetained` 条。
    ///
    /// 写失败不抛错：观测丢了只是少一条证据，不能影响主流程。
    @discardableResult
    public static func append(_ record: Record, to url: URL) -> [Record] {
        var records = load(from: url)
        records.append(record)
        let trimmed = Array(records.suffix(maximumRetained))
        guard let data = try? encoder.encode(trimmed) else { return records }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        return trimmed
    }

    /// 清空观测（供「重新开始观测」这类排障动作使用）。
    public static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
