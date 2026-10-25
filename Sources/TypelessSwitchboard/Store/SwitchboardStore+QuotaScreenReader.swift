import Foundation
import CoreGraphics
import Vision

/// v2.7.5：读屏取 Typeless 官方窗口上的「本周剩余字数」。
///
/// 背景：官方额度 API 自 2026-10-14 被 Cloudflare 指纹墙挡死（HTTP 418），App 读不到实时剩余；
/// 而 Typeless 自己的浏览器内核能过墙，界面上显示的是**活**的剩余。Electron 的 Accessibility
/// 对 Web 内容暴露极差（整页往往只是一个 AX 节点），故改用「窗口截图 + Vision OCR」取数，
/// 比 AX 可靠得多。
///
/// 取数失败（未授予屏幕录制权限 / Typeless 窗口不可见 / 解析失败）返回 nil，调用方回退到原有降级逻辑。
extension SwitchboardStore {

    /// 定位 Typeless 窗口并截图 + OCR，解析出本周剩余字数。
    func readTypelessOnScreenQuota() async -> Int? {
        // 1) 定位 Typeless 窗口（按进程名 "Typeless"）。
        let windowID = Self.typelessWindowID()
        guard let windowID else {
            lastScreenQuotaRawText = "(未找到 Typeless 窗口：App 未运行或未授予辅助功能/屏幕录制权限)"
            return nil
        }

        // 2) 截该窗口的图。无屏幕录制权限时这里直接返回 nil。
        guard let cgImage = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            lastScreenQuotaRawText = "(截图失败：可能未授予「屏幕录制」权限，或该窗口不可见)"
            return nil
        }

        // 3) Vision OCR（中英混合，开语言纠错提升「字/额度」类识别）。
        let texts: [String]
        do {
            texts = try Self.ocrImage(cgImage)
        } catch {
            lastScreenQuotaRawText = "(OCR 失败：\(error.localizedDescription))"
            return nil
        }

        // 4) 启发式解析本周剩余。保留原始文本供排错/调参。
        let joined = texts.joined(separator: "\n")
        let parsed = Self.parseWeeklyRemaining(from: texts)
        lastScreenQuotaRawText = joined.isEmpty ? "(OCR 未识别出任何文本)" : joined
        lastScreenQuotaParsed = parsed
        return parsed
    }

    /// 在屏幕上找到 owner 名为 "Typeless" 的窗口 ID。
    private static func typelessWindowID() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for dict in list {
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Typeless", let num = dict[kCGWindowNumber as String] as? Int {
                return CGWindowID(num)
            }
        }
        return nil
    }

    /// 对 CGImage 跑 Vision 文本识别，返回每个观测的最优候选文本。
    private static func ocrImage(_ cgImage: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// 从 OCR 文本里挑「本周剩余字数」。
    ///
    /// 优先级：
    /// 1. 带额度关键字的行里的数字（本周/剩余/可用/额度…），关键字越靠前权重越高；
    /// 2. 「X / Y」「X of Y」比例式里的 X（剩余），要求 X ≤ Y；
    /// 3. 整屏只有一个数字时取它。
    /// 都取不到返回 nil（调用方回退）。原始文本已存入 lastScreenQuotaRawText 供调参。
    private static func parseWeeklyRemaining(from texts: [String]) -> Int? {
        let keywords = [
            "本周剩余", "剩余", "还剩", "可用", "本周可用", "本周额度", "周额度", "额度",
            "本周", "left", "remaining", "available", "quota", "week", "used",
        ]

        // 1) 关键字近邻数字（行内）。
        var best: (value: Int, score: Int)?
        for line in texts {
            let ln = line.replacingOccurrences(of: " ", with: "")
            guard let num = firstInt(in: ln) else { continue }
            var score = 0
            for (idx, kw) in keywords.enumerated() {
                if ln.contains(kw) {
                    // 越靠前的关键字权重越高（剩余/可用 优先于 额度/本周）。
                    score = max(score, keywords.count - idx)
                }
            }
            if score > 0, best == nil || score > best!.score {
                best = (num, score)
            }
        }
        if let best { return best.value }

        // 2) 比例式 X / Y（去空格后匹配，避免误伤日期「2026/10/25」——其 X>Y 会被下面 ≤Y 过滤）。
        let joinedNoSpace = texts.joined(separator: "").replacingOccurrences(of: " ", with: "")
        if let ratio = firstRatio(in: joinedNoSpace), ratio.remaining <= ratio.total {
            return ratio.remaining
        }

        // 3) 全屏恰只有一个数字。
        let allNums = texts.compactMap { firstInt(in: $0.replacingOccurrences(of: " ", with: "")) }
        if allNums.count == 1 { return allNums[0] }

        return nil
    }

    /// 取字符串里第一个整数（自动去掉千分位逗号，如 "1,234" → 1234）。
    private static func firstInt(in s: String) -> Int? {
        let digits = s.filter { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 匹配第一个「剩余/总量」比例对，返回 (remaining, total)。
    private static func firstRatio(in s: String) -> (remaining: Int, total: Int)? {
        // 形如 1234/2000 或 1234of2000；容错千分位。
        let pattern = #"(\d{1,3}(?:,\d{3})*)\s*[/／]\s*(\d{1,4}(?:,\d{3})*)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let rRange = Range(m.range(at: 1), in: s),
              let tRange = Range(m.range(at: 2), in: s) else { return nil }
        let rStr = String(s[rRange]).filter { $0.isNumber }
        let tStr = String(s[tRange]).filter { $0.isNumber }
        guard let r = Int(rStr), let t = Int(tStr) else { return nil }
        return (r, t)
    }
}
