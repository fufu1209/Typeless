import Foundation

// MARK: - v2.8.0：额度直读桥（CDP）
//
// 背景（2026-11-17 本机实测，Typeless 2.12.0 / Electron 43.8.4 / Chrome 150）：
//
//   * `POST https://api.typeless.com/user/usage_stats` 现在有两道门：
//       ① 客户端签名（`This client is not supported` / code 20006）；
//       ② **JA3/TLS 指纹白名单**（Node 的 OpenSSL 握手直接 418 + `ja3_tls_code`）。
//     所以「外部进程自己发请求」这条路是**结构性死亡**，换密钥也救不回来 ——
//     `extract-active-session.js` 能把签名算对（2.12.0 的密钥仍能按形状提取），
//     但 TLS 握手在签名被看到之前就被拒了。
//
//   * Typeless 自己的渲染进程（Electron/Chromium）当然能过这两道门。而它页面上
//     那个 API 客户端是**可被页面自己 import 的 ES 模块**：
//         const m = await import('…/static/js/fw3XiDt9.js');
//         await m.y.post('/user/usage_stats', { params: {} });
//     拿到的就是 App 界面上显示的同一份真实数据（week_word_usage_value / _limit）。
//
//   * 前提只是 App 带 `--remote-debugging-port=PORT` 启动。本机实测：直接执行
//     `/Applications/Typeless.app/Contents/MacOS/Typeless --remote-debugging-port=9333`
//     即可（v2.7.x 文档里「启动器拒绝该参数」的结论是**误判** —— 当时的终端里
//     继承了 `ELECTRON_RUN_AS_NODE=1`，Electron 因此退化成 node 解释器，
//     `--remote-debugging-port` 被 node 当成非法选项拒绝）。
//
// 因此 v2.8.0 的额度链路改为：**CDP 直读（首选）→ 官方 API（历史路径，基本已死）
// → 读屏 OCR（兜底）→ 本地缓存（最后）**。CDP 一次读取约 0.2–0.8 秒，
// 不需要任何系统权限，不弹窗，不改动 App 界面。

/// 额度数字的来源。UI 必须显式标注，避免把「估算」当成「实测」。
public enum TypelessQuotaSource: String, Codable, Equatable, Sendable, CaseIterable {
    /// 通过 Typeless 渲染进程自己的 API 客户端直读（v2.8.0 首选）。
    case cdpBridge = "cdp"
    /// 官方 `/user/usage_stats`（Node 直连；2026-10 起被 JA3 墙挡死）。
    case officialAPI = "api"
    /// 截屏 + Vision OCR 读界面上的剩余字数（无 CDP 时的兜底）。
    case screenOCR = "ocr"
    /// 上次成功同步留下的缓存值（可能陈旧）。
    case cached = "cache"

    public var displayName: String {
        switch self {
        case .cdpBridge: return "CDP 直读"
        case .officialAPI: return "官方接口"
        case .screenOCR: return "读屏 OCR"
        case .cached: return "本地缓存"
        }
    }

    /// 这个来源的数字能否直接驱动「低于阈值就换号」。
    public var isLive: Bool {
        switch self {
        case .cdpBridge, .officialAPI: return true
        case .screenOCR, .cached: return false
        }
    }
}

/// 一次额度读数（与来源一起传递，绝不把来源丢掉）。
public struct TypelessQuotaSnapshot: Codable, Equatable, Sendable {
    public var email: String?
    public var userID: String?
    public var usedCharacters: Int
    public var weeklyLimit: Int
    public var averageWordsPerMinute: Double?
    public var minutesSaved: Double?
    public var capturedAt: Date
    public var source: TypelessQuotaSource
    /// 命中的渲染进程 chunk 文件名（排错用：版本升级后第一个变化的就是它）。
    public var clientChunk: String?

    public init(
        email: String? = nil,
        userID: String? = nil,
        usedCharacters: Int,
        weeklyLimit: Int,
        averageWordsPerMinute: Double? = nil,
        minutesSaved: Double? = nil,
        capturedAt: Date = Date(),
        source: TypelessQuotaSource = .cdpBridge,
        clientChunk: String? = nil
    ) {
        self.email = email
        self.userID = userID
        self.usedCharacters = usedCharacters
        self.weeklyLimit = weeklyLimit
        self.averageWordsPerMinute = averageWordsPerMinute
        self.minutesSaved = minutesSaved
        self.capturedAt = capturedAt
        self.source = source
        self.clientChunk = clientChunk
    }

    public var remainingCharacters: Int {
        max(weeklyLimit - usedCharacters, 0)
    }

    /// 一行摘要（不含任何令牌）。
    public var summary: String {
        "已用 \(usedCharacters)/\(weeklyLimit)，剩余 \(remainingCharacters)（\(source.displayName)）"
    }
}

/// 渲染进程返回的原始探针结果（对应 `TypelessQuotaBridge.probeExpression` 的 JSON）。
public struct TypelessQuotaProbe: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var used: Int?
    public var limit: Int?
    public var wpm: Double?
    public var minsSaved: Double?
    public var email: String?
    public var userId: String?
    public var chunk: String?
    public var error: String?
    public var tried: Int?

    public init(
        ok: Bool,
        used: Int? = nil,
        limit: Int? = nil,
        wpm: Double? = nil,
        minsSaved: Double? = nil,
        email: String? = nil,
        userId: String? = nil,
        chunk: String? = nil,
        error: String? = nil,
        tried: Int? = nil
    ) {
        self.ok = ok
        self.used = used
        self.limit = limit
        self.wpm = wpm
        self.minsSaved = minsSaved
        self.email = email
        self.userId = userId
        self.chunk = chunk
        self.error = error
        self.tried = tried
    }
}

/// CDP 桥的纯逻辑（可用测试直接覆盖，不依赖网络）。
public enum TypelessQuotaBridge {
    /// 默认调试端口。9333 不常见，避免撞上 9222（很多 Electron 工具默认用它）。
    public static let defaultPort = 9333

    /// 端口合法区间：1024–65535（1024 以下需要 root，普通用户绑不上）。
    public static func normalizePort(_ value: Int) -> Int {
        guard value >= 1024, value <= 65535 else { return defaultPort }
        return value
    }

    public static func versionURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(normalizePort(port))/json/version")!
    }

    public static func listURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(normalizePort(port))/json/list")!
    }

    /// 从 `/json/list` 里挑一个可用的页面。
    ///
    /// 优先级：floating-bar（常驻、不遮挡、不打断听写）> hub > 任意 Typeless 页面。
    /// 只看 `file://…/Typeless.app/…` 的页面，避免误连到别的 Electron 应用。
    public struct CDPTarget: Equatable, Sendable {
        public var id: String
        public var url: String
        public var webSocketDebuggerURL: String
        public var title: String?

        public init(id: String, url: String, webSocketDebuggerURL: String, title: String? = nil) {
            self.id = id
            self.url = url
            self.webSocketDebuggerURL = webSocketDebuggerURL
            self.title = title
        }

        /// 是否是 Typeless 的渲染页面。
        public var isTypelessRenderer: Bool {
            url.contains("app.asar")
        }

        public var pageRole: String {
            if url.contains("floating-bar.html") { return "floating-bar" }
            if url.contains("hub.html") { return "hub" }
            if url.contains("onboarding.html") { return "onboarding" }
            return "page"
        }
    }

    /// 解析 `/json/list` 响应。
    public static func decodeTargets(_ data: Data) -> [CDPTarget] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let array = object as? [[String: Any]]
        else { return [] }

        return array.compactMap { item -> CDPTarget? in
            guard
                (item["type"] as? String) == "page",
                let id = item["id"] as? String,
                let url = item["url"] as? String,
                let ws = item["webSocketDebuggerUrl"] as? String,
                ws.hasPrefix("ws://")
            else { return nil }
            return CDPTarget(id: id, url: url, webSocketDebuggerURL: ws, title: item["title"] as? String)
        }
    }

    /// 从候选里挑一个：floating-bar 优先，其次 hub，最后任意 Typeless 页面。
    public static func preferredTarget(in targets: [CDPTarget]) -> CDPTarget? {
        let typeless = targets.filter { $0.url.contains("app.asar") }
        guard !typeless.isEmpty else { return nil }
        return typeless.first { $0.pageRole == "floating-bar" }
            ?? typeless.first { $0.pageRole == "hub" }
            ?? typeless.first
    }

    /// 过滤出渲染进程里「可能导出 API 客户端」的 chunk URL。
    ///
    /// 页面上的 `link[rel=modulepreload]` 就是 Vite 预载的全部 chunk；
    /// 这条路径不需要开 Debugger，对 App 的干扰最小（v2.8.0 实测可命中）。
    public static func normalizedScriptURLs(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { raw -> String? in
            let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard url.hasPrefix("file://"), url.contains("app.asar") else { return nil }
            guard url.hasSuffix(".js") || url.hasSuffix(".mjs") else { return nil }
            // i18n / 图标等资源不可能导出 API 客户端，先剔掉，少 import 几个模块。
            guard !url.contains("/static/locales/") else { return nil }
            guard seen.insert(url).inserted else { return nil }
            return url
        }
    }

    /// 注入渲染进程的探针表达式。
    ///
    /// 行为：
    ///   1. 收集 `link[rel=modulepreload]` 的 chunk URL（外加调用方补的 URL）；
    ///   2. 逐个 `import()`，找出「带 `post` + `buildUrl` 的导出对象」——那就是 App 自己的
    ///      API 客户端（版本升级后它的导出名会变，所以按**形状**识别，不硬编码 `y`）；
    ///   3. 用 App 自己的客户端请求 `/user/usage_stats`（签名、Cookie、TLS 全是 App 的）；
    ///   4. 顺带读 `auth:get-current` 拿邮箱 / user_id（只取这两个字段，**不返回任何令牌**）。
    ///
    /// 返回的是一个 **JSON 字符串**（而不是对象），避免 CDP 的 `returnByValue`
    /// 在跨进程序列化时把 React 内部结构一起搬过来。
    public static func probeExpression(extraScriptURLs: [String] = []) -> String {
        let extraJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: normalizedScriptURLs(extraScriptURLs), options: []),
           let text = String(data: data, encoding: .utf8) {
            extraJSON = text
        } else {
            extraJSON = "[]"
        }

        return #"""
        (async () => {
          const out = { ok: false, error: 'no-client', tried: 0 };
          try {
            const urls = Array.from(new Set([
              ...Array.from(document.querySelectorAll('link[rel="modulepreload"]')).map(l => l.href),
              ...Array.from(document.querySelectorAll('script[src]')).map(s => s.src),
              ...\#(extraJSON)
            ])).filter(u => typeof u === 'string' && u.startsWith('file:') && u.includes('app.asar')
                        && /\.(js|mjs)$/.test(u) && !u.includes('/static/locales/'));

            for (const u of urls) {
              out.tried++;
              let mod;
              try { mod = await import(u); } catch (e) { continue; }
              for (const k of Object.keys(mod)) {
                const client = mod[k];
                if (!client || typeof client !== 'object') continue;
                if (typeof client.post !== 'function' || typeof client.buildUrl !== 'function') continue;
                try {
                  const resp = await client.post('/user/usage_stats', { params: {} });
                  const quota = resp && resp.success && resp.data && resp.data.data && resp.data.data.voice_transcription;
                  if (!quota) { out.error = 'no-quota'; continue; }
                  let auth = null;
                  try { auth = await window.ipcRenderer.invoke('auth:get-current'); } catch (e) { auth = null; }
                  return JSON.stringify({
                    ok: true,
                    used: Number(quota.week_word_usage_value || 0),
                    limit: Number(quota.week_word_usage_limit || 0),
                    wpm: typeof quota.avg_wpm === 'number' ? quota.avg_wpm : null,
                    minsSaved: typeof quota.mins_saved === 'number' ? quota.mins_saved : null,
                    email: (auth && typeof auth.email === 'string') ? auth.email : null,
                    userId: (auth && typeof auth.user_id === 'string') ? auth.user_id : null,
                    chunk: u.split('/').pop(),
                    tried: out.tried
                  });
                } catch (e) {
                  out.error = String((e && e.message) || e).slice(0, 160);
                }
              }
            }
          } catch (e) {
            out.error = String((e && e.message) || e).slice(0, 160);
          }
          return JSON.stringify(out);
        })()
        """#
    }

    /// 解析探针返回的 JSON 字符串。
    public static func decodeProbe(
        _ raw: String,
        capturedAt: Date = Date(),
        source: TypelessQuotaSource = .cdpBridge
    ) -> TypelessQuotaSnapshot? {
        guard let data = raw.data(using: .utf8),
              let probe = try? JSONDecoder().decode(TypelessQuotaProbe.self, from: data),
              probe.ok,
              let used = probe.used,
              let limit = probe.limit,
              limit > 0,
              used >= 0,
              used <= limit * 10 // 明显的脏数据（单位错误 / 串号）不接受
        else { return nil }

        return TypelessQuotaSnapshot(
            email: probe.email?.nilIfBlank,
            userID: probe.userId?.nilIfBlank,
            usedCharacters: used,
            weeklyLimit: limit,
            averageWordsPerMinute: probe.wpm,
            minutesSaved: probe.minsSaved,
            capturedAt: capturedAt,
            source: source,
            clientChunk: probe.chunk
        )
    }

    /// 解析官方 `/user/usage_stats` 的响应体（`extract-active-session.js` 也会产出同形状）。
    /// 保留这个入口是为了：① 兼容仍能连通的旧环境；② 让测试能直接喂真实报文。
    public static func decodeUsageStatsBody(
        _ body: String,
        capturedAt: Date = Date(),
        source: TypelessQuotaSource = .officialAPI
    ) -> TypelessQuotaSnapshot? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // 既接受线上响应 {status,data:{voice_transcription:{...}}}，
        // 也接受脚本包装过的 {success:true,data:{data:{voice_transcription:{...}}}}。
        func findVoice(_ node: Any?) -> [String: Any]? {
            guard let dict = node as? [String: Any] else { return nil }
            if let voice = dict["voice_transcription"] as? [String: Any] { return voice }
            for key in ["data", "result"] {
                if let inner = dict[key], let found = findVoice(inner) { return found }
            }
            return nil
        }

        guard let voice = findVoice(object),
              let used = intValue(voice["week_word_usage_value"]),
              let limit = intValue(voice["week_word_usage_limit"]),
              limit > 0
        else { return nil }

        return TypelessQuotaSnapshot(
            usedCharacters: used,
            weeklyLimit: limit,
            averageWordsPerMinute: doubleValue(voice["avg_wpm"]),
            minutesSaved: doubleValue(voice["mins_saved"]),
            capturedAt: capturedAt,
            source: source
        )
    }

    /// 日志脱敏：把 JWT 抹掉后再写盘。额度链路会顺手读到 access/refresh token，
    /// 以前只在内存里，现在要确保任何异常路径都不把它们写进日志。
    public static func redactSecrets(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        let patterns = [
            // JWT（三段 base64url）
            #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
            // 40–64 位十六进制密钥（Typeless 2.12.0 的客户端签名密钥实测 56 位）
            #"\b[0-9a-f]{40,64}\b"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<redacted>")
            }
        }
        return result
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}

extension String {
    /// 去掉首尾空白后为空则返回 nil。
    public var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
