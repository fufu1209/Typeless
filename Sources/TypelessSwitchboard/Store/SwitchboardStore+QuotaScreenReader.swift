import Foundation
import CoreGraphics
import Vision
import TypelessSwitchboardCore

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

        // 4) 解析本周剩余（v2.8.0：解析器搬到 Core，纯函数、可被测试直接覆盖）。
        //    保留原始文本与命中行，供排错/调参。
        let joined = texts.joined(separator: "\n")
        let parsed = QuotaScreenTextParser.parse(from: texts)
        lastScreenQuotaRawText = joined.isEmpty ? "(OCR 未识别出任何文本)" : joined
        lastScreenQuotaParsed = parsed?.remaining
        if let parsed {
            lastScreenQuotaRawText += "\n[解析] 剩余 \(parsed.remaining)"
                + (parsed.total.map { " / 上限 \($0)" } ?? "")
                + " · 置信度 \(String(format: "%.2f", parsed.confidence))"
                + " · 命中：\(parsed.matchedText)"
        }
        return parsed?.remaining
    }

    /// 在屏幕上找到 owner 名为 "Typeless" 的窗口 ID。
    ///
    /// v2.8.0：不再「拿到第一个就用」。Typeless 同时会有浮动条、欢迎页、主窗口等多个
    /// 窗口，浮条上根本没有额度数字 —— 旧逻辑一旦先命中浮条，OCR 只会读到模型名，
    /// 于是永远解析失败。现在只认「普通窗口层 + 面积最大」的那个。
    private static func typelessWindowID() -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: (id: CGWindowID, area: Double)?
        for dict in list {
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""
            guard owner == "Typeless" else { continue }
            let layer = dict[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let num = dict[kCGWindowNumber as String] as? Int else { continue }
            let boundsDict = dict[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = (boundsDict["Width"] as? Double) ?? 0
            let height = (boundsDict["Height"] as? Double) ?? 0
            let area = width * height
            // 太小的窗口（浮条 / 提示气泡）直接排除。
            guard width >= 320, height >= 240 else { continue }
            if best == nil || area > best!.area {
                best = (CGWindowID(num), area)
            }
        }
        return best?.id
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
}
