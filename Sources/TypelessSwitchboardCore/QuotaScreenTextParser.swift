import Foundation

// MARK: - v2.8.0：读屏文本 → 本周剩余字数（纯函数，可测）
//
// v2.7.5 的解析器有三个实测会踩的坑，这里逐个修掉：
//
//   1. **把日期当额度**：`firstInt` 会把 `2026年10月25日` 变成 `20261025`。
//      现在先剔掉日期 / 时间 / 版本号形状的行。
//   2. **把「上限」当「剩余」**：界面上同时有「本周额度 23333」和「已用 179」，
//      旧逻辑取第一个带关键字的数字 → 得到 23333，于是「剩余很充足」，
//      永远不会换号（最坏的一种错：静默失效）。
//      现在区分 remaining / used / limit 三类语义，能减就减。
//   3. **比例式方向**：`X / Y` 里 X 未必是剩余。现在只在 `X ≤ Y` 且 Y 像额度
//      （200–100000）时接受，并且优先相信带「剩余/left」字样的行。
//
// 解析失败一律返回 nil —— 让调用方降级，而不是拿一个猜出来的数字去做换号决策。

/// 解析结果。`confidence` 用于日志与 UI 提示；低于 0.5 时调用方应视为「只供参考」。
public struct QuotaScreenParseResult: Equatable, Sendable {
    public var remaining: Int
    public var total: Int?
    public var used: Int?
    public var matchedText: String
    public var confidence: Double

    public init(remaining: Int, total: Int? = nil, used: Int? = nil, matchedText: String, confidence: Double) {
        self.remaining = remaining
        self.total = total
        self.used = used
        self.matchedText = matchedText
        self.confidence = confidence
    }
}

public enum QuotaScreenTextParser {
    /// 合理的周额度上限区间：低于 200 不像额度，高于 100000 一定是识别错了。
    public static let plausibleTotalRange = 200...100_000
    /// 单行里关键字与数字之间允许的字符数（防止跨列误配）。
    public static let keywordProximity = 14

    private static let remainingKeywords = [
        "本周剩余", "本周可用", "剩余", "还剩", "可用", "剩余额度", "剩余字数",
        "remaining", "left", "available"
    ]
    private static let usedKeywords = [
        "本周已用", "已使用", "已用", "已消耗", "消耗", "used"
    ]
    private static let limitKeywords = [
        "本周额度", "周额度", "本周上限", "额度上限", "上限", "总额度", "总量", "limit"
    ]

    /// 兼容旧调用：只要数字。
    public static func parseWeeklyRemaining(from lines: [String]) -> Int? {
        parse(from: lines)?.remaining
    }

    /// 主入口。
    public static func parse(from lines: [String]) -> QuotaScreenParseResult? {
        let cleaned = lines
            .map(normalize)
            .filter { !$0.isEmpty && !isNoise($0) }

        guard !cleaned.isEmpty else { return nil }

        // 1) 带「剩余 / 可用 / left」关键字的行 —— 最高优先级。
        for line in cleaned {
            if let number = number(afterAnyOf: remainingKeywords, in: line) {
                return QuotaScreenParseResult(
                    remaining: number,
                    matchedText: line,
                    confidence: 0.9
                )
            }
        }

        // 1b) 关键字与数字被 OCR 拆成两行（Vision 常把「本周剩余」和「1,234 字」分成两个 block）。
        //     只在「关键字行自己没有数字」时才看下一行，避免把相邻的无关数字吞进来。
        for (index, line) in cleaned.enumerated() {
            guard hasAny(remainingKeywords, in: line), firstNumber(in: line) == nil,
                  cleaned.indices.contains(index + 1) else { continue }
            if let number = firstNumber(in: cleaned[index + 1]), number >= 0 {
                return QuotaScreenParseResult(
                    remaining: number,
                    matchedText: "\(line) / \(cleaned[index + 1])",
                    confidence: 0.6
                )
            }
        }

        // 2) 比例式：X / Y、X of Y、X／Y。
        //
        // 注意方向：`已用 179/2000` 和 `剩余 179/2000` 长得一样，但含义相反。
        // 行里出现「已用 / used」时 X 是**已用**，剩余要减；否则 X 才是剩余。
        for line in cleaned {
            if let ratio = ratio(in: line) {
                let isUsedLine = usedKeywords.contains { line.lowercased().contains($0.lowercased()) }
                if isUsedLine {
                    return QuotaScreenParseResult(
                        remaining: max(ratio.second - ratio.first, 0),
                        total: ratio.second,
                        used: ratio.first,
                        matchedText: line,
                        confidence: 0.8
                    )
                }
                return QuotaScreenParseResult(
                    remaining: ratio.first,
                    total: ratio.second,
                    matchedText: line,
                    confidence: 0.8
                )
            }
        }

        // 3) 「上限 + 已用」两段式：分处两行也算。
        let limit = cleaned.compactMap { number(afterAnyOf: limitKeywords, in: $0) }
            .first { plausibleTotalRange.contains($0) }
        let used = cleaned.compactMap { number(afterAnyOf: usedKeywords, in: $0) }
            .first { $0 >= 0 && $0 <= (limit ?? plausibleTotalRange.upperBound) }
        if let limit, let used, used <= limit {
            return QuotaScreenParseResult(
                remaining: limit - used,
                total: limit,
                used: used,
                matchedText: "额度 \(limit) - 已用 \(used)",
                confidence: 0.7
            )
        }

        // 4) 整屏只有一个数字时兜底（旧行为），但置信度明确标低。
        let allNumbers = cleaned.compactMap { firstNumber(in: $0) }
        if allNumbers.count == 1, let only = allNumbers.first, plausibleTotalRange.contains(only) {
            return QuotaScreenParseResult(
                remaining: only,
                matchedText: cleaned.first(where: { firstNumber(in: $0) == only }) ?? "",
                confidence: 0.35
            )
        }

        return nil
    }

    // MARK: - 文本处理

    /// 全角转半角、去空格、统一各种「／」与千分位。
    static func normalize(_ raw: String) -> String {
        var text = raw
        let maps: [Character: Character] = [
            "０": "0", "１": "1", "２": "2", "３": "3", "４": "4",
            "５": "5", "６": "6", "７": "7", "８": "8", "９": "9",
            "／": "/", "，": ",", "．": ".", "：": ":"
        ]
        text = String(text.map { maps[$0] ?? $0 })
        return text.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    /// 日期 / 时间 / 版本号 / 纯符号行：一律不参与解析。
    static func isNoise(_ line: String) -> Bool {
        let patterns = [
            #"\d{4}[-/年.]\d{1,2}[-/月.]\d{1,2}"#,       // 2026-10-25 / 2026年10月25日
            #"\d{1,2}:\d{2}(:\d{2})?"#,                   // 18:32 / 18:32:05
            #"v?\d+\.\d+\.\d+"#,                          // v2.12.0
            #"^\d{4,}$"#                                  // 孤立的长数字（多半是日期压缩）
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    static func hasAny(_ keywords: [String], in line: String) -> Bool {
        let lower = line.lowercased()
        return keywords.contains { lower.contains($0.lowercased()) }
    }

    static func firstNumber(in line: String) -> Int? {
        guard let range = line.range(of: #"\d{1,3}(?:,\d{3})+|\d+"#, options: .regularExpression) else {
            return nil
        }
        let digits = line[range].replacingOccurrences(of: ",", with: "")
        return Int(digits)
    }

    /// 关键字后 `keywordProximity` 个字符内的第一个数字。
    static func number(afterAnyOf keywords: [String], in line: String) -> Int? {
        let lower = line.lowercased()
        var best: (position: Int, value: Int)?
        for keyword in keywords {
            guard let keywordRange = lower.range(of: keyword.lowercased()) else { continue }
            let tail = lower[keywordRange.upperBound...]
            let window = tail.prefix(keywordProximity)
            guard let number = firstNumber(in: String(window)) else { continue }
            let position = lower.distance(from: lower.startIndex, to: keywordRange.lowerBound)
            if best == nil || position < best!.position {
                best = (position, number)
            }
        }
        return best?.value
    }

    /// `X/Y`、`XofY`、`X/Y字` 形状的比例。
    static func ratio(in line: String) -> (first: Int, second: Int)? {
        let patterns = [
            #"(\d{1,3}(?:,\d{3})+|\d+)/(\d{1,3}(?:,\d{3})+|\d+)"#,
            #"(\d{1,3}(?:,\d{3})+|\d+)of(\d{1,3}(?:,\d{3})+|\d+)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard match.numberOfRanges >= 3,
                      let firstRange = Range(match.range(at: 1), in: line),
                      let secondRange = Range(match.range(at: 2), in: line),
                      let first = Int(line[firstRange].replacingOccurrences(of: ",", with: "")),
                      let second = Int(line[secondRange].replacingOccurrences(of: ",", with: "")),
                      second > 0, first <= second,
                      plausibleTotalRange.contains(second)
                else { continue }
                return (first, second)
            }
        }
        return nil
    }
}
